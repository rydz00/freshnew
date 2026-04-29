#!/usr/bin/env bash
# =============================================================================
# glacier_backup.sh — Incremental backup to AWS S3 (Glacier storage class)
# Full backup: every 6 months | Incremental: weekly
# temp partition quota: 60GB
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Config ────────────────────────────────────────────────────────────────────
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/glacier-backup/config.sh"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/glacier-backup"
LOG_DIR="${STATE_DIR}/logs"
MANIFEST_DIR="${STATE_DIR}/manifests"
LOCK_FILE="/tmp/glacier-backup.lock"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%F %T')]${RESET} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${GREEN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE" >&2; }
die()  { err "$*"; exit 1; }

# ── Lock ──────────────────────────────────────────────────────────────────────
acquire_lock() {
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
        die "Another backup is already running (lock: $LOCK_FILE). Aborting."
    fi
    trap 'rmdir "$LOCK_FILE" 2>/dev/null; exit' INT TERM EXIT
}

# ── Load config ───────────────────────────────────────────────────────────────
load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE\nRun: glacier_backup.sh setup"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    : "${S3_BUCKET:?S3_BUCKET not set in config}"
    : "${S3_PREFIX:?S3_PREFIX not set in config}"
    : "${BACKUP_DIRS:?BACKUP_DIRS not set in config}"
    : "${AWS_PROFILE:?AWS_PROFILE not set in config}"

    export AWS_PROFILE
    FULL_CYCLE_DAYS="${FULL_CYCLE_DAYS:-180}"
    STORAGE_CLASS="${STORAGE_CLASS:-GLACIER}"        # or DEEP_ARCHIVE
    COMPRESS="${COMPRESS:-zstd}"                      # zstd | gzip | none
    MIN_FREE_GB="${MIN_FREE_GB:-60}"                  # minimum free disk to keep after each archive
    TMP_DIR="${TMP_DIR:-/tmp}"                        # where to write temp archives
    TMP_WORK_DIR="$TMP_DIR"                           # used by free_bytes()
    EXCLUDE_PATTERNS=("${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}")
}

# ── Setup ─────────────────────────────────────────────────────────────────────
cmd_setup() {
    echo -e "${BOLD}${BLUE}Glacier Backup — Interactive Setup${RESET}\n"

    mkdir -p "$(dirname "$CONFIG_FILE")" "$STATE_DIR" "$LOG_DIR" "$MANIFEST_DIR"

    read -rp "AWS profile name [default]: " aws_profile; aws_profile="${aws_profile:-default}"
    read -rp "S3 bucket name: " s3_bucket
    read -rp "S3 key prefix [backups/$(hostname)]: " s3_prefix; s3_prefix="${s3_prefix:-backups/$(hostname)}"
    read -rp "Directories to back up (space-separated): " -a backup_dirs
    read -rp "Full backup cycle in days [90]: " cycle; cycle="${cycle:-90}"
    read -rp "Storage class (GLACIER/DEEP_ARCHIVE) [GLACIER]: " storage; storage="${storage:-GLACIER}"
    read -rp "Compression (zstd/gzip/none) [zstd]: " compress; compress="${compress:-zstd}"
    read -rp "Minimum free disk to keep after each archive in GB [60]: " min_free; min_free="${min_free:-60}"
    read -rp "Temp directory for archives [/tmp]: " tmp_dir; tmp_dir="${tmp_dir:-/tmp}"

    cat > "$CONFIG_FILE" <<EOF
# Glacier Backup Configuration — generated $(date)
AWS_PROFILE="${aws_profile}"
S3_BUCKET="${s3_bucket}"
S3_PREFIX="${s3_prefix}"
BACKUP_DIRS=($(printf '"%s" ' "${backup_dirs[@]}"))
FULL_CYCLE_DAYS=${cycle}
STORAGE_CLASS="${storage}"
COMPRESS="${compress}"

# Disk space management
# Archive one directory at a time; abort if free space would drop below this.
MIN_FREE_GB=${min_free}
# Temp directory where archives are written before upload (then immediately deleted)
TMP_DIR="${tmp_dir}"

# Optional exclude patterns (rsync-style globs)
EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.swp"
    ".cache/"
    "node_modules/"
    "__pycache__/"
    ".Trash/"
)
EOF

    chmod 600 "$CONFIG_FILE"
    echo -e "\n${GREEN}Config written to: $CONFIG_FILE${RESET}"
    echo -e "Run ${BOLD}glacier_backup.sh run${RESET} to start your first backup."
}

# ── Determine backup type ─────────────────────────────────────────────────────
needs_full_backup() {
    local state_file="${STATE_DIR}/last_full_backup"
    [[ ! -f "$state_file" ]] && return 0

    local last_full; last_full=$(cat "$state_file")
    local days_since=$(( ( $(date +%s) - last_full ) / 86400 ))
    info "Days since last full backup: ${days_since} (full every ${FULL_CYCLE_DAYS} days)"
    (( days_since >= FULL_CYCLE_DAYS ))
}

# ── Build tar/rsync exclude args ─────────────────────────────────────────────
build_excludes() {
    local -a args=()
    for pat in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
        args+=(--exclude="$pat")
    done
    echo "${args[@]+"${args[@]}"}"
}

# ── Compress a tar archive ────────────────────────────────────────────────────
compress_ext() {
    case "$COMPRESS" in
        zstd) echo "tar.zst" ;;
        gzip) echo "tar.gz"  ;;
        *)    echo "tar"     ;;
    esac
}

compress_flag() {
    case "$COMPRESS" in
        zstd) echo "--use-compress-program=zstd" ;;
        gzip) echo "-z" ;;
        *)    echo ""   ;;
    esac
}

# ── Disk space helpers ────────────────────────────────────────────────────────
# Returns free bytes on the filesystem containing TMP_WORK_DIR
free_bytes() {
    df --output=avail -B1 "${TMP_WORK_DIR:-/tmp}" | tail -1 | tr -d ' '
}

# Returns the disk usage (bytes) of a directory tree
dir_bytes() {
    du -sb "$1" 2>/dev/null | awk '{print $1}'
}

# Human-readable bytes (no numfmt dependency here)
human_bytes() {
    local b=$1
    if   (( b >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576    )); then printf "%.1f MB" "$(echo "scale=1; $b/1048576"    | bc)"
    else printf "%d KB" "$(( b / 1024 ))"
    fi
}

# Check we have at least MIN_FREE_GB free after the archive is written.
# $1 = estimated compressed size in bytes
check_disk_space() {
    local needed_bytes="$1"
    local free; free=$(free_bytes)
    local min_free_bytes=$(( MIN_FREE_GB * 1024 * 1024 * 1024 ))
    local required=$(( needed_bytes + min_free_bytes ))

    if (( free < required )); then
        die "Insufficient disk space for this archive.\n" \
            "  Available : $(human_bytes "$free")\n" \
            "  Needed    : $(human_bytes "$needed_bytes") + ${MIN_FREE_GB} GB headroom = $(human_bytes "$required")\n" \
            "  Tip: set a smaller TMP_DIR in config, or free up space first."
    fi
    info "Disk space OK — free: $(human_bytes "$free"), needed: $(human_bytes "$needed_bytes") + ${MIN_FREE_GB} GB headroom"
}

# Estimate compressed size: sample compress ratio from a small subset, apply to raw size.
# Falls back to raw_bytes * 0.6 if the dir is too small to sample.
estimate_compressed_size() {
    local src_dir="$1"
    local raw; raw=$(dir_bytes "$src_dir")

    # If less than 1 MB, just use raw size (tiny dirs compress fast; don't bother sampling)
    if (( raw < 1048576 )); then
        echo "$raw"
        return
    fi

    # Sample up to 32 MB of data, compress it, measure ratio
    local sample_raw sample_comp ratio
    sample_raw=$(tar -cf - --one-file-system "$src_dir" 2>/dev/null | head -c 33554432 | wc -c)
    if (( sample_raw < 1024 )); then
        echo "$(( raw * 6 / 10 ))"   # fallback: assume 60% of raw
        return
    fi

    case "$COMPRESS" in
        zstd) sample_comp=$(tar -cf - --one-file-system "$src_dir" 2>/dev/null | \
                            head -c 33554432 | zstd -q -3 | wc -c) ;;
        gzip) sample_comp=$(tar -cf - --one-file-system "$src_dir" 2>/dev/null | \
                            head -c 33554432 | gzip -1 -c | wc -c) ;;
        *)    sample_comp=$sample_raw ;;
    esac

    (( sample_comp < 1 )) && sample_comp=1
    # ratio as integer percentage (compressed / raw * 100), capped 1-100
    ratio=$(( sample_comp * 100 / sample_raw ))
    (( ratio < 1  )) && ratio=1
    (( ratio > 100 )) && ratio=100
    echo $(( raw * ratio / 100 ))
}

# ── Upload a file to S3 ───────────────────────────────────────────────────────
s3_upload() {
    local local_file="$1" s3_key="$2"
    info "Uploading → s3://${S3_BUCKET}/${s3_key}"
    aws s3 cp "$local_file" "s3://${S3_BUCKET}/${s3_key}" \
        --storage-class "$STORAGE_CLASS" \
        --no-progress
}

# ── Delete old full backup from S3 ───────────────────────────────────────────
delete_old_full() {
    local old_prefix="$1"
    warn "Deleting old full backup: s3://${S3_BUCKET}/${old_prefix}"
    aws s3 rm "s3://${S3_BUCKET}/${old_prefix}" --recursive
    info "Old full backup deleted."
}

# ── Full backup — one directory at a time ─────────────────────────────────────
run_full_backup() {
    local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S')
    local label="full_${timestamp}"
    local ext; ext=$(compress_ext)
    local cflag; cflag=$(compress_flag)
    local combined_manifest="${MANIFEST_DIR}/${label}.manifest"
    local total_bytes=0

    info "Starting FULL backup (label: ${label})"
    info "Processing ${#BACKUP_DIRS[@]} director(ies) one at a time (disk headroom: ${MIN_FREE_GB} GB)"

    # Capture old full label before overwriting state
    local old_full_label=""
    [[ -f "${STATE_DIR}/current_full_label" ]] && old_full_label=$(cat "${STATE_DIR}/current_full_label")

    local -a excludes; IFS=' ' read -ra excludes <<< "$(build_excludes)"

    # Combined manifest accumulates file lists from every directory archive
    : > "$combined_manifest"

    local dir_index=0
    for src_dir in "${BACKUP_DIRS[@]}"; do
        (( dir_index++ )) || true

        if [[ ! -d "$src_dir" ]]; then
            warn "[${dir_index}/${#BACKUP_DIRS[@]}] Skipping non-existent directory: ${src_dir}"
            continue
        fi

        # Sanitise directory path into a safe archive name segment
        local safe_name; safe_name=$(echo "$src_dir" | sed 's|^/||; s|/|_|g')
        local part_label="${label}__${safe_name}"
        local archive_name="${part_label}.${ext}"

        info "━━━ [${dir_index}/${#BACKUP_DIRS[@]}] ${src_dir} ━━━"

        # ── Estimate size & check disk space ──────────────────────────────────
        info "Estimating size of ${src_dir} ..."
        local est_bytes; est_bytes=$(estimate_compressed_size "$src_dir")
        info "Estimated compressed size: $(human_bytes "$est_bytes")"
        check_disk_space "$est_bytes"

        # ── Create archive in a fresh per-directory temp dir ──────────────────
        local tmp_dir; tmp_dir=$(mktemp -d --tmpdir="${TMP_DIR:-/tmp}" glacier-backup-XXXXXX)

        # Trap ensures temp dir is always cleaned up even on error
        local _tmp_cleanup="$tmp_dir"
        trap 'rm -rf "$_tmp_cleanup"; rmdir "$LOCK_FILE" 2>/dev/null; exit' INT TERM EXIT

        local archive="${tmp_dir}/${archive_name}"

        info "Archiving ${src_dir} → ${archive_name} ..."
        # shellcheck disable=SC2068
        tar ${cflag} -cf "$archive" \
            --one-file-system \
            ${excludes[@]+"${excludes[@]}"} \
            "$src_dir" \
            2>>"$LOG_FILE" || warn "tar exited with warnings for ${src_dir} (check log)"

        local actual_bytes; actual_bytes=$(stat -c%s "$archive")
        total_bytes=$(( total_bytes + actual_bytes ))
        info "Archive size: $(human_bytes "$actual_bytes")"

        # ── Generate per-directory manifest ───────────────────────────────────
        local part_manifest="${tmp_dir}/${part_label}.manifest"
        tar -tf "$archive" > "$part_manifest" 2>/dev/null || true
        # Append to combined manifest
        cat "$part_manifest" >> "$combined_manifest"

        # ── Upload archive + manifest ─────────────────────────────────────────
        local s3_archive_key="${S3_PREFIX}/${label}/parts/${archive_name}"
        local s3_manifest_key="${S3_PREFIX}/${label}/parts/${part_label}.manifest"

        s3_upload "$archive"       "$s3_archive_key"
        s3_upload "$part_manifest" "$s3_manifest_key"

        # ── Wipe temp dir immediately to reclaim disk ─────────────────────────
        rm -rf "$tmp_dir"
        info "Temp files removed. Free space: $(human_bytes "$(free_bytes)")"

        # Reset trap to plain lock-only cleanup now that tmp_dir is gone
        trap 'rmdir "$LOCK_FILE" 2>/dev/null; exit' INT TERM EXIT
    done

    # ── Upload combined manifest & metadata ───────────────────────────────────
    local meta_tmp; meta_tmp=$(mktemp)
    cat > "$meta_tmp" <<JSON
{
  "type": "full",
  "label": "${label}",
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "dirs": $(printf '%s\n' "${BACKUP_DIRS[@]}" | jq -R . | jq -sc .),
  "storage_class": "${STORAGE_CLASS}",
  "total_size_bytes": ${total_bytes},
  "parts": ${dir_index}
}
JSON
    s3_upload "$combined_manifest" "${S3_PREFIX}/${label}/manifest.txt"
    s3_upload "$meta_tmp"          "${S3_PREFIX}/${label}/meta.json"
    rm -f "$meta_tmp"

    # ── Update local state ────────────────────────────────────────────────────
    date +%s > "${STATE_DIR}/last_full_backup"
    echo "$label" > "${STATE_DIR}/current_full_label"
    date +%s  > "${STATE_DIR}/last_full_timestamp"
    cp "$combined_manifest" "${STATE_DIR}/last_full.manifest"

    # ── Delete previous full backup from S3 ───────────────────────────────────
    if [[ -n "$old_full_label" && "$old_full_label" != "$label" ]]; then
        delete_old_full "${S3_PREFIX}/${old_full_label}"
    fi

    info "Full backup complete: s3://${S3_BUCKET}/${S3_PREFIX}/${label}/ (total: $(human_bytes "$total_bytes"))"
    echo "$label"
}

# ── Incremental backup — one directory at a time ──────────────────────────────
run_incremental_backup() {
    local full_label; full_label=$(cat "${STATE_DIR}/current_full_label" 2>/dev/null) \
        || die "No full backup found. Run a full backup first."
    local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S')
    local label="incr_${timestamp}"
    local ext; ext=$(compress_ext)
    local cflag; cflag=$(compress_flag)
    local total_bytes=0

    info "Starting INCREMENTAL backup (label: ${label}, base: ${full_label})"
    info "Processing ${#BACKUP_DIRS[@]} director(ies) one at a time (disk headroom: ${MIN_FREE_GB} GB)"

    local -a excludes; IFS=' ' read -ra excludes <<< "$(build_excludes)"
    local combined_manifest="${MANIFEST_DIR}/${label}.manifest"
    : > "$combined_manifest"

    # Each directory has its own snapshot file so incremental tracking is per-dir
    local snapshot_base="${STATE_DIR}/snapshots"
    mkdir -p "$snapshot_base"

    local dir_index=0
    for src_dir in "${BACKUP_DIRS[@]}"; do
        (( dir_index++ )) || true

        if [[ ! -d "$src_dir" ]]; then
            warn "[${dir_index}/${#BACKUP_DIRS[@]}] Skipping non-existent directory: ${src_dir}"
            continue
        fi

        local safe_name; safe_name=$(echo "$src_dir" | sed 's|^/||; s|/|_|g')
        local part_label="${label}__${safe_name}"
        local archive_name="${part_label}.${ext}"
        # Per-directory snapshot file — persists between runs to track changes
        local snapshot_file="${snapshot_base}/${safe_name}.snar"

        info "━━━ [${dir_index}/${#BACKUP_DIRS[@]}] ${src_dir} ━━━"

        # ── Estimate changed data size & check disk space ─────────────────────
        # For incrementals, raw dir size is an upper bound; actual will be smaller
        local est_bytes; est_bytes=$(dir_bytes "$src_dir")
        info "Source size (upper bound for estimation): $(human_bytes "$est_bytes")"
        check_disk_space "$(( est_bytes * 6 / 10 ))"   # assume ~60% compressed

        # ── Create incremental archive ────────────────────────────────────────
        local tmp_dir; tmp_dir=$(mktemp -d --tmpdir="${TMP_DIR:-/tmp}" glacier-backup-XXXXXX)
        local _tmp_cleanup="$tmp_dir"
        trap 'rm -rf "$_tmp_cleanup"; rmdir "$LOCK_FILE" 2>/dev/null; exit' INT TERM EXIT

        local archive="${tmp_dir}/${archive_name}"

        info "Archiving changes in ${src_dir} → ${archive_name} ..."
        # shellcheck disable=SC2068
        tar ${cflag} -cf "$archive" \
            --listed-incremental="$snapshot_file" \
            --one-file-system \
            ${excludes[@]+"${excludes[@]}"} \
            "$src_dir" \
            2>>"$LOG_FILE" || warn "tar exited with warnings for ${src_dir}"

        local actual_bytes; actual_bytes=$(stat -c%s "$archive")
        total_bytes=$(( total_bytes + actual_bytes ))
        info "Archive size: $(human_bytes "$actual_bytes")"

        # ── Manifest ──────────────────────────────────────────────────────────
        local part_manifest="${tmp_dir}/${part_label}.manifest"
        tar -tf "$archive" > "$part_manifest" 2>/dev/null || true
        cat "$part_manifest" >> "$combined_manifest"

        # ── Upload archive, manifest, snapshot ───────────────────────────────
        local s3_base="${S3_PREFIX}/${full_label}/incrementals/${label}"
        s3_upload "$archive"       "${s3_base}__${safe_name}.${ext}"
        s3_upload "$part_manifest" "${s3_base}__${safe_name}.manifest"
        s3_upload "$snapshot_file" "${s3_base}__${safe_name}.snar"

        # ── Wipe temp dir immediately ─────────────────────────────────────────
        rm -rf "$tmp_dir"
        info "Temp files removed. Free space: $(human_bytes "$(free_bytes)")"
        trap 'rmdir "$LOCK_FILE" 2>/dev/null; exit' INT TERM EXIT
    done

    # ── Upload combined manifest & metadata ───────────────────────────────────
    local meta_tmp; meta_tmp=$(mktemp)
    cat > "$meta_tmp" <<JSON
{
  "type": "incremental",
  "label": "${label}",
  "base_full": "${full_label}",
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "storage_class": "${STORAGE_CLASS}",
  "total_size_bytes": ${total_bytes},
  "parts": ${dir_index}
}
JSON
    s3_upload "$combined_manifest" "${S3_PREFIX}/${full_label}/incrementals/${label}.manifest"
    s3_upload "$meta_tmp"          "${S3_PREFIX}/${full_label}/incrementals/${label}.meta.json"
    rm -f "$meta_tmp"

    info "Incremental backup complete — total uploaded: $(human_bytes "$total_bytes")"
    echo "$label"
}

# ── Main run entry point ──────────────────────────────────────────────────────
cmd_run() {
    acquire_lock
    load_config

    mkdir -p "$LOG_DIR" "$MANIFEST_DIR" "$STATE_DIR"
    LOG_FILE="${LOG_DIR}/backup_$(date '+%Y%m%d_%H%M%S').log"

    log "═══════════════════════════════════════════"
    log "  Glacier Backup starting on $(hostname)"
    log "═══════════════════════════════════════════"

    if needs_full_backup; then
        run_full_backup
    else
        run_incremental_backup
    fi

    log "Backup finished successfully."
}

# ── Force full backup ─────────────────────────────────────────────────────────
cmd_full() {
    acquire_lock
    load_config
    mkdir -p "$LOG_DIR" "$MANIFEST_DIR" "$STATE_DIR"
    LOG_FILE="${LOG_DIR}/backup_$(date '+%Y%m%d_%H%M%S').log"
    log "Forcing full backup..."
    run_full_backup
}

# ── List backups ──────────────────────────────────────────────────────────────
cmd_list() {
    load_config
    LOG_FILE="/dev/null"
    echo -e "\n${BOLD}${BLUE}Available Backups in s3://${S3_BUCKET}/${S3_PREFIX}/${RESET}\n"

    # List full backups
    local fulls
    fulls=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --profile "$AWS_PROFILE" | \
        awk '/PRE full_/ {print $2}' | tr -d '/')

    if [[ -z "$fulls" ]]; then
        echo "No backups found."
        return
    fi

    while IFS= read -r full; do
        local meta_raw
        meta_raw=$(aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${full}/meta.json" - \
            --profile "$AWS_PROFILE" 2>/dev/null || echo '{}')
        local ts; ts=$(echo "$meta_raw" | jq -r '.timestamp // "unknown"')
        local sz; sz=$(echo "$meta_raw" | jq -r '.size_bytes // 0')
        local sz_human; sz_human=$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")

        echo -e "  ${GREEN}${BOLD}● FULL${RESET}  ${full}"
        echo -e "      Date:  ${ts}"
        echo -e "      Size:  ${sz_human}"

        # List incrementals under this full
        local incrs
        incrs=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${full}/incrementals/" \
            --profile "$AWS_PROFILE" 2>/dev/null | \
            grep '\.meta\.json' | awk '{print $4}' | sed 's/\.meta\.json//' || true)

        if [[ -n "$incrs" ]]; then
            while IFS= read -r incr; do
                local imeta
                imeta=$(aws s3 cp \
                    "s3://${S3_BUCKET}/${S3_PREFIX}/${full}/incrementals/${incr}.meta.json" - \
                    --profile "$AWS_PROFILE" 2>/dev/null || echo '{}')
                local its; its=$(echo "$imeta" | jq -r '.timestamp // "unknown"')
                local isz; isz=$(echo "$imeta" | jq -r '.size_bytes // 0')
                local isz_h; isz_h=$(numfmt --to=iec "$isz" 2>/dev/null || echo "${isz}B")
                echo -e "    ${CYAN}  ↳ INCR${RESET}  ${incr}"
                echo -e "            Date:  ${its}"
                echo -e "            Size:  ${isz_h}"
            done <<< "$incrs"
        fi
        echo
    done <<< "$fulls"
}

# ── Browse / search files in a backup ────────────────────────────────────────
cmd_browse() {
    load_config
    LOG_FILE="/dev/null"
    local backup_label="${1:-}"
    local search_pattern="${2:-}"

    if [[ -z "$backup_label" ]]; then
        echo "Usage: glacier_backup.sh browse <full_label> [search_pattern]"
        echo "       (run 'list' to see available backups)"
        exit 1
    fi

    echo -e "\n${BOLD}Browsing:${RESET} ${backup_label}"

    local manifest_key="${S3_PREFIX}/${backup_label}/manifest.txt"
    local manifest_data
    manifest_data=$(aws s3 cp "s3://${S3_BUCKET}/${manifest_key}" - \
        --profile "$AWS_PROFILE" 2>/dev/null) \
        || die "Could not fetch manifest for ${backup_label}"

    if [[ -n "$search_pattern" ]]; then
        echo -e "${CYAN}Matching files (pattern: ${search_pattern}):${RESET}\n"
        echo "$manifest_data" | grep -i "$search_pattern" || echo "No matches found."
    else
        echo -e "${CYAN}Files in archive:${RESET}\n"
        echo "$manifest_data" | head -100
        local total; total=$(echo "$manifest_data" | wc -l)
        echo -e "\n... ${total} total entries. Use a search pattern to filter."
    fi

    # Also show incrementals manifests
    local incrs
    incrs=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${backup_label}/incrementals/" \
        --profile "$AWS_PROFILE" 2>/dev/null | \
        grep '\.manifest' | awk '{print $4}' || true)

    if [[ -n "$incrs" ]]; then
        echo -e "\n${BOLD}Incrementals under this full backup:${RESET}"
        while IFS= read -r incr_manifest; do
            local incr_label; incr_label="${incr_manifest%.manifest}"
            echo -e "\n  ${CYAN}↳ ${incr_label}${RESET}"
            local idata
            idata=$(aws s3 cp \
                "s3://${S3_BUCKET}/${S3_PREFIX}/${backup_label}/incrementals/${incr_manifest}" - \
                --profile "$AWS_PROFILE" 2>/dev/null)
            if [[ -n "$search_pattern" ]]; then
                echo "$idata" | grep -i "$search_pattern" || true
            else
                echo "$idata" | head -20
            fi
        done <<< "$incrs"
    fi
}

# ── Restore ───────────────────────────────────────────────────────────────────
cmd_restore() {
    load_config
    LOG_FILE="${LOG_DIR}/restore_$(date '+%Y%m%d_%H%M%S').log"

    local full_label="${1:-}"; local restore_dest="${2:-}"; local file_filter="${3:-}"

    if [[ -z "$full_label" || -z "$restore_dest" ]]; then
        echo "Usage: glacier_backup.sh restore <full_label> <dest_dir> [file_filter]"
        echo ""
        echo "  full_label   — the full_YYYYMMDD_HHMMSS label (from 'list')"
        echo "  dest_dir     — local directory to restore into"
        echo "  file_filter  — optional: only restore files matching this pattern"
        echo ""
        echo "NOTE: Glacier objects may require a restore initiation (see restore-init command)"
        exit 1
    fi

    mkdir -p "$restore_dest"
    local tmp_dir; tmp_dir=$(mktemp -d --tmpdir="${TMP_DIR:-/tmp}" glacier-restore-XXXXXX)
    local ext; ext=$(compress_ext)
    local xflag; xflag=$(compress_flag)

    log "Restoring full backup: ${full_label} → ${restore_dest}"

    # ── List all part archives under this full backup ─────────────────────────
    local parts
    parts=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${full_label}/parts/" \
        --profile "$AWS_PROFILE" 2>/dev/null | \
        grep "\.${ext}$" | sort | awk '{print $4}' || true)

    if [[ -z "$parts" ]]; then
        die "No archive parts found for ${full_label}. Has a Glacier restore been initiated?"
    fi

    while IFS= read -r part_file; do
        [[ -z "$part_file" ]] && continue
        info "Downloading part: ${part_file}"
        local part_key="${S3_PREFIX}/${full_label}/parts/${part_file}"

        # Check disk space before each download
        local part_size
        part_size=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$part_key" \
            --profile "$AWS_PROFILE" --query ContentLength --output text 2>/dev/null || echo 0)
        check_disk_space "$part_size"

        aws s3 cp "s3://${S3_BUCKET}/${part_key}" "${tmp_dir}/${part_file}" \
            --profile "$AWS_PROFILE"

        info "Extracting: ${part_file}"
        if [[ -n "$file_filter" ]]; then
            # shellcheck disable=SC2086
            tar ${xflag} -xf "${tmp_dir}/${part_file}" -C "$restore_dest" \
                --wildcards "*${file_filter}*" 2>>"$LOG_FILE" || warn "No matches in ${part_file}"
        else
            # shellcheck disable=SC2086
            tar ${xflag} -xf "${tmp_dir}/${part_file}" -C "$restore_dest" 2>>"$LOG_FILE"
        fi

        # Delete downloaded part immediately to free space before the next
        rm -f "${tmp_dir}/${part_file}"
        info "Part removed. Free space: $(human_bytes "$(free_bytes)")"
    done <<< "$parts"

    info "Full backup extracted."

    # ── Apply incrementals in order ───────────────────────────────────────────
    local incr_archives
    incr_archives=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${full_label}/incrementals/" \
        --profile "$AWS_PROFILE" 2>/dev/null | \
        grep "\.${ext}$" | sort | awk '{print $4}' || true)

    if [[ -n "$incr_archives" ]]; then
        info "Applying incremental backups..."
        while IFS= read -r incr_file; do
            [[ -z "$incr_file" ]] && continue
            info "Downloading incremental: ${incr_file}"
            local incr_key="${S3_PREFIX}/${full_label}/incrementals/${incr_file}"

            local incr_size
            incr_size=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$incr_key" \
                --profile "$AWS_PROFILE" --query ContentLength --output text 2>/dev/null || echo 0)
            check_disk_space "$incr_size"

            aws s3 cp "s3://${S3_BUCKET}/${incr_key}" "${tmp_dir}/${incr_file}" \
                --profile "$AWS_PROFILE"

            info "Applying: ${incr_file}"
            if [[ -n "$file_filter" ]]; then
                # shellcheck disable=SC2086
                tar ${xflag} -xf "${tmp_dir}/${incr_file}" -C "$restore_dest" \
                    --wildcards "*${file_filter}*" 2>>"$LOG_FILE" || true
            else
                # shellcheck disable=SC2086
                tar ${xflag} -xf "${tmp_dir}/${incr_file}" -C "$restore_dest" 2>>"$LOG_FILE"
            fi

            rm -f "${tmp_dir}/${incr_file}"
            info "Incremental removed. Free space: $(human_bytes "$(free_bytes)")"
        done <<< "$incr_archives"
    fi

    rm -rf "$tmp_dir"
    info "Restore complete → ${restore_dest}"
}

# ── Glacier restore initiation ────────────────────────────────────────────────
cmd_restore_init() {
    load_config
    LOG_FILE="/dev/null"
    local full_label="${1:-}"; local tier="${2:-Bulk}"

    [[ -z "$full_label" ]] && { echo "Usage: glacier_backup.sh restore-init <full_label> [Bulk|Standard|Expedited]"; exit 1; }

    echo -e "${YELLOW}Initiating Glacier restore for: ${full_label} (Tier: ${tier})${RESET}"
    echo "Note: Bulk=5-12h, Standard=3-5h, Expedited=1-5min (higher cost)"

    local ext; ext=$(compress_ext)

    # Initiate restore on every part archive
    local parts
    parts=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${full_label}/parts/" \
        --profile "$AWS_PROFILE" 2>/dev/null | \
        grep "\.${ext}$" | awk '{print $4}' || true)

    if [[ -z "$parts" ]]; then
        warn "No part archives found — has this backup been created yet?"
        return 1
    fi

    while IFS= read -r part; do
        [[ -z "$part" ]] && continue
        aws s3api restore-object \
            --bucket "$S3_BUCKET" \
            --key "${S3_PREFIX}/${full_label}/parts/${part}" \
            --restore-request "Days=7,GlacierJobParameters={Tier=${tier}}" \
            --profile "$AWS_PROFILE" \
            && echo "Restore initiated: ${part}"
    done <<< "$parts"
}

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
    load_config
    LOG_FILE="/dev/null"
    echo -e "\n${BOLD}${BLUE}Glacier Backup Status${RESET}\n"

    local last_full_ts; last_full_ts=$(cat "${STATE_DIR}/last_full_timestamp" 2>/dev/null || echo 0)
    local current_full; current_full=$(cat "${STATE_DIR}/current_full_label" 2>/dev/null || echo "none")

    if (( last_full_ts > 0 )); then
        local days_since=$(( ( $(date +%s) - last_full_ts ) / 86400 ))
        local days_until=$(( FULL_CYCLE_DAYS - days_since ))
        echo -e "  Current full backup : ${GREEN}${current_full}${RESET}"
        echo -e "  Days since full     : ${days_since}"
        echo -e "  Next full backup in : ${days_until} day(s)"
    else
        echo -e "  ${YELLOW}No full backup recorded yet.${RESET}"
    fi

    echo -e "  S3 bucket           : s3://${S3_BUCKET}/${S3_PREFIX}"
    echo -e "  Storage class       : ${STORAGE_CLASS}"
    echo -e "  Backup directories  :"
    for d in "${BACKUP_DIRS[@]}"; do echo -e "    • ${d}"; done
    echo
}

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF

${BOLD}glacier_backup.sh${RESET} — Incremental Backup to AWS S3/Glacier

${BOLD}COMMANDS${RESET}
  setup                           Interactive configuration wizard
  run                             Auto-detect full vs incremental and run
  full                            Force a full backup immediately
  list                            List all backups in S3
  browse <full_label> [pattern]   Browse/search files in a backup
  restore <full_label> <dest> [filter]
                                  Restore a backup (full + all incrementals)
  restore-init <full_label> [tier]
                                  Initiate Glacier object retrieval (before restore)
  status                          Show current backup state

${BOLD}EXAMPLES${RESET}
  glacier_backup.sh setup
  glacier_backup.sh run
  glacier_backup.sh list
  glacier_backup.sh browse full_20250101_020000 ".conf"
  glacier_backup.sh restore-init full_20250101_020000 Bulk
  glacier_backup.sh restore full_20250101_020000 /mnt/restore ".conf"

${BOLD}SCHEDULING${RESET}
  Add to cron (weekly run, system decides full vs incremental):
    0 2 * * 0   /usr/local/bin/glacier_backup.sh run

EOF
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        setup)         cmd_setup ;;
        run)           cmd_run ;;
        full)          cmd_full ;;
        list)          cmd_list ;;
        browse)        cmd_browse "$@" ;;
        restore)       cmd_restore "$@" ;;
        restore-init)  cmd_restore_init "$@" ;;
        status)        cmd_status ;;
        help|--help|-h) usage ;;
        *) echo "Unknown command: ${cmd}"; usage; exit 1 ;;
    esac
}

main "$@"

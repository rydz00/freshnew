#!/usr/bin/env bash
# =============================================================================
# glacier_backup.sh — Incremental backup to AWS S3 (Glacier storage class)
# Full backup: every 3 months | Incremental: weekly
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
    FULL_CYCLE_DAYS="${FULL_CYCLE_DAYS:-90}"
    STORAGE_CLASS="${STORAGE_CLASS:-GLACIER}"        # or DEEP_ARCHIVE
    COMPRESS="${COMPRESS:-zstd}"                      # zstd | gzip | none
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

    cat > "$CONFIG_FILE" <<EOF
# Glacier Backup Configuration — generated $(date)
AWS_PROFILE="${aws_profile}"
S3_BUCKET="${s3_bucket}"
S3_PREFIX="${s3_prefix}"
BACKUP_DIRS=($(printf '"%s" ' "${backup_dirs[@]}"))
FULL_CYCLE_DAYS=${cycle}
STORAGE_CLASS="${storage}"
COMPRESS="${compress}"

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

# ── Full backup ───────────────────────────────────────────────────────────────
run_full_backup() {
    local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S')
    local label="full_${timestamp}"
    local ext; ext=$(compress_ext)
    local cflag; cflag=$(compress_flag)
    local tmp_dir; tmp_dir=$(mktemp -d)
    local manifest="${MANIFEST_DIR}/${label}.manifest"

    info "Starting FULL backup (label: ${label})"

    # Capture old full label before overwriting state
    local old_full_label=""
    [[ -f "${STATE_DIR}/current_full_label" ]] && old_full_label=$(cat "${STATE_DIR}/current_full_label")

    # Build archive of each directory
    local -a excludes; IFS=' ' read -ra excludes <<< "$(build_excludes)"
    local archive="${tmp_dir}/${label}.${ext}"

    # shellcheck disable=SC2068
    tar ${cflag} -cf "$archive" ${excludes[@]+"${excludes[@]}"} "${BACKUP_DIRS[@]}" \
        2>>"$LOG_FILE" || warn "tar exited with warnings (check log)"

    # Generate manifest (file list)
    tar -tf "$archive" > "$manifest" 2>/dev/null || true

    local s3_key="${S3_PREFIX}/${label}/${label}.${ext}"
    local manifest_key="${S3_PREFIX}/${label}/manifest.txt"

    s3_upload "$archive"   "$s3_key"
    s3_upload "$manifest"  "$manifest_key"

    # Upload metadata
    local meta="${tmp_dir}/meta.json"
    cat > "$meta" <<JSON
{
  "type": "full",
  "label": "${label}",
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "dirs": $(printf '%s\n' "${BACKUP_DIRS[@]}" | jq -R . | jq -sc .),
  "storage_class": "${STORAGE_CLASS}",
  "size_bytes": $(stat -c%s "$archive")
}
JSON
    s3_upload "$meta" "${S3_PREFIX}/${label}/meta.json"

    # Update state
    echo "$timestamp" > "${STATE_DIR}/last_full_backup"   # seconds for comparison
    date +%s > "${STATE_DIR}/last_full_backup"
    echo "$label" > "${STATE_DIR}/current_full_label"
    echo "$(date +%s)" > "${STATE_DIR}/last_full_timestamp"

    # Record for incremental reference
    cp "$manifest" "${STATE_DIR}/last_full.manifest"

    # Delete previous full backup from S3
    if [[ -n "$old_full_label" && "$old_full_label" != "$label" ]]; then
        delete_old_full "${S3_PREFIX}/${old_full_label}"
    fi

    rm -rf "$tmp_dir"
    info "Full backup complete: s3://${S3_BUCKET}/${S3_PREFIX}/${label}/"
    echo "$label"
}

# ── Incremental backup ────────────────────────────────────────────────────────
run_incremental_backup() {
    local full_label; full_label=$(cat "${STATE_DIR}/current_full_label" 2>/dev/null) \
        || die "No full backup found. Run a full backup first."
    local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S')
    local label="incr_${timestamp}"
    local ext; ext=$(compress_ext)
    local cflag; cflag=$(compress_flag)
    local tmp_dir; tmp_dir=$(mktemp -d)
    local snapshot_file="${STATE_DIR}/tar_snapshot.snar"

    info "Starting INCREMENTAL backup (label: ${label}, base: ${full_label})"

    local -a excludes; IFS=' ' read -ra excludes <<< "$(build_excludes)"
    local archive="${tmp_dir}/${label}.${ext}"

    # --listed-incremental makes tar track changes via snapshot file
    # shellcheck disable=SC2068
    tar ${cflag} -cf "$archive" \
        --listed-incremental="$snapshot_file" \
        ${excludes[@]+"${excludes[@]}"} \
        "${BACKUP_DIRS[@]}" \
        2>>"$LOG_FILE" || warn "tar exited with warnings"

    local manifest="${tmp_dir}/manifest.txt"
    tar -tf "$archive" > "$manifest" 2>/dev/null || true

    local s3_key="${S3_PREFIX}/${full_label}/incrementals/${label}.${ext}"
    local manifest_key="${S3_PREFIX}/${full_label}/incrementals/${label}.manifest"
    local snap_key="${S3_PREFIX}/${full_label}/incrementals/${label}.snar"

    s3_upload "$archive"        "$s3_key"
    s3_upload "$manifest"       "$manifest_key"
    s3_upload "$snapshot_file"  "$snap_key"

    local meta="${tmp_dir}/meta.json"
    cat > "$meta" <<JSON
{
  "type": "incremental",
  "label": "${label}",
  "base_full": "${full_label}",
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "storage_class": "${STORAGE_CLASS}",
  "size_bytes": $(stat -c%s "$archive")
}
JSON
    s3_upload "$meta" "${S3_PREFIX}/${full_label}/incrementals/${label}.meta.json"

    rm -rf "$tmp_dir"
    info "Incremental backup complete: s3://${S3_BUCKET}/${s3_key}"
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
    local tmp_dir; tmp_dir=$(mktemp -d)
    local ext; ext=$(compress_ext)

    log "Restoring full backup: ${full_label} → ${restore_dest}"

    # Download full archive
    local full_key="${S3_PREFIX}/${full_label}/${full_label}.${ext}"
    info "Downloading full archive..."
    aws s3 cp "s3://${S3_BUCKET}/${full_key}" "${tmp_dir}/full.${ext}" \
        --profile "$AWS_PROFILE"

    # Extract
    local xflag; xflag=$(compress_flag)
    if [[ -n "$file_filter" ]]; then
        info "Extracting files matching: ${file_filter}"
        # shellcheck disable=SC2086
        tar ${xflag} -xf "${tmp_dir}/full.${ext}" -C "$restore_dest" \
            --wildcards "*${file_filter}*" 2>>"$LOG_FILE" || warn "Some files may not have matched"
    else
        # shellcheck disable=SC2086
        tar ${xflag} -xf "${tmp_dir}/full.${ext}" -C "$restore_dest" 2>>"$LOG_FILE"
    fi

    info "Full backup extracted."

    # Apply incrementals in order
    local incrs
    incrs=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${full_label}/incrementals/" \
        --profile "$AWS_PROFILE" 2>/dev/null | \
        grep "\.${ext}$" | sort | awk '{print $4}' || true)

    if [[ -n "$incrs" ]]; then
        info "Applying incremental backups..."
        while IFS= read -r incr_file; do
            info "Applying: ${incr_file}"
            local incr_key="${S3_PREFIX}/${full_label}/incrementals/${incr_file}"
            aws s3 cp "s3://${S3_BUCKET}/${incr_key}" "${tmp_dir}/${incr_file}" \
                --profile "$AWS_PROFILE"
            if [[ -n "$file_filter" ]]; then
                # shellcheck disable=SC2086
                tar ${xflag} -xf "${tmp_dir}/${incr_file}" -C "$restore_dest" \
                    --wildcards "*${file_filter}*" 2>>"$LOG_FILE" || true
            else
                # shellcheck disable=SC2086
                tar ${xflag} -xf "${tmp_dir}/${incr_file}" -C "$restore_dest" 2>>"$LOG_FILE"
            fi
        done <<< "$incrs"
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
    local full_key="${S3_PREFIX}/${full_label}/${full_label}.${ext}"

    aws s3api restore-object \
        --bucket "$S3_BUCKET" \
        --key "$full_key" \
        --restore-request "Days=7,GlacierJobParameters={Tier=${tier}}" \
        --profile "$AWS_PROFILE" \
        && echo -e "${GREEN}Restore request submitted. Object will be available in S3 Standard temporarily.${RESET}"

    # Also initiate for incrementals
    local incrs
    incrs=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${full_label}/incrementals/" \
        --profile "$AWS_PROFILE" 2>/dev/null | \
        grep "\.${ext}$" | awk '{print $4}' || true)

    while IFS= read -r incr; do
        [[ -z "$incr" ]] && continue
        aws s3api restore-object \
            --bucket "$S3_BUCKET" \
            --key "${S3_PREFIX}/${full_label}/incrementals/${incr}" \
            --restore-request "Days=7,GlacierJobParameters={Tier=${tier}}" \
            --profile "$AWS_PROFILE" \
            && echo "Restore initiated: ${incr}"
    done <<< "$incrs"
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

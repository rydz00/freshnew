#!/usr/bin/env bash
# =============================================================================
# file_media.sh
# -----------------------------------------------------------------------------
# Scans the CURRENT directory for images and videos, reads EXIF/metadata
# timestamps, and files them into a structured target directory:
#
#   Images (jpg, jpeg):          TARGET/YYYY/MM/filename
#   Videos (mov, mpeg, mp4, m4v): TARGET/YYYY/MM/vids/filename
#
# Workflow per file: copy → validate (size + md5) → delete original
#
# Dependencies: exiftool, md5sum (coreutils)
# Install:  sudo apt install libimage-exiftool-perl coreutils
#           sudo dnf install perl-Image-ExifTool coreutils
#
# Usage:
#   cd /your/source/directory
#   bash /path/to/file_media.sh [--dry-run] [--log /path/to/logfile]
#
# Options:
#   --dry-run    Show what would happen without copying or deleting anything
#   --log FILE   Write a log to FILE (default: ./file_media.log)
# =============================================================================

#set -euo pipefail
# Note: intentionally no 'set -e' — errors are caught per-file so the loop always continues


# ── Configuration ─────────────────────────────────────────────────────────────
TARGET_BASE="/home/robryd/rydznas/Pics"
LOG_FILE="$(pwd)/file_media.log"
DRY_RUN=false

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --log)     LOG_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

die() { log "ERROR: $*"; exit 1; }

# Check required tools
for tool in exiftool md5sum; do
    command -v "$tool" &>/dev/null || die "'$tool' is not installed. See script header for install instructions."
done

# ── Extract best available timestamp from a file ──────────────────────────────
# Priority: DateTimeOriginal → CreateDate → MediaCreateDate → FileModifyDate
get_timestamp() {
    local file="$1"
    local ts=""

    # Try tags in order of preference
    for tag in DateTimeOriginal CreateDate MediaCreateDate TrackCreateDate FileModifyDate; do
        ts=$(exiftool -s3 -"$tag" "$file" 2>/dev/null | head -1)
        if [[ -n "$ts" && "$ts" != "0000:00:00 00:00:00" ]]; then
            break
        fi
        ts=""
    done

    # Last resort: file modification time
    if [[ -z "$ts" ]]; then
        ts=$(stat -c '%y' "$file" | cut -d'.' -f1)
        # Convert "YYYY-MM-DD HH:MM:SS" → "YYYY:MM:DD HH:MM:SS" for uniform parsing
        ts="${ts//-/:}"
        log "  WARNING: No EXIF timestamp found in '$file', using file mtime: $ts"
    fi

    echo "$ts"
}

# Parse YYYY and MM from a timestamp string like "2023:07:15 14:32:00"
parse_year()  { echo "$1" | cut -d':' -f1; }
parse_month() { echo "$1" | cut -d':' -f2; }

# ── File one media item ───────────────────────────────────────────────────────
file_item() {
    local src="$1"
    local subdir="$2"   # "" for images, "vids" for video

    local filename
    filename=$(basename "$src")

    local ts year month
    ts=$(get_timestamp "$src")
    year=$(parse_year "$ts")
    month=$(parse_month "$ts")

    # Sanity-check year is 4 digits and month 01-12
    if ! [[ "$year" =~ ^[0-9]{4}$ ]] || ! [[ "$month" =~ ^(0[1-9]|1[0-2])$ ]]; then
        log "  SKIP '$filename': Could not parse a valid date (got year='$year' month='$month')"
        return 1
    fi

    # Build destination path
    local dest_dir="$TARGET_BASE/$year/$month"
    [[ -n "$subdir" ]] && dest_dir="$dest_dir/$subdir"
    local dest="$dest_dir/$filename"

    # Handle filename collisions
    if [[ -e "$dest" ]]; then
        local base="${filename%.*}"
        local ext="${filename##*.}"
        local counter=1
        while [[ -e "$dest_dir/${base}_${counter}.${ext}" ]]; do
            ((counter++))
        done
        dest="$dest_dir/${base}_${counter}.${ext}"
        log "  RENAME: collision resolved → $(basename "$dest")"
    fi

    log "  DATE: $year/$month  |  $(basename "$src") → $dest"

    if $DRY_RUN; then
        log "  [DRY RUN] Would copy and validate."
        return 0
    fi

    # ── Copy ──────────────────────────────────────────────────────────────────
    mkdir -p "$dest_dir"
    if ! cp --preserve=timestamps "$src" "$dest"; then
        log "  ERROR: Copy failed for '$filename'"
        return 1
    fi

    # ── Validate: size ────────────────────────────────────────────────────────
    local src_size dest_size
    src_size=$(stat -c '%s' "$src")
    dest_size=$(stat -c '%s' "$dest")
    if [[ "$src_size" != "$dest_size" ]]; then
        log "  ERROR: Size mismatch for '$filename' (src=$src_size dest=$dest_size) — keeping original"
        rm -f "$dest"
        return 1
    fi

    # ── Validate: checksum ────────────────────────────────────────────────────
    local src_md5 dest_md5
    src_md5=$(md5sum "$src"  | awk '{print $1}')
    dest_md5=$(md5sum "$dest" | awk '{print $1}')
    if [[ "$src_md5" != "$dest_md5" ]]; then
        log "  ERROR: Checksum mismatch for '$filename' — keeping original"
        rm -f "$dest"
        return 1
    fi

    # ── Delete original ───────────────────────────────────────────────────────
    rm "$src"
    log "  OK: Moved and verified '$filename'"
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
SOURCE_DIR="$(pwd)"

log "============================================================"
log "file_media.sh starting"
$DRY_RUN && log "*** DRY RUN MODE — no files will be moved ***"
log "Source : $SOURCE_DIR"
log "Target : $TARGET_BASE"
log "Log    : $LOG_FILE"
log "============================================================"

count_ok=0
count_skip=0
count_err=0

# Use process-safe find with null-delimited output to handle spaces in filenames
while IFS= read -r -d '' file; do
    rel="${file#"$SOURCE_DIR/"}"
    log "Processing: $rel"

    ext="${file##*.}"
    ext_lower="${ext,,}"   # lowercase

    case "$ext_lower" in
        jpg|jpeg|png|gif|heic)
            if file_item "$file" ""; then
                count_ok=$((count_ok + 1))
            else
                count_err=$((count_err +1))
            fi
            ;;
        mov|mpeg|mp4|m4v|avi|3gp)
            if file_item "$file" "vids"; then
                count_ok=$((count_ok + 1))
            else
                count_err=$((count_err + 1))
            fi
            ;;
        *)
            log "  SKIP: '$rel' — not a handled file type"
            count_skip=$((count_skip + 1))
            ;;
    esac

done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -print0 | sort -z)

log "============================================================"
log "Done.  Moved: $count_ok  |  Skipped: $count_skip  |  Errors: $count_err"
$DRY_RUN && log "(Dry run — nothing was actually moved)"
log "============================================================"

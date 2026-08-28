# =============================================================================
# Glacier Backup — Configuration File
# Location: ~/.config/glacier-backup/config.sh
# =============================================================================

# AWS credentials profile (from ~/.aws/credentials or IAM role)
AWS_PROFILE="default"

# S3 bucket to store backups in (must already exist)
S3_BUCKET="my-company-backups"

# Key prefix inside the bucket (acts like a folder path)
S3_PREFIX="backups/$(hostname)"

# Directories to back up (space-separated array)
BACKUP_DIRS=(
    "/home/alice/documents"
    "/home/alice/projects"
    "/etc"
    "/var/www"
)

# How many days between full backups (default: 90 = every 3 months)
FULL_CYCLE_DAYS=90

# S3 storage class:
#   GLACIER            — 3–5 hours retrieval, lowest cost
#   DEEP_ARCHIVE       — 12 hours retrieval, even cheaper
#   GLACIER_IR         — millisecond retrieval, higher cost
STORAGE_CLASS="GLACIER"

# Compression algorithm:
#   zstd   — fast & excellent compression ratio (recommended)
#   gzip   — universal compatibility
#   none   — no compression (fastest, largest files)
COMPRESS="zstd"

# Patterns to exclude from backups (rsync/tar glob syntax)
EXCLUDE_PATTERNS=(
    "*.tmp"
    "*.swp"
    "*.log"
    ".cache/"
    "node_modules/"
    "__pycache__/"
    ".Trash/"
    "*.DS_Store"
)

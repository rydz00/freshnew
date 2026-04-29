# Glacier Backup — Linux → AWS S3/Glacier

Incremental backup system for Linux. Stores archives in S3 with Glacier storage class.

## Schedule

| Backup Type | Trigger | Behaviour |
|---|---|---|
| **Full** | Every 90 days (configurable) | Complete tar archive of all dirs; old full deleted |
| **Incremental** | Weekly (via cron) | Only files changed since last run (tar `--listed-incremental`) |

## Files

```
glacier_backup.sh   — Main script (all commands)
install.sh          — Dependency check + cron installer
config.example.sh   — Annotated config reference
iam-policy.json     — Minimal AWS IAM policy required
```

## Quick Start

### 1. AWS prerequisites

- Create an S3 bucket with versioning disabled (Glacier handles this)
- Create an IAM user/role, attach `iam-policy.json` (edit bucket name first)
- Run `aws configure` to save credentials locally

### 2. Install

```bash
chmod +x install.sh glacier_backup.sh
./install.sh
```

### 3. Commands

```bash
# Run auto (full if due, incremental otherwise)
glacier_backup.sh run

# Force a full backup
glacier_backup.sh full

# List all backups
glacier_backup.sh list

# Browse files in a backup / search for a file
glacier_backup.sh browse full_20250101_020000
glacier_backup.sh browse full_20250101_020000 "nginx.conf"

# Initiate Glacier retrieval (required before restore; takes hours)
glacier_backup.sh restore-init full_20250101_020000 Bulk

# Restore full backup + all its incrementals
glacier_backup.sh restore full_20250101_020000 /mnt/restore

# Restore only files matching a pattern
glacier_backup.sh restore full_20250101_020000 /mnt/restore ".conf"

# Show current status
glacier_backup.sh status
```

## S3 Layout

```
s3://BUCKET/PREFIX/
  full_20250101_020000/
    full_20250101_020000.tar.zst   ← full archive
    manifest.txt                   ← list of all files
    meta.json                      ← metadata (date, size, dirs)
    incrementals/
      incr_20250108_020000.tar.zst
      incr_20250108_020000.manifest
      incr_20250108_020000.snar    ← tar snapshot file
      incr_20250108_020000.meta.json
      incr_20250115_020000.tar.zst
      ...
```

## Restore Flow (Glacier)

Glacier objects are not immediately downloadable. You must:

1. **Initiate retrieval** — `glacier_backup.sh restore-init <label> Bulk`
2. **Wait** — Bulk: 5–12h / Standard: 3–5h / Expedited: 1–5min
3. **Restore** — `glacier_backup.sh restore <label> /dest`

The script handles full + all incrementals in order automatically.

## Compression

| Option | Speed | Ratio | Requirement |
|---|---|---|---|
| `zstd` (default) | ★★★★★ | ★★★★☆ | `apt install zstd` |
| `gzip` | ★★★☆☆ | ★★★☆☆ | Built-in |
| `none` | ★★★★★ | ☆☆☆☆☆ | Built-in |

## Config location

`~/.config/glacier-backup/config.sh` (created by `setup` command)

## State files

`~/.local/state/glacier-backup/`
- `last_full_timestamp` — epoch of last full backup
- `current_full_label` — label of active full backup
- `tar_snapshot.snar` — incremental tracking file (do not delete)
- `logs/` — per-run log files
- `manifests/` — local copies of manifests

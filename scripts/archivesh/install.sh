#!/usr/bin/env bash
# =============================================================================
# install.sh — Install glacier_backup.sh and configure cron
# =============================================================================

set -euo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'

INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="glacier_backup.sh"
CRON_TAG="# glacier-backup-cron"

echo -e "\n${BOLD}${CYAN}Glacier Backup Installer${RESET}\n"

# ── Check dependencies ────────────────────────────────────────────────────────
echo "Checking dependencies..."
for dep in aws tar jq numfmt; do
    if command -v "$dep" &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} $dep"
    else
        echo "  ✗ $dep — NOT FOUND"
        case "$dep" in
            aws)     echo "    Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html" ;;
            jq)      echo "    Install: sudo apt install jq   OR   sudo yum install jq" ;;
            numfmt)  echo "    Install: sudo apt install coreutils" ;;
            zstd)    echo "    Install: sudo apt install zstd  (optional, for zstd compression)" ;;
        esac
        MISSING=1
    fi
done

if [[ "${MISSING:-0}" == "1" ]]; then
    echo -e "\nPlease install missing dependencies and re-run."
    exit 1
fi

# ── Install script ────────────────────────────────────────────────────────────
echo -e "\nInstalling to ${INSTALL_DIR}/${SCRIPT_NAME}..."
sudo cp glacier_backup.sh "${INSTALL_DIR}/${SCRIPT_NAME}"
sudo chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
echo -e "${GREEN}✓ Script installed${RESET}"

# ── Configure cron ────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Cron Schedule Options:${RESET}"
echo "  1) Weekly on Sunday at 2:00 AM (recommended)"
echo "  2) Weekly on Saturday at 3:00 AM"
echo "  3) Custom"
echo "  4) Skip (configure cron manually)"
read -rp "Choice [1]: " cron_choice; cron_choice="${cron_choice:-1}"

LOG_PATH="$HOME/.local/state/glacier-backup/logs/cron.log"
mkdir -p "$(dirname "$LOG_PATH")"

case "$cron_choice" in
    1) CRON_SCHEDULE="0 2 * * 0" ;;
    2) CRON_SCHEDULE="0 3 * * 6" ;;
    3)
        echo "Enter cron schedule (e.g. '0 2 * * 0' for Sunday 2 AM):"
        read -r CRON_SCHEDULE
        ;;
    4)
        echo -e "\nSkipped. Add manually to crontab:"
        echo "  0 2 * * 0  ${INSTALL_DIR}/${SCRIPT_NAME} run >> ${LOG_PATH} 2>&1 ${CRON_TAG}"
        exit 0
        ;;
esac

CRON_LINE="${CRON_SCHEDULE}  ${INSTALL_DIR}/${SCRIPT_NAME} run >> ${LOG_PATH} 2>&1 ${CRON_TAG}"

# Remove any existing glacier-backup cron line, then add new one
( crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_LINE" ) | crontab -

echo -e "${GREEN}✓ Cron job installed:${RESET}"
echo "  ${CRON_LINE}"

# ── Run setup ─────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Would you like to run the configuration wizard now? [Y/n]${RESET}"
read -rp "" run_setup; run_setup="${run_setup:-Y}"
if [[ "${run_setup^^}" == "Y" ]]; then
    "${INSTALL_DIR}/${SCRIPT_NAME}" setup
fi

echo -e "\n${GREEN}${BOLD}Installation complete!${RESET}"
echo -e "Run your first backup with: ${BOLD}glacier_backup.sh run${RESET}\n"

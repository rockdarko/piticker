#!/usr/bin/env bash
# PiTicker Uninstaller
set -uo pipefail

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[1;32m"
RED="\033[1;31m"
RESET="\033[0m"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Please run as root (sudo ./uninstall.sh)${RESET}"
    exit 1
fi

echo ""
echo -e "${BOLD}PiTicker Uninstaller${RESET}"
echo ""

# Find install path from service file
INSTALL_DIR=""
if [[ -f /etc/systemd/system/piticker.service ]]; then
    INSTALL_DIR=$(grep "ExecStart=" /etc/systemd/system/piticker.service | sed 's|ExecStart=||;s|/ticker.sh.*||')
fi

echo -e "This will:"
echo -e "  - Stop and disable piticker services"
echo -e "  - Remove systemd service files"
echo -e "  - Remove state files from /tmp"
[[ -n "$INSTALL_DIR" ]] && echo -e "  - Remove ${INSTALL_DIR}/"
echo ""
echo -en "${BOLD}Proceed? [y/N]:${RESET} "
read -r confirm
[[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]] && echo "Cancelled." && exit 0

echo ""

# Stop and disable services
for svc in piticker.service piticker-ctl.service; do
    if systemctl is-active "$svc" &>/dev/null; then
        systemctl stop "$svc"
        echo -e "  ${GREEN}✓${RESET} Stopped ${svc}"
    fi
    if [[ -f "/etc/systemd/system/${svc}" ]]; then
        systemctl disable "$svc" &>/dev/null
        rm -f "/etc/systemd/system/${svc}"
        echo -e "  ${GREEN}✓${RESET} Removed ${svc}"
    fi
done
systemctl daemon-reload

# Remove state files
rm -f /tmp/ticker_mode /tmp/ticker_symbols /tmp/ticker_font \
      /tmp/ticker_sym_font /tmp/ticker_info_font /tmp/ticker_aliases \
      /tmp/ticker_slideshow_interval /tmp/ticker_cents
echo -e "  ${GREEN}✓${RESET} Removed state files"

# Remove install directory
if [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo -e "  ${GREEN}✓${RESET} Removed ${INSTALL_DIR}/"
fi

echo ""
echo -e "${GREEN}${BOLD}PiTicker uninstalled.${RESET}"
echo -e "${DIM}Screen rotation settings in /boot/config.txt were not changed.${RESET}"
echo ""

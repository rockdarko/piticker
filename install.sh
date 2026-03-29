#!/usr/bin/env bash
# PiTicker Installer — Interactive setup for Raspberry Pi GPIO displays
set -uo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEFAULT_INSTALL_DIR="/opt/piticker"
DEFAULT_PORT=8080
DEFAULT_TTY=1
DEFAULT_SYMBOLS="BTC-USD"

# ── Colors ────────────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

# ── Helpers ───────────────────────────────────────────────────

banner() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  PiTicker ${VERSION} — Stock & Crypto Display${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

step() {
    echo -e "\n${CYAN}▶ $1${RESET}"
}

ok() {
    echo -e "  ${GREEN}✓${RESET} $1"
}

warn() {
    echo -e "  ${YELLOW}!${RESET} $1"
}

fail() {
    echo -e "  ${RED}✗${RESET} $1"
}

ask() {
    local prompt="$1" default="$2" var="$3"
    if [[ -n "$default" ]]; then
        echo -en "  ${BOLD}${prompt}${RESET} ${DIM}[${default}]${RESET}: "
    else
        echo -en "  ${BOLD}${prompt}${RESET}: "
    fi
    read -r input
    eval "$var=\"${input:-$default}\""
}

ask_yn() {
    local prompt="$1" default="$2"
    local yn_hint="y/n"
    [[ "$default" == "y" ]] && yn_hint="Y/n"
    [[ "$default" == "n" ]] && yn_hint="y/N"
    echo -en "  ${BOLD}${prompt}${RESET} ${DIM}[${yn_hint}]${RESET}: "
    read -r input
    input="${input:-$default}"
    [[ "${input,,}" == "y" || "${input,,}" == "yes" ]]
}

# ── Root check ────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Please run as root (sudo ./install.sh)${RESET}"
    exit 1
fi

banner

# ── Step 1: GPIO display check ────────────────────────────────

step "Checking display configuration"

GPIO_DETECTED=false
ROTATE_LINE=""
CURRENT_ROTATE=""

if [[ -f /boot/config.txt ]]; then
    # Look for common GPIO display overlays
    ROTATE_LINE=$(grep -E "^dtoverlay=.*(tft|lcd|ili|waveshare|piscreen|hy28|joy-IT).*:rotate=" /boot/config.txt 2>/dev/null | tail -1)
    if [[ -n "$ROTATE_LINE" ]]; then
        GPIO_DETECTED=true
        CURRENT_ROTATE=$(echo "$ROTATE_LINE" | sed 's/.*rotate=//' | tr -d '[:space:]')
        ok "GPIO display detected: ${ROTATE_LINE}"
    else
        # Check for overlay without rotate parameter
        OVERLAY_LINE=$(grep -E "^dtoverlay=.*(tft|lcd|ili|waveshare|piscreen|hy28|joy-IT)" /boot/config.txt 2>/dev/null | tail -1)
        if [[ -n "$OVERLAY_LINE" ]]; then
            GPIO_DETECTED=true
            ok "GPIO display detected: ${OVERLAY_LINE}"
        fi
    fi
fi

if [[ "$GPIO_DETECTED" == "false" ]]; then
    warn "No GPIO display overlay found in /boot/config.txt"
    echo ""
    echo -e "  PiTicker is designed for GPIO displays. If you haven't set up"
    echo -e "  your display yet, see: ${BOLD}https://github.com/goodtft/LCD-show${RESET}"
    echo ""
    echo -e "  Clone the repo, run the script for your display model"
    echo -e "  (e.g. ${DIM}./LCD35-show${RESET}), then re-run this installer."
    echo ""
    if ! ask_yn "Continue anyway?" "n"; then
        echo -e "\n${DIM}Exiting. Set up your GPIO display first, then re-run.${RESET}"
        exit 0
    fi
fi

# ── Step 2: Screen rotation ──────────────────────────────────

step "Screen rotation"

echo -e "  Some GPIO screens mount upside-down depending on case design."
echo -e "  Current rotation: ${BOLD}${CURRENT_ROTATE:-not set}${RESET}"
echo ""

ROTATE_CHOICE="skip"
if [[ "$GPIO_DETECTED" == "true" ]]; then
    if ask_yn "Rotate display 180°?" "n"; then
        ROTATE_CHOICE="flip"
        if [[ -n "$CURRENT_ROTATE" ]]; then
            case "$CURRENT_ROTATE" in
                0)   NEW_ROTATE=180 ;;
                90)  NEW_ROTATE=270 ;;
                180) NEW_ROTATE=0 ;;
                270) NEW_ROTATE=90 ;;
                *)   NEW_ROTATE=180 ;;
            esac
        else
            NEW_ROTATE=180
        fi
        ok "Will set rotation to ${NEW_ROTATE}° (takes effect on next boot)"
    else
        ok "Keeping current rotation"
    fi
fi

# ── Step 3: Installation path ────────────────────────────────

step "Installation path"

ask "Where to install PiTicker?" "$DEFAULT_INSTALL_DIR" INSTALL_DIR
ok "Install to: ${INSTALL_DIR}"

# ── Step 4: Configuration ────────────────────────────────────

step "Configuration"

ask "Initial symbols (comma-separated)" "$DEFAULT_SYMBOLS" SYMBOLS
ask "Web control port" "$DEFAULT_PORT" PORT
ask "Display TTY number" "$DEFAULT_TTY" TTY_NUM

ok "Symbols: ${SYMBOLS}"
ok "Control port: ${PORT}"
ok "Display TTY: tty${TTY_NUM}"

# ── Step 5: Confirm ──────────────────────────────────────────

step "Summary"

echo ""
echo -e "  ${BOLD}Install path:${RESET}    ${INSTALL_DIR}"
echo -e "  ${BOLD}Symbols:${RESET}         ${SYMBOLS}"
echo -e "  ${BOLD}Control port:${RESET}    ${PORT}"
echo -e "  ${BOLD}Display TTY:${RESET}     tty${TTY_NUM}"
[[ "$ROTATE_CHOICE" == "flip" ]] && \
echo -e "  ${BOLD}Rotation:${RESET}        ${NEW_ROTATE}°"
echo ""

if ! ask_yn "Proceed with installation?" "y"; then
    echo -e "\n${DIM}Installation cancelled.${RESET}"
    exit 0
fi

# ── Step 6: Install dependencies ─────────────────────────────

step "Installing dependencies"

apt-get update -qq
for pkg in figlet toilet jq curl socat inotify-tools; do
    if dpkg -s "$pkg" &>/dev/null; then
        ok "${pkg} (already installed)"
    else
        apt-get install -y -qq "$pkg" &>/dev/null
        if dpkg -s "$pkg" &>/dev/null; then
            ok "${pkg} (installed)"
        else
            fail "${pkg} (failed to install)"
        fi
    fi
done

# ── Step 7: Copy files ───────────────────────────────────────

step "Installing PiTicker files"

mkdir -p "$INSTALL_DIR"

for f in ticker.sh tickerctl.sh ticker-ui.html; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
        cp "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/${f}"
        ok "${f}"
    else
        fail "${f} not found in ${SCRIPT_DIR}"
        exit 1
    fi
done

chmod +x "${INSTALL_DIR}/ticker.sh" "${INSTALL_DIR}/tickerctl.sh"

# ── Step 8: Apply rotation ───────────────────────────────────

if [[ "$ROTATE_CHOICE" == "flip" ]]; then
    step "Applying screen rotation"

    if [[ -n "$ROTATE_LINE" ]]; then
        # Replace existing rotate value
        OLD_PATTERN=$(echo "$ROTATE_LINE" | sed 's/[.[\*^$()+?{|]/\\&/g')
        NEW_LINE=$(echo "$ROTATE_LINE" | sed "s/rotate=${CURRENT_ROTATE}/rotate=${NEW_ROTATE}/")
        sed -i "s|${ROTATE_LINE}|${NEW_LINE}|" /boot/config.txt
        ok "Updated /boot/config.txt: rotate=${NEW_ROTATE}"
    else
        warn "Could not find rotate parameter to update"
    fi
fi

# ── Step 9: Create systemd services ──────────────────────────

step "Creating systemd services"

cat > /etc/systemd/system/piticker.service <<EOF
[Unit]
Description=PiTicker Display
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${INSTALL_DIR}/ticker.sh ${SYMBOLS} 60
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty${TTY_NUM}
TTYReset=yes
TTYVHangup=yes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
ok "piticker.service"

cat > /etc/systemd/system/piticker-ctl.service <<EOF
[Unit]
Description=PiTicker Control Server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${INSTALL_DIR}/tickerctl.sh ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
ok "piticker-ctl.service"

systemctl daemon-reload
systemctl enable piticker.service piticker-ctl.service &>/dev/null
ok "Services enabled"

# ── Step 10: Start services ──────────────────────────────────

step "Starting PiTicker"

systemctl start piticker-ctl.service
ok "Control server started on port ${PORT}"

systemctl start piticker.service
ok "Display started on tty${TTY_NUM}"

# ── Done ─────────────────────────────────────────────────────

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  PiTicker installed successfully!${RESET}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}Web control:${RESET}   http://${LOCAL_IP}:${PORT}/"
echo -e "  ${BOLD}Files:${RESET}         ${INSTALL_DIR}/"
echo -e "  ${BOLD}Display:${RESET}       /dev/tty${TTY_NUM}"
echo ""
echo -e "  ${DIM}Manage with:${RESET}"
echo -e "    sudo systemctl start|stop|restart piticker"
echo -e "    sudo systemctl start|stop|restart piticker-ctl"
echo -e "    journalctl -u piticker -f"
echo ""
[[ "$ROTATE_CHOICE" == "flip" ]] && \
echo -e "  ${YELLOW}Reboot required for screen rotation to take effect.${RESET}" && echo ""

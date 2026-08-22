#!/usr/bin/env bash
# PiTicker Installer — Interactive setup for Raspberry Pi GPIO displays
set -uo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEFAULT_INSTALL_DIR="/opt/piticker"
DEFAULT_PORT=8080
DEFAULT_TTY=1
DEFAULT_SYMBOLS="BTC-USD"

# Bookworm+ moved the boot partition to /boot/firmware; /boot holds a stub that
# the firmware never reads. Resolve once, use everywhere.
resolve_boot_file() {
    if [[ -f "/boot/firmware/$1" ]]; then
        echo "/boot/firmware/$1"
    else
        echo "/boot/$1"
    fi
}
BOOT_CONFIG="$(resolve_boot_file config.txt)"
BOOT_CMDLINE="$(resolve_boot_file cmdline.txt)"

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

if [[ -f "$BOOT_CONFIG" ]]; then
    # Look for common GPIO display overlays
    ROTATE_LINE=$(grep -E "^dtoverlay=.*(tft|lcd|ili|waveshare|piscreen|hy28|joy-IT).*:rotate=" "$BOOT_CONFIG" 2>/dev/null | tail -1)
    if [[ -n "$ROTATE_LINE" ]]; then
        GPIO_DETECTED=true
        CURRENT_ROTATE=$(echo "$ROTATE_LINE" | sed 's/.*rotate=//' | tr -d '[:space:]')
        ok "GPIO display detected: ${ROTATE_LINE}"
    else
        # Check for overlay without rotate parameter
        OVERLAY_LINE=$(grep -E "^dtoverlay=.*(tft|lcd|ili|waveshare|piscreen|hy28|joy-IT)" "$BOOT_CONFIG" 2>/dev/null | tail -1)
        if [[ -n "$OVERLAY_LINE" ]]; then
            GPIO_DETECTED=true
            ok "GPIO display detected: ${OVERLAY_LINE}"
        fi
    fi
fi

if [[ "$GPIO_DETECTED" == "false" ]]; then
    warn "No GPIO display overlay found in ${BOOT_CONFIG}"
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

ROTATE_CHOICE="skip"
if [[ "$GPIO_DETECTED" == "true" ]]; then
    echo -e "  Some GPIO screens mount upside-down depending on case design."
    echo -e "  Current rotation: ${BOLD}${CURRENT_ROTATE:-not set}°${RESET}"
    echo ""
    echo -e "  ${BOLD}1)${RESET} 0°   — Normal (connectors at bottom)"
    echo -e "  ${BOLD}2)${RESET} 90°  — Rotated left"
    echo -e "  ${BOLD}3)${RESET} 180° — Flipped upside-down (connectors at top)"
    echo -e "  ${BOLD}4)${RESET} 270° — Rotated right"
    echo -e "  ${BOLD}5)${RESET} Keep current (${CURRENT_ROTATE:-0}°)"
    echo ""
    echo -en "  ${BOLD}Choose rotation${RESET} ${DIM}[5]${RESET}: "
    read -r rot_input
    rot_input="${rot_input:-5}"
    case "$rot_input" in
        1) NEW_ROTATE=0;   ROTATE_CHOICE="set" ;;
        2) NEW_ROTATE=90;  ROTATE_CHOICE="set" ;;
        3) NEW_ROTATE=180; ROTATE_CHOICE="set" ;;
        4) NEW_ROTATE=270; ROTATE_CHOICE="set" ;;
        *) ROTATE_CHOICE="skip" ;;
    esac
    if [[ "$ROTATE_CHOICE" == "set" ]]; then
        if [[ "$NEW_ROTATE" == "${CURRENT_ROTATE:-0}" ]]; then
            ok "Already at ${NEW_ROTATE}° — no change needed"
            ROTATE_CHOICE="skip"
        else
            ok "Will set rotation to ${NEW_ROTATE}° (takes effect on next boot)"
        fi
    else
        ok "Keeping current rotation (${CURRENT_ROTATE:-0}°)"
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
[[ "$ROTATE_CHOICE" == "set" ]] && \
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

if [[ "$ROTATE_CHOICE" == "set" ]]; then
    step "Applying screen rotation"

    if [[ -n "$ROTATE_LINE" ]]; then
        # Replace existing rotate value
        NEW_LINE=$(echo "$ROTATE_LINE" | sed "s/rotate=${CURRENT_ROTATE}/rotate=${NEW_ROTATE}/")
        sed -i "s|${ROTATE_LINE}|${NEW_LINE}|" "$BOOT_CONFIG"
        ok "Updated ${BOOT_CONFIG}: rotate=${NEW_ROTATE}"
    elif [[ -n "$OVERLAY_LINE" ]]; then
        # Overlay exists but no rotate parameter — append it
        sed -i "s|${OVERLAY_LINE}|${OVERLAY_LINE}:rotate=${NEW_ROTATE}|" "$BOOT_CONFIG"
        ok "Added rotate=${NEW_ROTATE} to ${OVERLAY_LINE}"
    else
        warn "Could not find display overlay to update"
    fi
fi

# ── Step 8b: Map the console to the GPIO panel ───────────────

if [[ "$GPIO_DETECTED" == "true" ]]; then
    step "Mapping console to the GPIO display"

    if grep -q "fbcon=map:" "$BOOT_CMDLINE" 2>/dev/null; then
        ok "Console mapping already present in ${BOOT_CMDLINE}"
    else
        # cmdline.txt must stay a single line — append to it, don't add one.
        sed -i "1s|\\s*$| fbcon=map:10|" "$BOOT_CMDLINE"
        ok "Added fbcon=map:10 to ${BOOT_CMDLINE}"
    fi
fi

# ── Step 9: Create systemd services ──────────────────────────

step "Creating systemd services"

cat > /etc/systemd/system/piticker.service <<EOF
[Unit]
Description=PiTicker Display
After=network-online.target
Wants=network-online.target
Conflicts=getty@tty${TTY_NUM}.service

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

# An autologin getty on the same TTY hangs up the terminal out from under
# ticker.sh (SIGHUP), and both units respawn forever. The display owns the TTY.
if systemctl is-enabled "getty@tty${TTY_NUM}.service" &>/dev/null || \
   systemctl is-active "getty@tty${TTY_NUM}.service" &>/dev/null; then
    systemctl disable --now "getty@tty${TTY_NUM}.service" &>/dev/null
    ok "Disabled getty@tty${TTY_NUM} (it would fight PiTicker for the TTY)"
fi

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
[[ "$ROTATE_CHOICE" == "set" ]] && \
echo -e "  ${YELLOW}Reboot required for screen rotation to take effect.${RESET}" && echo ""

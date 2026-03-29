#!/usr/bin/env bash
# ticker.sh — Fullscreen stock/crypto price display
set -uo pipefail

# Default TERM for headless/tty launches (e.g. via setsid from SSH)
export TERM="${TERM:-linux}"

VERSION="1.1.0"

usage() {
    cat <<'EOF'
ticker.sh — Fullscreen stock/crypto price display using figlet

Usage:
    ./ticker.sh [OPTIONS] SYMBOL[,SYMBOL,...] [INTERVAL]

Options:
    -h, --help       Show this help message and exit
    -v, --version    Show version and exit
    --font FONT      Set the figlet font for the price (default: bigascii12).
                     Use --list-fonts to see available fonts.
    --list-fonts     List all available fonts and exit

Arguments:
    SYMBOL           Stock ticker (AAPL, MSFT) or crypto (BTC-USD, ETH-USD).
                     Pass a comma-separated list for list mode.
    INTERVAL         Refresh interval in seconds (default: 60).

Display modes:
    single           One symbol displayed large via figlet (auto-selected
                     when a single symbol is given).
    list             Tabular view of multiple symbols with price, change, and
                     percent (auto-selected when multiple symbols are given).

    Display rotation is handled at the OS level via /boot/config.txt
    (dtoverlay rotate parameter), not by the script.

Runtime control:
    The display can be changed at runtime without restarting. Either write to
    the state files directly or use the companion tickerctl.sh HTTP server.

    State files:
        /tmp/ticker_mode      "single" or "list"
        /tmp/ticker_symbols   one symbol per line
        /tmp/ticker_font      font name (e.g. "bigascii12", "Banner")

    HTTP server (see tickerctl.sh):
        GET /                  current state
        GET /set/SYMBOL        switch to single mode with SYMBOL
        GET /list/S1,S2,S3     switch to list mode with given symbols
        GET /add/SYMBOL        add a symbol to the list
        GET /remove/SYMBOL     remove a symbol from the list
        GET /mode/single|list  change display mode
        GET /font/NAME         change the font

Examples:
    ./ticker.sh BTC-USD                          # single mode
    ./ticker.sh --font Banner BTC-USD            # custom font
    ./ticker.sh BTC-USD,ETH-USD,AAPL             # list mode
    ./ticker.sh --list-fonts                     # show available fonts

Dependencies:
    curl, jq, figlet
    Install on Raspbian:  sudo apt install figlet jq curl
EOF
    exit 0
}

# ── List fonts ─────────────────────────────────────────────────

list_fonts() {
    echo "Available fonts (figlet .flf and toilet .tlf):"
    echo ""
    local fontdir="/usr/share/figlet"
    {
        ls "$fontdir"/*.flf 2>/dev/null | sed 's|.*/||;s|\.flf||'
        ls "$fontdir"/*.tlf 2>/dev/null | sed 's|.*/||;s|\.tlf||'
    } | sort -uf | column 2>/dev/null || cat
    echo ""
    echo "Preview a font:  figlet -f 'Banner' '\$ 12345'"
    exit 0
}

# ── Argument parsing ───────────────────────────────────────────

USER_FONT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)       usage ;;
        -v|--version)    echo "ticker.sh $VERSION"; exit 0 ;;
        --list-fonts)    list_fonts ;;
        --font)          USER_FONT="${2:?--font requires a font name}"; shift 2 ;;
        -*)              echo "Unknown option: $1 (try --help)"; exit 1 ;;
        *)               break ;;
    esac
done

SYMBOLS_ARG="${1:?Usage: $0 [OPTIONS] SYMBOL[,SYMBOL,...] [INTERVAL] (try --help)}"
INTERVAL="${2:-60}"

# State files
MODE_FILE="/tmp/ticker_mode"
SYMBOLS_FILE="/tmp/ticker_symbols"
FONT_FILE="/tmp/ticker_font"
SYM_FONT_FILE="/tmp/ticker_sym_font"
INFO_FONT_FILE="/tmp/ticker_info_font"
ALIASES_FILE="/tmp/ticker_aliases"
SLIDESHOW_INTERVAL_FILE="/tmp/ticker_slideshow_interval"
CENTS_FILE="/tmp/ticker_cents"

# Parse initial symbols
IFS=',' read -ra SYMBOLS <<< "$SYMBOLS_ARG"

# Set initial mode based on argument count
if [[ ${#SYMBOLS[@]} -gt 1 ]]; then
    MODE="slideshow"
else
    MODE="single"
fi

SLIDESHOW_INTERVAL=5

# Write initial state only if files don't already exist
[[ ! -f "$MODE_FILE" ]] && echo "$MODE" > "$MODE_FILE"
[[ ! -f "$SYMBOLS_FILE" ]] && printf '%s\n' "${SYMBOLS[@]}" > "$SYMBOLS_FILE"
[[ -n "$USER_FONT" ]] && echo "$USER_FONT" > "$FONT_FILE"

# ── Yahoo Finance ──────────────────────────────────────────────

fetch_price() {
    local sym="$1"
    local url="https://query1.finance.yahoo.com/v8/finance/chart/${sym}?interval=1d&range=1d"
    local response
    response=$(curl -sf --max-time 10 \
        -H "User-Agent: Mozilla/5.0" \
        "$url" 2>/dev/null) || { echo "ERR"; return; }

    local price prev_close
    price=$(echo "$response" | jq -r '.chart.result[0].meta.regularMarketPrice // empty')
    prev_close=$(echo "$response" | jq -r '.chart.result[0].meta.chartPreviousClose // empty')

    [[ -z "$price" ]] && { echo "ERR"; return; }

    local change pct sign
    if [[ -n "$prev_close" && "$prev_close" != "0" ]]; then
        change=$(awk "BEGIN {printf \"%.2f\", $price - $prev_close}")
        pct=$(awk "BEGIN {printf \"%.2f\", (($price - $prev_close) / $prev_close) * 100}")
        if awk "BEGIN {exit !($price >= $prev_close)}"; then
            sign="+"
        else
            sign=""
        fi
    else
        change="0.00"
        pct="0.00"
        sign=""
    fi

    local display_price
    display_price=$(printf "%.2f" "$price")

    echo "${display_price}|${sign}${change}|${sign}${pct}%"
}

# ── Font / rendering helpers ───────────────────────────────────

pick_font() {
    local fonts=("Colossal" "Banner" "big" "standard")
    for f in "${fonts[@]}"; do
        if figlet -f "$f" "test" &>/dev/null; then
            echo "$f"
            return
        fi
    done
    echo "standard"
}

render_with_font() {
    local font="$1" text="$2" width="$3"
    figlet -f "$font" -w "$width" "$text" 2>/dev/null
}

# Check the natural (unwrapped) width of text in a given font
# Uses bash ${#line} instead of awk length — awk counts bytes for
# multi-byte UTF-8 chars (e.g. ANSI Shadow box-drawing), inflating width
natural_width() {
    local font="$1" text="$2"
    local max=0
    while IFS= read -r line; do
        line="${line%"${line##*[! ]}"}"  # trim trailing spaces
        [[ ${#line} -gt $max ]] && max=${#line}
    done < <(figlet -f "$font" -w 1000 "$text" 2>/dev/null)
    echo "$max"
}

render_big() {
    local text="$1" width=$(( $2 - 2 ))
    local nw

    # Try each font: user's choice, then Colossal, then Banner
    # For each font, try: full text, then without cents
    local f
    for f in "$FONT" "Colossal" "Banner" "big"; do
        # With cents
        nw=$(natural_width "$f" "$text")
        if [[ $nw -le $width ]]; then
            render_with_font "$f" "$text" "$width"
            return
        fi

        # Without cents
        local no_cents="${text%.*}"
        if [[ "$no_cents" != "$text" ]]; then
            nw=$(natural_width "$f" "$no_cents")
            if [[ $nw -le $width ]]; then
                render_with_font "$f" "$no_cents" "$width"
                return
            fi
        fi
    done

    # Last resort
    echo "$text"
}

# Set initial font: user-specified or auto-detect
if [[ -n "$USER_FONT" ]]; then
    FONT="$USER_FONT"
else
    FONT="ANSI Shadow"
fi
SYM_FONT="DOS Rebel"
INFO_FONT="ntgreek"

# Associative array: raw symbol -> display name (populated by read_aliases)
declare -A ALIAS_MAP

read_aliases() {
    ALIAS_MAP=()
    [[ ! -f "$ALIASES_FILE" ]] && return
    while IFS=$'\t' read -r key val; do
        key=$(echo "$key" | tr -d '[:space:]')
        [[ -n "$key" && -n "$val" ]] && ALIAS_MAP["$key"]="$val"
    done < "$ALIASES_FILE"
}

display_name() {
    local sym="$1"
    echo "${ALIAS_MAP[$sym]:-$sym}"
}

# Associative array: raw symbol -> cents preference (populated by read_cents)
# Values: "yes" (always show), "no" (always hide), absent = auto
declare -A CENTS_MAP

read_cents() {
    CENTS_MAP=()
    [[ ! -f "$CENTS_FILE" ]] && return
    while IFS=$'\t' read -r key val; do
        key=$(echo "$key" | tr -d '[:space:]')
        [[ -n "$key" && -n "$val" ]] && CENTS_MAP["$key"]="$val"
    done < "$CENTS_FILE"
}

# Apply cents preference to a price string
# Usage: format_price "$price" "$sym"
format_price() {
    local price="$1" sym="$2"
    local pref="${CENTS_MAP[$sym]:-auto}"
    case "$pref" in
        no)  printf "%.0f" "$price" ;;
        yes) printf "%.2f" "$price" ;;
        *)   # auto: drop cents if >= 1000
             if awk "BEGIN {exit !($price >= 1000)}"; then
                 printf "%.0f" "$price"
             else
                 printf "%.2f" "$price"
             fi
             ;;
    esac
}

# ANSI codes
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[1;32m"
RED="\033[1;31m"

color_for_change() {
    [[ "$1" == +* ]] && echo "$GREEN" || echo "$RED"
}

center_text() {
    local text="$1" color="$2" cols="$3"
    local tpad=$(( (cols - ${#text}) / 2 ))
    [[ $tpad -lt 0 ]] && tpad=0
    printf "${color}%*s%s${RESET}\n" "$tpad" "" "$text"
}

center_art() {
    local art="$1" color="$2" cols="$3"
    while IFS= read -r line; do
        local pad=$(( (cols - ${#line}) / 2 ))
        [[ $pad -lt 0 ]] && pad=0
        printf "${BOLD}${color}%*s%s${RESET}\n" "$pad" "" "$line"
    done <<< "$art"
}

# ── Read runtime state ─────────────────────────────────────────

read_state() {
    # Mode
    if [[ -f "$MODE_FILE" ]]; then
        local m
        m=$(cat "$MODE_FILE" | tr -d '[:space:]')
        [[ "$m" == "single" || "$m" == "list" || "$m" == "slideshow" ]] && MODE="$m"
    fi

    # Symbols
    if [[ -f "$SYMBOLS_FILE" ]]; then
        local -a new_syms=()
        while IFS= read -r s; do
            s=$(echo "$s" | tr -d '[:space:]')
            [[ -n "$s" ]] && new_syms+=("$s")
        done < "$SYMBOLS_FILE"
        [[ ${#new_syms[@]} -gt 0 ]] && SYMBOLS=("${new_syms[@]}")
    fi

    # Font
    if [[ -f "$FONT_FILE" ]]; then
        local new_font
        new_font=$(cat "$FONT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$new_font" ]] && FONT="$new_font"
    fi

    # Symbol font
    if [[ -f "$SYM_FONT_FILE" ]]; then
        local new_sf
        new_sf=$(cat "$SYM_FONT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$new_sf" ]] && SYM_FONT="$new_sf"
    fi

    # Info font
    if [[ -f "$INFO_FONT_FILE" ]]; then
        local new_if
        new_if=$(cat "$INFO_FONT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$new_if" ]] && INFO_FONT="$new_if"
    fi

    # Slideshow interval
    if [[ -f "$SLIDESHOW_INTERVAL_FILE" ]]; then
        local new_si
        new_si=$(cat "$SLIDESHOW_INTERVAL_FILE" | tr -d '[:space:]')
        [[ "$new_si" =~ ^[0-9]+$ && "$new_si" -ge 2 && "$new_si" -le 60 ]] && SLIDESHOW_INTERVAL="$new_si"
    fi

    # Aliases and cents preferences
    read_aliases
    read_cents
}

# ── Single mode ────────────────────────────────────────────────

render_single() {
    local cols="$1" rows="$2"
    local sym="${SYMBOLS[0]}"

    local data
    data=$(fetch_price "$sym")

    if [[ "$data" == "ERR" ]]; then
        center_text "Waiting for $sym ..." "$DIM" "$cols"
        sleep 5
        return
    fi

    IFS='|' read -r price change pct <<< "$data"

    local display_price
    display_price=$(format_price "$price" "$sym")

    local price_art sym_art
    price_art=$(render_big "$display_price" "$cols")
    # Render symbol name in Banner — smaller but matching block style
    local disp_name
    disp_name=$(display_name "$sym")
    sym_art=$(render_with_font "$SYM_FONT" "$disp_name" "$cols")
    [[ -z "$sym_art" ]] && sym_art="$disp_name"

    local price_lines sym_lines
    price_lines=$(echo "$price_art" | wc -l)
    sym_lines=$(echo "$sym_art" | wc -l)

    local info_text="${pct}"
    local ts="Updated: $(date '+%H:%M:%S')"
    local color
    color=$(color_for_change "$change")

    # Render info line with figlet (use -- to handle negative signs)
    local info_art
    info_art=$(figlet -f "$INFO_FONT" -w 1000 -- "$info_text" 2>/dev/null)
    local info_w
    info_w=$(echo "$info_art" | awk '{ if (length > m) m = length } END { print m+0 }')
    # Fall back to plain text if too wide
    if [[ $info_w -gt $((cols - 2)) ]] || [[ -z "$info_art" ]]; then
        info_art=""
    fi

    local info_lines=1
    [[ -n "$info_art" ]] && info_lines=$(echo "$info_art" | wc -l)

    # sym_art + blank + price_art + blank + info + timestamp
    local content_h=$((sym_lines + price_lines + info_lines + 4))
    local top=$(( (rows - content_h) / 2 ))
    [[ $top -lt 0 ]] && top=0

    for ((i = 0; i < top; i++)); do echo; done

    center_art "$sym_art" "${BOLD}" "$cols"
    echo ""
    center_art "$price_art" "$color" "$cols"
    echo ""
    if [[ -n "$info_art" ]]; then
        center_art "$info_art" "$color" "$cols"
    else
        center_text "${change}  (${pct})" "$color" "$cols"
    fi
    center_text "$ts" "$DIM" "$cols"
}

# ── List mode (table view) ─────────────────────────────────────

render_list() {
    local cols="$1" rows="$2"

    # Fetch all prices in parallel
    local -a results=()
    local -a pids=()
    local tmpdir
    tmpdir=$(mktemp -d)

    for i in "${!SYMBOLS[@]}"; do
        ( fetch_price "${SYMBOLS[$i]}" > "$tmpdir/$i" ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    for i in "${!SYMBOLS[@]}"; do
        results+=("$(cat "$tmpdir/$i" 2>/dev/null || echo "ERR")")
    done
    rm -rf "$tmpdir"

    # Build table rows
    local -a rows_out=()
    local sym_w=10 price_w=12 change_w=12 pct_w=10

    for i in "${!SYMBOLS[@]}"; do
        local sym="${SYMBOLS[$i]}"
        local data="${results[$i]}"
        local disp
        disp=$(display_name "$sym")
        if [[ "$data" == "ERR" ]]; then
            rows_out+=("$(printf "%-${sym_w}s %${price_w}s %${change_w}s %${pct_w}s" "$disp" "---" "---" "---")|0")
        else
            IFS='|' read -r price change pct <<< "$data"
            local dp
            dp=$(format_price "$price" "$sym")
            rows_out+=("$(printf "%-${sym_w}s %${price_w}s %${change_w}s %${pct_w}s" "$disp" "\$$dp" "$change" "($pct)")|$change")
        fi
    done

    local header
    header=$(printf "%-${sym_w}s %${price_w}s %${change_w}s %${pct_w}s" "SYMBOL" "PRICE" "CHANGE" "(%)")
    local sep_len=$((sym_w + price_w + change_w + pct_w + 3))
    local separator
    separator=$(printf '%*s' "$sep_len" '' | tr ' ' '─')

    local ts="Updated: $(date '+%H:%M:%S')"

    local content_h=$(( ${#rows_out[@]} + 4 ))
    local top=$(( (rows - content_h) / 2 ))
    [[ $top -lt 0 ]] && top=0

    for ((i = 0; i < top; i++)); do echo; done
    center_text "$header" "${BOLD}" "$cols"
    center_text "$separator" "$DIM" "$cols"
    for i in "${!rows_out[@]}"; do
        local row_data="${rows_out[$i]}"
        local row_text="${row_data%|*}"
        local row_change="${row_data##*|}"
        local color
        color=$(color_for_change "$row_change")
        center_text "$row_text" "$color" "$cols"
    done
    echo ""
    center_text "$ts" "$DIM" "$cols"
}

# ── Slideshow mode (full-screen cycling) ───────────────────────

CYCLE_INDEX=0

# ── Wait for state change or timeout ──────────────────────────
# Uses inotifywait to wake instantly when any state file changes,
# or falls back to plain sleep if inotifywait is unavailable.

STATE_FILES=("$MODE_FILE" "$SYMBOLS_FILE" "$FONT_FILE" "$SYM_FONT_FILE" "$INFO_FONT_FILE" "$ALIASES_FILE" "$SLIDESHOW_INTERVAL_FILE" "$CENTS_FILE")
HAS_INOTIFY=$(command -v inotifywait &>/dev/null && echo 1 || echo 0)

wait_for_change() {
    local timeout="$1"
    if [[ "$HAS_INOTIFY" == "1" ]]; then
        # Watch existing state files; wake on modify/create/delete
        local watch_files=()
        for f in "${STATE_FILES[@]}"; do
            [[ -f "$f" ]] && watch_files+=("$f")
        done
        if [[ ${#watch_files[@]} -gt 0 ]]; then
            inotifywait -qq -t "$timeout" -e modify,create,delete \
                "${watch_files[@]}" 2>/dev/null || true
        else
            sleep "$timeout"
        fi
    else
        sleep "$timeout"
    fi
}

# ── Main loop ──────────────────────────────────────────────────

tput civis 2>/dev/null || true
trap 'tput cnorm 2>/dev/null; clear; exit' EXIT INT TERM

while true; do
    read_state
    clear

    COLS=$(tput cols 2>/dev/null || echo 80)
    ROWS=$(tput lines 2>/dev/null || echo 24)

    case "$MODE" in
        single)
            render_single "$COLS" "$ROWS"
            wait_for_change "$INTERVAL"
            ;;
        list)
            render_list "$COLS" "$ROWS"
            wait_for_change "$INTERVAL"
            ;;
        slideshow)
            CYCLE_SYM="${SYMBOLS[$CYCLE_INDEX]}"
            OLD_SYMBOLS=("${SYMBOLS[@]}")
            SYMBOLS=("$CYCLE_SYM")
            render_single "$COLS" "$ROWS"
            SYMBOLS=("${OLD_SYMBOLS[@]}")
            CYCLE_INDEX=$(( (CYCLE_INDEX + 1) % ${#SYMBOLS[@]} ))
            wait_for_change "$SLIDESHOW_INTERVAL"
            ;;
    esac
done

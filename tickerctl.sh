#!/usr/bin/env bash
# tickerctl.sh — HTTP server to control the ticker display
# Usage: ./tickerctl.sh [PORT]
#   PORT — listen port (default: 8080)
#
# Web GUI at /
# API endpoints at /api/status, /set/, /add/, /remove/, /mode/, /font/, /fonts
#
# Dependencies: socat (sudo apt install socat)

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MODE_FILE="/tmp/ticker_mode"
SYMBOLS_FILE="/tmp/ticker_symbols"
FONT_FILE="/tmp/ticker_font"
SYM_FONT_FILE="/tmp/ticker_sym_font"
INFO_FONT_FILE="/tmp/ticker_info_font"
ALIASES_FILE="/tmp/ticker_aliases"
SLIDESHOW_INTERVAL_FILE="/tmp/ticker_slideshow_interval"
CENTS_FILE="/tmp/ticker_cents"
HTML_FILE="$SCRIPT_DIR/ticker-ui.html"

if [[ "${1:-}" == "--handle" ]]; then
    read -r line
    path=$(echo "$line" | awk '{print $2}')

    while read -r header; do
        [[ "$header" == $'\r' || -z "$header" ]] && break
    done

    status="200 OK"
    content_type="text/plain"
    body=""

    sanitize_sym() {
        local s="$1"
        s=$(echo "$s" | sed 's/%3D/=/gI; s/%3d/=/g; s/%5E/^/gI')
        echo "$s" | tr -cd 'A-Za-z0-9._^=/-' | tr '[:lower:]' '[:upper:]'
    }

    case "$path" in
        /|/index.html)
            content_type="text/html"
            if [[ -f "$HTML_FILE" ]]; then
                body=$(cat "$HTML_FILE")
            else
                body="<h1>ticker-ui.html not found</h1>"
            fi
            ;;

        /api/status)
            content_type="application/json"
            mode="single"
            [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE" | tr -d '[:space:]')
            syms_json="[]"
            if [[ -f "$SYMBOLS_FILE" ]]; then
                syms_json=$(awk 'BEGIN{printf "["} NR>1{printf ","} {gsub(/"/,"\\\""); printf "\"%s\"",$0} END{printf "]"}' "$SYMBOLS_FILE")
            fi
            font="Colossal"
            [[ -f "$FONT_FILE" ]] && font=$(cat "$FONT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            sym_font="Banner"
            [[ -f "$SYM_FONT_FILE" ]] && sym_font=$(cat "$SYM_FONT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            info_font="halfiwi"
            [[ -f "$INFO_FONT_FILE" ]] && info_font=$(cat "$INFO_FONT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            fontdir="/usr/share/figlet"
            fonts_json=$( {
                ls "$fontdir"/*.flf 2>/dev/null | sed 's|.*/||;s|\.flf||'
                ls "$fontdir"/*.tlf 2>/dev/null | sed 's|.*/||;s|\.tlf||'
            } | sort -uf | awk 'BEGIN{printf "["} NR>1{printf ","} {gsub(/"/,"\\\""); printf "\"%s\"",$0} END{printf "]"}' )
            # Build aliases JSON object from /tmp/ticker_aliases
            aliases_json="{}"
            if [[ -f "$ALIASES_FILE" ]]; then
                aliases_json="{"
                first=1
                while IFS=$'\t' read -r akey aval; do
                    akey=$(echo "$akey" | tr -d '[:space:]')
                    [[ -z "$akey" || -z "$aval" ]] && continue
                    akey=$(echo "$akey" | sed 's/"/\\"/g')
                    aval=$(echo "$aval" | sed 's/"/\\"/g')
                    [[ $first -eq 0 ]] && aliases_json+=","
                    aliases_json+="\"${akey}\":\"${aval}\""
                    first=0
                done < "$ALIASES_FILE"
                aliases_json+="}"
            fi
            slideshow_interval=5
            [[ -f "$SLIDESHOW_INTERVAL_FILE" ]] && slideshow_interval=$(cat "$SLIDESHOW_INTERVAL_FILE" | tr -d '[:space:]')
            # Build cents JSON object from /tmp/ticker_cents
            cents_json="{}"
            if [[ -f "$CENTS_FILE" ]]; then
                cents_json="{"
                cfirst=1
                while IFS=$'\t' read -r ckey cval; do
                    ckey=$(echo "$ckey" | tr -d '[:space:]')
                    [[ -z "$ckey" || -z "$cval" ]] && continue
                    ckey=$(echo "$ckey" | sed 's/"/\\"/g')
                    cval=$(echo "$cval" | sed 's/"/\\"/g')
                    [[ $cfirst -eq 0 ]] && cents_json+=","
                    cents_json+="\"${ckey}\":\"${cval}\""
                    cfirst=0
                done < "$CENTS_FILE"
                cents_json+="}"
            fi
            body="{\"mode\":\"$mode\",\"symbols\":$syms_json,\"font\":\"$font\",\"sym_font\":\"$sym_font\",\"info_font\":\"$info_font\",\"fonts\":$fonts_json,\"aliases\":$aliases_json,\"cents\":$cents_json,\"slideshow_interval\":$slideshow_interval}"
            # Use byte count (not ${#body}) — alias values may contain non-ASCII (PITFALLS.md Pitfall 1)
            byte_len=$(printf '%s' "$body" | wc -c)
            printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
                "$byte_len" "$body"
            exit 0
            ;;

        /set/*)
            symbol=$(sanitize_sym "${path#/set/}")
            if [[ -z "$symbol" ]]; then
                status="400 Bad Request"; body="Missing symbol"
            else
                # Move symbol to front of list without wiping other symbols
                if [[ -f "$SYMBOLS_FILE" ]]; then
                    { echo "$symbol"; grep -vx "$symbol" "$SYMBOLS_FILE" || true; } > "$SYMBOLS_FILE.tmp"
                    mv "$SYMBOLS_FILE.tmp" "$SYMBOLS_FILE"
                else
                    echo "$symbol" > "$SYMBOLS_FILE"
                fi
                echo "single" > "$MODE_FILE"
                body="OK — single mode: $symbol"
            fi
            ;;

        /list/*)
            raw="${path#/list/}"
            IFS=',' read -ra parts <<< "$raw"
            syms=()
            for s in "${parts[@]}"; do
                clean=$(sanitize_sym "$s")
                [[ -n "$clean" ]] && syms+=("$clean")
            done
            if [[ ${#syms[@]} -eq 0 ]]; then
                status="400 Bad Request"; body="No valid symbols"
            else
                printf '%s\n' "${syms[@]}" > "$SYMBOLS_FILE"
                echo "list" > "$MODE_FILE"
                body="OK — list mode: ${syms[*]}"
            fi
            ;;

        /slideshow/*)
            raw="${path#/slideshow/}"
            IFS=',' read -ra parts <<< "$raw"
            syms=()
            for s in "${parts[@]}"; do
                clean=$(sanitize_sym "$s")
                [[ -n "$clean" ]] && syms+=("$clean")
            done
            if [[ ${#syms[@]} -eq 0 ]]; then
                status="400 Bad Request"; body="No valid symbols"
            else
                printf '%s\n' "${syms[@]}" > "$SYMBOLS_FILE"
                echo "slideshow" > "$MODE_FILE"
                body="OK — slideshow mode: ${syms[*]}"
            fi
            ;;

        /add/*)
            symbol=$(sanitize_sym "${path#/add/}")
            if [[ -z "$symbol" ]]; then
                status="400 Bad Request"; body="Missing symbol"
            else
                if [[ -f "$SYMBOLS_FILE" ]] && grep -qx "$symbol" "$SYMBOLS_FILE"; then
                    body="$symbol already in list"
                else
                    echo "$symbol" >> "$SYMBOLS_FILE"
                    body="OK — added $symbol"
                fi
                count=$(wc -l < "$SYMBOLS_FILE")
                if [[ $count -gt 1 ]]; then
                    cur_mode="single"
                    [[ -f "$MODE_FILE" ]] && cur_mode=$(cat "$MODE_FILE" | tr -d '[:space:]')
                    [[ "$cur_mode" == "single" ]] && echo "slideshow" > "$MODE_FILE"
                fi
            fi
            ;;

        /remove/*)
            symbol=$(sanitize_sym "${path#/remove/}")
            if [[ -z "$symbol" ]]; then
                status="400 Bad Request"; body="Missing symbol"
            elif [[ ! -f "$SYMBOLS_FILE" ]] || ! grep -qx "$symbol" "$SYMBOLS_FILE"; then
                status="404 Not Found"; body="$symbol not in list"
            else
                grep -vx "$symbol" "$SYMBOLS_FILE" > "$SYMBOLS_FILE.tmp"
                mv "$SYMBOLS_FILE.tmp" "$SYMBOLS_FILE"
                count=$(wc -l < "$SYMBOLS_FILE")
                [[ $count -le 1 ]] && echo "single" > "$MODE_FILE"
                body="OK — removed $symbol ($count remaining)"
            fi
            ;;

        /mode/single|/mode/list|/mode/slideshow)
            m="${path#/mode/}"
            echo "$m" > "$MODE_FILE"
            body="OK — mode: $m"
            ;;

        /font/*)
            font_name="${path#/font/}"
            font_name=$(echo "$font_name" | sed 's/%20/ /g; s/+/ /g')
            if [[ -z "$font_name" ]]; then
                status="400 Bad Request"; body="Missing font name"
            else
                echo "$font_name" > "$FONT_FILE"
                body="OK — font: $font_name"
            fi
            ;;

        /sym_font/*)
            font_name="${path#/sym_font/}"
            font_name=$(echo "$font_name" | sed 's/%20/ /g; s/+/ /g')
            if [[ -z "$font_name" ]]; then
                status="400 Bad Request"; body="Missing font name"
            else
                echo "$font_name" > "$SYM_FONT_FILE"
                body="OK — ticker font: $font_name"
            fi
            ;;

        /info_font/*)
            font_name="${path#/info_font/}"
            font_name=$(echo "$font_name" | sed 's/%20/ /g; s/+/ /g')
            if [[ -z "$font_name" ]]; then
                status="400 Bad Request"; body="Missing font name"
            else
                echo "$font_name" > "$INFO_FONT_FILE"
                body="OK — info font: $font_name"
            fi
            ;;

        /cents/set/*/*)
            rest="${path#/cents/set/}"
            symbol="${rest%%/*}"
            val="${rest#*/}"
            symbol=$(sanitize_sym "$symbol")
            val=$(echo "$val" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [[ -z "$symbol" || ( "$val" != "yes" && "$val" != "no" && "$val" != "auto" ) ]]; then
                status="400 Bad Request"; body="Usage: /cents/set/SYMBOL/yes|no|auto"
            else
                if [[ "$val" == "auto" ]]; then
                    # Remove entry — auto is the default
                    if [[ -f "$CENTS_FILE" ]]; then
                        grep -v "^${symbol}	" "$CENTS_FILE" > "$CENTS_FILE.tmp" || true
                        mv "$CENTS_FILE.tmp" "$CENTS_FILE"
                    fi
                else
                    if [[ -f "$CENTS_FILE" ]]; then
                        grep -v "^${symbol}	" "$CENTS_FILE" > "$CENTS_FILE.tmp" || true
                        mv "$CENTS_FILE.tmp" "$CENTS_FILE"
                    fi
                    printf '%s\t%s\n' "$symbol" "$val" >> "$CENTS_FILE"
                fi
                body="OK — cents for $symbol: $val"
            fi
            ;;

        /slideshow_interval/*)
            val="${path#/slideshow_interval/}"
            val=$(echo "$val" | tr -d '[:space:]')
            if [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 2 || "$val" -gt 60 ]]; then
                status="400 Bad Request"; body="Interval must be 2-60 seconds"
            else
                echo "$val" > "$SLIDESHOW_INTERVAL_FILE"
                body="OK — slideshow interval: ${val}s"
            fi
            ;;

        /preview/*/*)
            slot="${path#/preview/}"
            font_name="${slot#*/}"
            slot="${slot%%/*}"
            font_name=$(echo "$font_name" | sed 's/%20/ /g; s/+/ /g')

            case "$slot" in
                font)      sample='$1234' ;;
                sym_font)  sample='BTC' ;;
                info_font) sample='+2.34%' ;;
                *)
                    printf "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\nUnknown slot: %s" \
                        "$((14 + ${#slot}))" "$slot"
                    exit 0
                    ;;
            esac

            fontdir="/usr/share/figlet"
            if [[ ! -f "$fontdir/${font_name}.flf" && ! -f "$fontdir/${font_name}.tlf" ]]; then
                err_body="Unknown font: $font_name"
                printf "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
                    "${#err_body}" "$err_body"
                exit 0
            fi

            # Command substitution strips trailing newline — consistent with byte count below
            body=$(figlet -f "$font_name" -w 1000 -- "$sample" 2>/dev/null)
            if [[ -z "$body" ]]; then
                printf "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 20\r\nConnection: close\r\n\r\nfiglet render failed"
                exit 0
            fi
            # Use byte count (not ${#body} char count) per PITFALLS.md Pitfall 1
            byte_len=$(printf '%s' "$body" | wc -c)
            printf "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
                "$byte_len" "$body"
            exit 0
            ;;

        /alias/set/*/*)
            rest="${path#/alias/set/}"
            symbol="${rest%%/*}"
            name="${rest#*/}"
            symbol=$(sanitize_sym "$symbol")
            # URL-decode alias name but preserve case — do NOT uppercase
            name=$(echo "$name" | sed 's/%20/ /g; s/+/ /g; s/%2F/\//g; s/%3D/=/g; s/%5E/^/g')
            name=$(echo "$name" | tr -cd '[:print:]' | tr -d $'\n')
            if [[ -z "$symbol" || -z "$name" ]]; then
                status="400 Bad Request"; body="Missing symbol or name"
            else
                if [[ -f "$ALIASES_FILE" ]]; then
                    grep -v "^${symbol}	" "$ALIASES_FILE" > "$ALIASES_FILE.tmp" || true
                    mv "$ALIASES_FILE.tmp" "$ALIASES_FILE"
                fi
                printf '%s\t%s\n' "$symbol" "$name" >> "$ALIASES_FILE"
                body="OK — alias: $symbol -> $name"
            fi
            ;;

        /alias/remove/*)
            symbol=$(sanitize_sym "${path#/alias/remove/}")
            if [[ -z "$symbol" ]]; then
                status="400 Bad Request"; body="Missing symbol"
            else
                if [[ -f "$ALIASES_FILE" ]]; then
                    grep -v "^${symbol}	" "$ALIASES_FILE" > "$ALIASES_FILE.tmp" || true
                    mv "$ALIASES_FILE.tmp" "$ALIASES_FILE"
                fi
                body="OK — alias removed: $symbol"
            fi
            ;;

        /reorder/*)
            raw="${path#/reorder/}"
            IFS=',' read -ra parts <<< "$raw"
            syms=()
            for s in "${parts[@]}"; do
                clean=$(sanitize_sym "$s")
                [[ -n "$clean" ]] && syms+=("$clean")
            done
            if [[ ${#syms[@]} -eq 0 ]]; then
                status="400 Bad Request"; body="No valid symbols"
            else
                current_count=0
                [[ -f "$SYMBOLS_FILE" ]] && current_count=$(wc -l < "$SYMBOLS_FILE")
                if [[ ${#syms[@]} -ne $current_count ]]; then
                    status="400 Bad Request"; body="Symbol count mismatch — refresh and retry"
                else
                    printf '%s\n' "${syms[@]}" > "$SYMBOLS_FILE.tmp"
                    mv "$SYMBOLS_FILE.tmp" "$SYMBOLS_FILE"
                    body="OK — reordered: ${syms[*]}"
                fi
            fi
            ;;

        /fonts)
            fontdir="/usr/share/figlet"
            body=$( {
                ls "$fontdir"/*.flf 2>/dev/null | sed 's|.*/||;s|\.flf||'
                ls "$fontdir"/*.tlf 2>/dev/null | sed 's|.*/||;s|\.tlf||'
            } | sort -uf )
            ;;

        *)
            status="404 Not Found"; body="Not found"
            ;;
    esac

    byte_len=$(printf '%s' "$body" | wc -c)
    printf "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$status" "$content_type" "$byte_len" "$body"
    exit 0
fi

PORT="${1:-8080}"
SCRIPT="$(readlink -f "$0")"

echo "tickerctl listening on port $PORT"
echo "  http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT/"

exec socat TCP-LISTEN:"$PORT",reuseaddr,fork EXEC:"$SCRIPT --handle"

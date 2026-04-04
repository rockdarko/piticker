# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PiTicker is a fullscreen stock/crypto price display for Raspberry Pi with GPIO touchscreen. Prices render as large ASCII art via figlet fonts, color-coded green/red. A web UI (served from the Pi) controls everything. Pure Bash + vanilla JS, no frameworks or build tools.

## Architecture

Four files make up the entire system:

- **ticker.sh** — Main display loop. Fetches prices from Yahoo Finance chart API, renders ASCII art via figlet to a TTY. Three display modes: single, slideshow, list. Uses `inotifywait` to react instantly to state file changes instead of polling.
- **tickerctl.sh** — HTTP control server built on `socat`. Each request forks a new process (`socat ... EXEC:"$0 --handle"`). Serves the web UI at `/` and exposes a REST-ish API for all controls. Reads/writes the same `/tmp/ticker_*` state files that ticker.sh watches.
- **ticker-ui.html** — Single-file web UI (HTML/CSS/JS). Mobile-first dark theme. Manages symbols, fonts, aliases, cents preferences, drag-to-reorder. Communicates with tickerctl.sh via fetch calls.
- **install.sh** / **uninstall.sh** — Interactive installer/uninstaller. Creates systemd services (`piticker.service`, `piticker-ctl.service`), installs deps, handles GPIO display detection and screen rotation.

## State File IPC

ticker.sh and tickerctl.sh communicate through `/tmp/ticker_*` files — this is the core IPC mechanism:

| File | Content |
|------|---------|
| `/tmp/ticker_mode` | `single`, `slideshow`, or `list` |
| `/tmp/ticker_symbols` | One symbol per line |
| `/tmp/ticker_font` | Price font name |
| `/tmp/ticker_sym_font` | Ticker name font |
| `/tmp/ticker_info_font` | Change/percent font |
| `/tmp/ticker_aliases` | TSV: `SYMBOL\tdisplay_name` |
| `/tmp/ticker_cents` | TSV: `SYMBOL\tyes|no` |
| `/tmp/ticker_slideshow_interval` | Integer 2-60 (seconds) |

## Key Implementation Details

- **Content-Length must use byte count** (`printf '%s' "$body" | wc -c`), not `${#body}` char count. Figlet fonts with multi-byte UTF-8 chars (e.g. ANSI Shadow box-drawing) cause mismatches otherwise.
- **natural_width()** uses `${#line}` (char count) rather than `awk length` for the opposite reason — awk counts bytes, inflating width calculations for multi-byte chars.
- **Font fallback chain**: tries user font -> Colossal -> Banner -> big, each with full text first then without cents, before falling back to plain text.
- **sanitize_sym()** in tickerctl.sh URL-decodes `%3D`->`=`, `%5E`->`^` and uppercases symbols. Alias names preserve case.
- Yahoo Finance API endpoint: `https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?interval=1d&range=1d`

## Dependencies

figlet, toilet, jq, curl, socat, inotify-tools

## Testing Locally (without a Pi)

```bash
# Run the display in a terminal (needs figlet, jq, curl)
./ticker.sh BTC-USD

# Run the control server (needs socat)
./tickerctl.sh 8080
# Then open http://localhost:8080/
```

## Managing on Pi

```bash
sudo systemctl start|stop|restart piticker      # display
sudo systemctl start|stop|restart piticker-ctl   # web server
journalctl -u piticker -f                        # logs
```

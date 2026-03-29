# PiTicker

Fullscreen stock and crypto price display for Raspberry Pi with GPIO touchscreen. Prices render as large ASCII art using [figlet](http://www.figlet.org/) fonts, color-coded green/red for up/down. Control everything from your phone via the built-in web UI.

## What it looks like

- **Single mode** — one symbol, big ASCII art price filling the screen
- **Slideshow mode** — cycles through symbols with configurable interval
- **List mode** — table view of multiple symbols at once

## Hardware

**Raspberry Pi** — any model with GPIO header (tested on Pi 3B+)

**GPIO Display** — 3.5" TFT touchscreen, plugs directly into the GPIO pins:
- [Kuman 3.5" TFT LCD (Amazon)](https://www.amazon.ca/dp/B0BJDTL9J3)
- Any goodtft-compatible 3.5" GPIO display should work

**Display driver setup** — use the [goodtft/LCD-show](https://github.com/goodtft/LCD-show) scripts:
```bash
git clone https://github.com/goodtft/LCD-show.git
cd LCD-show
sudo ./LCD35-show    # for 3.5" screens — reboots the Pi
```
To switch back to HDMI: `sudo ./LCD-hdmi`

## Install

```bash
git clone https://github.com/rockdarko/piticker.git
cd piticker
sudo ./install.sh
```

The installer will:
1. Check for GPIO display configuration
2. Offer to rotate the screen 180° (for upside-down mounts)
3. Ask for install path, initial symbols, web UI port, and display TTY
4. Install dependencies (figlet, jq, curl, socat, inotify-tools)
5. Set up systemd services that start on boot

## Web Control

After install, open `http://<pi-ip>:8080/` from any device on the network.

**Features:**
- Switch display modes (Single / Slideshow / List)
- Add and remove symbols — stocks, crypto, indices, forex
- Drag to reorder symbols
- Set custom display names (e.g., "CL=F" → "Oil")
- Choose cents display per symbol (Auto / Show / Hide)
- Live font preview with Apply button
- Adjustable slideshow interval

## Symbols

Works with anything Yahoo Finance supports:
- **Stocks** — `AAPL`, `MSFT`, `NVDA`, `TSLA`
- **Crypto** — `BTC-USD`, `ETH-USD`, `SOL-USD`
- **Indices** — `^GSPC` (S&P 500), `^DJI` (Dow Jones)
- **Forex** — `EURUSD=X`, `GBPUSD=X`
- **Commodities** — `CL=F` (Oil), `GC=F` (Gold)

## Managing

```bash
# Start / stop / restart
sudo systemctl start piticker
sudo systemctl stop piticker
sudo systemctl restart piticker

# Control server
sudo systemctl start piticker-ctl
sudo systemctl stop piticker-ctl

# View logs
journalctl -u piticker -f

# Change what's displayed (no SSH needed)
curl http://pi:8080/set/ETH-USD
curl http://pi:8080/list/BTC-USD,ETH-USD,AAPL
curl http://pi:8080/add/NVDA
curl http://pi:8080/remove/AAPL
```

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes services, files, and state. Does not change screen rotation settings.

## Fonts

PiTicker uses [figlet](http://www.figlet.org/) to render prices as large ASCII art. It ships with whatever fonts are installed on your system — the installer pulls in both `figlet` and `toilet` which together provide 300+ fonts.

The web UI lets you preview any installed font before applying it. PiTicker uses three independent font slots:
- **Ticker font** — the symbol name (e.g., BTC)
- **Price font** — the big price display (e.g., $42,567)
- **Change font** — the percent change (e.g., +2.34%)

The display auto-fits: if your chosen font is too wide for the screen, it gracefully falls back to a smaller font. You can also force cents on or off per symbol to help things fit.

Some fonts that work well on small GPIO screens: `Banner`, `Colossal`, `big`, `ANSI Shadow`, `DOS Rebel`, `Doom`, `Electronic`.

## How this was built

This project was vibe coded from start to finish. I'm not a developer — I'm an SRE who lives in terminals, writes Bash and Ansible in my sleep, and spends my days wrangling metrics and keeping systems alive. I had the idea for a desk ticker, knew exactly how I wanted it to work, and paired with AI to build it.

The entire project — every feature, every bug fix, every UI decision — was built in a single session using [Claude Code](https://claude.ai/claude-code) with the [Get Shit Done (GSD)](https://github.com/gsd-build/get-shit-done) workflow framework. GSD handled the planning, phasing, execution, and verification while I drove the product decisions.

**Models used:** Claude Opus 4.6 (orchestration), Claude Sonnet 4.6 (planning, research, execution agents)

The result: ~2,200 lines of pure Bash and vanilla JS, zero frameworks, zero build tools — just the kind of clean, dependency-light stack an SRE can appreciate.

## License

MIT

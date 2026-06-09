# gtm

A terminal-based music player with tabbed interface, daemon architecture, and comprehensive library management.

## Features

- **Daemon Architecture**: Background playback daemon with TUI client
- **Tabbed Interface**: Now Playing, Library, Playlists, Settings tabs
- **Command Palette**: Fuzzy-search commands with `:`
- **Leader Key**: Space shows context menu; double-tap toggles play/pause
- **Select Mode**: Vim-style visual selection + per-item toggle
- **Library Management**: SQLite-backed track/artist/album/playlist database
- **Audio Backend**: FFmpeg + ALSA — system libraries, full format support
- **Visualizer**: Real-time FFT spectrum analyzer via shared memory
- **11 Themes**: Catppuccin (4), Gruvbox (2), Dracula, Tokyo Night (2), Ayu (2)
- **Responsive Layout**: Adapts to terminal width (≥120, 60–119, 40–59 cols)
- **Nerd Font Icons**: Auto-detected with emoji fallback
- **Configurable**: JSON config with JSON Schema validation
- **Remote Control**: CLI commands for daemon control (`gtm play`, `gtm pause`, etc.)

## Quick Start

```bash
gtm ~/Music           # Launch TUI with music directory
gtm play              # If daemon is running, resume playback
gtm daemon            # Start daemon manually
```

## Keybindings

| Key | Action |
|-----|--------|
| `Space` | Leader key (hold for menu) |
| `Space Space` | Toggle play/pause |
| `s` | Stop |
| `h` / `l` | Seek backward/forward 5s |
| `j` / `k` | Navigate up/down |
| `1`-`4` | Switch tabs |
| `:` | Open command palette |
| `/` | Filter items |
| `v` | Toggle select mode |
| `?` | Help |
| `q` | Quit |

## Tabs

1. **Now Playing** — Current track info, progress bar, status
2. **Library** — Browse by tracks, artists, or albums
3. **Playlists** — Manage saved playlists
4. **Settings** — Theme selection, volume, visualizer toggle

## Installation

```bash
nim c -d:release src/gtm.nim
cp bin/gtm ~/.local/bin/
```

## Configuration

`~/.config/gtm/config.json` (see `config.schema.json`):

```json
{
  "theme": "mocha",
  "volume": 80,
  "idle_timeout": 300,
  "visualizer": { "enabled": true, "bar_count": 32 }
}
```

## Requirements

- Nim >= 2.0.0
- Linux with `/dev/shm` (for visualizer)
- Terminal with true color support recommended

## Development

```bash
nim c -d:release src/gtm.nim              # release build
nim check src/gtm.nim                      # syntax check
```

## Architecture

```
┌──────────┐    Unix socket     ┌──────────┐
│  gtm TUI  │◄─────────────────►│  gtm-d   │
│  (client) │    JSON IPC       │ (daemon) │
└──────────┘                    └──────────┘
                                      │
                               ┌──────┴──────┐
                                │ ffmpeg + alsa│
                                │  (playback)  │
                               └──────┬──────┘
                                      │ PCM via
                                      │ shm/mmap
                               ┌──────┴──────┐
                               │  visualizer  │
                               │  (FFT bars)  │
                               └─────────────┘
```

---

> ## License 📜

> (c) 2026, [prjctimg](https://prjctimg.me)
>
> This is free software, released under the GPL-3.0 license.

---
---

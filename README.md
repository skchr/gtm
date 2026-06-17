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

## Demos

| Overlay | Trigger | Recording |
|---------|---------|-----------|
| **Now Playing** | default view | `your-asciicast-id` |
| **Library** | `2` | `your-asciicast-id` |
| **Playlists** | `3` | `your-asciicast-id` |
| **Settings** | `4` | `your-asciicast-id` |
| **Help Overlay** | `?` / `Alt+H` | `your-asciicast-id` |
| **About Overlay** | `Alt+A` | `your-asciicast-id` |
| **Trash Overlay** | `Alt+T` | `your-asciicast-id` |
| **Equalizer** | `Alt+E` | `your-asciicast-id` |
| **EQ Presets** | `:` → "EQ Presets" | `your-asciicast-id` |
| **Theme Picker** | `Alt+C` | `your-asciicast-id` |
| **Command Palette** | `:` | `your-asciicast-id` |
| **Leader Menu** | `Ctrl+L` | `your-asciicast-id` |
| **YouTube Search** | `Alt+Y` | `your-asciicast-id` |
| **Fuzzy Finder** | `Alt+F` | `your-asciicast-id` |
| **Enqueue** | `Alt+I` | `your-asciicast-id` |
| **Queue Overlay** | `Alt+Q` | `your-asciicast-id` |
| **Playlist Input** | `Alt+P` / `a` | `your-asciicast-id` |
| **Volume Cue** | `+` / `-` | `your-asciicast-id` |
| **Now Playing Cue** | track change | `your-asciicast-id` |
| **Up Next Cue** | queue advance | `your-asciicast-id` |

Replace each `your-asciicast-id` with your asciinema recording ID:

```markdown
[![asciicast](https://asciinema.org/a/your-asciicast-id.svg)](https://asciinema.org/a/your-asciicast-id)
```

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
| `Alt+T` | Trash (browse/restore/delete) |
| `Alt+X` | Delete selected tracks |
| `q` | Quit |

## Tabs

1. **Now Playing** — Current track info, progress bar, status
2. **Library** — Browse by tracks, artists, or albums
3. **Playlists** — Manage saved playlists
4. **Settings** — Theme selection, volume, visualizer toggle

## Installation

### From source

```bash
nim c -d:release src/gtm.nim
cp bin/gtm ~/.local/bin/
```

### One-liner (requires published releases)

```bash
curl -sf https://raw.githubusercontent.com/skchr/gtm/main/install.sh | sh
```

Override version or prefix:

```bash
VERSION=0.5.3 PREFIX=/usr/local curl -sf https://raw.githubusercontent.com/skchr/gtm/main/install.sh | sh
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

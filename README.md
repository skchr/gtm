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

See [INSTALL.md](INSTALL.md) for install instructions (one-liner, from source, post-install steps).

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

## Spotify Setup

gtm can import Spotify playlists and search Spotify tracks via [spotDL](https://github.com/spotDL/spotify-downloader).

1. **Install spotDL**:
   ```bash
   pip install spotdl
   ```

2. **Cookies from browser** (recommended): gtm uses `--cookies-from-browser` (via yt-dlp's JS runtime) to authenticate with YouTube for Spotify downloads. No manual cookie file needed — just run spotDL once to cache your session:
   ```bash
   spotdl --cookies-from-browser firefox "https://open.spotify.com/playlist/..."
   ```
   Replace `firefox` with `chrome`, `brave`, `edge`, etc. depending on your browser.

3. **Configure in gtm**: Settings tab → Spotify section:
   - Set `spotdl` binary path (default: `spotdl` on PATH)
   - Optionally set output directory and format
   - Import playlist URLs via `Alt+S` or the Settings menu

4. **Import a Spotify playlist URL**: Press `Alt+S`, paste the URL (e.g. `https://open.spotify.com/playlist/...`), and press Enter. gtm will fetch metadata via spotDL and queue the downloads.

## Building & Documentation

| Resource | Description |
|----------|-------------|
| [BUILD.md](BUILD.md) | Build prerequisites and commands |
| [DOCS.md](DOCS.md) | Documentation system reference |
| [INSTALL.md](INSTALL.md) | Installation instructions |

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
## Technical Changes (v0.7.30)

### Queue & Playlist Index Consistency

The codebase uses five distinct indexing systems: `libraryTracks[i]` (library array position, changes on rescan), `displayItems[i]` (UI visible item position, rebuilt per view change), `playbackQueue[i]` (queue position), `track.id` (stable SQLite row ID), and `UserPlaylist.trackIds` (SQLite IDs in playlist). Seven fixes address index confusion and state sync gaps:

1. **`getCurrentTrack` fallback guard** — Removed `libraryTracks[selectIndex]` fallback that played a random unrelated track when pressing Enter on artist, album, or playlist items. The function now returns an empty `Track()` for non-track selections.

2. **`playSelected` non-track guard** — Returns early when the selected item is not a track (`kind != likTrack`), preventing Enter on artist/album/playlist/Spotify playlist items from triggering playback of a wrong track.

3. **Dead fallback removal** — Removed unreachable fallback loop in `playSelected` that iterated `libraryTracks` by raw index (ignoring sort/filter), which was dead code after the above two guards.

4. **Playlist contents rendering** — `rebuildItems` now renders individual playlist tracks (via `trackIds`→`libraryTracks` index resolution) when `playlistContentsIdx >= 0`, instead of showing the playlist list stub. Users can now see, scroll, and play tracks inside a playlist view.

5. **Shuffle order sync** — `shuffleOrder` from daemon `queue_changed` events was missing from the IPC metadata key list (`src/session.nim:146`) and was never parsed by the TUI. Now it is serialized through the wire protocol and reconstructed on the TUI side, so `state.shuffleOrder` reflects the actual daemon permutation.

6. **Queue cursor sync** — Up/Down key presses in the Now Playing tab's "Up Next" section now send `queue_set_cursor` to the daemon, aligning `d.shuffleIndex` with `state.queueCursor` so that Enter on a queue item correctly advances playback to the selected position even in shuffle mode.

7. **File existence validation** — Non-existent local files are now skipped in `dckQueueAdd` (guard before `playbackQueue.add`), rejected in `dckLoadFile` (returns `"file not found"` error), and scanned past in `handleAutoAdvance` (loop advances through the queue until finding a valid path or exhausting the queue).

---

> ## License 📜

> (c) 2026, [prjctimg](https://prjctimg.me)
>
> This is free software, released under the GPL-3.0 license.

---

---

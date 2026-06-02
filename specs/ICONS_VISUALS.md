# State-Dependent Icons & Visuals

## Status
P1 (mute/pause icons don't update based on state)

## Current State
- `src/icons.nim` defines two icon packs: Nerd Font and Emoji fallback
- `currentIcons()` auto-detects which pack to use based on `NERD_FONTS` env var
- However, icons are **not actually used** in the UI rendering code. The UI hardcodes Unicode characters:
  - `ui.nim:268-270`: Status icons are hardcoded (`"\u25B6"`, `"\u23F8"`, `"\u25A0"`)
  - `ui.nim:159-163`: Library view uses hardcoded emoji
- `commands.nim`: Uses hardcoded icons in CommandEntry definitions
- No icon reflects mute state (volume=0)

## Requirements

### Runtime State-Dependent Icons
The following components should use icons from `currentIcons()` that reflect the actual playback/mute state:

| UI Element | Current (hardcoded) | Should Use |
|-----------|-------------------|------------|
| ProgressBar status icon (play/pause/stop) | `▶`/`⏸`/`■` | `icons.play` / `icons.pause` / `icons.stop` based on `state.status` |
| Mute indicator | Nothing | `icons.volumeMuted` when volume=0, otherwise volume-level icon |
| Library item icons | Emoji only | `icons.music` / `icons.artist` / `icons.album` / `icons.playlist` |
| Command palette icons | Hardcoded per-command | Already defined in commands — just not used in overlay rendering |
| Settings/status bar | None | Could show state-dependent icons |

### Nerd Font Detection Improvement
Current detection (`icons.nim:47-56`) only checks `NERD_FONTS` env var. Should also:
1. Try rendering a known Nerd Font glyph (e.g., U+F0001) and check width
2. Or check `TERMINFO`/`TERM` for known Nerd Font-compatible terminals

## Implementation Plan
1. Update `ui.nim` to use `currentIcons()` for status-dependent icons
2. Add volume-level icon selection (high/medium/low/muted) in ProgressBarComp
3. Add mute/unmute icon indicator to status bar
4. Update LibraryView to use icon pack
5. Improve Nerd Font detection

## Affected Files
- `src/ui.nim` — ProgressBarComp, StatusBarComp, LibraryView, NowPlayingView
- `src/icons.nim` — improve detection, add convenience procs

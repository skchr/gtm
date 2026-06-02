# Shuffle / Repeat / Sleep

## Status
P3 (entirely missing feature)

## Current State
No shuffle, repeat, or sleep functionality exists anywhere in the codebase. There are no state fields, no UI indicators, no daemon commands, and no keybindings for these features.

### Relevant Existing Code
- `nextTrack` (`gtm.nim:96-101`) simply increments `selectIndex` by 1 (modulo count)
- `prevTrack` (`gtm.nim:103-108`) decrements by 1 (modulo count)
- `displayItems` order is set by `rebuildDisplayItems` and never changes between plays
- No random/shuffle order logic anywhere

## Requirements

### Shuffle Mode
- When enabled, tracks play in random order
- Shuffle creates a shuffled index list when enabled (or on playlist load)
- The shuffled order persists until disabled or playlist changes
- Toggle with `Shift+S` or via command palette (`toggle_shuffle`)
- UI indicator in status bar or ProgressBar: shuffle icon when active
- Scope: shuffle current view (displayItems / filtered list)

### Repeat Modes
Three-state toggle: `Off → All → One → Off`

| Mode | Behavior |
|------|----------|
| Off | Stop after last track |
| All | Repeat entire playlist from beginning after last track |
| One | Repeat current track (replay on end) |

- Cycle with `Shift+R` or via command palette (`toggle_repeat`)
- UI indicator showing current mode:
  - `🔁` (repeat all) in `theme.green`
  - `🔂` (repeat one) in `theme.blue`
  - No icon when off

### Sleep Timer
- Set a timer to automatically stop playback after N minutes
- Trigger via command palette: prompt for minutes (5, 10, 15, 30, 60, or custom)
- Show remaining time in status bar when active
- Cancel by setting timer to 0
- On expiry: pause playback (not stop — preserves position)
- State persists in daemon (so sleep works even with TUI closed)

### Data Flow for End-of-Track
Current `aekTrackEnded` handler (`gtm.nim:536-539`):
```nim
of aekTrackEnded:
  state.player.stop()
  state.status = psStopped
  state.nextTrack()
```

Should become:
```nim
of aekTrackEnded:
  if repeatOne: replay current track
  elif shuffle: select next shuffled index
  elif not repeatAll and last track: stop
  else: nextTrack as usual
  if sleepTimer active and all tracks played since timer start: pause
```

### State Fields
Add to `AppState`:
- `shuffleEnabled: bool` — shuffle on/off
- `shuffleOrder: seq[int]` — shuffled index list
- `shuffleIndex: int` — current position in shuffle order
- `repeatMode: int` — 0=off, 1=all, 2=one
- `sleepTimerRemaining: int` — seconds remaining (0 = off)
- `sleepTimerActive: bool`

### Daemon Integration
Shuffle/repeat logic should work even when TUI is closed:
- Add daemon commands: `set_shuffle`, `set_repeat`, `set_sleep_timer`
- Daemon manages shuffle order and repeat state
- TUI syncs state via status polling

## Implementation Plan
1. Add state fields to `AppState`
2. Add shuffle order generation (Fisher-Yates on displayItems indices)
3. Modify `nextTrack`/`prevTrack` to respect shuffle/repeat modes
4. Add sleep timer countdown logic to main loop
5. Update `aekTrackEnded` handler
6. Add daemon commands for shuffle/repeat/sleep
7. Add UI indicators to ProgressBarComp and StatusBarComp
8. Add keybindings: `Shift+S` for shuffle, `Shift+R` for repeat
9. Add command palette entries

## Affected Files
- `src/state.nim` — add shuffle/repeat/sleep state fields
- `src/gtm.nim` — modify nextTrack, prevTrack, aekTrackEnded handler, add keybindings, add sleep countdown
- `src/daemon.nim` — add daemon commands for shuffle/repeat/sleep
- `src/daemon_client.nim` — add client methods
- `src/ui.nim` — add UI indicators to ProgressBarComp, StatusBarComp
- `src/commands.nim` — register new commands

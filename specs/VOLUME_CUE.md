# Volume Visual Cue

## Status
P1 (user-facing feedback missing)

## Overview
When the user adjusts volume (via `Shift+J`/`Shift+K`/`+`/`-`), there is no visual feedback. The user needs to glance at the Now Playing view or Settings tab to see the current volume level. This spec defines a transient overlay that appears briefly when volume changes.

## Current State
- Volume is changed in `gtm.nim:110-113` (`adjustVolume`) and `gtm.nim:115-120` (`toggleMute`)
- Volume is displayed only in: NowPlayingView (`ui.nim:103`), ProgressBarComp (`ui.nim:245`-275 has no volume), StatusBar has no volume
- No visual cue when volume changes

## Requirements

### Volume Change Cue
- When volume changes, show a transient overlay in the bottom-right of the main content area
- Display format: a volume icon + percentage + a small progress bar (e.g., `♪ 65% [████████░░░░]`)
- Duration: 1.5 seconds, then fade out
- The cue should not block interaction — it's a non-modal overlay

### Display States
| Volume | Icon | Color |
|--------|------|-------|
| 0 (muted) | Mute icon (e.g., `🔇`) | `theme.red` |
| 1-33% | Low volume icon (e.g., `🔈`) | `theme.yellow` |
| 34-66% | Medium volume icon (e.g., `🔉`) | `theme.text` |
| 67-100% | High volume icon (e.g., `🔊`) | `theme.green` |

### Progress Bar
- 10 characters wide
- Filled portion: `theme.mauve` or `theme.blue`
- Empty portion: `theme.surface2`
- Use `█` for filled, `░` for empty (or `━`/`─`)

### Timing
- Show immediately on volume change
- Auto-hide after 1.5 seconds (90 frames at ~16ms)
- Reset timer on each volume change
- Do not show on initial volume setting

### Interaction
- Overlay is purely visual — no hover, no click
- Does not affect key processing
- Drawn on top of existing content

## Implementation Plan
1. Add `volumeCueTimer: int` and `volumeCueVolume: int` fields to `AppState`
2. In `adjustVolume` and `toggleMute`, set the timer to 90 frames and store volume
3. Create `VolumeCueOverlay` component in `ui.nim`
4. Render it in `renderApp` when `volumeCueTimer > 0`
5. Decrement timer each frame

## Affected Files
- `src/state.nim` — add volume cue state fields
- `src/gtm.nim` — set cue on volume change
- `src/ui.nim` — render VolumeCueOverlay component, add to renderApp

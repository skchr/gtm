# UI Components

## Status
P1 (tab fixes, volume cue, unknown fields, time display, mute icon) / P2 (visualizer overlap fix, navigation fixes)

## Tab Bar

### Current Behavior (`src/ui.nim:52-74`)

Tabs display as `[N] Name`. Active tab gets a blue background fill. Inactive tabs show `[N]` in overlay1 and `Name` in subtext0, separated by a space.

### Issues
1. For inactive tabs, the `[N]` and `Name` are written separately at different x positions, but there's no gap between the bracket closing and the name starting
2. The active tab's background fill range calculation may be off: `x + key.runeLen + name.runeLen + 3` — this is `x + len(key) + len(name) + 3` which accounts for `[`, `]`, ` `, and the space before the name. This looks correct.
3. No visual distinction between brackets for active vs inactive tabs

### Requirements
- Active tab: blue background with white text, format: `[1] Now Playing`
- Inactive tab: no special background, `[2]` in overlay0/overlay1, `Library` in subtext0
- Consistent spacing between tabs (2 spaces gap)
- The version label on the right should not overlap with tabs

### Fix Plan
1. Review the x-position math for inactive tabs to ensure proper spacing
2. Ensure brackets `[]` are always present around the tab number
3. Add hover/preview effect is not needed (terminal TUI, no hover)

## Volume Visual Cue

See `VOLUME_CUE.md` for full spec. This is a transient overlay shown when volume changes.

## "Unknown" Field Filtering

### Current Behavior (`src/library.nim:379-383`)

```nim
proc displayArtist*(track: Track): string =
  if track.artist.len > 0: track.artist else: "Unknown Artist"

proc displayAlbum*(track: Track): string =
  if track.album.len > 0: track.album else: "Unknown Album"
```

In `src/ui.nim:92-100`, the `wl` template renders all label/value pairs unconditionally:

```nim
template wl(label, value: string) =
  if value.len > 0:
    writeStr(ctx.tb, 1, line, label & " ", theme.subtext0)
    writeStr(ctx.tb, 1 + label.runeLen + 1, line, value, theme.text)
    line.inc
wl("Track", track.displayName())
wl("Artist", track.displayArtist())
wl("Album", track.displayAlbum())
```

### Requirements
- If `displayArtist` would return `"Unknown Artist"`, hide the entire Artist row
- If `displayAlbum` would return `"Unknown Album"`, hide the entire Album row
- Only "Track", "Status", "Volume", and "Time" are always shown
- The `wll` template should check if the value is "Unknown" before rendering

### Implementation
Change the `wl` template call to either:
```nim
if track.artist.len > 0:
  wl("Artist", track.artist)
```
Or modify `wl` to skip when value starts with "Unknown".

### Affected Files
- `src/ui.nim` — NowPlayingView, `wl` template
- `src/library.nim` — displayArtist, displayAlbum (no change needed, these are fine as-is)

## Time Display

### Current Behavior (`src/ui.nim:105-107, 245-248`)

Shows `[elapsed] / [total]` format (e.g., `1:23 / 3:45`).

### Requirements
Change to `[elapsed] / [remaining]` where remaining = duration - timePos.
Example: `1:23 / -2:22`

The remaining should be shown as a negative offset from the end, or simply the remaining time. Most music players show either:
- `1:23 / 3:45` (elapsed / total) — current implementation
- `1:23 / -2:22` (elapsed / remaining) — requested format

### Implementation
```nim
let elapsed = formatTime(state.timePos)
let remaining = formatTime(state.duration - state.timePos)
let timeText = elapsed & " / -" & remaining
```

### Affected Files
- `src/ui.nim:247` — ProgressBarComp render
- `src/ui.nim:106` — NowPlayingView render

## Right Sidebar / Visualizer Overlap

### Current Behavior (`src/ui.nim:474-483`)

```nim
case ctx.data.tab
of tabNowPlaying:
  if w >= 120:
    # Split: 2/3 NowPlaying, 1/3 Visualizer
    sliceCtx = nw.slice(ctx, 0, y, splitW, mainH); render(NowPlayingView(), sliceCtx)
    sliceCtx = nw.slice(ctx, splitW + 1, y, w - splitW - 1, mainH); render(VisualizerView(), sliceCtx)
  elif w >= 60:
    # BUG: Both rendered at same position — they overlap!
    sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(NowPlayingView(), sliceCtx)
    sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(VisualizerView(), sliceCtx)
  else:
    sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(NowPlayingView(), sliceCtx)
```

### Requirement
At width 60-119, the visualizer should be placed as a right sidebar (e.g., 20-30% of width), not overlapping the NowPlaying view.

### Fix
```nim
elif w >= 60:
  let splitW = w - 20  # reserve 20 cols for visualizer
  sliceCtx = nw.slice(ctx, 0, y, splitW, mainH); render(NowPlayingView(), sliceCtx)
  sliceCtx = nw.slice(ctx, splitW, y, w - splitW, mainH); render(VisualizerView(), sliceCtx)
```

### Clarification in UI
The visualizer is a real-time FFT spectrum analyzer showing frequency bars. It is rendered via shared memory PCM data (see `src/visualizer.nim`). At widths < 60, it is hidden. At widths 60-119, it appears as a narrow sidebar. At widths >= 120, it gets 1/3 of the screen.

## Navigation Fixes

### Playlists Tab
- Enter on a playlist should open its contents (list of tracks in the playlist)
- Need a "back" navigation (Escape) to return to playlist list
- j/k navigation in playlist contents view should work

### Command Palette
- See `COMMAND_PALETTE.md` for specifics

### General
- Ensure `moveSelection` works correctly when `filteredIndices` is active
- Ensure `gg` (go to first) and `ShiftG` (go to last) work on all tabs

### Affected Files
- `src/gtm.nim` — key handling for playlists, Enter behavior
- `src/ui.nim` — PlaylistsView may need a sub-view for playlist contents
- `src/state.nim` — may need state for "inside playlist" view

# Command Palette

## Status
P2 (partially implemented, navigation may have issues)

## Current State

### Implementation
- Triggered by `:` key (`gtm.nim:438-443`)
- Implemented as an overlay in `ui.nim:334-363` (`CommandPaletteOverlay`)
- Commands registered in `commands.nim:50-112` (`buildDefaultCommands`)
- Fuzzy matching logic in `commands.nim:8-15` (`fuzzyMatch`)
- Filtering on query in `gtm.nim:351-357` (inline fuzzy match)
- Navigation: `j/k` or `Up/Down` in `gtm.nim:340-345`
- Execute on `Enter` in `gtm.nim:325-336`

### Issues
1. **Trigger vs Filter**: PROMPT.md requests `Trigger the search for the commands using '/'.` Currently `:` opens palette, `/` opens filter mode. The user may want `/` to filter within the palette instead of the current filter mode.
2. **Palette Results Rendering**: `ui.nim:348` iterates by index `i` but compares against `paletteSelect` which is the index in results, not the index in the iteration. The iteration goes from `i=0` to `displayResults`, and `paletteSelect` is an index into `paletteResults`. This looks correct but `i == ctx.data.paletteSelect` should match the selected item.
3. **Display Limit**: Shows max 10 results (`displayResults = 10`). Should show more (at least 15-20) in larger terminals.
4. **Commands Missing**: PROMPT.md requests adding more commands. Current commands are basic playback/navigation. Missing: shuffle, repeat, sleep timer, crossfade toggle, playlist operations.
5. **No category grouping**: Results are flat. Could group by category (`ccPlayback`, `ccNavigation`, etc.).

## Requirements

### Opening the Palette
- `:` opens the command palette overlay
- `/` triggers search/filter within currently shown content (separate from palette)

### Palette UI
- Overlay centered on screen
- Shows a text input at the bottom: `> query`
- Results list with fuzzy matching against command name, description, and ID
- Results show: icon + name + keybinding hint
- Selected item highlighted with background color

### Navigation
- `j`/`K` or `Up`/`Down`: Move selection
- `Enter`: Execute selected command and close palette
- `Escape`: Close palette without action
- Typing filters results in real-time

### Commands to Add
| Command | ID | Description |
|---------|----|-------------|
| Toggle Shuffle | `toggle_shuffle` | Enable/disable shuffle mode |
| Toggle Repeat | `toggle_repeat` | Cycle: none → all → one → none |
| Set Sleep Timer | `sleep_timer` | Prompt for minutes until auto-stop |
| Toggle Crossfade | `toggle_crossfade` | Enable/disable crossfade transition |
| Create Playlist | `create_playlist` | Create new playlist |
| Delete Playlist | `delete_playlist` | Delete selected playlist |
| Rename Playlist | `rename_playlist` | Rename selected playlist |
| Import M3U | `import_m3u` | Import playlist from .m3u file |
| Export M3U | `export_m3u` | Export playlist to .m3u file |
| Rescan Library | `rescan_library` | Rescan music directories |
| Show Now Playing | `show_now_playing` | Jump to Now Playing view |

### Fuzzy Search Improvement
- The existing `fuzzySearchCommands` in `commands.nim:22-33` has scoring (name=3, id=2, desc=1) but is not used by the palette filtering code in `gtm.nim`
- Palette filtering uses a simpler `fuzzyMatch` that just checks substring-like matching
- Should unify: use `fuzzySearchCommands` for better results

## Implementation Plan
1. Add missing commands to `buildDefaultCommands`
2. Fix palette navigation if needed (verify `paletteSelect` vs display iteration)
3. Integrate `fuzzySearchCommands` scoring into palette filtering
4. Increase display results to 15-20
5. Add category grouping (optional)
6. Rename/consolidate command palette and filter modes per user's requested `/` behavior

## Affected Files
- `src/commands.nim` — add new commands, update `buildDefaultCommands`
- `src/gtm.nim` — fix palette filtering, add dispatch for new commands
- `src/ui.nim` — CommandPaletteOverlay rendering improvements

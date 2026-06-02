# Playlist Management

## Status
P1 (incomplete feature with existing database schema)

## Current State

### Database Schema (`src/library.nim:143-157`)

Tables `playlists` and `playlist_tracks` exist:
- `playlists`: id, name, created_at
- `playlist_tracks`: playlist_id, track_id, position (composite PK)

### Operations Available (`src/library.nim`)

| Operation | Function | Exists? |
|-----------|----------|---------|
| Create playlist | `createPlaylist` | Yes |
| Delete playlist | `deletePlaylist` | Yes |
| Add track to playlist | `addTrackToPlaylist` | Yes |
| Remove track from playlist | `removeTrackFromPlaylist` | Yes |
| Load all playlists | `loadPlaylists` | Yes |
| Rename playlist | — | **No** |
| Reorder tracks | — | **No** |
| Export to .m3u | — | **No** |
| Import from .m3u | `parseM3u` | Yes (file loading only) |

### UI State (`src/gtm.nim`)

- `addSelectionToPlaylist` (lines 193-209): Adds selected tracks to a playlist. If no playlists exist, creates a default one named "Playlist N".
- `saveCurrentQueue` (lines 181-191): Saves current track list as .m3u file.
- No keybinding for creating/deleting/renaming playlists from UI.

### UI Rendering (`src/ui.nim:173-194`)

PlaylistsView shows playlist list with name and track count. Enter on a playlist currently triggers `playSelected()` which looks for `likTrack` items — but playlist items are `likPlaylist`, so it won't find a track and will do nothing useful.

## Requirements

### Create Playlist
- Keybinding: `a` or `Shift+N` in PlaylistsView
- Show a text prompt overlay to enter playlist name
- Call `library.createPlaylist(db, name)`
- Refresh playlist list

### Delete Playlist
- Keybinding: `d` or `Shift+X` on selected playlist
- Confirmation prompt: "Delete playlist 'NAME'? (y/N)"
- Call `library.deletePlaylist(db, id)`
- Refresh playlist list

### Rename Playlist
- Keybinding: `r` on selected playlist
- Show text prompt with current name pre-filled
- Update database

### Add Tracks to Playlist
- From Library tab, select tracks with `v` (select mode)
- Press `Shift+A` to show playlist picker overlay
- Select target playlist from list
- Call `library.addTrackToPlaylist(db, plId, trackId, position)`
- Show confirmation toast

### Remove Tracks from Playlist
- Inside playlist contents view, select tracks
- Press `d` or `Shift+X` to remove from playlist
- Confirm and remove

### Reorder Tracks
- Inside playlist contents view
- Keybindings: `Shift+J`/`Shift+K` to move track up/down
- Update `position` values in `playlist_tracks`

### View Playlist Contents
- Enter on a playlist in PlaylistsView
- Show track list (title, artist, duration) filtered to that playlist
- Escape to go back to playlist list

### Save/Load Playlists (.m3u)
- **Export**: Save playlist contents as .m3u file (path like `dataDir/playlist_name.m3u`)
- **Import**: Parse .m3u files and create playlists (`parseM3u` already exists)
- Keybinding: `Ctrl+S` to save, `Ctrl+O` to import

## Data Flow

```
User action → gtm.nim (key handler) → Command dispatch
  → library.nim (database operation)
  → state.rebuildDisplayItems()
  → ui.nim (re-render)
```

For daemon-operated playlists, operations that are local-only (no daemon needed) can be done in the TUI client. The library database is opened by the daemon, but the TUI client doesn't have direct DB access — this means playlist operations must be routed through the daemon's IPC. Currently, there's no daemon command for playlist operations.

### Design Decision
Playlist management should be done via the daemon since it owns the database connection. Add daemon commands for:
- `create_playlist` / `delete_playlist` / `rename_playlist`
- `add_to_playlist` / `remove_from_playlist` / `reorder_playlist`
- `get_playlists` / `get_playlist_tracks`
- `export_playlist` / `import_playlist`

## Affected Files
- `src/library.nim` — add rename, reorder, export functions
- `src/daemon.nim` — add playlist commands to `DaemonCmdKind` and `executeCommand`
- `src/daemon_client.nim` — add playlist methods
- `src/gtm.nim` — add key handlers for playlist operations
- `src/state.nim` — add state for playlist contents view, playlist creation prompt
- `src/ui.nim` — PlaylistsView sub-views, prompts, overlays
- `src/commands.nim` — add playlist command entries

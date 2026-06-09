# Architecture Restructuring: TUI → Stateless Daemon Client

## Goal

Make the TUI a pure rendering client with **zero authoritative state**. The daemon is the single source of truth for all playback, library, queue, and feature state. Any client (Neovim, CLI, web dashboard) can control the daemon via the same Unix socket JSON protocol.

The TUI MUST NOT:
- Maintain playback state (status, timePos, duration, volume)
- Own queue/shuffle/repeat state
- Handle crossfade scheduling
- Spawn yt-dlp subprocesses
- Read/write library files (SQLite, config, queue JSON)
- Advance tracks or decide what plays next

The TUI MAY ONLY:
- Render display from daemon event data
- Send commands to the daemon
- Maintain ephemeral UI state (cursor position, open overlays, input buffers)
- Cache library data for rendering performance (read-only, refreshed from daemon)

---

## Current Violations Summary

### Playback State Duplicated in TUI

| TUI Field (`AppState`) | Daemon Equivalent | Problem |
|---|---|---|
| `status` (psPlaying/Paused/Stopped) | `player.state` (0/1/2) | TUI coerces from events but holds redundant copy |
| `timePos` | `player.timePos` | Duplicated; reported via `aekPositionChanged` |
| `duration` | `player.duration` | Duplicated |
| `volume` | `player.volume` | Duplicated |
| `currentPlayingPath` | `currentTrackPath` | Duplicated |
| `currentPlayingId` | `lastTrackId` from `load_file` | Duplicated |
| `audioAvailable` | `player.working` | Duplicated |
| `shuffleEnabled` | `shuffleEnabled` (Daemon) | Duplicated |
| `repeatMode` | `repeatMode` (Daemon) | Duplicated |
| `sleepTimerRemaining` | `sleepTimerRemaining` (Daemon) | Duplicated |
| `shuffleOrder` / `shuffleIndex` | **MISSING** from Daemon | Daemon cannot advance tracks |
| `playbackQueue` / `queueCursor` | **MISSING** from Daemon | Queue only works with TUI |
| `crossfade*` (6 fields) | **MISSING** from Daemon | Crossfade only works with TUI |
| `favouriteIds` | **MISSING** from Daemon | Favourites lost on disconnect |
| `ytStream*` fields | **MISSING** from Daemon | Stream state not shareable |
| `ytDownload*` fields | **MISSING** from Daemon | Downloads not managed centrally |
| `ytPlaybackStartTime` / `ytPause*` | **MISSING** from Daemon | YT time tracking only works in TUI |

### Business Logic in TUI That Belongs in Daemon

| Logic | Location | Lines | Why Wrong |
|---|---|---|---|
| **Track advancement** (`nextTrack`) | `gtm.nim` | 279-307 | Daemon should auto-advance on `aekTrackEnded` |
| **Previous track** (`prevTrack`) | `gtm.nim` | 309-323 | Daemon owns queue navigation |
| **Next track computation** (`getNextTrackInfo`) | `gtm.nim` | 1968-1991 | Daemon knows queue/shuffle/repeat state |
| **Crossfade scheduling** (3 phases) | `gtm.nim` `processEvents` | 2156-2180 | Daemon should auto-schedule |
| **Track-ended handler** (auto-download, advance) | `gtm.nim` `processEvents` | 2064-2103 | Daemon should handle |
| **Crossfade-ended handler** (advance selection) | `gtm.nim` `processEvents` | 2104-2141 | Daemon owns this |
| **Queue add/remove/reorder** | `gtm.nim` `handleKey` | multiple | Queue is daemon state |
| **Shuffle order generation** | `gtm.nim` | 187-191 | Daemon generates shuffle order |
| **Favourites management** | `gtm.nim` | 735-747 | Should hit daemon |
| **Now-Playing cue on track change** | `gtm.nim` `processEvents` | 2038-2049 | Should come from daemon event |

### Filesystem Access in TUI That Bypasses Daemon

| Access | Location | Lines | Replacement |
|---|---|---|---|
| `saveQueue` / `loadQueue` (JSON I/O) | `gtm.nim` | 460-492 | Daemon manages queue in memory |
| `saveCurrentQueue` (M3U export) | `gtm.nim` | 494-504 | Daemon does file I/O |
| `scanLocalDir` (directory scan) | `gtm.nim` | 127-137 | Daemon `scan` command |
| `buildPlaylistFromArgs` (file scan) | `gtm.nim` | 160-168 | Daemon `scan` command |
| M3U import (file read) | `gtm.nim` `handleKey` | 943-954 | Daemon `add_track` / `scan` |
| `detectBrowserCookieSource` (file read) | `gtm.nim` `runTui` | 2252 | Daemon detects and reports |
| `parseM3u` + `scanDirectoryRecursive` | `library.nim` | 424-463 | Daemon-only filesystem access |
| `cleanQuit` (pid/sock removal) | `gtm.nim` | 412-413 | Daemon handles own lifecycle |
| Fork/exec in `startDaemonProcess` | `client.nim` | 26-39 | Valid — initiates daemon |

### yt-dlp Process Spawning (All in TUI)

| Function | File | Lines |
|---|---|---|
| `findYtdlp` | `ytdlp.nim` | 6-9 |
| `parseYtJsonLine` | `ytdlp.nim` | 11-33 |
| `detectBrowserCookieSource` | `ytdlp.nim` | 35-61 |
| `cookieFlags` / `jsRuntimeFlags` | `ytdlp.nim` | 63-72 |
| `startYoutubeSearch` | `ytdlp.nim` | 74-83 |
| `pollYoutubeSearch` | `ytdlp.nim` | 85-113 |
| `finishYoutubeSearch` | `ytdlp.nim` | 115-141 |
| `startStreamUrlFetch` | `ytdlp.nim` | 143-151 |
| `pollStreamUrlFetch` | `ytdlp.nim` | 153-175 |
| `startDownload` | `ytdlp.nim` | 177-187 |
| `pollDownload` | `ytdlp.nim` | 189-203 |
| `fetchPlaylistTracks` | `ytdlp.nim` | 205-236 |

### DaemonClient Duplicate State

| DaemonClient Field | Duplicates | Problem |
|---|---|---|
| `sleepTimerRemaining` | `Daemon.sleepTimerRemaining` + `AppState.sleepTimerRemaining` | Triple duplication |
| `pendingStreamTitle` / `pendingStreamChannel` | Daemon track metadata | Pass as args, not stored |
| `lastTrackId` | Daemon `load_file` response | Read from response directly |
| `volume` (inherited from AudioBackend) | Daemon `player.volume` | Read from events |
| `timePos` (inherited) | Daemon `player.timePos` | Read from events |
| `duration` (inherited) | Daemon `player.duration` | Read from events |
| `state` (inherited, 0/1/2) | Daemon `player.state` | Read from events |

---

## Phase 1: Daemon Foundation

### 1.1 — Add queue + shuffle + crossfade state to Daemon object

**File:** `src/daemon.nim` — `Daemon` object

Add fields:
```nim
playbackQueue*: seq[string]      # ordered list of track paths
shuffleOrder*: seq[int]          # shuffled indices into playbackQueue
shuffleIndex*: int               # current position in shuffle order
crossfadeDuration*: int          # seconds (0 = off)
crossfadePrepared*: bool
crossfadeStarted*: bool
crossfadeNextPath*: string
earlyPreloaded*: bool
```

### 1.2 — Add queue IPC commands

**File:** `src/daemon.nim` — `DaemonCmdKind` enum

Add:
```
dckQueueAdd, dckQueueRemove, dckQueueClear, dckQueueList,
dckQueueSetCursor
```

**Implement in `executeCommand`:**
- `queue_add {path}` → append to `playbackQueue`, return queue
- `queue_remove {index}` → remove at index, return queue
- `queue_clear` → clear queue, return `{"ok": true}`
- `queue_list` → return `{"queue": [...], "cursor": N}`
- `queue_set_cursor {index}` → set cursor

**Add to `DaemonCmd` parsing** in `parseDaemonCommand`.

### 1.3 — Add daemon-side track advancement

**File:** `src/daemon.nim` — event loop, new proc `advanceToNextTrack`

When `aekTrackEnded` is polled from the player:
1. If `playbackQueue` non-empty: pop first track, `loadFile` + `play`
2. Else if shuffle: advance `shuffleIndex`, play next shuffled track
3. Else if repeat all: wrap around to first track
4. Else if repeat one: replay current track
5. Else: stop, send `aekPlaybackStopped`
6. Emit events to client

**Also handle `dckNext` / `dckPrev`:** instead of `d.player.stop()`, call `advanceToNextTrack()` / `goToPrevTrack()`.

**Add to client protocol:** `{"cmd": "next"}`, `{"cmd": "prev"}` now actually advance, not just stop.

### 1.4 — Add daemon-side crossfade scheduling

**File:** `src/daemon.nim` — event loop, new proc `scheduleCrossfade`

On each frame, after polling `player.timePos`:
1. Compute `remaining = player.duration - player.timePos`
2. If `crossfadeDuration > 0` and next track is known:
   - Phase 0 (remaining <= 90s, not yet prepared): `player.prepareNext(nextPath)`
   - Phase 1 (remaining <= crossfadeDuration + 2s): ensure prepared
   - Phase 2 (remaining <= crossfadeDuration): `player.startCrossfade(crossfadeDuration)`
3. When crossfade ends (masterEnded): auto-advance queue/selection

### 1.5 — Add favourites to daemon

**File:** `src/library.nim` — `initSchema`

Add table:
```sql
CREATE TABLE IF NOT EXISTS favourites (
  track_id INTEGER PRIMARY KEY REFERENCES tracks(id)
)
```

**Add library procs:** `addFavourite`, `removeFavourite`, `getFavourites`, `isFavourite`.

**File:** `src/daemon.nim` — add commands:
```
dckAddFavourite, dckRemoveFavourite, dckGetFavourites
```

**Add to `DaemonCmdKind`**, `parseDaemonCommand`, and `executeCommand`.

### 1.6 — Add `dckGetFullState` command

Returns complete daemon state in one response:
- All `dckGetState` fields
- Queue list + cursor
- Favourites set
- Crossfade state

**Replace** separate `get_state` + `get_library` + `list_playlists` calls from TUI on reconnect.

### 1.7 — Persist all daemon state to SQLite

**File:** `src/daemon.nim` — `savePlaybackState`

Save additionally:
```
queue -> JSON array of paths
shuffle -> "0" or "1"
repeat -> "0", "1", or "2"
sleep_timer -> minutes
crossfade_duration -> seconds
```

**On daemon startup** (lines 443-455), restore all saved state:
- Restore queue, shuffle, repeat, sleep timer, crossfade duration
- Load track, seek to saved `time_pos`, call `play()` if state was "playing"
- Do NOT call `updatePlayCount` on restored track (count only new plays)

---

## Phase 2: YouTube in Daemon

### 2.1 — Add YouTube daemon commands

**File:** `src/daemon.nim` — add:
```
dckYtSearch, dckYtStreamUrl, dckYtDownload, dckYtPlaylistDetail,
dckYtPollSearch, dckYtPollDownload
```

**Design (non-blocking, daemon-internal):**
- `yt_search {query, page_size}`: spawn `yt-dlp`, store process handle in a `ytSearchTasks: seq[YtSearchTask]` table on Daemon, return `{"ok": true, "search_id": "..."}`
- `yt_poll_search {search_id}`: read available stdout lines from the yt-dlp process, return parsed results so far
- `yt_stream_url {url}`: spawn `yt-dlp -g`, wait for it (synchronous, quick), return stream URL
- `yt_download {url, title, channel}`: spawn `yt-dlp`, store in `ytDownloadTasks`, return `{"ok": true, "download_id": "..."}`, emit `aekDownloadProgress` events
- `yt_playlist_detail {url}`: spawn `yt-dlp --dump-json --flat-playlist`, wait for it, return all track entries

**Daemon internal state:**
```nim
ytSearchTasks*: seq[YtSearchTask]
ytDownloadTasks*: seq[DaemonDownloadTask]
ytCookieSource*: string
ytJsRuntime*: string
```

Where `YtSearchTask` and `DaemonDownloadTask` hold the `Process` handle, output buffer, and metadata. Polled in the daemon's main event loop.

### 2.2 — Move ytdlp.nim to daemon side

**Move** `src/ytdlp.nim` to daemon compilation (it's included via `import` in daemon.nim, not gtm.nim). Remove `import ytdlp` from TUI side.

**Add** `ytSpawnSearch` / `ytSpawnDownload` / `ytPollSearch` / `ytPollDownload` / `ytSpawnStreamUrl` procs that daemon calls from its event loop.

### 2.3 — TUI YouTube integration

TUI sends lightweight commands, receives responses:
- `yt_search` → daemon spawns, TUI polls with `yt_poll_search`
- `yt_stream_url` → daemon returns URL, TUI sends `load_file` with it
- `yt_download` → daemon spawns, sends `aekDownloadProgress` events, `aekDownloadComplete` when done

TUI YouTube state becomes: `ytResults` (display cache), `ytSearchQuery`, `ytSearchPage`, and overlay cursor state — nothing persistent.

---

## Phase 3: TUI Purification

### 3.1 — Remove duplicate playback state from AppState

**Remove from `AppState` (`src/state.nim`):**

| Field | Line | Replacement |
|---|---|---|
| `status` | 168 | Read from last `aekPlaybackStarted/Paused/Stopped` event |
| `timePos` | 169 | Read from `aekPositionChanged` event or daemon response |
| `duration` | 170 | Read from `aekDurationChanged` event |
| `volume` | 171 | Read from `aekVolumeChanged` event or `get_volume` |
| `currentPlayingPath` | 210 | Read from daemon response |
| `currentPlayingId` | 211 | Read from `load_file` response |
| `shuffleEnabled` | 221 | Read from daemon `set_shuffle` response |
| `shuffleOrder` | 222 | Daemon owns |
| `shuffleIndex` | 223 | Daemon owns |
| `repeatMode` | 224 | Read from daemon |
| `sleepTimerRemaining` | 225 | Read from daemon |
| `sleepTimerFrames` | 226 | Daemon owns |
| `playbackQueue` | 237 | Read from daemon |
| `queueCursor` | 281 | Read from daemon |
| `queuePendingConfirm` | 282 | Removed entirely |
| `crossfadePrepared/Started/fading/ masterEnded/earlyPreloaded/ NextPath/NextId` | 270-276 | Daemon owns |
| `ytStreamTitle/Channel/Duration/Url` | 246-249 | Read from daemon track metadata |
| `ytPlaybackStartTime/PauseDuration/PauseStartTime/DurationSec` | 288-291 | Daemon manages YT time tracking |
| `favouriteIds` | 195 | Read from daemon |
| `ytDownloadQueue/DownloadTasks/Downloaded/DownloadCount` | 251-254 | Daemon manages |
| `audioAvailable` | 209 | Read from daemon |
| `prevVolume` | 220 | Removed (mute: send `set_volume 0`, store prev locally if needed) |

### 3.2 — Library caching in AppState

**Keep but enforce read-only:**
- `libraryTracks` (line 191)
- `libraryArtists` (line 192)
- `libraryAlbums` (line 193)
- `libraryPlaylists` (line 194)

**Rules:**
1. Refreshed from daemon via `getFullState` on connect/reconnect
2. NEVER mutated locally — all mutations go through daemon commands
3. After each mutation command, re-fetch the affected subset
4. On `aekTrackEnded`, daemon sends new track metadata — TUI updates display from event, not from cached library
5. Mark as `var` but treat as `let` outside initialization/re-fetch

### 3.3 — Event-driven TUI rendering

**Change `processEvents` to be purely reactive:**
- Don't store event values in persistent `AppState` fields
- Read directly from daemon event data for rendering
- Use a lightweight transient snapshot instead of persistent fields:
  ```nim
  type PlaybackSnapshot = object
    status: PlaybackStatus
    timePos: float
    duration: float
    volume: int
    currentTrackPath: string
  ```
- Replace on each `pollEvents` call
- UI rendering reads from this snapshot

**When `aekTrackEnded` fires:**
- Do NOT call `nextTrack()` or any track advancement logic
- Wait for daemon to start next track and send `aekPlaybackStarted`
- The snapshot will be replaced with new track data

### 3.4 — Remove direct filesystem access from TUI

**Remove these functions entirely:**

| Function | File | Lines | Reason |
|---|---|---|---|
| `saveQueue` | `gtm.nim` | 460-472 | Daemon manages queue |
| `loadQueue` | `gtm.nim` | 474-492 | Daemon manages queue |
| `saveCurrentQueue` | `gtm.nim` | 494-504 | Daemon does file I/O |
| `scanLocalDir` | `gtm.nim` | 127-137 | Use daemon `scan` |
| `cleanQuit` sock/pid removal | `gtm.nim` | 412-413 | Daemon handles lifecycle |
| `detectBrowserCookieSource` | `gtm.nim` `runTui` | 2252 | Daemon detects |
| M3U file parsing in `handleKey` | `gtm.nim` | 943-954 | Daemon `scan` command |
| `loadFromArgs` filesystem fallback | `gtm.nim` | 160-168 | Send paths to daemon |

**Keep:**
- `loadConfig` / `saveConfig` — TUI-local UI settings (theme, keybindings, etc.)
- `daemonIsRunning` / `startDaemonProcess` — lifecycle management
- Visualizer shared-memory access — architectural choice, not daemon state

### 3.5 — Reset-to-defaults via daemon commands

**File:** `src/ui.nim` — Reset handler (lines 1442+)

Currently sets state fields directly. Change to send daemon commands:
```nim
# Before:
state.status = psStopped
state.volume = 80
state.repeatMode = 0

# After (simplified):
if state.player of DaemonClient:
  let cli = DaemonClient(state.player)
  cli.stop()
  cli.setVolume(80)
  cli.setRepeat(0)
  cli.setShuffle(false)
```

### 3.6 — Simplify DaemonClient

**Remove from `DaemonClient` (`src/client.nim`):**
- `sleepTimerRemaining` — read from daemon response
- `pendingStreamTitle` / `pendingStreamChannel` — pass as `load_file` args
- `lastTrackId` — read from `load_file` response
- Inherited `volume`, `timePos`, `duration`, `state` — read from events/responses, don't cache

**Keep:** `sock`, `connected`, `buf`, `drainedEvents` — pure I/O state.

**Modify `pollEvents`:** Return events WITHOUT updating DaemonClient fields. The TUI reads event data directly.

**Modify `loadFile`:** Accept `title` and `channel` as parameters instead of reading from `pendingStreamTitle`/`pendingStreamChannel`.

---

## Phase 4: Cleanup & Dead Code Removal

### 4.1 — Remove dead code

| What | File | Lines | Reason |
|---|---|---|---|
| `ProcessBackend` | `audio.nim` | 54-119 | Daemon uses Mixer/Ffmpeg; subprocess fallback is TUI-only |
| `newProcessBackend` | `audio.nim` | 115-119 | Dead once TUI doesn't use it |
| All `ytdlp.nim` from TUI | `ytdlp.nim` | entire | Moved to daemon |
| `nextTrack` / `prevTrack` TUI logic | `gtm.nim` | 279-323 | Daemon handles |
| `getNextTrackInfo` | `gtm.nim` | 1968-1991 | Daemon knows next track |
| Crossfade scheduling in `processEvents` | `gtm.nim` | 2156-2180 | Daemon schedules |
| `aekTrackEnded` handler business logic | `gtm.nim` | 2064-2103 | Daemon handles |
| Crossfade-ended handler | `gtm.nim` | 2104-2141 | Daemon handles |
| `toggleShuffle` / `cycleRepeat` TUI logic | `gtm.nim` | 331-344 | Send daemon commands |
| `shuffleOrder` function | `gtm.nim` | 187-191 | Daemon generates |
| `loadFromArgs` , `scanDirectory*`, `parseM3u`, `buildPlaylistFromArgs` filesystem functions | `library.nim` | 424-483 | Daemon-only filesystem access |
| `addTrackItems` / `sortedIndices` / `rebuildItems` | `library.nim` | 484-577 | Replace with daemon-queried display building |
| `saveQueue` / `loadQueue` / `saveCurrentQueue` | `gtm.nim` | 460-504 | Daemon manages |
| `daemonSimpleCmd("kill")` | `cli.nim` | 157-165 | Replace with `quit` command |
| `dbDummy` fallback (non-SQLite build) | `library.nim` | 379-403 | Keep for now, optional build |

### 4.2 — Update IPC spec

**File:** `docs/gtmd-ipc.md`

Add commands:
- `queue_add`, `queue_remove`, `queue_clear`, `queue_list`, `queue_set_cursor`
- `add_favourite`, `remove_favourite`, `get_favourites`
- `yt_search`, `yt_stream_url`, `yt_download`, `yt_playlist_detail`, `yt_poll_search`, `yt_poll_download`
- `get_full_state`
- `set_crossfade_duration`

Add events:
- `aekQueueChanged` — queue modified
- `aekFavouriteChanged` — favourite added/removed
- `aekCrossfadeStarted` / `aekCrossfadeEnded`
- `aekDownloadProgress` / `aekDownloadComplete`
- `aekTrackChanged` — new track started (includes full metadata: title, artist, album, duration)

### 4.3 — Simplify AudioBackend hierarchy

**File:** `src/audio.nim`

TUI only uses `DaemonClient`. Daemon only uses `MixerBackend` / `FfmpegBackend`. `ProcessBackend` was a TUI fallback — remove it.

**Remove:** `ProcessBackend` type, all its methods, `newProcessBackend`.

### 4.4 — Remove TUI state enum fields from state.nim

**File:** `src/state.nim`

Remove types that become unused:
- `PlaybackStatus` — replaced by daemon state string
- `ChangeEvent.ceQueue`, `ceQueueCursor` — daemon manages queue

---

## Phase 5: TUI Rebuild (After State Removal)

### 5.1 — Build display from daemon data

**File:** `src/gtm.nim` — `processEvents` + `runTui` main loop

After removing all duplicate state:
1. Each frame: `pollEvents()` returns events with current state snapshot
2. Render from snapshot only
3. No background crossfade scheduling, no queue management, no track advancement
4. When daemon disconnects: show "Disconnected" overlay, attempt reconnect, on reconnect call `getFullState` to rebuild display

### 5.2 — Now-Playing tab

Read from daemon's current track metadata (via events or snapshot). No local computation of "what's playing next" — the daemon sends the new track when it starts.

### 5.3 — Queue display

Read from daemon via `queue_list` command. Show whatever the daemon reports.

### 5.4 — Library tabs

Read from cached library data (refreshed from daemon). All filter, sort, and search operations operate on the local cache (fast) but never mutate it.

---

## Migration Order

```
Phase 1: Daemon Foundation (backward-compatible)
├── 1.1 Queue/shuffle/crossfade fields on Daemon
├── 1.2 Queue IPC commands
├── 1.3 Track advancement in daemon
├── 1.4 Crossfade scheduling in daemon
├── 1.5 Favourites schema + commands
├── 1.6 getFullState command
└── 1.7 Persist all state to SQLite

Phase 2: YouTube in Daemon
├── 2.1 YouTube daemon commands + event loop polling
├── 2.2 Move ytdlp.nim to daemon side
└── 2.3 TUI YouTube integration via IPC

Phase 3: TUI Purification (breaking — requires coordinated release)
├── 3.1 Remove duplicate playback state
├── 3.2 Enforce read-only library cache
├── 3.3 Event-driven TUI rendering
├── 3.4 Remove filesystem access
├── 3.5 Reset-to-defaults via daemon commands
└── 3.6 Simplify DaemonClient

Phase 4: Cleanup
├── 4.1 Remove dead code
├── 4.2 Update IPC spec
├── 4.3 Remove ProcessBackend
└── 4.4 Remove unused types from state.nim

Phase 5: TUI Rebuild
├── 5.1 Build display from daemon events
├── 5.2 Now-Playing tab from daemon data
├── 5.3 Queue display from daemon
└── 5.4 Library tabs from read-only cache
```

## Backward Compatibility

- **Phases 1-2**: Fully backward-compatible. Daemon grows new capabilities. TUI continues to work with old logic and can be incrementally switched to new commands. Daemon and old TUI coexist.
- **Phase 3**: Breaking. Requires coordinated release of daemon + TUI. TUI removes state that old daemon doesn't provide. Must be done after Phase 1 is complete and deployed.
- **Phases 4-5**: Cleanup. Requires Phase 3 complete.

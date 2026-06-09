# Implementation Plan

Prioritized items yet to implement, based on comparison of `implementation.md` plan vs actual source code in `src/`.

## Codebase State Summary

- Daemon has 27 commands, SQLite library, MixerBackend/FfmpegBackend audio, visualizer SHM, EQ
- TUI (`gtm.nim`) is monolithic — owns queue, crossfade scheduling, yt-dlp, track advancement, filesystem access, and duplicates ~20 daemon state fields in `AppState`
- P0 daemon foundation **completed**: queue (add/remove/clear/list/cursor), track advancement (`advanceToNextTrack` + `aekTrackEnded` auto-advance), crossfade scheduling (2-phase prepare/start), favourites schema/commands, `dckGetFullState`, and full state persistence to SQLite
- `playbackQueue`, `shuffleOrder`, `shuffleIndex`, `crossfadeDuration`, `crossfadePrepared`, `crossfadeStarted`, `crossfadeNextPath`, `earlyPreloaded` fields now actively populated and consumed in daemon event loop
- yt-dlp entirely in TUI (`ytdlp.nim`, included by `gtm.nim`)
- Tests: 31 tests total, only JSON serialization and yt-dlp line parsing — 0 tests for daemon, audio, crossfade, library, EQ
- IPC doc (`docs/gtmd-ipc.md`) out of date — missing queue/fav/yt/full_state commands/events
- Doc inconsistency: man page says `/tmp/gtm-daemon.sock`, code uses `$XDG_RUNTIME_DIR/gtm/gtmd.sock`
- `keyDispatch`/`multiKeyDispatch` tables populated in `commands.nim` but never read — main `handleKey` uses hardcoded `case key`
- Several unused constants, imports, types, and widgets throughout codebase

---

## P0 — Completed

- [x] **Activate dead daemon state fields**: Wired `playbackQueue`, `shuffleOrder`, `shuffleIndex`, `crossfadeDuration`, `crossfadePrepared`, `crossfadeStarted`, `crossfadeNextPath`, `earlyPreloaded` into `advanceToNextTrack`, crossfade scheduling in event loop, `dckSetShuffle` generates `shuffleOrder`, `dckGetFullState` returns all fields.
- [x] **Queue IPC commands**: Added `dckQueueAdd`, `dckQueueRemove`, `dckQueueClear`, `dckQueueList`, `dckQueueSetCursor` to enum, parser, and executor. Client-side procs added to `client.nim`.
- [x] **Daemon-side track advancement**: Added `advanceToNextTrack` proc that pops from `playbackQueue`. `dckNext` calls it instead of `stop()`. `aekTrackEnded` in event loop auto-advances.
- [x] **Daemon-side crossfade scheduling**: Added crossfade scheduling in daemon event loop: Phase 1 prepares next track at ≤crossfadeDuration+2s, Phase 2 starts crossfade at ≤crossfadeDuration.
- [x] **Favourites schema + commands**: Added `favourites` table to `library.nim` `initSchema`. Added `addFavourite`, `removeFavourite`, `getFavourites`, `isFavourite` to library. Added `dckAddFavourite`, `dckRemoveFavourite`, `dckGetFavourites` to daemon.
- [x] **`dckGetFullState` command**: Added `dckGetFullState` returning queue, shuffle, shuffleOrder, shuffleIndex, crossfade fields, all player state, and metadata.
- [x] **Persist all daemon state to SQLite**: Extended `savePlaybackState` to persist `shuffle`, `repeat`, `sleep_timer`, `crossfade_duration`, `queue_json`. Restored on daemon startup.

## P0 — Critical (Daemon Foundation — backward-compatible)

- [x] **Activate dead daemon state fields** (`daemon.nim:44-51`): Wire `shuffleOrder`, `shuffleIndex`, `playbackQueue`, `crossfadeDuration`, `crossfadePrepared`, `crossfadeStarted`, `crossfadeNextPath`, `earlyPreloaded` into execution flow. These are declared but never read or written to.
- [x] **Queue IPC commands** (`src/daemon.nim`): Add `dckQueueAdd`, `dckQueueRemove`, `dckQueueClear`, `dckQueueList`, `dckQueueSetCursor` to `DaemonCmdKind`, `parseDaemonCommand`, `executeCommand`. Parse JSON array from `queue_add` data, store in `d.playbackQueue`, return queue state.
- [x] **Daemon-side track advancement**: Add `advanceToNextTrack` proc. On `aekTrackEnded` (poll events in event loop), pop from `playbackQueue`, else use shuffle order, else use repeat mode. `dckNext`/`dckPrev` call advance logic instead of just `stop()`. Add `dckToggleShuffle` to generate `shuffleOrder` from `playbackQueue`.
- [x] **Daemon-side crossfade scheduling**: Add `scheduleCrossfade` called each frame after polling `player.timePos`. Phase 0 (≤90s remaining, not prepared): `player.prepareNext` from next track. Phase 1 (≤crossfadeDuration+2s): ensure prepared. Phase 2 (≤crossfadeDuration): `player.startCrossfade`. On crossfade end: auto-advance.
- [x] **Favourites schema + commands**: Add `favourites` table to `library.nim` `initSchema`. Add `addFavourite`, `removeFavourite`, `getFavourites`, `isFavourite` to library. Add `dckAddFavourite`, `dckRemoveFavourite`, `dckGetFavourites` to daemon.
- [x] **`dckGetFullState` command**: Returns queue, favourites, crossfade state, all `dckGetState` fields in one response. Replace TUI's multi-call reconnection logic.
- [x] **Persist all daemon state to SQLite**: Extend `savePlaybackState`/restore to include queue (JSON), shuffle, repeat, sleep_timer, crossfade_duration. Restore on daemon startup after loading track.

## P1 — High Priority (YouTube in Daemon — backward-compatible)

- [ ] **YouTube daemon commands**: Add `dckYtSearch`, `dckYtStreamUrl`, `dckYtDownload`, `dckYtPlaylistDetail`, `dckYtPollSearch`, `dckYtPollDownload` to daemon. Add `ytSearchTasks`, `ytDownloadTasks`, `ytCookieSource`, `ytJsRuntime` to Daemon state. Spawn/manage yt-dlp processes in daemon event loop.
- [ ] **Move ytdlp.nim to daemon side**: All procs in `ytdlp.nim` currently imported by TUI (`gtm.nim`). Move to daemon compilation. Create daemon-side `ytSpawnSearch`, `ytSpawnDownload`, `ytSpawnStreamUrl`, `ytPollSearch`, `ytPollDownload` procs. Remove `import ytdlp` from TUI.
- [ ] **TUI YouTube via IPC**: TUI sends lightweight `yt_search`/`yt_poll_search`/`yt_stream_url`/`yt_download` commands. Daemon returns search_id, TUI polls, reads results from response. No yt-dlp processes in TUI.

## P2 — Medium Priority (TUI Purification — breaking)

- [ ] **Remove duplicate playback state from AppState**: Remove `status`, `timePos`, `duration`, `volume`, `currentPlayingPath`, `currentPlayingId`, `audioAvailable`, `prevVolume`, `shuffleEnabled`, `shuffleOrder`, `shuffleIndex`, `repeatMode`, `sleepTimerRemaining`, `sleepTimerFrames`, `playbackQueue`, `queueCursor`, `queuePendingConfirm`, `crossfade*` (6 fields), `ytStream*` (4 fields), `ytPlaybackStartTime`, `ytPauseDuration`, `ytPauseStartTime`, `ytDurationSec`, `favouriteIds`, `ytDownloadQueue`, `ytDownloadTasks`, `ytDownloaded`, `downloadCount` from `AppState`.
- [ ] **Enforce read-only library cache**: `libraryTracks`, `libraryArtists`, `libraryAlbums`, `libraryPlaylists` must never be mutated locally. All mutations via daemon commands. Re-fetch affected subset after mutation.
- [ ] **Event-driven TUI rendering**: Replace persistent `AppState` playback fields with transient `PlaybackSnapshot` created fresh each `pollEvents` call. `processEvents` becomes purely reactive — no crossfade scheduling, no track advancement, no play count tracking, no YT time tracking.
- [ ] **Remove direct filesystem access from TUI**: Remove `saveQueue`, `loadQueue`, `saveCurrentQueue`, `scanLocalDir`, M3U parsing in `handleKey`, `detectBrowserCookieSource` call, `buildPlaylistFromArgs` filesystem fallback, `cleanQuit` sock/pid removal (daemon handles).
- [ ] **Reset-to-defaults via daemon commands**: System Reset handler sends daemon commands instead of setting `AppState` fields directly.
- [ ] **Simplify DaemonClient**: Remove `sleepTimerRemaining`, `pendingStreamTitle`, `pendingStreamChannel`, `lastTrackId` fields. Stop caching inherited `volume`, `timePos`, `duration`, `state`. `pollEvents` returns events without updating DaemonClient fields.
- [ ] **Fix `pendingStreamTitle`/`pendingStreamChannel` stale data** (`client.nim:134-136`): Reset to `""` after each `loadFile` to avoid leaking stream metadata onto subsequent local-file loads.
- [ ] **Fix `DaemonClient.running` never set** (`client.nim:149-159`): `play()` and `stop()` must set `cli.running = true/false` respectively.
- [ ] **Fix `DaemonClient.getVolume` round-trip** (`client.nim:248-253`): Return cached `cli.volume` instead of sending `get_volume` IPC to daemon.
- [ ] **Remove dead `DaemonClient` fields**: `lastState` and `metadata` are inherited but never updated — remove or wire them.
- [ ] **Build TUI display from daemon events** (post-purification): Each frame: `pollEvents()` returns events + snapshot. Render from snapshot only. No background crossfade/queue/advancement. On disconnect: reconnect + `getFullState`.
- [ ] **Now-Playing tab reads from daemon**: Read from daemon metadata via events/snapshot. No local "what's next" computation.
- [ ] **Queue display reads from daemon**: Read from daemon via `queue_list`. Show daemon-reported queue.
- [ ] **Library tabs read from cache**: Read from read-only cached library (refreshed from daemon). Filter/sort/search on cache, never mutate.

## P3 — Cleanup (Dead Code Removal)

- [ ] **Remove dead dispatch tables in `commands.nim`**: `keyDispatch` and `multiKeyDispatch` tables are fully populated but never read. Main `handleKey` in `gtm.nim:1621-1966` uses hardcoded `case key`. Either wire up the data-driven dispatch or delete tables and their builder procs.
- [ ] **Remove `ProgressBarComp` dead widget** (`ui.nim:660-700`): Fully defined but never instantiated in `renderApp()`.
- [ ] **Remove unused `SYS_MEM_TOTAL`, `SYS_MEM_AVAIL`, `SYS_TERM` constants** (`ui.nim:43-45`): Computed via `staticExec` but never read.
- [ ] **Remove or fix `peakVals` in visualizer** (`visualizer.nim:182`): Peak tracking data is maintained but `VisualizerView.render()` reads `smoothBins`, not `peakVals` — dead computation.
- [ ] **Fix `writePcm` silent sample dropping** (`visualizer.nim:67-70`): If ring buffer is nearly full, `writePcm` breaks early but still advances `writePos` by full sample count, dropping unwritten samples.
- [ ] **Remove `isDirty` template** (`state.nim:345-346`): Defined but never called. Code checks `dirtyFlags` directly.
- [ ] **Remove unused `ChangeEvent` values**: `cePlaylists`, `ceQueueCursor` never set or checked.
- [ ] **Remove `scPause` dead enum value** (`cli.nim:5-6`): Declared but never assigned; `"pause"` maps to `scToggle`.
- [ ] **Fix `daemon` subcommand silent no-op** (`cli.nim:167`): `gtm daemon` exits silently with no output — add error message or delegate.
- [ ] **Remove unused imports**: `math` in `theme.nim`, `library` and `audio` in `cli.nim`.
- [ ] **Remove ProcessBackend**: Delete `ProcessBackend` type and `newProcessBackend` from `audio.nim` (lines 54-119). TUI only uses `DaemonClient`. Daemon only uses `MixerBackend`/`FfmpegBackend`.
- [ ] **Remove TUI track advancement**: `nextTrack`, `prevTrack`, `getNextTrackInfo` procs.
- [ ] **Remove TUI crossfade scheduling** in `processEvents`.
- [ ] **Remove `toggleShuffle`/`cycleRepeat` TUI logic** and `shuffleOrder` function.
- [ ] **Remove filesystem procs**: `loadFromArgs`, `scanDirectory*`, `parseM3u`, `buildPlaylistFromArgs`, `addTrackItems`, `sortedIndices`, `rebuildItems`, `saveQueue`/`loadQueue`/`saveCurrentQueue`.
- [ ] **Remove `daemonSimpleCmd("kill")`** from `cli.nim`.
- [ ] **Remove unused types from `state.nim`**: `PlaybackStatus`, `ChangeEvent.ceQueue`, `ceQueueCursor`.

## P4 — Documentation Fixes

- [ ] **Fix man page database path** (`docs/gtm.1.md:184`): Says `~/.config/gtm/gtm.sqlite`, code uses `$XDG_DATA_HOME/gtm/gtm.db`.
- [ ] **Fix man page socket path** (`docs/gtm.1.md:187`): Says `/tmp/gtm-daemon.sock`, code uses `$XDG_RUNTIME_DIR/gtm/gtmd.sock`.
- [ ] **Add missing CLI subcommands to man page**: `shuffle`, `repeat`, `sleep`, `now`, `kill`, `daemon`, `help`, `--version` not listed.
- [ ] **Remove `enqueue` subcommand from man page** (`docs/gtm.1.md:51-52`): Documented but no code exists.
- [ ] **Remove or implement `list-playlists` CLI subcommand**: Daemon supports it via IPC but no CLI subcommand exists.
- [ ] **Add 3 undocumented daemon commands to IPC doc** (`docs/gtmd-ipc.md`): `get_library`, `add_track`, `update_track_path` exist in code but not documented.
- [ ] **Fix IPC doc auto-start timeout** (`docs/gtmd-ipc.md`): Says 600ms, code waits up to 900ms total.
- [ ] **Update IPC doc for queue/fav/yt/full_state commands** (after P0/P1 implementation).
- [ ] **Document crash.log location**: Daemon redirects stdout/stderr to `$XDG_CACHE_HOME/gtm/crash.log`.
- [ ] **Document `dckAddTrack` data field** (`daemon.nim:258`): Expects JSON object in `data` field but IPC doc doesn't specify format.

## P5 — Testing (cross-cutting)

- [ ] **Cover remaining 5 of 10 `AudioEventKind` values in IPC tests**: `aekPlaybackPaused`(2), `aekPlaybackStopped`(3), `aekMetadataChanged`(8), `aekError`(9) not tested.
- [ ] **Test daemon JSON command serialization for all 27 commands**: Only 5 of 27 commands tested.
- [ ] **Test `state.nim` path utilities**: `stateDir`, `configDir`, `dataDir`, `pidPath`, `sockPath` not tested.
- [ ] **Test `library.nim` SQLite operations**: CRUD for tracks, artists, albums, playlists not tested.
- [ ] **Daemon integration tests**: Command dispatch, event loop, state management, queue operations, crossfade scheduling, favourites, persistence.
- [ ] **Audio tests**: Backend lifecycle, crossfade timing, volume, seek, EQ band/preset.
- [ ] **Equalizer tests**: Biquad filter application, preset application, C integration.
- [ ] **Integration tests**: TUI → socket → daemon round-trip, full playback cycle.
- [ ] **Error recovery tests**: Malformed IPC, daemon crash/reconnect, socket disconnection.

---

## Cross-cutting Issues

- **`playbackQueue` type mismatch**: Daemon uses `seq[string]` (paths), TUI uses `seq[int]` (library indices). Must reconcile — daemon should own paths, TUI maps to display via library cache.
- **Shuffle order generation**: Daemon has `shuffleOrder`/`shuffleIndex` declared but never used. Need to implement generation (random permutation of queue indices, or of library if no queue).
- **`repeatOne`/`repeatAll` icon collision in Nerd Font set** (`icons.nim:21`): Both use same codepoint `\uF01E`, making them visually indistinguishable.
- **Sample rate hardcoded to 44100** (`audio.nim:344`): Crossfade frame calculation assumes 44.1kHz content. Content at 48kHz or other rates will have wrong crossfade timing.
- **FFmpeg/MPV fallback chain logs to stderr**: No structured logging or user notification when backend degrades.
- **No mutex/synchronization on SHM ring buffer**: Inter-process communication without atomic ops could race under concurrent access.
- **`detectNerdFonts` not thread-safe**: Uses module-level globals without synchronization.
- **EQ preset values duplicated** between Nim (`cycleEqPreset` in `gtm.nim`) and C (`EQ_PRESETS`) — maintenance risk documented in AGENTS.md.
- **Daemon's crash.log**: stdout/stderr redirected to `$XDG_CACHE_HOME/gtm/crash.log` — document this.
- **TUI `detectBrowserCookieSource`** (`ytdlp.nim:35-61`) probes browser paths — should move to daemon as `ytCookieSource`.
- **`dckAddTrack`** (`daemon.nim:258`) expects `data` field with JSON object but IPC doc doesn't document it.
- **Doc vs code socket path**: `docs/gtm.1.md:187` says `/tmp/gtm-daemon.sock` but code uses `$XDG_RUNTIME_DIR/gtm/gtmd.sock`.

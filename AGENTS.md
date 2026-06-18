# gtm

## Implementation Progress

### Phase 0 — Album Art — COMPLETE
- `src/graphics.nim` rewritten: accepts `seq[byte]` + mime string, single encode, proper format detection from mime
- `src/state.nim`: `coverCache` type changed to `Table[string, tuple[data: seq[byte], mime: string]]`, added `LrcLine`, `LrcData`, `daemonStateVersion`, `currentLyrics`, `lyricsLineIdx` fields
- `src/gtm.nim`: cover art fetcher decodes base64 before caching, stores raw bytes + mime; `base64` import added
- `src/ui.nim`: album art renderer uses decoded bytes + mime, calls `deleteOld()` before `transmitImage`, resets `coverImageId = -1` on track change

### Phase 1 — State Purification — COMPLETE
- `src/gtm.nim`: `playSelected()` no longer builds `playbackQueue` locally — sends queue to daemon via IPC, daemon owns queue from there
- `src/gtm.nim`: `evTrackEnded` no longer manually advances queue — trusts daemon's `queue_changed` event to update TUI state
- `src/gtm.nim`: `nextTrack()` no longer syncs TUI queue to daemon before advancing — daemon already has the queue
- `src/gtm.nim`: `adjustVolume()` does not set `state.volume` locally — trusts daemon's `evVolumeChanged` event
- `src/gtm.nim`: `toggleShuffle()` sends IPC then trusts daemon echo event for state update (not local toggle)
- `src/gtm.nim`: `cycleRepeat()` sends IPC then trusts daemon echo event for state update
- `src/gtm.nim`: `toggleMute()` sends volume IPC, daemon events update state

### Phase 2 — Rendering Optimization — COMPLETE
- `src/audio.nim`: position event throttle reduced from 250ms to 100ms in both `FfmpegBackend` and `MixerBackend`
- `src/gtm.nim`: 60fps frame cap via `epochTime` delta check (16ms threshold) in main render loop

### Phase 3 — LRC Lyrics — COMPLETE
- `src/lyrics.nim`: new file with `parseLrc()`, `findLrcSidecar()`, `currentLrcLine()`, `searchLrclib()`, `fetchLrclib()`, `fetchLrclibByParams()`, `resolveLyrics()` (sidecar → LRCLIB by params → LRCLIB search fallback)
- `src/daemon.nim`: `dckGetLyrics` and `dckSearchLyrics` commands added with handlers, `import lyrics`
- `src/client.nim`: `getLyrics()` and `searchLyrics()` procs added
- `src/gtm.nim`: lyrics fetched on `evPlaybackStarted`, line index updated on each `evPositionChanged`
- `src/ui.nim`: synced lyrics rendered in Now Playing tab between album art and Up Next section (green highlight for current line)
- `src/library.nim`: `lyrics_cache` table added to schema

### Phase 4 — LRCLIB Integration — COMPLETE (built into lyrics.nim)

### Phase 5 — Selective State Sync — COMPLETE
- `src/daemon.nim`: `stateVersion` counter added to Daemon struct, incremented every `pollEvents` frame and on `pushFullState`, included in all serialized events (`serializeEvents`), `pushFullState`, `dckGetFullState`, and duration change broadcasts
- `src/audio.nim`: `version` field added to `AudioEvent` type for end-to-end version tracking
- `src/client.nim`: version parsed from daemon JSON events into `AudioEvent.version`
- `src/gtm.nim`: `processEvents` tracks `state.daemonStateVersion = ev.version` on every event

### Phase 6 — Documentation & Manpage Generator — COMPLETE
- `tools/genman.nim`: full manpage generator extracting CLI subcmds (15), TUI commands (47), daemon commands (72), audio events (11) from source
- `tools/docs.nim`: example code blocks (`DocExample` objects) for CLI, daemon, lyrics, and audio use cases
- `.githooks/pre-push`: auto-regenerates + commits manpages on push
- `build.nims`: sets `core.hooksPath .githooks`
- ASCII architecture diagrams added to `src/daemon.nim`, `src/audio.nim`, `src/client.nim`, `src/state.nim`, `src/gtm.nim`, `src/commands.nim`, `src/cli.nim`, `src/library.nim`
- `docs/gtm.1.md`: examples section (shell usage, programmatic piping via jq)
- `docs/gtmd.1.md`: examples section (socat interaction, event streaming, scripted shell, Nim sock API example)

## Build & Test

```bash
nim e build.nims          # build both (release + man page)
nim e build.nims -t       # TUI only
nim e build.nims -d       # daemon only
nim check src/gtm.nim     # TUI syntax check
nim check src/gtmd.nim    # daemon syntax check
nim r tools/genman.nim    # regenerate manpages from source
# Tests:
nim r --path:src tests/test_ipc.nim
nim r --path:src tests/test_parse.nim
nim r --path:src tests/test_examples.nim

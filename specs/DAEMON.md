# Daemon

Single source of truth for all playback, library, queue, and feature state.

## State Fields

- `player: AudioBackend` — audio playback (MixerBackend / FfmpegBackend)
- `lib: LibraryDb` — SQLite library database
- `viz: Visualizer` — PCM capture for FFT bars
- `currentTrackPath`, `currentTrackTitle`, `currentTrackChannel`
- `playbackQueue: seq[string]` — ordered track paths
- `shuffleOrder: seq[int]`, `shuffleIndex: int`
- `repeatMode: int` (0=off, 1=all, 2=one)
- `shuffleEnabled: bool`
- `sleepTimerRemaining: int`, `sleepTimerFrames: int`
- `crossfadeDuration: int`, `crossfadePrepared: bool`, `crossfadeStarted: bool`, `crossfadeNextPath: string`, `earlyPreloaded: bool`
- `idleFrames: int`, `idleTimeout: int`
- `persistFrames: int`

## Event Loop (16ms select loop)

1. Accept new connections (max 1)
2. Parse JSON commands from client
3. Execute commands (playback, library, queue, shuffle, repeat, crossfade, EQ, yt-dlp)
4. Poll audio events → serialize + forward to client
5. Capture PCM → write to visualizer SHM
6. Sleep timer countdown
7. Persist state every ~30s
8. Idle timeout after 5 min stopped
9. Track auto-advance on `aekTrackEnded`
10. Crossfade auto-scheduling

## Missing Functionality

- Queue commands (add/remove/clear/list/set_cursor)
- Track advancement (auto-advance on track ended)
- Previous track (queue/shuffle navigation)
- Crossfade scheduling (phase 0/1/2 auto-prepare/start)
- Favourites (SQL table + commands)
- getFullState command
- Persist queue/shuffle/repeat/sleep_timer/crossfade to SQLite
- yt-dlp integration (search/stream/download/playlist)

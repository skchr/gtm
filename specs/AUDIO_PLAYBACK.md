# Audio Playback

## Status
P0 (no audio output bug) / P3 (crossfade, gapless, replaygain)

## File Format Support

The application already defines supported extensions in `src/library.nim:385-388`:

```nim
const audioExtensions* = [
  ".mp3", ".flac", ".ogg", ".m4a", ".wav", ".opus",
  ".aac", ".wma", ".alac", ".aiff", ".ape"
]
```

MiniAudio (vendored in `vendor/miniaudio/`) handles decoding. No changes needed to supported formats.

## Current Audio Pipeline

1. Daemon (`src/daemon.nim`) creates a `MiniAudioBackend` (`src/audio.nim:146-153`)
2. MiniAudioBackend wraps C calls to `vendor/miniaudio/miniaudio_impl.c`
3. PCM data is written to shared memory (`/dev/shm`) for the visualizer (`src/visualizer.nim`)
4. TUI (`src/gtm.nim`) connects via `DaemonClient` (`src/daemon_client.nim`) over Unix socket

## Bug: No Audio Playback (P0)

### Symptoms
- `MiniAudioBackend` may fail initialization: `audio.nim:152-153` — `gtm_audio_init()` returns nil
- `loadFile` checks `b.ctx == nil` at line 77 and returns early with state=0
- Even when ctx is valid, `gtm_audio_load()` may return 0 (failure) silently

### Investigation Required
1. Check `vendor/miniaudio/miniaudio_impl.c` for `gtm_audio_init` implementation
2. Verify that `gtm_audio_start()` actually produces sound
3. Check if the daemon is correctly receiving `load_file` commands from the TUI client
4. Add debug logging to trace the full playback path: TUI key → DaemonClient.sendDaemonCmd → daemon.executeCommand → MiniAudioBackend.play

### Potential Root Causes
- MiniAudio device initialization fails (no ALSA/PulseAudio/JACK available)
- The C implementation in `miniaudio_impl.c` may have broken API calls
- The `-lm -ldl -lpthread` link flags may be insufficient
- The daemon's event loop may not be processing commands fast enough

## Crossfade (P3)

### Behavior
- When transitioning between tracks, fade out the current track while fading in the next
- Configurable crossfade duration (default: 3 seconds)
- Crossfade should be seamless (no silence gap)

### Implementation Notes
- Requires a mixing buffer in `MiniAudioBackend` or daemon
- Two audio sources need to play simultaneously during the crossfade window
- The `aekTrackEnded` event currently triggers `nextTrack()` in `src/gtm.nim:536-539` — crossfade logic should be in the daemon
- Need a playback queue managed by the daemon (currently queue management is in the TUI client only)

### Affected Files
- `src/audio.nim` — add crossfade state and methods to `MiniAudioBackend`
- `src/daemon.nim` — implement crossfade logic in `executeCommand` and main loop
- `src/state.nim` — add crossfade config to `ConfigData`
- `schema.json` — add `crossfade_duration` config option

## Gapless Playback (P3)

### Behavior
- Remove the silence gap between consecutive tracks
- Ideally gapless is automatic with MiniAudio (depends on decoder behavior)
- If not, pre-decode the next track and feed PCM continuously

### Implementation Notes
- Gapless requires the decoder to not flush/reset between tracks
- May need to preload the next track's data

## Seeking Behavior

Already implemented in `src/audio.nim:106-109` (`MiniAudioBackend.seek`) and `src/gtm.nim:476-477` (`h`/`l` keys for ±5s).

## Volume Normalization / ReplayGain (P3)

### Behavior
- Parse ReplayGain tags (stored in metadata)
- Apply gain adjustment during playback
- Optionally use EBU R128 loudness normalization

## Play/Pause/Stop Semantics

Already implemented:
- `Play()`: resumes from current position, state → playing
- `Pause()`: maintains position, state → paused
- `Stop()`: resets position to 0, state → stopped
- `TogglePause()`: switches between playing and paused

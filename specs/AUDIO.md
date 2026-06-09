# Audio Backend

## Hierarchy

- `AudioBackend` — abstract base with `loadFile`, `play`, `pause`, `stop`, `seek`, `setVolume`, `pollEvents`, `readPcmFrames`, `prepareNext`, `startCrossfade`
- `MixerBackend` — primary, dual-context crossfade via C (`ffmpeg_mixer_*`), EQ via C biquad filters
- `FfmpegBackend` — single-track fallback via C (`ffmpeg_audio_*`)
- `ProcessBackend` — subprocess fallback (mpv/ffplay), **slated for removal**
- `DaemonClient` — TUI-side IPC proxy (inherits AudioBackend)

## Crossfade Flow (C layer)

1. `prepareNext(path)` → C loads slave decoder
2. `startCrossfade(durationSec)` → equal-power cos/sin envelope on PCM
3. C auto-promotes slave→master when crossfade completes
4. `pollEvents` reports `master_ended` flag

## Scheduling (currently in TUI, should move to daemon)

Phase 0: remaining ≤ 90s → prepareNext
Phase 1: remaining ≤ crossfadeDuration + 2s → ensure prepared
Phase 2: remaining ≤ crossfadeDuration → startCrossfade

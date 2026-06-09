# gtm - Agent Notes

## Build & Test
```bash
nim e build.nims                # full build script (release + man page)
nim c -d:release src/gtm.nim   # alternative: TUI-only release build
nim c -d:release src/gtmd.nim  # alternative: daemon-only release build
nim check src/gtm.nim           # syntax check
nim check src/gtmd.nim          # daemon syntax check
```

## Commands
- `show_equalizer` (`E`): toggle 10-band EQ overlay with sliders, presets (j/k select, ←→ adjust, P cycle)
- `show_about` (`Shift+A`): system info (version, deps, paths, playback state)
- `show_help` (`?`): keybindings reference
- `rebindCommand` in `commands.nim`: data-driven keybinding with user JSON overrides in config
- `set_eq_band <band> <gain_db>`, `set_eq_preset <name>`: daemon commands for real-time EQ

## Equalizer
- 10-band biquad peaking filters (31Hz–16kHz) in C code (`ffmpeg_impl.c`)
- EQ applied post-crossfade to final PCM output (mixbuf) or master (mbuf)
- 10 presets: Flat, Rock, Pop, Classical, Jazz, HipHop, Vocal, BassBoost, Headphones, Laptop
- Preset values duplicated in Nim (`cycleEqPreset` in `gtm.nim`) and C (`EQ_PRESETS`)

## Architecture
- TUI client (`src/gtm.nim`) ↔ Unix socket ↔ Daemon (`src/daemon.nim`)
- Daemon owns FFmpeg backend and SQLite library DB
- Visualizer uses shared memory (`/dev/shm`) for PCM data
- MixerCtx (C) for PCM crossfade: dual decode contexts + single decode thread

## Crossfade Flow
1. TUI sends `prepare_next <url>` → daemon loads slave context (MixerCtx)
2. TUI sends `crossfade <duration_sec>` → daemon starts crossfade (equal-power cos/sin)
3. C thread auto-promotes slave→master when crossfade completes
4. TUI receives `aekTrackEnded` → updates display, prepares next-next

## Audio Backend Priority
1. `MixerBackend` (C MixerCtx with crossfade + equalizer)
2. `FfmpegBackend` (single-track C decoder, fallback if mixer fails)
3. `ProcessBackend` (mpv/ffplay subprocess)
4. `DaemonClient` (TUI side, communicates over Unix socket)

## About Overlay
- Version: `v{tag}-{gitHash7}:{release-type}`
- OS, Kernel, CPU info (compile-time staticExec)
- Deps: Nim, GCC, FFmpeg, yt-dlp, JS runtimes (node/bun/deno)
- Binary path (from /proc/self/exe), Download dir, Storage used (du -sh)
- Audio backend type, Playback state (Playing/Paused/Stopped)

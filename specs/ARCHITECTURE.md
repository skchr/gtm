# Architecture

```
┌──────────┐   Unix socket   ┌──────────┐
│  gtm TUI  │◄──────────────►│  gtm-d   │
│ (client)  │   JSON IPC     │ (daemon) │
└──────────┘                  └──────────┘
                                   │
                            ┌──────┴──────┐
                            │ ffmpeg + alsa│
                            │  (playback)  │
                            └──────┬──────┘
                                   │ PCM via
                                   │ shm/mmap
                            ┌──────┴──────┐
                            │  visualizer  │
                            │  (FFT bars)  │
                            └─────────────┘
```

## Principle

The daemon is the **single source of truth** for all playback, library, queue, and feature state. The TUI is a **pure rendering client** with zero authoritative state.

## TUI MAY NOT

- Maintain playback state (status, timePos, duration, volume)
- Own queue/shuffle/repeat state
- Handle crossfade scheduling
- Spawn yt-dlp subprocesses
- Read/write library files (SQLite, config queue JSON)
- Advance tracks or decide what plays next

## TUI MAY ONLY

- Render display from daemon event data
- Send commands to the daemon
- Maintain ephemeral UI state (cursor position, open overlays, input buffers)
- Cache library data for rendering performance (read-only, refreshed from daemon)

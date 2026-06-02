# gtm - Agent Notes

## Build & Test
```bash
nim c -d:release src/gtm.nim   # release build
nim check src/gtm.nim           # syntax check
```

## Architecture
- TUI client (`src/gtm.nim`) ↔ Unix socket ↔ Daemon (`src/daemon.nim`)
- Daemon owns MiniAudio backend and SQLite library DB
- Visualizer uses shared memory (`/dev/shm`) for PCM data

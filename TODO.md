# gtm Patched Release — Task List

## Phase 0 — Quick Wins (blocking daemon fixes)

- [x] 0a: Fix `trySend` EAGAIN/EINTR handling (`src/daemon.nim:1642-1655`)
- [x] 0b: Move yt-dlp URL resolution to PulseWorker thread
- [x] 0c: Move lyrics fetching (HTTP) to PulseWorker thread

## Phase 1 — Full IPC Thread + Reactive State System — CANCELLED

- [ ] 1a–1e: Cancelled due to Nim threading complexity (`tryRecv` not available, `Channel` race conditions). The 15-second blocking root causes are already eliminated by Phase 0's PulseWorker offload.

## Phase 2 — Command Icon Fallback

- [x] 2a: Add missing icon fields to `IconPack` in `src/icons.nim`
- [x] 2b: Populate Nerd Font + emoji variants for new fields
- [x] 2c: Add `commandIcon()` proc mapping cmd IDs to IconPack fields
- [x] 2d: Route command palette render through `commandIcon()` in `src/ui.nim`

## Phase 3 — Android Audio Backend

- [x] 3a: Create `vendor/android/audio_impl.h` — backend-agnostic API header
- [x] 3b: Create `vendor/android/audio_impl.c` — AAudio (primary) + OpenSL ES (fallback)
- [x] 3c: Integrate AAudio/SLES PCM output into `vendor/ffmpeg/ffmpeg_impl.c` via `__ANDROID__` guards
- [x] 3d: Add compile/link directives for Android in `src/audio.nim`
- [x] 3e: Fix `build.nims` for Termux (shared FFmpeg, no static, cc instead of musl-gcc)

## Verification

- [x] Verify `nim check src/gtmd.nim`
- [x] Verify `nim check src/gtm.nim`
- [x] Run tests: `nim r --path:src tests/test_ipc.nim` — PASS
- [x] Run tests: `nim r --path:src tests/test_examples.nim` — PASS
- [x] Run tests: `nim r --path:src tests/test_parse.nim` — pre-existing issues (unrelated)
- [x] Verify `nim r tools/genman.nim`

## Release

- [ ] Commit all changes
- [ ] Tag and push release

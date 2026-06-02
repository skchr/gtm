# Dependency Resolution

## Status
P0 (build blocker on other machines)

## Problem
`config.nims:11-13` contains hardcoded absolute paths:
```nim
switch("path", "/home/prjctimg/sources/nimwave/src")
switch("path", "/home/prjctimg/sources/illwave/src")
switch("path", "/home/prjctimg/sources/ansiutils/src")
```

These paths do not exist on other machines, making the project unbuildable outside the author's environment. Additionally, `gtm.nimble` declares `requires "nimwave >= 1.2.1"` which conflicts with the manual path approach — Nimble should handle dependency resolution but the hardcoded paths override it.

## Root Cause
The project depends on external libraries (`nimwave`, `illwave`, `ansiutils`) that are not available as Nimble packages or are local forks. The author avoided proper Nimble dependency management by hardcoding source paths.

## Required Dependencies
| Library | Role | Current Source |
|---------|------|---------------|
| `nimwave` | TUI framework (terminal widgets, layout, rendering) | Hardcoded path |
| `illwave` | Low-level terminal I/O (keyboard, colors, terminal buffer) | Hardcoded path |
| `ansiutils` | Terminal utilities | Hardcoded path |
| `miniaudio` | Audio playback backend (vendored) | `vendor/miniaudio/` |
| `sqlite3` | Database (vendored) | `vendor/sqlite/` |

## Solutions

### Option A: Vendor all dependencies (preferred for stability)
1. Copy `nimwave`, `illwave`, `ansiutils` source into `vendor/` directory
2. Add `switch("path", ...)` entries pointing to vendored copies
3. Remove Nimble dependency requirements for these libraries
4. Keep `miniaudio` and `sqlite3` already vendored as-is

### Option B: Fix Nimble + publish
1. Publish `nimwave`, `illwave`, `ansiutils` as proper Nimble packages
2. Update `gtm.nimble` to list them as dependencies
3. Remove hardcoded paths from `config.nims`
4. Replace `switch("path", ...)` with import paths that work via Nimble

### Option C: Conditional paths with env var fallback
1. Check for `NIMWAVE_PATH` / `ILLWAVE_PATH` / `ANSIUTILS_PATH` env vars
2. Fall back to Nimble package resolution
3. Remove hardcoded `/home/prjctimg/...` paths

## Implementation Plan
1. Verify what version/state of nimwave/illwave/ansiutils is needed (check current hardcoded paths)
2. Copy them into `vendor/` or create a proper Nimble package setup
3. Update `config.nims` to remove hardcoded paths
4. Verify build succeeds on a clean machine

## Affected Files
- `config.nims` — remove hardcoded paths
- `gtm.nimble` — update dependencies

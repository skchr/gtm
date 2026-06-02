# Daemon IPC Protocol

## Status
P3 (documentation for external use)

## Overview

The gtm daemon (`gtm daemon`) runs as a background process and communicates over a **Unix stream socket**. The TUI client and CLI subcommands connect to this socket to control playback.

## Socket Path Discovery

The socket path is determined by `state.sockPath()` in `src/state.nim:143`:

```nim
proc sockPath*(): string = stateDir() & "/gtmd.sock"
proc stateDir*(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = "/tmp/gtm-" & getEnv("USER", "unknown")
```

Typical path: `/run/user/$UID/gtm/gtmd.sock` or `/tmp/gtm-$USER/gtmd.sock`.

The PID file is at the same directory in `gtmd.pid` (`src/state.nim:142`).

## Wire Format

Messages are **newline-delimited JSON** (JSON lines / NDJSON). Each request is one JSON object followed by `\n`. Each response is one JSON object followed by `\n`.

## Request Format

```json
{"cmd": "<command_name>", ...args}
```

### Supported Commands (from `src/daemon.nim:43-66`)

| Command | Args | Description |
|---------|------|-------------|
| `"play"` | (none) | Resume playback |
| `"pause"` | (none) | Pause playback |
| `"stop"` | (none) | Stop playback (position reset) |
| `"toggle_pause"` | (none) | Toggle play/pause |
| `"seek"` | `"seconds"`: float | Seek by relative offset (e.g., `5.0` or `-5.0`) |
| `"next"` | (none) | Next track (stops current, client should queue next) |
| `"prev"` | (none) | Previous track (stops current) |
| `"set_volume"` | `"volume"`: int (0-100) | Set volume level |
| `"get_volume"` | (none) | Get current volume |
| `"load_file"` | `"path"`: string | Load and start playing a file |
| `"quit"` | (none) | Shut down the daemon gracefully |
| `"status"` | (none) | Get full playback status |
| `"now_playing"` | (none) | Get current track info |
| `"scan"` | `"path"`: string | Scan a directory for audio files |

## Response Format

All responses include `"ok"`: true/false. Status/now_playing responses include additional fields:

### Status Response Example

```json
{
  "ok": true,
  "state": "playing",
  "volume": 80,
  "time_pos": 124.5,
  "duration": 267.0,
  "track": "/home/user/Music/song.flac"
}
```

The `state` field is one of: `"stopped"`, `"playing"`, `"paused"`.

### Events

If events have occurred since the last poll, the response includes an `"events"` array:

```json
{
  "ok": true,
  "state": "playing",
  "events": [
    {"kind": "1", "time_pos": 124.5},
    {"kind": "2", "duration": 267.0}
  ]
}
```

Event kinds (from `AudioEventKind` in `src/audio.nim:6-9`):
| Kind int | Enum | Extra Fields |
|----------|------|-------------|
| 0 | `aekNone` | — |
| 1 | `aekPlaybackStarted` | state="playing" |
| 2 | `aekPlaybackPaused` | state="paused" |
| 3 | `aekPlaybackStopped` | state="stopped" |
| 4 | `aekTrackEnded` | reason="eof" |
| 5 | `aekPositionChanged` | time_pos: float |
| 6 | `aekDurationChanged` | duration: float |
| 7 | `aekVolumeChanged` | volume: int |

## socat Usage Examples

```bash
# Get status
echo '{"cmd":"status"}' | socat - UNIX-CONNECT:/run/user/1000/gtm/gtmd.sock

# Play/pause toggle
echo '{"cmd":"toggle_pause"}' | socat - UNIX-CONNECT:/run/user/1000/gtm/gtmd.sock

# Set volume to 50%
echo '{"cmd":"set_volume","volume":50}' | socat - UNIX-CONNECT:/run/user/1000/gtm/gtmd.sock

# Load and play a file
echo '{"cmd":"load_file","path":"/home/user/Music/song.mp3"}' | socat - UNIX-CONNECT:/run/user/1000/gtm/gtmd.sock

# Seek forward 10 seconds
echo '{"cmd":"seek","seconds":10}' | socat - UNIX-CONNECT:/run/user/1000/gtm/gtmd.sock

# Get volume
echo '{"cmd":"get_volume"}' | socat - UNIX-CONNECT:/run/user/1000/gtm/gtmd.sock
```

## Error Handling

On parse error, the daemon returns `{"ok": true}` (default status response) — this is a bug. Errors should return `{"ok": false, "error": "description"}`.

If the socket doesn't exist or is stale, the TUI client will start a new daemon process automatically (`src/daemon_client.nim:44-53`).

## Event Streaming

Currently the protocol is request-response only. There is no persistent subscription for events. The TUI client polls by sending `"status"` commands every frame (16ms via `pollEvents` in `src/daemon_client.nim:107-131`). This is inefficient — a persistent event stream would be better but is not critical.

## Security Considerations

- The Unix socket is world-writable (no permission restrictions)
- No authentication is performed
- Any local user can control the daemon
- Consider using `chmod 0700` on the state directory

# gtmd — Daemon Specification

gtmd is a standalone audio playback daemon that owns all playback, library,
queue, and feature state. Clients communicate over a Unix domain socket using
newline-delimited JSON.

---

## 1. Architecture

```
┌──────────────┐   Unix socket    ┌──────────────────┐
│  TUI / CLI   │◄──────────────►│      gtmd        │
│  (client)    │   JSON IPC      │    (daemon)       │
└──────────────┘                 └────────┬─────────┘
                                          │
                              ┌───────────┴───────────┐
                              │  Audio Backend         │
                              │  (MixerBackend /       │
                              │   FfmpegBackend /      │
                              │   ProcessBackend)      │
                              └───────────┬───────────┘
                                          │ PCM via shm
                              ┌───────────┴───────────┐
                              │  Visualizer            │
                              │  (FFT bars via SHM)    │
                              └───────────────────────┘
```

### Principle

The daemon is the **single source of truth** for all authoritative state:

- Playback state, position, duration, volume
- Queue, shuffle order, repeat mode
- Crossfade scheduling (phases 0/1/2)
- SQLite library database (tracks, artists, albums, playlists, favourites)
- yt-dlp subprocess management (search, stream resolution, download, playlist)
- PCM capture for visualizer shared memory

The client **may only**:
- Send commands to the daemon
- Render display from daemon event data
- Maintain ephemeral UI state (cursor position, open overlays, input buffers)
- Cache library data read-only for rendering performance

The client **may not**:
- Maintain playback state (status, timePos, duration, volume)
- Own queue/shuffle/repeat state
- Handle crossfade scheduling
- Spawn yt-dlp subprocesses
- Read/write library files directly

---

## 2. Daemon Lifecycle

### 2.1 Startup Sequence

1. **Create runtime directories** — `$XDG_RUNTIME_DIR/gtm` (state dir, for socket and PID)
2. **Create cache directory** — `$XDG_CACHE_HOME/gtm` (for crash log)
3. **Redirect stdout/stderr** — appended to `$XDG_CACHE_HOME/gtm/crash.log` (unless `--debug` preserves terminal output)
4. **Set process name** — `prctl(PR_SET_NAME, "gtmd")`
5. **Write PID file** — `$XDG_RUNTIME_DIR/gtm/gtmd.pid`
6. **Set up signal handlers** — `SIGINT`/`SIGTERM` → cleanup (remove PID file) + exit
7. **Initialize audio backend** — priority order:
   1. `MixerBackend` (C dual-decode with crossfade + 10-band EQ, ALSA output)
   2. `FfmpegBackend` (single-track C decode, no crossfade/EQ)
   3. `ProcessBackend` (spawns `mpv` or `ffplay` subprocess)
8. **Create visualizer** — shared memory PCM ring buffer at `/dev/shm/gtm-pcm`
9. **Open SQLite database** — `$XDG_DATA_HOME/gtm/gtm.db`, init schema
10. **Restore playback state** — volume, track path, shuffle, repeat, sleep timer,
    crossfade duration/curve, yt-dlp config, queue, completed downloads
11. **Auto-scan download directory** — add files not yet in library
12. **Set up Unix socket** — remove old socket, `bind()`, `listen()`
13. **Enter event loop**

### 2.2 Event Loop (16ms `select()` cycle)

Each iteration:

1. **Accept new connections** — max 1 client; new connection replaces previous
2. **Parse JSON commands** from client buffer (`\n`-delimited)
3. **Execute commands** — playback, library, queue, crossfade, EQ, yt-dlp
4. **Poll audio events** — serialize + forward to client as `{"events": [...]}`
5. **Auto-advance** on `aekTrackEnded` (crossfade or immediate next)
6. **Manage yt-dlp tasks** — poll downloads, stream URL resolution
7. **Retry queue advancement** — if stopped with pending items (waiting for YT)
8. **Send `up_next` notification** — ~8 seconds before track ends
9. **Crossfade scheduling**:
   - `timeRemaining <= crossfadeDuration + 2s` → `prepareNext()`
   - `timeRemaining <= crossfadeDuration` → `startCrossfade()`
10. **Background scan** — process 10 files per tick
11. **Capture PCM** → write to visualizer shared memory
12. **Sleep timer countdown** — decrement every 60 frames (~1s)
13. **Persist state** — every 1800 frames (~30s)
14. **Idle timeout** — shutdown after `idleTimeout * 60` frames (~5 min default) when stopped
15. **Shutdown** on `{"cmd":"quit"}` or signal

### 2.3 Shutdown

1. Save playback state to SQLite
2. Close SQLite database
3. Stop visualizer capture
4. Shut down audio backend
5. Close client socket
6. Close server socket
7. Remove socket file (`sockPath()`)
8. Remove PID file (`pidPath()`)

---

## 3. IPC Transport

| Field | Value |
|---|---|
| Socket family | `AF_UNIX` / `SOCK_STREAM` |
| Socket path | `$XDG_RUNTIME_DIR/gtm/gtmd.sock` or `/tmp/gtm-<USER>/gtmd.sock` |
| Framing | Newline-delimited — each JSON object is terminated by `\n` |
| Encoding | UTF-8 |
| Max clients | 1 (new connection replaces previous) |
| I/O model | Non-blocking; daemon uses `select()` with 16ms time-out |
| Buffer size | 4096 bytes per `recv()` call |

### Socket Path Resolution

- Primary: `$XDG_RUNTIME_DIR/gtm/gtmd.sock`
- Fallback: `/tmp/gtm-$USER/gtmd.sock`

```nim
proc sockPath*(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR", "")
  if xdg.len > 0: xdg & "/gtm/gtmd.sock"
  else: "/tmp/gtm-" & getEnv("USER", "unknown") & "/gtmd.sock"
```

Related paths:
- PID file: `sockPath` dir + `/gtmd.pid`
- Config dir: `$XDG_CONFIG_HOME/gtm`
- Data dir: `$XDG_DATA_HOME/gtm` (or `~/.local/share/gtm`)
- DB path: `dataDir() + "/gtm.db"`
- Download dir: `dataDir() + "/audio"`
- Crash log: `$XDG_CACHE_HOME/gtm/crash.log`

### Client Auto-Start

When a client launches, it checks for the running daemon via the PID file at
`pidPath()`. If the daemon is not running, it spawns `gtmd` as a child process.
Resolution order: `gtmd` next to client binary → `gtmd` on `$PATH` → `gtm daemon`
(self-fallback). The client waits up to 600ms for the socket to appear.

---

## 4. Message Format

### 4.1 Request (client → daemon)

```json
{"cmd": "<command_name>", "arg1": value1, "arg2": value2, ...}
```

Every request MUST contain a `"cmd"` string. Additional arguments are
command-specific (see [Commands](#5-commands)).

### 4.2 Response (daemon → client)

Success: `{"ok": true, "field1": value1, ...}`
Failure: `{"ok": false, "error": "description of error"}`

Every command produces exactly **one** response line.

### 4.3 Async Events (daemon → client, unsolicited)

```json
{"events": [{"kind": 5, "time_pos": 123.45}, ...]}
```

Multiple events may be batched into a single line. Events are sent:
- After every command response
- Between commands (each iteration of the daemon's event loop)

A client MUST be prepared to receive event lines at **any time**.

### 4.4 Client Message Handling

1. Open a `SOCK_STREAM` connection to the Unix socket
2. Send a command as a single JSON line: `{"cmd":"<cmd>", ...}\n`
3. Read lines from the socket — each `\n`-terminated string is a JSON object
4. If the JSON contains an `"events"` key → it is an async event batch (drain)
5. Otherwise → it is the response to the last command sent
6. Event lines may arrive between a command and its response — the response is
   the **first** non-event line received after the command
7. The daemon accepts at most one connected client; a new connection
   automatically replaces the previous one

---

## 5. Commands

Unless noted otherwise, every response includes at least `"ok": true` or
`"ok": false` with an `"error"` string. Additional response fields are listed
per command.

### 5.1 Playback Control

#### `play`

Resume playback from paused state.

Request: `{"cmd": "play"}`
Response: `{"ok": true}`

#### `pause`

Pause playback (clears visualizer PCM data).

Request: `{"cmd": "pause"}`
Response: `{"ok": true}`

#### `toggle_pause`

Toggle between playing and paused.

Request: `{"cmd": "toggle_pause"}`
Response: `{"ok": true}`

#### `stop`

Stop playback and rewind to position 0.

Request: `{"cmd": "stop"}`
Response: `{"ok": true}`

#### `seek`

Seek by a relative offset.

| Arg | Type | Default | Description |
|---|---|---|---|
| `seconds` | float | `5.0` | Seek offset in seconds (negative = backward) |

Request: `{"cmd": "seek", "seconds": -10.0}`
Response: `{"ok": true}`

#### `next`

Skip to the next track in queue (auto-advances with crossfade if configured).

Request: `{"cmd": "next"}`
Response: `{"ok": true}`

#### `prev`

Go to previous track from history or last-consumed-from-queue list. Supports
reverse crossfade if `crossfadeDuration > 0`.

Request: `{"cmd": "prev"}`
Response: `{"ok": true}`

Additional field (if library track found): `{"track_id": <int>}`

#### `load_file`

Load a file or URL and begin playback. Optionally attach metadata.

| Arg | Type | Default | Description |
|---|---|---|---|
| `path` | string | `""` | File path, URL, or YouTube page URL |
| `title` | string | `""` | Track title for display and library |
| `channel` | string | `""` | Artist / channel name |

Request: `{"cmd": "load_file", "path": "/music/track.flac", "title": "Song", "channel": "Artist"}`
Response:
```json
{
  "ok": true,
  "state": "playing",
  "duration": 234.5,
  "time_pos": 0.0,
  "track_id": 42
}
```

| Field | Type | Description |
|---|---|---|
| `state` | string | `"playing"`, `"paused"`, or `"stopped"` |
| `duration` | float | Track duration in seconds |
| `time_pos` | float | Current playback position in seconds |
| `track_id` | int | Library track ID (0 if not in library) |

#### `resume`

Resume the last loaded track from saved state. If no track is loaded, returns
`"stopped"`.

Request: `{"cmd": "resume"}`

Response (with track):
```json
{"ok": true, "state": "playing", "track": "/music/track.flac", "time_pos": 12.3, "duration": 234.5}
```

Response (no track): `{"ok": true, "state": "stopped"}`

### 5.2 Status & Info

#### `status` / `now_playing`

Both commands are identical. Get current playback status.

Request: `{"cmd": "status"}`

Response:
```json
{
  "ok": true,
  "state": "playing",
  "volume": 80,
  "time_pos": 42.0,
  "duration": 234.5,
  "track": "/music/track.flac",
  "audio_working": true,
  "sleep_timer": 0,
  "crossfading": false,
  "master_ended": false
}
```

| Field | Type | Description |
|---|---|---|
| `state` | string | `"playing"`, `"paused"`, or `"stopped"` |
| `volume` | int | Current volume (0–100) |
| `time_pos` | float | Current playback position in seconds |
| `duration` | float | Track duration in seconds |
| `track` | string | Path or URL of the current track |
| `audio_working` | bool | Whether the audio backend is operational |
| `sleep_timer` | int | Sleep timer remaining (minutes, 0 = off) |
| `crossfading` | bool | Whether a crossfade is in progress |
| `master_ended` | bool | Whether the master decode context has ended |

#### `get_state`

Get comprehensive playback state including track metadata, shuffle, repeat.

Request: `{"cmd": "get_state"}`

Response:
```json
{
  "ok": true,
  "state": "playing",
  "volume": 80,
  "time_pos": 42.0,
  "duration": 234.5,
  "track_path": "/music/track.flac",
  "track_title": "Song",
  "track_channel": "Artist",
  "track_album": "Album",
  "shuffle": false,
  "repeat": 0,
  "sleep_timer": 0,
  "crossfading": false,
  "master_ended": false
}
```

| Field | Type | Description |
|---|---|---|
| `track_title` | string | Title from metadata or filename if YouTube or sanitized filename |
| `track_channel` | string | Artist/channel from metadata |
| `track_album` | string | Album from metadata |
| `shuffle` | bool | Shuffle enabled |
| `repeat` | int | Repeat mode (0=off, 1=all, 2=one) |

#### `get_full_state`

Get extended state including queue, shuffle order, crossfade details.

Request: `{"cmd": "get_full_state"}`

Response:
```json
{
  "ok": true,
  "state": "playing",
  "volume": 80,
  "time_pos": 42.0,
  "duration": 234.5,
  "track_path": "/music/track.flac",
  "track_title": "Song",
  "track_channel": "Artist",
  "track_album": "Album",
  "shuffle": false,
  "repeat": 0,
  "sleep_timer": 0,
  "crossfading": false,
  "master_ended": false,
  "queue": ["/music/track1.flac", "/music/track2.flac"],
  "shuffleOrder": [0, 1],
  "shuffleIndex": 0,
  "crossfadeDuration": 5,
  "crossfadeCurve": 1,
  "crossfadePrepared": false,
  "crossfadeStarted": false,
  "crossfadeNextPath": ""
}
```

| Field | Type | Description |
|---|---|---|
| `queue` | array | Array of track paths in the playback queue |
| `shuffleOrder` | array | Array of indices representing shuffled order |
| `shuffleIndex` | int | Current position in shuffle order |
| `crossfadeDuration` | int | Crossfade duration in seconds (0 = disabled) |
| `crossfadeCurve` | int | Curve type (1=equal-power, 2=quadratic, 3=cubic, 4=asymmetric) |
| `crossfadePrepared` | bool | Whether next track is pre-loaded in slave context |
| `crossfadeStarted` | bool | Whether crossfade transition has begun |
| `crossfadeNextPath` | string | Path of the next track being crossfaded to |

#### `ping`

Health check.

Request: `{"cmd": "ping"}`
Response: `{"pong": true}`

### 5.3 Volume

#### `set_volume`

Set playback volume.

| Arg | Type | Default | Description |
|---|---|---|---|
| `volume` | int | `80` | Volume level (0–100) |

Request: `{"cmd": "set_volume", "volume": 75}`
Response: `{"ok": true}`

#### `get_volume`

Get current volume.

Request: `{"cmd": "get_volume"}`
Response: `{"ok": true, "volume": 80}`

### 5.4 Queue Management

#### `queue_add`

Add items to the playback queue. Automatically starts YouTube downloads for
watch URLs and resolves stream URLs for instant playback.

| Arg | Type | Description |
|---|---|---|
| `data` | array | Array of strings (paths) or objects `{"path","title","channel"}` |

Request: `{"cmd": "queue_add", "data": ["/music/track1.flac", "/music/track2.flac"]}`
Request (with metadata): `{"cmd": "queue_add", "data": [{"path":"/music/track.flac","title":"Song","channel":"Artist"}]}`
Request (YouTube): `{"cmd": "queue_add", "data": ["https://youtube.com/watch?v=..."]}`

Response: `{"ok": true, "queue_length": 3}`

#### `queue_remove`

Remove item at index from queue.

| Arg | Type | Default | Description |
|---|---|---|---|
| `index` | int | `0` | 0-based index in queue |

Request: `{"cmd": "queue_remove", "index": 0}`
Response: `{"ok": true}`

#### `queue_remove_path`

Remove item by path from queue.

| Arg | Type | Default | Description |
|---|---|---|---|
| `path` | string | `""` | Path to remove |

Request: `{"cmd": "queue_remove_path", "path": "/music/track.flac"}`
Response: `{"ok": true}`

#### `queue_clear`

Clear entire queue and reset shuffle state.

Request: `{"cmd": "queue_clear"}`
Response: `{"ok": true}`

#### `queue_list`

List all items in the queue.

Request: `{"cmd": "queue_list"}`
Response: `{"ok": true, "queue": ["/music/track1.flac", "/music/track2.flac"]}`

#### `queue_set_cursor`

Set the shuffle cursor position.

| Arg | Type | Default | Description |
|---|---|---|---|
| `index` | int | `0` | New shuffle index |

Request: `{"cmd": "queue_set_cursor", "index": 2}`
Response: `{"ok": true, "cursor": 2}`

### 5.5 Playback Mode

#### `set_shuffle`

Enable or disable shuffle mode. Enabling shuffle generates a new random order
over the current queue.

| Arg | Type | Default | Description |
|---|---|---|---|
| `enabled` | int | `0` | `1` to enable, `0` to disable |

Request: `{"cmd": "set_shuffle", "enabled": 1}`
Response: `{"ok": true, "shuffle": true}`

#### `set_repeat`

Set repeat mode.

| Arg | Type | Default | Description |
|---|---|---|---|
| `mode` | int | `0` | `0` = off, `1` = repeat all, `2` = repeat one |

Request: `{"cmd": "set_repeat", "mode": 1}`
Response: `{"ok": true, "repeat": 1}`

#### `set_sleep_timer`

Set a sleep timer after which playback stops and the daemon shuts down.

| Arg | Type | Default | Description |
|---|---|---|---|
| `minutes` | int | `0` | Minutes until stop. `0` disables the timer. |

Request: `{"cmd": "set_sleep_timer", "minutes": 15}`
Response: `{"ok": true, "sleep_timer": 15}`

### 5.6 Crossfade

#### `prepare_next`

Pre-load the next track in a secondary decode context for gapless crossfade.

| Arg | Type | Default | Description |
|---|---|---|---|
| `path` | string | `""` | File path or URL to prepare |

Request: `{"cmd": "prepare_next", "path": "/music/next.flac"}`
Response: `{"ok": true}`

#### `crossfade`

Begin an equal-power crossfade from the current (master) context to the
prepared (slave) context. `prepare_next` must have been called first.

| Arg | Type | Default | Description |
|---|---|---|---|
| `duration` | float | `5.0` | Crossfade duration in seconds |

Request: `{"cmd": "crossfade", "duration": 3.0}`
Response: `{"ok": true}`

#### `set_crossfade_curve`

Set the crossfade curve type.

| Arg | Type | Default | Description |
|---|---|---|---|
| `curve_type` | int | `1` | `1`=equal-power (cos/sin), `2`=quadratic, `3`=cubic, `4`=asymmetric |

Request: `{"cmd": "set_crossfade_curve", "curve_type": 2}`
Response: `{"ok": true}`

### 5.7 Equalizer

#### `set_eq_band`

Set the gain for a single equalizer band.

| Arg | Type | Default | Description |
|---|---|---|---|
| `band` | int | `0` | Band index 0–9 (31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz) |
| `gain_db` | float | `0.0` | Gain in dB (−12 to +12) |

Request: `{"cmd": "set_eq_band", "band": 3, "gain_db": -2.5}`
Response: `{"ok": true}`

#### `set_eq_preset`

Apply a named equalizer preset.

| Arg | Type | Default | Description |
|---|---|---|---|
| `name` | string | `""` | Preset name (see list below) |

Available presets: `Flat`, `Rock`, `Pop`, `Classical`, `Jazz`, `HipHop`,
`Vocal`, `BassBoost`, `Headphones`, `Laptop`, `Electronic`, `Acoustic`,
`Podcast`, `Dance`

Request: `{"cmd": "set_eq_preset", "name": "Rock"}`
Response: `{"ok": true}`

#### `list_eq_presets`

List available EQ preset names.

Request: `{"cmd": "list_eq_presets"}`
Response: `{"ok": true, "presets": ["Flat", "Rock", "Pop", "Classical", "Jazz", "HipHop", "Vocal", "BassBoost", "Headphones", "Laptop", "Electronic", "Acoustic", "Podcast", "Dance"]}`

### 5.8 Library

#### `get_library`

Fetch all tracks, artists, and albums from the SQLite database.

Request: `{"cmd": "get_library"}`

Response:
```json
{
  "ok": true,
  "tracks": [{"id": 1, "path": "/music/track.flac", "title": "Song", "artist": "Artist", "album": "Album", "duration": 234.5, "track_num": 1, "year": 2024, "genre": "Rock", "play_count": 5, "artist_id": 1, "album_id": 1, "is_favourite": false, "added_at": "2024-01-01", "last_played": "2024-06-01"}],
  "artists": [{"id": 1, "name": "Artist"}],
  "albums": [{"id": 1, "title": "Album", "artist_id": 1, "artist_name": "Artist", "year": 2024, "genre": "Rock"}]
}
```

Track object fields:

| Field | Type | Description |
|---|---|---|
| `id` | int | Unique track ID |
| `path` | string | File path or URL |
| `title` | string | Track title |
| `artist` | string | Artist name (from artists table) |
| `album` | string | Album title (from albums table) |
| `duration` | float | Duration in seconds |
| `track_num` | int | Track number |
| `year` | int | Release year |
| `genre` | string | Genre |
| `play_count` | int | Number of times played |
| `artist_id` | int | FK to artists table |
| `album_id` | int | FK to albums table |
| `is_favourite` | bool | Whether track is in favourites |
| `added_at` | string | ISO datetime added |
| `last_played` | string | ISO datetime last played |

#### `add_track`

Add a track to the library.

| Arg | Type | Description |
|---|---|---|
| `data` | object | `{"path", "title", "channel", "album", "duration"}` |

Request: `{"cmd": "add_track", "data": {"path": "/music/track.flac", "title": "Song", "channel": "Artist", "album": "Album", "duration": 234.5}}`
Response: `{"ok": true, "track_id": 42}`

#### `update_track_path`

Update a track's path in the library (e.g. after a YouTube download completes).

| Arg | Type | Description |
|---|---|---|
| `data` | object | `{"old_path", "new_path", "title"}` |

Request: `{"cmd": "update_track_path", "data": {"old_path": "https://youtube.com/watch?v=...", "new_path": "/downloads/song.opus", "title": "Song"}}`
Response: `{"ok": true, "updated": true}`

#### `scan`

Start a background scan of a directory for audio files. Processes 10 files per
event loop tick. Emits `scan_done` custom event when complete.

| Arg | Type | Default | Description |
|---|---|---|---|
| `path` | string | `""` | Directory path to scan |

Request: `{"cmd": "scan", "path": "/music"}`
Response:
```json
{"ok": true, "scanning": true, "total_files": 150}
```
Or if already scanning: `{"ok": true, "scanning_already": true}`

### 5.9 Playlists

#### `create_playlist`

Create a new empty playlist.

| Arg | Type | Default | Description |
|---|---|---|---|
| `name` | string | `""` | Playlist name |

Request: `{"cmd": "create_playlist", "name": "Favourites"}`
Response: `{"ok": true, "playlist_id": 5, "playlists": [...]}`

| Field | Type | Description |
|---|---|---|
| `playlist_id` | int | ID of the newly created playlist |
| `playlists` | array | Array of all current playlists `{"id", "name", "track_count"}` |

#### `delete_playlist`

Delete a playlist by ID.

| Arg | Type | Default | Description |
|---|---|---|---|
| `playlist_id` | int | `0` | Playlist ID to delete |

Request: `{"cmd": "delete_playlist", "playlist_id": 5}`
Response: `{"ok": true, "playlists": [...]}`

#### `rename_playlist`

Rename a playlist.

| Arg | Type | Default | Description |
|---|---|---|---|
| `playlist_id` | int | `0` | Playlist ID |
| `name` | string | `""` | New name |

Request: `{"cmd": "rename_playlist", "playlist_id": 5, "name": "Best Of"}`
Response: `{"ok": true, "playlists": [...]}`

#### `add_to_playlist`

Add a track to a playlist.

| Arg | Type | Description |
|---|---|---|
| `data` | object | `{"playlist_id", "track_id", "position"}` |

Request: `{"cmd": "add_to_playlist", "data": {"playlist_id": 5, "track_id": 42, "position": 0}}`
Response: `{"ok": true}`

#### `remove_from_playlist`

Remove a track from a playlist.

| Arg | Type | Description |
|---|---|---|
| `data` | object | `{"playlist_id", "track_id"}` |

Request: `{"cmd": "remove_from_playlist", "data": {"playlist_id": 5, "track_id": 42}}`
Response: `{"ok": true}`

#### `list_playlists`

List all playlists with track counts.

Request: `{"cmd": "list_playlists"}`
Response: `{"ok": true, "playlists": [{"id": 1, "name": "Favourites", "track_count": 15}, ...]}`

#### `get_playlist_tracks`

Get track IDs belonging to a playlist.

| Arg | Type | Default | Description |
|---|---|---|---|
| `playlist_id` | int | `0` | Playlist ID |

Request: `{"cmd": "get_playlist_tracks", "playlist_id": 5}`
Response: `{"ok": true, "playlist_id": 5, "track_ids": [1, 2, 3, ...]}`

### 5.10 Favourites

#### `add_favourite`

Add a track to favourites.

| Arg | Type | Default | Description |
|---|---|---|---|
| `track_id` | int | `0` | Library track ID |

Request: `{"cmd": "add_favourite", "track_id": 42}`
Response: `{"ok": true}`

#### `remove_favourite`

Remove a track from favourites.

| Arg | Type | Default | Description |
|---|---|---|---|
| `track_id` | int | `0` | Library track ID |

Request: `{"cmd": "remove_favourite", "track_id": 42}`
Response: `{"ok": true}`

#### `get_favourites`

Get all favourite track IDs.

Request: `{"cmd": "get_favourites"}`
Response: `{"ok": true, "favourites": [1, 2, 3, ...]}`

### 5.11 YouTube / yt-dlp

All YouTube operations use an **async poll pattern**: start the operation with
a `yt_*` command, then loop calling the corresponding `*_poll` command until
`"done"` is `true`.

#### `yt_search`

Start a YouTube search via yt-dlp.

| Arg | Type | Default | Description |
|---|---|---|---|
| `query` | string | `""` | Search query |
| `page_size` | int | `10` | Results per page |

Request: `{"cmd": "yt_search", "query": "lofi hip hop", "page_size": 10}`
Response: `{"ok": true, "active": true}`

#### `yt_search_poll`

Poll for search results. Results accumulate across calls. The search is
`"done"` when the yt-dlp process finishes.

Request: `{"cmd": "yt_search_poll"}`

Response (in progress):
```json
{"ok": true, "results": [{"title": "...", "url": "...", "duration": "3:45", "channel": "...", "kind": 0}], "done": false}
```
Response (complete):
```json
{"ok": true, "results": [{"title": "...", "url": "...", "duration": "3:45", "channel": "...", "kind": 0}], "done": true}
```

| Field | Type | Description |
|---|---|---|
| `results` | array | Array of result objects |
| `done` | bool | Whether search is complete |

Result object:

| Field | Type | Description |
|---|---|---|
| `title` | string | Video/playlist title |
| `url` | string | YouTube URL |
| `duration` | string | Human-readable duration |
| `channel` | string | Channel/uploader name |
| `kind` | int | `0` = video, `1` = playlist |

#### `yt_search_cancel`

Cancel an active search.

Request: `{"cmd": "yt_search_cancel"}`
Response: `{"ok": true}`

#### `yt_resolve_stream`

Start resolving a YouTube video to its direct stream URL.

| Arg | Type | Default | Description |
|---|---|---|---|
| `url` | string | `""` | YouTube watch URL |
| `title` | string | `""` | Track title |
| `channel` | string | `""` | Channel name |

Request: `{"cmd": "yt_resolve_stream", "url": "https://youtube.com/watch?v=...", "title": "Song", "channel": "Artist"}`
Response: `{"ok": true, "active": true}`

#### `yt_resolve_stream_poll`

Poll for stream URL resolution result.

Request: `{"cmd": "yt_resolve_stream_poll"}`

Response (complete):
```json
{"ok": true, "url": "https://rr2---sn-...googlevideo.com/...", "title": "Song", "channel": "Artist", "done": true}
```

| Field | Type | Description |
|---|---|---|
| `url` | string | Direct stream URL (empty until done) |
| `title` | string | Original track title |
| `channel` | string | Original channel name |
| `done` | bool | Whether resolution is complete |

#### `yt_download`

Start downloading a YouTube video's audio via yt-dlp.

| Arg | Type | Default | Description |
|---|---|---|---|
| `url` | string | `""` | YouTube watch URL |
| `title` | string | `""` | Track title |
| `channel` | string | `""` | Channel name |

Request: `{"cmd": "yt_download", "url": "https://youtube.com/watch?v=...", "title": "Song", "channel": "Artist"}`
Response: `{"ok": true, "started": true}`

#### `yt_download_poll`

Poll download progress. Returns active and completed downloads.

Request: `{"cmd": "yt_download_poll"}`

Response:
```json
{
  "ok": true,
  "done": false,
  "path": "/downloads/song.opus",
  "url": "https://youtube.com/watch?v=...",
  "active": [{"url": "...", "title": "...", "started": 1234567890.0}],
  "completed": [{"url": "...", "path": "...", "title": "..."}]
}
```

| Field | Type | Description |
|---|---|---|
| `done` | bool | Whether all downloads are complete |
| `path` | string | Path of most recently completed download (cleared after read) |
| `url` | string | URL of most recently completed download |
| `active` | array | Array of active download objects `{"url", "title", "started"}` |
| `completed` | array | Array of completed download objects `{"url", "path", "title"}` |

#### `yt_cancel_download`

Cancel an active download.

| Arg | Type | Default | Description |
|---|---|---|---|
| `url` | string | `""` | YouTube URL of the download to cancel |

Request: `{"cmd": "yt_cancel_download", "url": "https://youtube.com/watch?v=..."}`
Response: `{"ok": true}`

#### `yt_list_downloads`

List all completed downloads from the database.

Request: `{"cmd": "yt_list_downloads"}`
Response: `{"ok": true, "downloads": [{"url": "...", "path": "...", "title": "..."}, ...]}`

#### `yt_fetch_playlist`

Start fetching a YouTube playlist's track listing.

| Arg | Type | Default | Description |
|---|---|---|---|
| `url` | string | `""` | YouTube playlist URL |

Request: `{"cmd": "yt_fetch_playlist", "url": "https://youtube.com/playlist?list=..."}`
Response: `{"ok": true, "pending": true}`

#### `yt_fetch_playlist_poll`

Poll for playlist tracks. Results accumulate across calls.

Request: `{"cmd": "yt_fetch_playlist_poll"}`

Response (complete):
```json
{
  "ok": true,
  "title": "Playlist Title",
  "channel": "Channel Name",
  "tracks": [{"title": "...", "url": "...", "duration": "3:45", "channel": "...", "kind": 0}],
  "track_count": 15,
  "done": true
}
```

Response (in progress): `{"ok": true, "pending": true}`

#### `yt_set_config`

Configure yt-dlp settings.

| Arg | Type | Default | Description |
|---|---|---|---|
| `cookie_source` | string | `""` | Browser for cookies (e.g. "firefox", "chrome") |
| `js_runtime` | string | `""` | JS runtime (e.g. "node", "bun", "deno") |
| `download_dir` | string | `""` | Download directory path |
| `max_concurrent` | int | `4` | Max concurrent downloads |

Request: `{"cmd": "yt_set_config", "cookie_source": "firefox", "js_runtime": "node", "download_dir": "/music/yt", "max_concurrent": 4}`
Response: `{"ok": true, "cookie_source": "firefox", "js_runtime": "node", "download_dir": "/music/yt", "max_concurrent": 4}`

#### `yt_get_search_history`

Get recent search queries from the database.

Request: `{"cmd": "yt_get_search_history"}`
Response: `{"ok": true, "history": ["lofi hip hop", "jazz chill", ...]}`

#### `yt_clear_search_history`

Clear search history.

Request: `{"cmd": "yt_clear_search_history"}`
Response: `{"ok": true}`

### 5.12 Daemon Lifecycle

#### `quit`

Gracefully shut down the daemon. Saves playback state to SQLite, stops
visualizer capture, closes audio backend, removes socket file, and exits.

Request: `{"cmd": "quit"}`
Response: `{"ok": true}` (client may not receive this before socket closes)

---

## 6. Events

Each event object has at minimum a `"kind"` field (integer). Multiple events
may be batched into a single JSON line: `{"events": [{...}, {...}]}`.

### 6.1 Event Table

| Kind | Name | Extra Fields | When Emitted |
|---|---|---|---|
| `0` | `aekNone` | — | Unused |
| `1` | `aekPlaybackStarted` | `state: "playing"`, `track_path`, `track_title`, `track_channel`, `auto_advanced: bool` | Playback begins/resumes after stop |
| `2` | `aekPlaybackPaused` | `state: "paused"` | Playback paused |
| `3` | `aekPlaybackStopped` | `state: "stopped"` | Playback stopped |
| `4` | `aekTrackEnded` | `reason: "eof"` | Current track reached end-of-file |
| `5` | `aekPositionChanged` | `time_pos: <float>` | Playback position advanced (~1 Hz) |
| `6` | `aekDurationChanged` | `duration: <float>` | Track duration resolved/changed |
| `7` | `aekVolumeChanged` | `volume: <int>` | Volume changed |
| `8` | `aekMetadataChanged` | `event: "crossfade_started"` or `"crossfade_ended"` | Crossfade state changes |
| `9` | `aekError` | — | Audio backend error (unused currently) |
| `10` | `aekCustomEvent` | `event: <string>`, plus sub-type fields (see below) | Various async notifications |

### 6.2 Custom Event Sub-Types (kind=10)

| Event String | Additional Fields | When Sent |
|---|---|---|
| `"queue_changed"` | `queue: [paths]`, `shuffleOrder: [ints]`, `shuffleIndex: int` | Queue is modified (add/remove/clear/advance) |
| `"up_next"` | `next_path: string`, `next_title: string`, `next_channel: string` | ~8 seconds before current track ends |
| `"yt_download_done"` | `url: string`, `path: string`, `title: string` | YouTube download completes |
| `"scan_done"` | — | Background directory scan finishes |

### 6.3 Example Event Lines

```json
{"events":[{"kind":5,"time_pos":42.7},{"kind":1,"state":"playing","track_path":"/music/track.flac","track_title":"Song","track_channel":"Artist","auto_advanced":false}]}

{"events":[{"kind":10,"event":"queue_changed","queue":["/path/1","/path/2"],"shuffleOrder":[0,1],"shuffleIndex":0}]}

{"events":[{"kind":10,"event":"up_next","next_path":"/path/to/next","next_title":"Next Song","next_channel":"Artist"}]}

{"events":[{"kind":10,"event":"yt_download_done","url":"https://youtube.com/watch?v=...","path":"/downloads/song.opus","title":"Song"}]}

{"events":[{"kind":10,"event":"scan_done"}]}
```

---

## 7. Database Schema

**Path**: `$XDG_DATA_HOME/gtm/gtm.db` (or `~/.local/share/gtm/gtm.db`)

### `tracks`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK AUTOINCREMENT | Unique track identifier |
| `path` | TEXT | UNIQUE NOT NULL | File path or URL |
| `title` | TEXT | DEFAULT '' | Track title |
| `artist_id` | INTEGER | FK → artists(id) | Artist reference |
| `album_id` | INTEGER | FK → albums(id) | Album reference |
| `track_num` | INTEGER | DEFAULT 0 | Track number on album |
| `duration` | REAL | DEFAULT 0.0 | Duration in seconds |
| `year` | INTEGER | DEFAULT 0 | Release year |
| `genre` | TEXT | DEFAULT '' | Genre |
| `added_at` | TEXT | DEFAULT datetime('now') | ISO datetime added |
| `play_count` | INTEGER | DEFAULT 0 | Times played |
| `last_played` | TEXT | | ISO datetime last played |

### `artists`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK AUTOINCREMENT | Unique artist identifier |
| `name` | TEXT | UNIQUE NOT NULL | Artist name |

### `albums`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK AUTOINCREMENT | Unique album identifier |
| `title` | TEXT | NOT NULL | Album title |
| `artist_id` | INTEGER | FK → artists(id) | Artist reference |
| `year` | INTEGER | DEFAULT 0 | Release year |
| `genre` | TEXT | DEFAULT '' | Genre |

### `playlists`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK AUTOINCREMENT | Unique playlist identifier |
| `name` | TEXT | NOT NULL | Playlist name |
| `created_at` | TEXT | DEFAULT datetime('now') | ISO datetime created |

### `playlist_tracks`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `playlist_id` | INTEGER | FK → playlists(id) | Playlist reference |
| `track_id` | INTEGER | FK → tracks(id) | Track reference |
| `position` | INTEGER | | Sort order position |

Primary key: `(playlist_id, track_id)`

### `favourites`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `track_id` | INTEGER | PK, FK → tracks(id) | Track reference |
| `added_at` | TEXT | DEFAULT datetime('now') | ISO datetime favourited |

### `downloads`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK AUTOINCREMENT | Unique identifier |
| `source_url` | TEXT | UNIQUE NOT NULL | Original YouTube URL |
| `local_path` | TEXT | NOT NULL | Local file path |
| `title` | TEXT | DEFAULT '' | Track title |
| `channel` | TEXT | DEFAULT '' | Channel/artist |
| `downloaded_at` | TEXT | DEFAULT datetime('now') | ISO datetime downloaded |

### `playback_state`

Key-value store for daemon state persistence.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `key` | TEXT | PK | State key |
| `value` | TEXT | | State value |

Known keys: `volume`, `time_pos`, `track_path`, `track_title`, `track_channel`,
`state`, `shuffle`, `repeat`, `sleep_timer`, `crossfade_duration`,
`crossfade_curve`, `yt_cookie_source`, `yt_js_runtime`, `yt_download_dir`,
`yt_max_concurrent`, `queue_json`

### `search_history`

| Column | Type | Constraints | Description |
|---|---|---|---|
| `id` | INTEGER | PK AUTOINCREMENT | Unique identifier |
| `query` | TEXT | NOT NULL | Search query text |
| `searched_at` | TEXT | DEFAULT datetime('now') | ISO datetime of search |

---

## 8. Shared Memory (Visualizer)

### SHM Path

`/dev/shm/gtm-pcm` (created via `shm_open` with `O_RDWR | O_CREAT`, mode `0600`)

### Ring Buffer Layout

```
Offset  │ Content          │ Type       │ Size
────────┼──────────────────┼────────────┼───────────
0       │ PCM samples      │ float32[]  │ PCM_RING_SIZE * sizeof(float32) = 32768 bytes
32768   │ writePos         │ int32      │ 4 bytes
32772   │ readPos          │ int32      │ 4 bytes
32776   │ size             │ int32      │ 4 bytes
───────────────────────────────────────┼───────────
Total                                   │ 32780 bytes
```

### Constants

| Constant | Value | Description |
|---|---|---|
| `FFT_SIZE` | 1024 | Samples per FFT frame |
| `PCM_RING_SIZE` | 8192 (FFT_SIZE × 8) | Total ring buffer capacity in samples |
| `MAX_VIS_BARS` | 64 | Maximum number of FFT bars |
| `MIN_VIS_BARS` | 4 | Minimum number of FFT bars |
| Default bar count | 32 | Default visualizer bar count |

### Data Flow

1. Daemon reads 512 PCM frames from the audio backend each event loop tick
2. Daemon writes samples to the ring buffer via `writePcm()`
3. Visualizer reads up to `FFT_SIZE * 4` samples per tick
4. For each complete FFT frame (1024 samples), the visualizer runs:
   - Hanning windowing
   - Manual Cooley-Tukey radix-2 FFT
   - Logarithmic frequency bin mapping
   - dB compression (20*log10, normalized to 0..1, power 1.8 curve)
   - Smoothing (85% previous frame + 15% current)
   - Peak decay (94% per frame)

### Client Access

Clients attach read-only to the same shared memory segment using `shm_open`
with `O_RDONLY`, then `mmap` with `PROT_READ`.

```nim
proc openShm*(name: string): PcmRingBuffer =
  let totalSize = sizeof(float32) * PCM_RING_SIZE + sizeof(int32) * 2 + sizeof(int32)
  result.fd = shm_open(name.cstring, O_RDONLY, 0)
  let mem = mmap(nil, totalSize, PROT_READ, MAP_SHARED, result.fd, 0)
  result.data = cast[ptr UncheckedArray[float32]](mem)
  result.writePos = cast[ptr int32](cast[int](mem) + sizeof(float32) * PCM_RING_SIZE)
  result.readPos = cast[ptr int32](cast[int](mem) + sizeof(float32) * PCM_RING_SIZE + sizeof(int32))
  result.size = PCM_RING_SIZE
```

---

## 9. Audio Backend

### Backend Priority

The daemon initializes backends in priority order at startup. The first
successful backend is used.

| Priority | Backend | Type | Capabilities |
|---|---|---|---|
| 1 | `MixerBackend` | `abtMixer` | Dual decode contexts, equal-power crossfade, 10-band biquad EQ, ALSA output. Requires `-d:useFFmpeg`. |
| 2 | `FfmpegBackend` | `abtFFmpeg` | Single-track decode via FFmpeg C bindings. No crossfade, no EQ. |
| 3 | `ProcessBackend` | `abtProcess` | Spawns `mpv` or `ffplay` subprocess. Minimal control (play/stop/pause only). |

### Backend State Machine

- `0` = stopped
- `1` = playing
- `2` = paused

### Capabilities by Backend

| Feature | MixerBackend | FfmpegBackend | ProcessBackend |
|---|---|---|---|
| loadFile | ✓ | ✓ | ✓ (stored, loaded on play) |
| play/pause/stop | ✓ | ✓ | ✓ (SIGSTOP/SIGCONT) |
| seek | ✓ | ✓ | ✗ |
| setVolume | ✓ | ✓ | ✓ (only on process start) |
| pollEvents | ✓ (full state machine) | ✓ (full state machine) | ✓ (peek exit code only) |
| readPcmFrames | ✓ | ✓ | ✗ |
| prepareNext | ✓ | ✗ | ✗ |
| startCrossfade | ✓ (with reverse) | ✗ | ✗ |
| getStatusFlags | ✓ (crossfading, masterEnded) | ✗ (false, false) | ✗ |
| setEqBand | ✓ | ✗ | ✗ |
| setEqPreset | ✓ | ✗ | ✗ |
| setCrossfadeCurve | ✓ | ✗ | ✗ |

### DaemonClient (Client-Side Proxy)

The TUI client wraps IPC communication in a `DaemonClient` object that inherits
`AudioBackend`. All method calls are translated to JSON commands sent over the
Unix socket. This allows the TUI to treat the daemon connection identically to
a local backend.

---

## 10. Crossfade

### Architecture

Crossfade is implemented in the C layer (`MixerCtx`) with dual decode contexts:
- **Master** context: current playing track
- **Slave** context: next track (loaded via `prepareNext`)

### Curve Types

| Value | Name | Description |
|---|---|---|
| 1 | Equal-power | cos/sin envelope (smooth constant power) |
| 2 | Quadratic | Quadratic fade curves |
| 3 | Cubic | Cubic fade curves |
| 4 | Asymmetric | Asymmetric fade (slower fade-in, faster fade-out) |

### Scheduling (Daemon-Managed)

The daemon automatically schedules crossfade phases when `crossfadeDuration > 0`
and a next track exists:

```
Phase 0: timeRemaining ≤ crossfadeDuration + 2s → prepareNext()
Phase 1: timeRemaining ≤ crossfadeDuration         → startCrossfade()
                                                → auto-promote slave→master
                                                → aekTrackEnded on master end
                                                → consume queue
```

When `reverse=true` (for "prev" command), the slave context loads the previous
track and crossfades in reverse direction.

### Auto-Advance Flow

1. `aekTrackEnded` event fires
2. If crossfade was in progress: promote slave→master, consume queue, update state
3. If no crossfade: call `advanceToNextTrack()` which resolves YouTube URLs
   (downloaded file → stream URL → start download/stream resolution)
4. If crossfade enabled: `prepareNext()` then `startCrossfade()`
5. If no crossfade: `stop()` → `loadFile()` → `play()`

---

## 11. Client Implementation Guide

### 11.1 Finding the Socket Path

```python
import os
runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
if runtime_dir:
    sock_path = f"{runtime_dir}/gtm/gtmd.sock"
else:
    sock_path = f"/tmp/gtm-{os.environ['USER']}/gtmd.sock"
```

### 11.2 Connecting

```python
import socket, json

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sock_path)
sock.setblocking(False)
```

### 11.3 Sending a Command

```python
def send_cmd(sock, cmd_dict):
    data = json.dumps(cmd_dict) + "\n"
    sock.send(data.encode("utf-8"))
```

### 11.4 Reading Responses and Events

The daemon sends `\n`-delimited JSON lines. A response is the **first**
non-event line received after a command. Event lines (`{"events": [...]}`) can
arrive at any time and must be drained.

```python
buffer = ""
def read_line(sock):
    global buffer
    while "\n" not in buffer:
        chunk = sock.recv(4096).decode("utf-8")
        if not chunk:
            raise ConnectionError("socket closed")
        buffer += chunk
    idx = buffer.index("\n")
    line = buffer[:idx]
    buffer = buffer[idx+1:]
    return json.loads(line)

def send_and_recv(sock, cmd_dict):
    global buffer
    send_cmd(sock, cmd_dict)
    while True:
        obj = read_line(sock)
        if "events" in obj:
            handle_events(obj["events"])
        else:
            return obj
```

### 11.5 Ping / Heartbeat

Send `{"cmd": "ping"}` every few seconds. Expect `{"pong": true}`. If multiple
pings are missed, the daemon may be dead. Check the PID file at `pidPath()`:

```python
import os
pid_path = sock_path.replace("gtmd.sock", "gtmd.pid")
if os.path.exists(pid_path):
    with open(pid_path) as f:
        pid = int(f.read().strip())
    try:
        os.kill(pid, 0)  # check if alive
    except OSError:
        print("daemon is dead")
```

### 11.6 Polling Pattern (YouTube Operations)

```python
# Start search
resp = send_and_recv(sock, {"cmd": "yt_search", "query": "lofi", "page_size": 10})

# Poll until done
results = []
while True:
    resp = send_and_recv(sock, {"cmd": "yt_search_poll"})
    results = resp.get("results", [])
    if resp.get("done"):
        break
```

### 11.7 Handling Async Events in a Background Loop

For UIs, a background thread or async task should continuously read from the
socket and dispatch events:

```python
import threading, select

events_queue = []

def reader_thread(sock):
    global buffer
    while True:
        r, _, _ = select.select([sock], [], [], 0.1)
        if r:
            try:
                chunk = sock.recv(4096).decode("utf-8")
                if not chunk:
                    break
                buffer += chunk
                while "\n" in buffer:
                    idx = buffer.index("\n")
                    line = buffer[:idx]
                    buffer = buffer[idx+1:]
                    obj = json.loads(line)
                    if "events" in obj:
                        events_queue.extend(obj["events"])
            except:
                break
```

### 11.8 Single-Client Constraint

The daemon accepts at most **one** connected client. When a new client
connects, the previous client is silently disconnected. Active yt-dlp
subprocesses (search, stream resolution) from the old client are terminated.

### 11.9 Daemon Auto-Start

```python
import subprocess, time

def ensure_daemon():
    pid_path = os.path.join(os.path.dirname(sock_path), "gtmd.pid")
    if os.path.exists(pid_path):
        with open(pid_path) as f:
            pid = int(f.read().strip())
        try:
            os.kill(pid, 0)
            return  # daemon is running
        except OSError:
            pass  # stale PID
    # Start daemon
    subprocess.Popen(["gtmd"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Wait for socket
    for _ in range(60):
        if os.path.exists(sock_path):
            return
        time.sleep(0.01)
    raise TimeoutError("daemon did not start")
```

### 11.10 Error Handling

- Commands return `{"ok": false, "error": "description"}` on failure
- If the socket is closed mid-command, the client will receive incomplete data
  and should reconnect
- Upon reconnect, the client should call `{"cmd": "resume"}` or
  `{"cmd": "get_state"}` to restore its view of daemon state
- Event lines may be interleaved with command responses — always check for
  `"events"` key first

---

## 12. State Persistence

The daemon persists its state to the SQLite `playback_state` table:

- **Frequency**: every 1800 event loop frames (~30 seconds at ~60fps) and on
  shutdown
- **Restored on startup**: volume, current track path/title/channel, shuffle
  state, repeat mode, sleep timer, crossfade duration/curve, yt-dlp config
  (cookie source, JS runtime, download dir, max concurrent), playback queue
  (as JSON), completed downloads list
- **Queue persistence**: serialized as a JSON array of path strings

---

## 13. Source Reference

| Component | File | Role |
|---|---|---|
| Daemon entry point | `src/gtmd.nim` | Calls `runDaemon()` |
| Daemon main loop + IPC | `src/daemon.nim` | Socket, event loop, command execution, event serialization |
| Client library | `src/client.nim` | `DaemonClient` IPC proxy |
| Audio backend types | `src/audio.nim` | Backend classes, event kinds, mixer/ffmpeg/process backends |
| Paths and directories | `src/state.nim` | `sockPath()`, `pidPath()`, `stateDir()`, `dataDir()`, `configDir()` |
| Visualizer (SHM) | `src/visualizer.nim` | PCM ring buffer, FFT processing |
| SQLite database | `src/library.nim` | Schema, CRUD operations |
| yt-dlp integration | `src/ytdlp.nim` | Search, stream resolve, download, playlist fetch |
| Commands registry | `src/commands.nim` | Keybinding and command registration |
| MPRIS interface | `src/mpris.nim` | D-Bus MPRIS (opt-in: `-d:useMpris`) |

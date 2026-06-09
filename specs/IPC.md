# IPC Protocol

See `docs/gtmd-ipc.md` for the full specification.

## Transport

- AF_UNIX / SOCK_STREAM
- Path: `$XDG_RUNTIME_DIR/gtm/gtmd.sock` or `/tmp/gtm-$USER/gtmd.sock`
- Newline-delimited JSON
- Max 1 client (new connection replaces previous)
- Non-blocking I/O via select()

## Missing Commands (to be added)

- `queue_add`, `queue_remove`, `queue_clear`, `queue_list`, `queue_set_cursor`
- `add_favourite`, `remove_favourite`, `get_favourites`
- `yt_search`, `yt_stream_url`, `yt_download`, `yt_playlist_detail`, `yt_poll_search`, `yt_poll_download`
- `get_full_state`
- `set_crossfade_duration`

## Missing Events (to be added)

- `aekQueueChanged`, `aekFavouriteChanged`
- `aekCrossfadeStarted`, `aekCrossfadeEnded`
- `aekDownloadProgress`, `aekDownloadComplete`
- `aekTrackChanged` (full metadata on new track)

## Doc Inconsistency

IPC doc line 187 says `/tmp/gtm-daemon.sock` but code uses `$XDG_RUNTIME_DIR/gtm/gtmd.sock`.

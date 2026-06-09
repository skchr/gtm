# YouTube Integration

All yt-dlp operations MUST be managed by the daemon, not the TUI.

## Commands (to add to daemon)

- `yt_search {query, page_size}` → spawn yt-dlp, return search_id, TUI polls with `yt_poll_search`
- `yt_poll_search {search_id}` → return parsed results so far
- `yt_stream_url {url}` → spawn yt-dlp -g, return direct stream URL
- `yt_download {url, title, channel}` → spawn yt-dlp download, return download_id, emit `aekDownloadProgress` / `aekDownloadComplete`
- `yt_playlist_detail {url}` → spawn yt-dlp --dump-json --flat-playlist, return track entries

## Daemon State

- `ytSearchTasks: seq[YtSearchTask]` — process handle + buffer per search
- `ytDownloadTasks: seq[DaemonDownloadTask]` — process handle + metadata per download
- `ytCookieSource: string` — detected browser cookie source
- `ytJsRuntime: string` — detected JS runtime

## Current Violation

All yt-dlp logic lives in `src/ytdlp.nim` which is imported by the TUI (`gtm.nim`). The daemon has zero YouTube awareness.

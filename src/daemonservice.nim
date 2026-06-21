## DaemonService — typed IPC proxy for TUI ↔ daemon communication
##
## All daemon IPC flows through this module. No code outside this file
## should import session.nim or cast to DaemonSession directly.
##
## DaemonService.session is the SAME object as Store.state.player (both
## point to the same DaemonSession ref), so polymorphic AudioBackend
## methods (play, stop, loadFile, seek, setVolume, etc.) work via
## store.state.player while daemon-specific IPC goes through store.service.

import json, session, audio

type
  DaemonService* = ref object of RootObj
    session*: DaemonSession

proc newDaemonService*(): DaemonService =
  DaemonService(session: newDaemonSession())

proc ensureConnected*(svc: DaemonService) =
  svc.session.ensureRunning()

proc isConnected*(svc: DaemonService): bool =
  svc.session != nil and svc.session.connected

proc isWorking*(svc: DaemonService): bool =
  svc.session != nil and svc.session.working

proc getSleepTimerRemaining*(svc: DaemonService): int =
  if svc.session == nil: 0 else: svc.session.sleepTimerRemaining

proc getReconnectCooldown*(svc: DaemonService): int =
  if svc.session == nil: 0 else: svc.session.reconnectCooldown

proc decReconnectCooldown*(svc: DaemonService) =
  if svc.session != nil and svc.session.reconnectCooldown > 0:
    svc.session.reconnectCooldown.dec

proc getIpcTimeout*(svc: DaemonService): float =
  if svc.session == nil: 3.0 else: svc.session.ipcTimeoutSec

proc setIpcTimeout*(svc: DaemonService, val: float) =
  if svc.session != nil: svc.session.ipcTimeoutSec = val

proc ping*(svc: DaemonService): bool =
  svc.session != nil and svc.session.connected

# ── Raw IPC (for operations without dedicated methods) ───────

proc sendOnly*(svc: DaemonService, cmd: JsonNode) =
  svc.session.send(cmd)

proc daemonSimpleCmd*(svc: DaemonService, cmd: string): JsonNode =
  svc.session.daemonSimpleCmd(cmd)

proc sendDaemonCmd*(svc: DaemonService, cmd: JsonNode): JsonNode =
  svc.session.request(cmd)

proc getFullState*(svc: DaemonService): JsonNode =
  svc.session.daemonSimpleCmd("get_full_state")

proc getVolume*(svc: DaemonService): int =
  svc.session.volume

# ── Queue ────────────────────────────────────────────────────

proc queueAdd*(svc: DaemonService, items: seq[tuple[path, title, channel: string]]): JsonNode =
  var arr = newJArray()
  for (path, title, channel) in items:
    arr.add(%*{"path": path, "title": title, "channel": channel})
  svc.session.request(%*{"cmd": "queue_add", "items": arr})

proc queueRemovePath*(svc: DaemonService, path: string): JsonNode =
  svc.session.request(%*{"cmd": "queue_remove_path", "path": path})

proc queueClear*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "queue_clear"})

proc queueValidate*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "queue_validate"})

proc queueList*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "queue_list"})

proc queueSetCursor*(svc: DaemonService, index: int): JsonNode =
  svc.session.request(%*{"cmd": "set_queue_cursor", "index": index})

# ── Playback control (daemon-specific, not on AudioBackend) ──

proc sendNext*(svc: DaemonService) =
  svc.session.send(%*{"cmd": "next"})

proc sendPrev*(svc: DaemonService) =
  svc.session.send(%*{"cmd": "prev"})

proc loadAndPlay*(svc: DaemonService, path, title, channel: string) =
  svc.session.send(%*{"cmd": "load_file", "path": path, "title": title, "channel": channel})
  svc.session.send(%*{"cmd": "play"})

# ── Shuffle / Repeat / Sleep ─────────────────────────────────

proc setShuffle*(svc: DaemonService, enabled: bool): JsonNode =
  svc.session.request(%*{"cmd": "set_shuffle", "enabled": enabled})

proc setRepeat*(svc: DaemonService, mode: int): JsonNode =
  svc.session.request(%*{"cmd": "set_repeat", "mode": mode})

proc setSleepTimer*(svc: DaemonService, minutes: int): JsonNode =
  svc.session.request(%*{"cmd": "set_sleep_timer", "minutes": minutes})

# ── Crossfade ────────────────────────────────────────────────

proc setCrossfadeDuration*(svc: DaemonService, duration: int) =
  svc.session.send(%*{"cmd": "set_crossfade_duration", "duration": duration})

proc setCrossfadeCurve*(svc: DaemonService, curveType: int) =
  svc.session.send(%*{"cmd": "set_crossfade_curve", "curve_type": curveType})

proc startCrossfade*(svc: DaemonService, durationSeconds: float) =
  svc.session.send(%*{"cmd": "start_crossfade", "duration": durationSeconds})

# ── EQ ───────────────────────────────────────────────────────

proc setEqBand*(svc: DaemonService, band: int, gainDb: float) =
  svc.session.send(%*{"cmd": "set_eq_band", "band": band, "value": gainDb})

proc setEqPreset*(svc: DaemonService, name: string) =
  svc.session.send(%*{"cmd": "set_eq_preset", "preset": name})

proc getEqPresets*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "list_eq_presets"})

# ── Library ──────────────────────────────────────────────────

proc getLibrary*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "get_library"})

proc scanDir*(svc: DaemonService, path: string): JsonNode =
  svc.session.request(%*{"cmd": "scan_dir", "path": path})

proc deleteTrack*(svc: DaemonService, trackId: int64, permanent: bool = false): JsonNode =
  svc.session.request(%*{"cmd": "delete_track", "track_id": trackId, "permanent": permanent})

# ── Playlists ────────────────────────────────────────────────

proc createPlaylist*(svc: DaemonService, name: string): JsonNode =
  svc.session.request(%*{"cmd": "create_playlist", "name": name})

proc deletePlaylist*(svc: DaemonService, playlistId: int64): JsonNode =
  svc.session.request(%*{"cmd": "delete_playlist", "playlist_id": playlistId})

proc renamePlaylist*(svc: DaemonService, playlistId: int64, name: string): JsonNode =
  svc.session.request(%*{"cmd": "rename_playlist", "playlist_id": playlistId, "name": name})

proc addToPlaylist*(svc: DaemonService, playlistId, trackId: int64, position: int = 0): JsonNode =
  svc.session.request(%*{"cmd": "add_to_playlist", "playlist_id": playlistId, "track_id": trackId, "position": position})

proc removeFromPlaylist*(svc: DaemonService, playlistId, trackId: int64): JsonNode =
  svc.session.request(%*{"cmd": "remove_from_playlist", "playlist_id": playlistId, "track_id": trackId})

proc listPlaylists*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "list_playlists"})

proc getPlaylistTracks*(svc: DaemonService, playlistId: int64): JsonNode =
  svc.session.request(%*{"cmd": "get_playlist_tracks", "playlist_id": playlistId})

# ── Favourites ───────────────────────────────────────────────

proc addFavourite*(svc: DaemonService, trackId: int64): JsonNode =
  svc.session.request(%*{"cmd": "add_favourite", "track_id": trackId})

proc removeFavourite*(svc: DaemonService, trackId: int64): JsonNode =
  svc.session.request(%*{"cmd": "remove_favourite", "track_id": trackId})

proc getFavourites*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "get_favourites"})

# ── YouTube ──────────────────────────────────────────────────

proc ytSearch*(svc: DaemonService, query: string, pageSize: int = 10) =
  svc.session.send(%*{"cmd": "yt_search", "query": query, "page_size": pageSize})

proc ytSearchCancel*(svc: DaemonService) =
  svc.session.send(%*{"cmd": "yt_search_cancel"})

proc ytResolveStream*(svc: DaemonService, url: string): JsonNode =
  svc.session.request(%*{"cmd": "yt_resolve_stream", "url": url})

proc ytDownload*(svc: DaemonService, url, title, channel: string): JsonNode =
  svc.session.request(%*{"cmd": "yt_download", "url": url, "title": title, "channel": channel})

proc ytCancelDownload*(svc: DaemonService, url: string): JsonNode =
  svc.session.request(%*{"cmd": "yt_cancel_download", "url": url})

proc ytFetchPlaylist*(svc: DaemonService, url: string): JsonNode =
  svc.session.request(%*{"cmd": "yt_fetch_playlist", "url": url})

proc ytSetConfig*(svc: DaemonService, cookieSource, jsRuntime, downloadDir: string, maxConcurrent: int): JsonNode =
  svc.session.request(%*{"cmd": "yt_set_config", "cookie_source": cookieSource, "js_runtime": jsRuntime, "download_dir": downloadDir, "max_concurrent": maxConcurrent})

proc ytClearSearchHistory*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "yt_clear_search_history"})

# ── Spotify ──────────────────────────────────────────────────

proc spSetConfig*(svc: DaemonService, cookieSource, cookiePath, audioFormat: string): JsonNode =
  svc.session.request(%*{"cmd": "sp_set_config", "cookie_source": cookieSource, "cookie_file_path": cookiePath, "audio_format": audioFormat})

proc spListDownloads*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "sp_list_downloads"})

proc spOAuthUrl*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "sp_oauth_url"})

proc spOAuthCallback*(svc: DaemonService, code: string): JsonNode =
  svc.session.request(%*{"cmd": "sp_oauth_callback", "code": code})

proc spFeed*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "sp_feed"})

proc spDisconnect*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "sp_disconnect"})

# ── Trash ────────────────────────────────────────────────────

proc listTrash*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "list_trash"})

proc restoreTrack*(svc: DaemonService, trashId: int): JsonNode =
  svc.session.request(%*{"cmd": "restore_track", "trash_id": trashId})

proc permanentDeleteTrash*(svc: DaemonService, trashId: int): JsonNode =
  svc.session.request(%*{"cmd": "permanent_delete_trash", "trash_id": trashId})

proc purgeTrash*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "purge_trash"})

# ── Cover Art / Lyrics ──────────────────────────────────────

proc requestCoverArt*(svc: DaemonService, path: string) =
  svc.session.send(%*{"cmd": "request_cover_art", "path": path})

proc requestLyrics*(svc: DaemonService, path, title, artist: string, duration: float) =
  svc.session.send(%*{"cmd": "request_lyrics",
    "path": path, "title": title,
    "artist": artist, "duration": duration})

# ── Lifecycle ────────────────────────────────────────────────

proc sendQuit*(svc: DaemonService) =
  svc.session.send(%*{"cmd": "quit"})

proc resumePlayback*(svc: DaemonService): JsonNode =
  svc.session.request(%*{"cmd": "resume"})

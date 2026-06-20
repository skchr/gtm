## DaemonService — typed IPC proxy for TUI ↔ daemon communication
##
## All daemon IPC flows through this module. No code outside this file
## should import client.nim or cast to DaemonClient directly.
##
## DaemonService.client is the SAME object as Store.state.player (both
## point to the same DaemonClient ref), so polymorphic AudioBackend
## methods (play, stop, loadFile, seek, setVolume, etc.) work via
## store.state.player while daemon-specific IPC goes through store.service.

import json, client, audio

type
  DaemonService* = ref object of RootObj
    client*: DaemonClient

proc newDaemonService*(): DaemonService =
  DaemonService(client: newDaemonClient())

# ── Connectivity ──────────────────────────────────────────────

proc ensureConnected*(svc: DaemonService) =
  svc.client.ensureDaemon()

proc isConnected*(svc: DaemonService): bool =
  svc.client != nil and svc.client.connected

proc isWorking*(svc: DaemonService): bool =
  svc.client != nil and svc.client.working

proc getSleepTimerRemaining*(svc: DaemonService): int =
  if svc.client == nil: 0 else: svc.client.sleepTimerRemaining

proc getReconnectCooldown*(svc: DaemonService): int =
  if svc.client == nil: 0 else: svc.client.reconnectCooldown

proc decReconnectCooldown*(svc: DaemonService) =
  if svc.client != nil and svc.client.reconnectCooldown > 0:
    svc.client.reconnectCooldown.dec

proc getIpcTimeout*(svc: DaemonService): float =
  if svc.client == nil: 3.0 else: svc.client.ipcTimeoutSec

proc setIpcTimeout*(svc: DaemonService, val: float) =
  if svc.client != nil: svc.client.ipcTimeoutSec = val

proc ping*(svc: DaemonService): bool =
  svc.client.ping()

# ── Raw IPC (for operations without dedicated methods) ───────

proc sendOnly*(svc: DaemonService, cmd: JsonNode) =
  svc.client.sendOnly(cmd)

proc daemonSimpleCmd*(svc: DaemonService, cmd: string): JsonNode =
  svc.client.daemonSimpleCmd(cmd)

proc sendDaemonCmd*(svc: DaemonService, cmd: JsonNode): JsonNode =
  svc.client.sendDaemonCmd(cmd)

proc sendAsync*(svc: DaemonService, cmd: JsonNode, cb: proc(resp: JsonNode) {.closure.}) =
  svc.client.sendAsync(cmd, cb)

proc getFullState*(svc: DaemonService): JsonNode =
  svc.client.getFullState()

proc getVolume*(svc: DaemonService): int =
  svc.client.getVolume()

# ── Queue ────────────────────────────────────────────────────

proc queueAdd*(svc: DaemonService, items: seq[tuple[path, title, channel: string]]): JsonNode =
  svc.client.queueAdd(items)

proc queueRemovePath*(svc: DaemonService, path: string): JsonNode =
  svc.client.queueRemovePath(path)

proc queueClear*(svc: DaemonService): JsonNode =
  svc.client.queueClear()

proc queueValidate*(svc: DaemonService): JsonNode =
  svc.client.queueValidate()

proc queueList*(svc: DaemonService): JsonNode =
  svc.client.queueList()

proc queueSetCursor*(svc: DaemonService, index: int): JsonNode =
  svc.client.queueSetCursor(index)

# ── Playback control (daemon-specific, not on AudioBackend) ──

proc sendNext*(svc: DaemonService) =
  svc.client.sendOnly(%*{"cmd": "next"})

proc sendPrev*(svc: DaemonService) =
  svc.client.sendOnly(%*{"cmd": "prev"})

proc loadAndPlay*(svc: DaemonService, path, title, channel: string) =
  svc.client.sendOnly(%*{"cmd": "load_file", "path": path, "title": title, "channel": channel})
  svc.client.sendOnly(%*{"cmd": "play"})

# ── Shuffle / Repeat / Sleep ─────────────────────────────────

proc setShuffle*(svc: DaemonService, enabled: bool): JsonNode =
  svc.client.setShuffle(enabled)

proc setRepeat*(svc: DaemonService, mode: int): JsonNode =
  svc.client.setRepeat(mode)

proc setSleepTimer*(svc: DaemonService, minutes: int): JsonNode =
  svc.client.setSleepTimer(minutes)

# ── Crossfade ────────────────────────────────────────────────

proc setCrossfadeDuration*(svc: DaemonService, duration: int) =
  svc.client.setCrossfadeDuration(duration)

proc setCrossfadeCurve*(svc: DaemonService, curveType: int) =
  svc.client.setCrossfadeCurve(curveType)

proc startCrossfade*(svc: DaemonService, durationSeconds: float) =
  svc.client.startCrossfade(durationSeconds)

# ── EQ ───────────────────────────────────────────────────────

proc setEqBand*(svc: DaemonService, band: int, gainDb: float) =
  svc.client.setEqBand(band, gainDb)

proc setEqPreset*(svc: DaemonService, name: string) =
  svc.client.setEqPreset(name)

proc getEqPresets*(svc: DaemonService): JsonNode =
  svc.client.getEqPresets()

# ── Library ──────────────────────────────────────────────────

proc getLibrary*(svc: DaemonService): JsonNode =
  svc.client.getLibrary()

proc scanDir*(svc: DaemonService, path: string): JsonNode =
  svc.client.scanDir(path)

proc deleteTrack*(svc: DaemonService, trackId: int64, permanent: bool = false): JsonNode =
  svc.client.deleteTrack(trackId, permanent)

# ── Playlists ────────────────────────────────────────────────

proc createPlaylist*(svc: DaemonService, name: string): JsonNode =
  svc.client.createPlaylist(name)

proc deletePlaylist*(svc: DaemonService, playlistId: int64): JsonNode =
  svc.client.deletePlaylist(playlistId)

proc renamePlaylist*(svc: DaemonService, playlistId: int64, name: string): JsonNode =
  svc.client.renamePlaylist(playlistId, name)

proc addToPlaylist*(svc: DaemonService, playlistId, trackId: int64, position: int = 0): JsonNode =
  svc.client.addToPlaylist(playlistId, trackId, position)

proc removeFromPlaylist*(svc: DaemonService, playlistId, trackId: int64): JsonNode =
  svc.client.removeFromPlaylist(playlistId, trackId)

proc listPlaylists*(svc: DaemonService): JsonNode =
  svc.client.listPlaylists()

proc getPlaylistTracks*(svc: DaemonService, playlistId: int64): JsonNode =
  svc.client.getPlaylistTracks(playlistId)

# ── Favourites ───────────────────────────────────────────────

proc addFavourite*(svc: DaemonService, trackId: int64): JsonNode =
  svc.client.addFavourite(trackId)

proc removeFavourite*(svc: DaemonService, trackId: int64): JsonNode =
  svc.client.removeFavourite(trackId)

proc getFavourites*(svc: DaemonService): JsonNode =
  svc.client.getFavouritesFromDaemon()

# ── YouTube ──────────────────────────────────────────────────

proc ytSearch*(svc: DaemonService, query: string, pageSize: int = 10) =
  svc.client.ytSearch(query, pageSize)

proc ytSearchCancel*(svc: DaemonService) =
  svc.client.ytSearchCancel()

proc ytResolveStream*(svc: DaemonService, url: string): JsonNode =
  svc.client.ytResolveStream(url)

proc ytDownload*(svc: DaemonService, url, title, channel: string): JsonNode =
  svc.client.ytDownload(url, title, channel)

proc ytCancelDownload*(svc: DaemonService, url: string): JsonNode =
  svc.client.ytCancelDownload(url)

proc ytFetchPlaylist*(svc: DaemonService, url: string): JsonNode =
  svc.client.ytFetchPlaylist(url)

proc ytSetConfig*(svc: DaemonService, cookieSource, jsRuntime, downloadDir: string, maxConcurrent: int): JsonNode =
  svc.client.ytSetConfig(cookieSource, jsRuntime, downloadDir, maxConcurrent)

proc ytClearSearchHistory*(svc: DaemonService): JsonNode =
  svc.client.ytClearSearchHistory()

# ── Spotify ──────────────────────────────────────────────────

proc spSetConfig*(svc: DaemonService, cookieSource, cookiePath, audioFormat: string): JsonNode =
  svc.client.spSetConfig(cookieSource, cookiePath, audioFormat)

proc spListDownloads*(svc: DaemonService): JsonNode =
  svc.client.spListDownloads()

proc spOAuthUrl*(svc: DaemonService): JsonNode =
  svc.client.spOAuthUrl()

proc spOAuthCallback*(svc: DaemonService, code: string): JsonNode =
  svc.client.spOAuthCallback(code)

proc spFeed*(svc: DaemonService): JsonNode =
  svc.client.spFeed()

proc spDisconnect*(svc: DaemonService): JsonNode =
  svc.client.spDisconnect()

# ── Trash ────────────────────────────────────────────────────

proc listTrash*(svc: DaemonService): JsonNode =
  svc.client.listTrash()

proc restoreTrack*(svc: DaemonService, trashId: int): JsonNode =
  svc.client.restoreTrack(trashId)

proc permanentDeleteTrash*(svc: DaemonService, trashId: int): JsonNode =
  svc.client.permanentDeleteTrash(trashId)

proc purgeTrash*(svc: DaemonService): JsonNode =
  svc.client.purgeTrash()

# ── Cover Art / Lyrics ──────────────────────────────────────

proc requestCoverArt*(svc: DaemonService, path: string) =
  svc.client.sendOnly(%*{"cmd": "request_cover_art", "path": path})

proc requestLyrics*(svc: DaemonService, path, title, artist: string, duration: float) =
  svc.client.sendOnly(%*{"cmd": "request_lyrics",
    "path": path, "title": title,
    "artist": artist, "duration": duration})

# ── Lifecycle ────────────────────────────────────────────────

proc sendQuit*(svc: DaemonService) =
  svc.client.sendQuitDaemon()

proc resumePlayback*(svc: DaemonService): JsonNode =
  svc.client.resumePlayback()

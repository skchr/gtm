## gtmd — background audio daemon
##
## Owns audio playback, the music library (SQLite), and exposes a
## JSON-over-Unix-socket IPC interface for the TUI and CLI clients.
##
## ┌──────────────────────────────────────────────────┐
## │                gtmd main loop                    │
## │                                                  │
## │  select() on:                                    │
## │    ┌──────────────┐                              │
## │    │  Unix socket  │  client requests             │
## │    │  (listen)     │  (new connections)           │
## │    └──────┬───────┘                              │
## │           ▼                                       │
## │    ┌──────────────┐                              │
## │    │  client conns │  readLine → parseJson        │
## │    │  (per-client) │  → parseCmd() → execute()    │
## │    └──────┬───────┘                              │
## │           ▼                                       │
## │    ┌──────────────────────┐                      │
## │    │  AudioBackend        │  pollEvents() every   │
## │    │  (FFmpeg / Mixer)    │  iteration → queue    │
## │    └──────────────────────┘  events for all       │
## │                              connected clients    │
## │    ┌──────────────────────┐                      │
## │    │  yt-dlp subprocs     │  async downloads,     │
## │    │  (nonblocking)       │  searches, resolves   │
## │    └──────────────────────┘                      │
## │                                                  │
## │  Every poll: write queued events → each client   │
## └──────────────────────────────────────────────────┘

import os, json, strutils, net, posix, random, osproc, times, base64
from nativesockets import setBlocking, selectRead, SocketHandle
when not defined(macosx):
  proc prctl(option: cint, arg2: cstring): cint {.importc, header: "<sys/prctl.h>".}
else:
  proc pthread_setname_np(name: cstring): cint {.importc, header: "<pthread.h>".}
import audio, state, library, ytdlp, lyrics

proc parseFilenameForMetadata(path: string): tuple[title, artist: string] =
  let (_, stem, _) = path.splitFile()
  result = (stem, "")
  let dashPos = stem.find(" - ")
  if dashPos > 0:
    let left = stem[0..<dashPos].strip()
    var isTrackNum = left.len in {2, 3}
    if isTrackNum:
      for c in left:
        if c notin {'0'..'9'}: isTrackNum = false; break
    if not isTrackNum:
      result.artist = left
      result.title = stem[dashPos+3..^1].strip()

type
  DaemonCmdKind* = enum
    dckPlay, dckPause, dckStop, dckSeek, dckNext, dckPrev,
    dckSetVolume, dckGetVolume, dckLoadFile, dckTogglePause,
    dckQuit, dckStatus, dckScan, dckNowPlaying,
    dckCreatePlaylist, dckDeletePlaylist, dckRenamePlaylist,
    dckAddToPlaylist, dckRemoveFromPlaylist,
    dckListPlaylists, dckGetPlaylistTracks,
    dckSetShuffle, dckSetRepeat, dckSetSleepTimer, dckGetState, dckResume,
    dckPrepareNext, dckCrossfade,
    dckSetEqBand, dckSetEqPreset,
    dckGetLibrary, dckAddTrack, dckUpdateTrackPath,
    dckQueueAdd, dckQueueRemove, dckQueueRemovePath, dckQueueClear, dckQueueValidate, dckQueueList, dckQueueSetCursor,
    dckAddFavourite, dckRemoveFavourite, dckGetFavourites, dckGetFullState,
    dckYtSearch, dckYtSearchPoll, dckYtSearchCancel,
    dckYtResolveStream, dckYtResolveStreamPoll,
    dckYtDownload, dckYtDownloadPoll, dckYtCancelDownload,
    dckYtListDownloads, dckYtFetchPlaylist, dckYtFetchPlaylistPoll,
    dckYtSetConfig, dckYtGetSearchHistory, dckYtClearSearchHistory,
    dckSpSetConfig, dckSpListDownloads,
    dckListEqPresets,
    dckSetCrossfadeDuration,
    dckSetCrossfadeCurve,
    dckGetCoverArt,
    dckGetLyrics,
    dckSearchLyrics,
    dckPing,
    dckDeleteTrack, dckRestoreTrack, dckPermanentDelete, dckListTrash, dckPurgeTrash

  DaemonCmd* = object
    kind*: DaemonCmdKind
    strArg*: string
    floatArg*: float
    intArg*: int
    intArg2*: int
    strArg2*: string
    strArg3*: string
    strArg4*: string

  ClientState* = object
    sock*: Socket
    buf*: string

  Daemon* = ref object
    player: AudioBackend
    lib: LibraryDb
    running: bool
    server: Socket
    clients*: seq[ClientState]
    currentTrackPath: string
    currentTrackTitle: string
    currentTrackChannel: string
    trackHistory: seq[string]
    idleFrames: int
    idleTimeout: int
    shuffleEnabled*: bool
    repeatMode*: int
    sleepTimerRemaining*: int
    sleepTimerFrames*: int
    persistFrames: int
    trashPurgeFrames: int
    playbackQueue*: seq[string]
    shuffleOrder*: seq[int]
    shuffleIndex*: int
    crossfadeDuration*: int
    crossfadeCurve*: int
    crossfadePrepared*: bool
    crossfadeStarted*: bool
    crossfadeNextPath*: string
    crossfadeConsumed: bool
    autoAdvancing*: bool
    lastConsumedFromQueue: seq[string]
    upNextSent: bool
    # Background scan state
    scanningDir: string
    scanningFiles: seq[string]
    scanningIdx: int
    # yt-dlp state
    ytCookieSource: string
    ytCookieFilePath: string
    ytJsRuntime: string
    ytDownloadDir: string
    ytMaxConcurrentDownloads: int
    # Spotify state
    spCookieSource: string
    spCookieFilePath: string
    spAudioFormat: string
    ytSearchProcess: Process
    ytSearchBuf: string
    ytSearchActive: bool
    ytSearchQuery: string
    ytSearchResults: seq[YtSearchResult]
    ytStreamProcess: Process
    ytStreamBuf: string
    ytStreamActive: bool
    ytStreamResultUrl: string
    ytStreamPendingTitle: string
    ytStreamPendingChannel: string
    ytStreamPendingDuration: string
    ytStreamResolvedUrl: string
    ytStreamResolvedFor: string
    ytStreamResolveProcess: Process
    ytStreamResolveBuf: string
    ytStreamResolveUrl: string
    ytStreamResolving: bool
    ytDownloadTasks: seq[DownloadTask]
    ytLastCompletedPath: string
    ytLastCompletedUrl: string
    ytPlaylistProcess: Process
    ytPlaylistBuf: string
    ytPlaylistActive: bool
    ytPlaylistResult: YtPlaylistDetail
    ytPlaylistUrl: string
    lastTrackDuration: float
    stateVersion*: int

proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}
const LOCK_EX = 2
const LOCK_NB = 4

var gPidLockFd: cint = -1

proc acquirePidLock(): bool =
  let dir = stateDir()
  if not dirExists(dir): createDir(dir)
  let fd = open(pidPath().cstring, O_RDWR or O_CREAT, 0o644)
  if fd < 0: return false
  if flock(fd, LOCK_EX or LOCK_NB) < 0:
    discard close(fd)
    return false
  gPidLockFd = fd
  result = true

proc writePidFile() =
  let dir = stateDir()
  if not dirExists(dir): createDir(dir)
  writeFile(pidPath(), $getpid())

proc removePidFile() =
  try: removeFile(pidPath()) except: stderr.writeLine("[gtm] removePidFile: " & getCurrentExceptionMsg())

proc setupSignalHandlers() =
  proc handler(sig: cint) {.noconv.} =
    removePidFile()
    quit(0)
  signal(SIGINT, handler)
  signal(SIGTERM, handler)

proc cookiesForUrl(d: Daemon, url: string): tuple[source, filePath: string] =
  if "spotify.com" in url:
    (d.spCookieSource, d.spCookieFilePath)
  else:
    (d.ytCookieSource, d.ytCookieFilePath)

proc parseDaemonCommand(line: string): DaemonCmd =
  try:
    let j = parseJson(line)
    let cmd = j["cmd"].getStr()
    case cmd
    of "play": result.kind = dckPlay
    of "pause": result.kind = dckPause
    of "stop": result.kind = dckStop
    of "toggle_pause": result.kind = dckTogglePause
    of "seek":
      result.kind = dckSeek; result.floatArg = j{"seconds"}.getFloat(5.0)
    of "next": result.kind = dckNext
    of "prev": result.kind = dckPrev
    of "set_volume":
      result.kind = dckSetVolume; result.intArg = j{"volume"}.getInt(80)
    of "get_volume": result.kind = dckGetVolume
    of "load_file":
      result.kind = dckLoadFile; result.strArg = j{"path"}.getStr("")
      result.strArg2 = j{"title"}.getStr("")
      result.strArg3 = j{"channel"}.getStr("")
    of "quit": result.kind = dckQuit
    of "status": result.kind = dckStatus
    of "now_playing": result.kind = dckNowPlaying
    of "create_playlist":
      result.kind = dckCreatePlaylist; result.strArg = j{"name"}.getStr("")
    of "delete_playlist":
      result.kind = dckDeletePlaylist; result.intArg = j{"playlist_id"}.getInt(0)
    of "rename_playlist":
      result.kind = dckRenamePlaylist; result.intArg = j{"playlist_id"}.getInt(0); result.strArg = j{"name"}.getStr("")
    of "add_to_playlist":
      result.kind = dckAddToPlaylist; result.strArg = $j["data"]
    of "remove_from_playlist":
      result.kind = dckRemoveFromPlaylist; result.strArg = $j["data"]
    of "list_playlists": result.kind = dckListPlaylists
    of "get_playlist_tracks":
      result.kind = dckGetPlaylistTracks; result.intArg = j{"playlist_id"}.getInt(0)
    of "scan":
      result.kind = dckScan; result.strArg = j{"path"}.getStr("")
    of "set_shuffle":
      result.kind = dckSetShuffle; result.intArg = j{"enabled"}.getInt(0)
    of "set_repeat":
      result.kind = dckSetRepeat; result.intArg = j{"mode"}.getInt(0)
    of "set_sleep_timer":
      result.kind = dckSetSleepTimer; result.intArg = j{"minutes"}.getInt(0)
    of "get_state": result.kind = dckGetState
    of "resume": result.kind = dckResume
    of "prepare_next":
      result.kind = dckPrepareNext; result.strArg = j{"path"}.getStr("")
    of "crossfade":
      result.kind = dckCrossfade; result.floatArg = j{"duration"}.getFloat(5.0)
    of "set_eq_band":
      result.kind = dckSetEqBand; result.intArg = j{"band"}.getInt(0); result.floatArg = j{"gain_db"}.getFloat(0.0)
    of "set_eq_preset":
      result.kind = dckSetEqPreset; result.strArg = j{"name"}.getStr("")
    of "set_crossfade_duration":
      result.kind = dckSetCrossfadeDuration; result.intArg = j{"duration"}.getInt(0)
    of "set_crossfade_curve":
      result.kind = dckSetCrossfadeCurve; result.intArg = j{"curve_type"}.getInt(1)
    of "get_library": result.kind = dckGetLibrary
    of "add_track":
      result.kind = dckAddTrack; result.strArg = $j["data"]
    of "update_track_path":
      result.kind = dckUpdateTrackPath; result.strArg = $j["data"]
    of "queue_add":
      result.kind = dckQueueAdd; result.strArg = $j["data"]
    of "queue_remove":
      result.kind = dckQueueRemove; result.intArg = j{"index"}.getInt(0)
    of "queue_remove_path":
      result.kind = dckQueueRemovePath; result.strArg = j{"path"}.getStr("")
    of "queue_clear":
      result.kind = dckQueueClear
    of "queue_validate":
      result.kind = dckQueueValidate
    of "queue_list":
      result.kind = dckQueueList
    of "queue_set_cursor":
      result.kind = dckQueueSetCursor; result.intArg = j{"index"}.getInt(0)
    of "add_favourite":
      result.kind = dckAddFavourite; result.intArg = j{"track_id"}.getInt(0)
    of "remove_favourite":
      result.kind = dckRemoveFavourite; result.intArg = j{"track_id"}.getInt(0)
    of "get_favourites":
      result.kind = dckGetFavourites
    of "get_full_state":
      result.kind = dckGetFullState
    of "yt_search":
      result.kind = dckYtSearch; result.strArg = j{"query"}.getStr(""); result.intArg = j{"page_size"}.getInt(10)
    of "yt_search_poll":
      result.kind = dckYtSearchPoll
    of "yt_search_cancel":
      result.kind = dckYtSearchCancel
    of "yt_resolve_stream":
      result.kind = dckYtResolveStream; result.strArg = j{"url"}.getStr("")
      result.strArg2 = j{"title"}.getStr(""); result.strArg3 = j{"channel"}.getStr("")
    of "yt_resolve_stream_poll":
      result.kind = dckYtResolveStreamPoll
    of "yt_download":
      result.kind = dckYtDownload; result.strArg = j{"url"}.getStr("")
      result.strArg2 = j{"title"}.getStr(""); result.strArg3 = j{"channel"}.getStr("")
    of "yt_download_poll":
      result.kind = dckYtDownloadPoll
    of "yt_cancel_download":
      result.kind = dckYtCancelDownload; result.strArg = j{"url"}.getStr("")
    of "yt_list_downloads":
      result.kind = dckYtListDownloads
    of "yt_fetch_playlist":
      result.kind = dckYtFetchPlaylist; result.strArg = j{"url"}.getStr("")
    of "yt_fetch_playlist_poll":
      result.kind = dckYtFetchPlaylistPoll
    of "yt_set_config":
      result.kind = dckYtSetConfig; result.strArg = j{"cookie_source"}.getStr("")
      result.strArg2 = j{"js_runtime"}.getStr(""); result.strArg3 = j{"download_dir"}.getStr("")
      result.intArg = j{"max_concurrent"}.getInt(4)
    of "yt_get_search_history":
      result.kind = dckYtGetSearchHistory
    of "yt_clear_search_history":
      result.kind = dckYtClearSearchHistory
    of "sp_set_config":
      result.kind = dckSpSetConfig; result.strArg = j{"cookie_source"}.getStr("")
      result.strArg2 = j{"cookie_path"}.getStr("")
      result.strArg3 = j{"audio_format"}.getStr("")
    of "sp_list_downloads":
      result.kind = dckSpListDownloads
    of "list_eq_presets":
      result.kind = dckListEqPresets
    of "ping":
      result.kind = dckPing
    of "get_cover_art":
      result.kind = dckGetCoverArt; result.strArg = j{"path"}.getStr("")
    of "get_lyrics":
      result.kind = dckGetLyrics; result.strArg = j{"path"}.getStr("")
      result.strArg2 = j{"title"}.getStr(""); result.strArg3 = j{"artist"}.getStr("")
      result.strArg4 = j{"album"}.getStr(""); result.floatArg = j{"duration"}.getFloat(0.0)
    of "search_lyrics":
      result.kind = dckSearchLyrics; result.strArg = j{"title"}.getStr(""); result.strArg2 = j{"artist"}.getStr("")
    of "delete_track":
      result.kind = dckDeleteTrack; result.intArg = j{"track_id"}.getInt(0); result.intArg2 = j{"permanent"}.getInt(0)
    of "restore_track":
      result.kind = dckRestoreTrack; result.intArg = j{"trash_id"}.getInt(0)
    of "permanent_delete_trash":
      result.kind = dckPermanentDelete; result.intArg = j{"trash_id"}.getInt(0)
    of "list_trash":
      result.kind = dckListTrash
    of "purge_trash":
      result.kind = dckPurgeTrash
    else: result.kind = dckStatus
  except:
    result.kind = dckStatus

proc serializeEvents(events: seq[AudioEvent]; d: Daemon = nil): JsonNode =
  result = newJArray()
  for ev in events:
    var obj = %*{"kind": %ev.kind.int}
    case ev.kind
    of evPositionChanged: obj["time_pos"] = %ev.floatVal
    of evDurationChanged: obj["duration"] = %ev.floatVal
    of evVolumeChanged: obj["volume"] = %ev.intVal
    of evPlaybackStarted:
      obj["state"] = %"playing"
      if d != nil:
        obj["track_path"] = %d.currentTrackPath
        obj["track_title"] = %d.currentTrackTitle
        obj["track_channel"] = %d.currentTrackChannel
        obj["auto_advanced"] = %d.autoAdvancing
        obj["time_pos"] = %d.player.timePos
        obj["duration"] = %d.player.duration
    of evPlaybackPaused: obj["state"] = %"paused"
    of evPlaybackStopped: obj["state"] = %"stopped"
    of evTrackEnded: obj["reason"] = %"eof"
    of evMetadataChanged:
      if ev.strVal.len > 0: obj["event"] = %ev.strVal
    else: discard
    if d != nil:
      obj["version"] = %d.stateVersion
    result.add(obj)

proc broadcastAll(d: Daemon, data: string) =
  var alive: seq[ClientState]
  for c in d.clients:
    if trySend(c.sock, data):
      alive.add(c)
    else:
      try: c.sock.close() except: discard
  d.clients = alive

proc sendQueueEvent(d: Daemon) =
  if d.clients.len == 0: return
  var qArr = newJArray()
  for p in d.playbackQueue: qArr.add(%p)
  var soArr = newJArray()
  for i in d.shuffleOrder: soArr.add(%i)
  let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "queue_changed",
    "queue": qArr, "shuffleOrder": soArr, "shuffleIndex": %d.shuffleIndex}]}
  d.broadcastAll($ev & "\n")

proc pushFullState(d: Daemon) =
  if d.clients.len == 0: return
  d.stateVersion.inc
  var ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "full_state_sync",
    "state": $(d.player.state),
    "track_path": d.currentTrackPath,
    "track_title": d.currentTrackTitle,
    "track_channel": d.currentTrackChannel,
    "time_pos": %d.player.timePos,
    "duration": %d.player.duration,
    "volume": %d.player.volume,
    "shuffle": %d.shuffleEnabled,
    "repeat": %d.repeatMode,
    "sleep_timer": %d.sleepTimerRemaining,
    "version": %d.stateVersion}]}
  d.broadcastAll($ev & "\n")

proc savePlaybackState(d: Daemon) =
  if d.lib != nil and d.player != nil:
    d.lib.setPlaybackState("volume", $d.player.volume)
    d.lib.setPlaybackState("time_pos", $d.player.timePos)
    d.lib.setPlaybackState("track_path", d.currentTrackPath)
    d.lib.setPlaybackState("track_title", d.currentTrackTitle)
    d.lib.setPlaybackState("track_channel", d.currentTrackChannel)
    d.lib.setPlaybackState("state", $(d.player.state))
    d.lib.setPlaybackState("shuffle", $(d.shuffleEnabled))
    d.lib.setPlaybackState("repeat", $(d.repeatMode))
    d.lib.setPlaybackState("sleep_timer", $(d.sleepTimerRemaining))
    d.lib.setPlaybackState("crossfade_duration", $(d.crossfadeDuration))
    d.lib.setPlaybackState("crossfade_curve", $(d.crossfadeCurve))
    d.lib.setPlaybackState("yt_cookie_source", d.ytCookieSource)
    d.lib.setPlaybackState("yt_cookie_file_path", d.ytCookieFilePath)
    d.lib.setPlaybackState("yt_js_runtime", d.ytJsRuntime)
    d.lib.setPlaybackState("yt_download_dir", d.ytDownloadDir)
    d.lib.setPlaybackState("yt_max_concurrent", $(d.ytMaxConcurrentDownloads))
    d.lib.setPlaybackState("sp_cookie_source", d.spCookieSource)
    d.lib.setPlaybackState("sp_cookie_file_path", d.spCookieFilePath)
    d.lib.setPlaybackState("sp_audio_format", d.spAudioFormat)
    var qArr = newJArray()
    for p in d.playbackQueue:
      qArr.add(%p)
    d.lib.setPlaybackState("queue_json", $qArr)
    d.lib.setPlaybackState("shuffle_index", $(d.shuffleIndex))


proc shuffleOrder(count: int): seq[int] =
  result = newSeq[int](count)
  for i in 0..<count:
    result[i] = i
  for i in countup(0, count - 2):
    let j = rand(i..<count)
    swap(result[i], result[j])

proc regenShuffleIfNeeded(d: Daemon) =
  if d.shuffleEnabled:
    d.shuffleOrder = shuffleOrder(d.playbackQueue.len)
    d.shuffleIndex = 0

proc nextTrackFromQueue(d: Daemon): string =
  # Repeat-one: return current track without consuming queue
  if d.repeatMode == 2 and d.currentTrackPath.len > 0:
    result = d.currentTrackPath
    if result.len > 0:
      d.lastConsumedFromQueue.add(result)
      if d.lastConsumedFromQueue.len > 10:
        d.lastConsumedFromQueue.delete(0)
    return
  if d.shuffleEnabled and d.shuffleOrder.len > 0:
    if d.shuffleIndex < d.shuffleOrder.len:
      let idx = d.shuffleOrder[d.shuffleIndex]
      if idx >= 0 and idx < d.playbackQueue.len:
        result = d.playbackQueue[idx]
      d.shuffleIndex.inc
    if d.shuffleIndex >= d.shuffleOrder.len:
      if d.repeatMode == 1:
        d.shuffleOrder = shuffleOrder(d.playbackQueue.len)
        d.shuffleIndex = 0
        if d.shuffleOrder.len > 0:
          result = d.playbackQueue[d.shuffleOrder[0]]
          d.shuffleIndex = 1
      else:
        result = ""
  elif d.playbackQueue.len > 0:
    result = d.playbackQueue[0]
    d.playbackQueue.delete(0)
    if d.repeatMode == 1 and result.len > 0:
      d.playbackQueue.add(result)
  if result.len > 0:
    d.lastConsumedFromQueue.add(result)
    if d.lastConsumedFromQueue.len > 10:
      d.lastConsumedFromQueue.delete(0)

proc pushTrackHistory(d: Daemon, newPath: string) =
  if d.currentTrackPath.len > 0 and d.currentTrackPath != newPath:
    d.trackHistory.add(d.currentTrackPath)
    if d.trackHistory.len > 50:
      d.trackHistory.delete(0)

proc advanceToNextTrack(d: Daemon, forward: bool = true): bool =
  d.autoAdvancing = true
  d.upNextSent = false
  if forward:
    # Repeat-one: use current track path when queue is empty
    if d.repeatMode == 2 and d.currentTrackPath.len > 0 and d.playbackQueue.len == 0:
      discard d.nextTrackFromQueue()
      d.player.stop()
      if not d.player.loadFile(d.currentTrackPath):
        return false
      d.player.play()
      d.idleFrames = 0
      return true
    if d.playbackQueue.len == 0: return false
    # Peek at next candidate without consuming
    var nextCandidate = ""
    if d.shuffleEnabled and d.shuffleIndex < d.shuffleOrder.len:
      nextCandidate = d.playbackQueue[d.shuffleOrder[d.shuffleIndex]]
    elif not d.shuffleEnabled:
      nextCandidate = d.playbackQueue[0]
    if nextCandidate.len == 0: return false
    # Resolve YouTube watch URLs: prefer downloaded file, fall back to stream URL
    var loadPath = nextCandidate
    if isYtWatchUrl(nextCandidate):
      var dlTitle = ""
      var dlChannel = ""
      if d.lib != nil:
        let meta = d.lib.getDownloadMetaByUrl(nextCandidate)
        dlTitle = meta.title; dlChannel = meta.channel
        if meta.path.len > 0:
          loadPath = meta.path
      if d.ytStreamResolvedFor == nextCandidate and d.ytStreamResolvedUrl.len > 0:
        loadPath = d.ytStreamResolvedUrl
        # Ensure download is running in background
        var alreadyDL = false
        for t in d.ytDownloadTasks:
          if t.url == nextCandidate: alreadyDL = true; break
        if not alreadyDL and d.lib != nil:
          var task: DownloadTask
          let (cSrc, cPath) = cookiesForUrl(d, nextCandidate)
          if startDownload(YtSearchResult(url: nextCandidate, title: dlTitle, channel: dlChannel), d.ytDownloadDir, task.process, cSrc, d.ytJsRuntime, cPath):
            task.title = dlTitle; task.url = nextCandidate; task.channel = dlChannel
            task.outputDir = d.ytDownloadDir; task.completed = false; task.startedAt = epochTime()
            d.ytDownloadTasks.add(task)
      else:
        # Start resolving stream URL and retry next frame
        if not d.ytStreamResolving or d.ytStreamResolveUrl != nextCandidate:
          try: d.ytStreamResolveProcess.terminate() except: discard
          close(d.ytStreamResolveProcess)
          d.ytStreamResolveBuf = ""
          let (cSrc, cPath) = cookiesForUrl(d, nextCandidate)
          discard startStreamUrlFetch(nextCandidate, d.ytStreamResolveProcess, cSrc, d.ytJsRuntime, cPath)
          d.ytStreamResolving = true
        return false
      if dlTitle.len > 0:
        d.currentTrackTitle = dlTitle
        d.currentTrackChannel = dlChannel
    else:
      # Local file — title already set from earlier metadata or defaults
      discard
    # Consume and play
    let consumed = d.nextTrackFromQueue()
    if consumed.len == 0: return false
    d.pushTrackHistory(loadPath)
    if d.crossfadeDuration > 0 and d.player.state == 1:
      # Crossfade transition
      d.crossfadeConsumed = true
      d.player.prepareNext(loadPath)
      d.player.startCrossfade(float(d.crossfadeDuration))
      d.currentTrackPath = loadPath
      d.crossfadePrepared = false
      d.crossfadeStarted = false
      d.crossfadeNextPath = ""
    else:
      d.player.stop()
      if not d.player.loadFile(loadPath):
        return false
      d.currentTrackPath = loadPath
      d.player.play()
    d.idleFrames = 0
    d.lastTrackDuration = 0.0
    if d.lib != nil:
      let trackId = d.lib.findTrackByPath(loadPath)
      if trackId > 0:
        d.lib.updatePlayCount(trackId)
    return true

when defined(useMpris):
  include mpris

proc executeCommand(d: Daemon, cmd: DaemonCmd): JsonNode =
  result = %*{"ok": true}
  if d.player == nil:
    result["ok"] = %false
    result["error"] = %"no audio backend"
    return
  case cmd.kind
  of dckLoadFile:
    if cmd.strArg.len > 0:
      d.upNextSent = false
      d.autoAdvancing = false
      # Push current track to history before switching
      if d.currentTrackPath.len > 0 and d.currentTrackPath != cmd.strArg:
        d.trackHistory.add(d.currentTrackPath)
        if d.trackHistory.len > 50:
          d.trackHistory.delete(0)
      # Crossfade transition if a track is currently playing
      if d.crossfadeDuration > 0 and d.player.state == 1:
        d.crossfadeConsumed = true
        d.player.prepareNext(cmd.strArg)
        d.player.startCrossfade(float(d.crossfadeDuration))
        d.currentTrackPath = cmd.strArg
        d.currentTrackTitle = cmd.strArg2
        d.currentTrackChannel = cmd.strArg3
        d.crossfadePrepared = false
        d.crossfadeStarted = true
        d.crossfadeNextPath = cmd.strArg
      else:
        d.player.stop()
        if not d.player.loadFile(cmd.strArg):
          result["ok"] = %false
          result["error"] = %"failed to load file"
          return
        d.currentTrackPath = cmd.strArg
        d.currentTrackTitle = cmd.strArg2
        d.currentTrackChannel = cmd.strArg3
        d.player.play()
      d.idleFrames = 0
      # Poll events once so state reflects actual playback status
      discard d.player.pollEvents()
      # Track play count for library tracks, or add YouTube streams to library
      var trackId = d.lib.findTrackByPath(d.currentTrackPath)
      if trackId == 0 and d.currentTrackTitle.len > 0:
        trackId = d.lib.addTrack(d.currentTrackPath, d.currentTrackTitle, d.currentTrackChannel, "YouTube", 0.0, 0, 0, "")
      if trackId > 0:
        d.lib.updatePlayCount(trackId)
        result["track_id"] = %trackId
      let st = case d.player.state
        of 1: "playing"
        of 2: "paused"
        else: "stopped"
      result["state"] = %st
      result["duration"] = %d.player.duration
      result["time_pos"] = %d.player.timePos
      when defined(useMpris):
        emitMprisPlayerChanged(d)
  of dckPlay:
    # Skip if already playing (e.g. crossfade already started by dckLoadFile)
    if d.player.state != 1:
      d.player.play()
    d.idleFrames = 0
    d.pushFullState()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckPause:
    d.player.pause()
    d.pushFullState()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckTogglePause:
    d.player.togglePause(); d.idleFrames = 0
    d.pushFullState()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckStop:
    if d.player != nil:
      d.player.stop()
    d.crossfadePrepared = false
    d.crossfadeStarted = false
    d.crossfadeNextPath = ""
    d.crossfadeConsumed = false
    d.pushFullState()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckSeek:
    d.player.seek(cmd.floatArg)
    when defined(useMpris):
      let pos = int64(d.player.timePos * 1_000_000)
      emitMprisSeeked(pos)
  of dckNext:
    d.autoAdvancing = false
    if d.crossfadePrepared and d.player.state == 1:
      d.player.startCrossfade(float(d.crossfadeDuration), reverse = false)
      d.currentTrackPath = d.crossfadeNextPath
      d.currentTrackTitle = ""
      d.currentTrackChannel = ""
      d.crossfadePrepared = false
      d.crossfadeStarted = false
      d.crossfadeNextPath = ""
      d.crossfadeConsumed = false
      d.idleFrames = 0
      d.pushFullState()
      when defined(useMpris):
        emitMprisPlayerChanged(d)
    elif d.advanceToNextTrack(true):
      d.sendQueueEvent()
      d.pushFullState()
      when defined(useMpris):
        emitMprisPlayerChanged(d)
    else:
      result = %*{"ok": false, "error": "no next track"}
  of dckPrev:
    d.autoAdvancing = false
    var prevPath = ""
    # Try last-consumed-from-queue first for queue-aware prev
    if d.lastConsumedFromQueue.len > 1:
      # last entry is the current track just consumed; entry before it is the one we want
      let idx = d.lastConsumedFromQueue.len - 2
      if idx >= 0:
        prevPath = d.lastConsumedFromQueue[idx]
        # Remove both last entries (current and previous) so replaying doesn't loop
        d.lastConsumedFromQueue.setLen(idx + 1)
    if prevPath.len == 0 and d.trackHistory.len > 0:
      prevPath = d.trackHistory.pop()
    if prevPath.len > 0:
      d.pushTrackHistory(prevPath)
      if d.crossfadeDuration > 0 and d.player.state == 1:
        d.player.prepareNext(prevPath)
        d.player.startCrossfade(float(d.crossfadeDuration), reverse = true)
        d.currentTrackPath = prevPath
        d.currentTrackTitle = ""
        d.currentTrackChannel = ""
        d.crossfadePrepared = false
        d.crossfadeStarted = false
        d.crossfadeNextPath = ""
        d.crossfadeConsumed = false
      else:
        d.player.stop()
        discard d.player.loadFile(prevPath)
        d.currentTrackPath = prevPath
        d.currentTrackTitle = ""
        d.currentTrackChannel = ""
        d.player.play()
      d.idleFrames = 0
      d.pushFullState()
      when defined(useMpris):
        emitMprisPlayerChanged(d)
      if d.lib != nil:
        var trackId = d.lib.findTrackByPath(prevPath)
        if trackId > 0:
          d.lib.updatePlayCount(trackId)
          result["track_id"] = %trackId
    else:
      result = %*{"ok": false, "error": "no previous track"}
  of dckSetVolume:
    d.player.setVolume(cmd.intArg)
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckGetVolume:
    result["volume"] = %d.player.volume
  of dckQuit:
    when defined(useMpris):
      shutdownMpris()
    d.savePlaybackState()
    if d.lib != nil:
      d.lib.closeDb()
    d.player.shutdown()
    d.running = false
  of dckStatus, dckNowPlaying:
    let st = case d.player.state
      of 0: "stopped"
      of 1: "playing"
      of 2: "paused"
      else: "unknown"
    result["state"] = %st
    result["volume"] = %d.player.volume
    result["time_pos"] = %d.player.timePos
    result["duration"] = %d.player.duration
    result["track"] = %d.currentTrackPath
    result["audio_working"] = %d.player.working
    result["sleep_timer"] = %d.sleepTimerRemaining
    let flags = d.player.getStatusFlags()
    result["crossfading"] = %flags.crossfading
    result["master_ended"] = %flags.masterEnded
  of dckPrepareNext:
    d.player.prepareNext(cmd.strArg)
  of dckCrossfade:
    d.player.startCrossfade(cmd.floatArg)
  of dckSetEqBand:
    d.player.setEqBand(cmd.intArg, cmd.floatArg)
  of dckSetEqPreset:
    d.player.setEqPreset(cmd.strArg)
  of dckSetCrossfadeDuration:
    d.crossfadeDuration = cmd.intArg
    d.lib.setPlaybackState("crossfade_duration", $(d.crossfadeDuration))
  of dckSetCrossfadeCurve:
    d.crossfadeCurve = cmd.intArg
    d.player.setCrossfadeCurve(cmd.intArg)
  of dckGetLibrary:
    if d.lib != nil:
      let dbTracks = d.lib.loadTracks()
      var arr = newJArray()
      for t in dbTracks:
        arr.add(%*{
          "id": %t.id, "path": %t.path, "title": %t.title,
          "artist": %t.artist, "album": %t.album, "duration": %t.duration,
          "track_num": %t.trackNum, "year": %t.year, "genre": %t.genre,
          "play_count": %t.playCount, "artist_id": %t.artistId,
          "album_id": %t.albumId, "is_favourite": %t.isFavourite,
          "added_at": %t.addedAt, "last_played": %t.lastPlayed
        })
      result["tracks"] = arr
      let dbArtists = d.lib.loadArtists()
      var artArr = newJArray()
      for a in dbArtists:
        artArr.add(%*{"id": %a.id, "name": %a.name})
      result["artists"] = artArr
      let dbAlbums = d.lib.loadAlbums()
      var albArr = newJArray()
      for a in dbAlbums:
        albArr.add(%*{"id": %a.id, "title": %a.title, "artist_id": %a.artistId, "artist_name": %a.artistName, "year": %a.year, "genre": %a.genre})
      result["albums"] = albArr
  of dckAddTrack:
    if d.lib != nil and cmd.strArg.len > 0:
      try:
        let data = parseJson(cmd.strArg)
        let path = data{"path"}.getStr("")
        let title = data{"title"}.getStr("")
        let artist = data{"channel"}.getStr("")
        let album = data{"album"}.getStr("YouTube")
        let duration = data{"duration"}.getFloat(0.0)
        if path.len > 0:
          let trackId = d.lib.addTrack(path, title, artist, album, duration, 0, 0, "")
          result["track_id"] = %trackId
      except: stderr.writeLine("[gtm] addTrack error: " & getCurrentExceptionMsg())
  of dckUpdateTrackPath:
    if d.lib != nil and cmd.strArg.len > 0:
      try:
        let data = parseJson(cmd.strArg)
        let oldPath = data{"old_path"}.getStr("")
        let newPath = data{"new_path"}.getStr("")
        let newTitle = data{"title"}.getStr("")
        if oldPath.len > 0 and newPath.len > 0:
          d.lib.updateTrackPath(oldPath, newPath, newTitle)
          result["updated"] = %true
      except: stderr.writeLine("[gtm] updateTrackPath error: " & getCurrentExceptionMsg())
  of dckCreatePlaylist:
    if d.lib != nil and cmd.strArg.len > 0:
      let id = d.lib.createPlaylist(cmd.strArg)
      result["playlist_id"] = %id
      let pls = d.lib.loadPlaylists()
      var arr = newJArray()
      for pl in pls:
        arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
      result["playlists"] = arr
  of dckDeletePlaylist:
    if d.lib != nil and cmd.intArg > 0:
      d.lib.deletePlaylist(int64(cmd.intArg))
      let pls = d.lib.loadPlaylists()
      var arr = newJArray()
      for pl in pls:
        arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
      result["playlists"] = arr
  of dckRenamePlaylist:
    if d.lib != nil and cmd.intArg > 0 and cmd.strArg.len > 0:
      d.lib.renamePlaylist(int64(cmd.intArg), cmd.strArg)
      let pls = d.lib.loadPlaylists()
      var arr = newJArray()
      for pl in pls:
        arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
      result["playlists"] = arr
  of dckAddToPlaylist, dckRemoveFromPlaylist:
    if d.lib != nil and cmd.strArg.len > 0:
      try:
        let data = parseJson(cmd.strArg)
        let plId = int64(data{"playlist_id"}.getInt(0))
        let trackId = int64(data{"track_id"}.getInt(0))
        if plId > 0 and trackId > 0:
          if cmd.kind == dckAddToPlaylist:
            let pos = data{"position"}.getInt(0)
            d.lib.addTrackToPlaylist(plId, trackId, pos)
          else:
            d.lib.removeTrackFromPlaylist(plId, trackId)
      except: stderr.writeLine("[gtm] addToPlaylist error: " & getCurrentExceptionMsg())
  of dckListPlaylists:
    if d.lib != nil:
      let pls = d.lib.loadPlaylists()
      var arr = newJArray()
      for pl in pls:
        arr.add(%*{"id": pl.id, "name": pl.name, "track_count": pl.trackIds.len})
      result["playlists"] = arr
  of dckGetPlaylistTracks:
    if d.lib != nil and cmd.intArg > 0:
      let pls = d.lib.loadPlaylists()
      for pl in pls:
        if pl.id == int64(cmd.intArg):
          var arr = newJArray()
          for tid in pl.trackIds:
            arr.add(%tid)
          result["track_ids"] = arr
          break
      result["playlist_id"] = %cmd.intArg
  of dckScan:
    if cmd.strArg.len > 0 and dirExists(cmd.strArg):
      if d.scanningDir.len > 0:
        result["scanning_already"] = %true
      else:
        d.scanningDir = cmd.strArg
        d.scanningFiles = scanDirectoryRecursive(cmd.strArg)
        d.scanningIdx = 0
        result["scanning"] = %true
        result["total_files"] = %d.scanningFiles.len
  of dckSetShuffle:
    d.shuffleEnabled = cmd.intArg != 0
    if d.shuffleEnabled and d.playbackQueue.len > 0:
      d.shuffleOrder = shuffleOrder(d.playbackQueue.len)
      d.shuffleIndex = 0
    result["shuffle"] = %d.shuffleEnabled
    if d.lib != nil:
      d.lib.setPlaybackState("shuffle", $(d.shuffleEnabled))
    let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "shuffle_changed", "shuffle": %d.shuffleEnabled}]}
    d.broadcastAll($ev & "\n")
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckSetRepeat:
    d.repeatMode = cmd.intArg
    result["repeat"] = %d.repeatMode
    if d.lib != nil:
      d.lib.setPlaybackState("repeat", $(d.repeatMode))
    let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "repeat_changed", "repeat": %d.repeatMode}]}
    d.broadcastAll($ev & "\n")
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckSetSleepTimer:
    d.sleepTimerRemaining = cmd.intArg
    result["sleep_timer"] = %d.sleepTimerRemaining
  of dckGetState:
    result["shuffle"] = %d.shuffleEnabled
    result["repeat"] = %d.repeatMode
    result["sleep_timer"] = %d.sleepTimerRemaining
    result["time_pos"] = %d.player.timePos
    result["duration"] = %d.player.duration
    result["track_path"] = %d.currentTrackPath
    if d.currentTrackPath.len > 0:
      if d.currentTrackTitle.len > 0:
        result["track_title"] = %d.currentTrackTitle
      elif d.currentTrackPath.contains("youtube.com") or d.currentTrackPath.contains("googlevideo.com"):
        result["track_title"] = %d.player.metadata.title
      else:
        result["track_title"] = %(splitFile(d.currentTrackPath).name.replace(".", " "))
      if d.currentTrackChannel.len > 0:
        result["track_channel"] = %d.currentTrackChannel
      elif d.player.metadata.artist.len > 0:
        result["track_channel"] = %d.player.metadata.artist
      if d.player.metadata.album.len > 0:
        result["track_album"] = %d.player.metadata.album
    let flags2 = d.player.getStatusFlags()
    result["crossfading"] = %flags2.crossfading
    result["master_ended"] = %flags2.masterEnded
    let st2 = case d.player.state
      of 0: "stopped"
      of 1: "playing"
      of 2: "paused"
      else: "unknown"
    result["state"] = %st2
    result["volume"] = %d.player.volume
    result["backend_type"] = %(if d.player of MixerBackend: "Mixer" elif d.player of FfmpegBackend: "FFmpeg" else: "ALSA")
  of dckResume:
    if d.currentTrackPath.len > 0:
      d.idleFrames = 0
      let st = case d.player.state
        of 0: "stopped"
        of 1: "playing"
        of 2: "paused"
        else: "stopped"
      result["state"] = %st
      result["track"] = %d.currentTrackPath
      result["time_pos"] = %d.player.timePos
      result["duration"] = %d.player.duration
    else:
      result["state"] = %"stopped"
  of dckQueueAdd:
    if cmd.strArg.len > 0:
      try:
        let items = parseJson(cmd.strArg)
        for item in items:
          var path = ""
          var title = ""
          var channel = ""
          if item.kind == JString:
            path = item.getStr("")
          elif item.kind == JObject:
            path = item{"path"}.getStr("")
            title = item{"title"}.getStr("")
            channel = item{"channel"}.getStr("")
          if path.len > 0:
            d.playbackQueue.add(path)
            if isYtWatchUrl(path):
              let existingPath = if d.lib != nil: d.lib.getDownloadByUrl(path) else: ""
              if existingPath.len == 0:
                var alreadyDL = false
                for task in d.ytDownloadTasks:
                  if task.url == path:
                    alreadyDL = true
                    break
                if not alreadyDL:
                  var task: DownloadTask
                  let (cSrc, cPath) = cookiesForUrl(d, path)
                  if startDownload(YtSearchResult(url: path, title: title, channel: channel), d.ytDownloadDir, task.process, cSrc, d.ytJsRuntime, cPath):
                    task.title = title
                    task.url = path
                    task.channel = channel
                    task.outputDir = d.ytDownloadDir
                    task.completed = false
                    task.startedAt = epochTime()
                    d.ytDownloadTasks.add(task)
              # Also start resolving stream URL for instant playback
              if d.ytStreamResolvedFor != path and not d.ytStreamResolving:
                d.ytStreamResolveBuf = ""
                d.ytStreamResolveUrl = path
                let (cSrc, cPath) = cookiesForUrl(d, path)
                discard startStreamUrlFetch(path, d.ytStreamResolveProcess, cSrc, d.ytJsRuntime, cPath)
                d.ytStreamResolving = true
        result["queue_length"] = %d.playbackQueue.len
        d.regenShuffleIfNeeded()
        d.sendQueueEvent()
        if d.player != nil and d.player.state == 0 and d.playbackQueue.len > 0:
          if d.advanceToNextTrack(true):
            d.sendQueueEvent()
            d.pushFullState()
      except: stderr.writeLine("[gtm] queueAdd error: " & getCurrentExceptionMsg())
  of dckQueueRemove:
    if cmd.intArg >= 0 and cmd.intArg < d.playbackQueue.len:
      d.playbackQueue.delete(cmd.intArg)
    d.regenShuffleIfNeeded()
    d.sendQueueEvent()
  of dckQueueRemovePath:
    if cmd.strArg.len > 0:
      let idx = d.playbackQueue.find(cmd.strArg)
      if idx >= 0:
        d.playbackQueue.delete(idx)
    d.regenShuffleIfNeeded()
    d.sendQueueEvent()
  of dckQueueClear:
    d.playbackQueue = @[]
    d.shuffleOrder = @[]
    d.shuffleIndex = 0
    d.crossfadePrepared = false
    d.crossfadeStarted = false
    d.crossfadeNextPath = ""
    d.crossfadeConsumed = false
    d.sendQueueEvent()
  of dckQueueValidate:
    var removed = 0
    var i = 0
    while i < d.playbackQueue.len:
      let p = d.playbackQueue[i]
      if p.len > 0 and not isYtWatchUrl(p) and not fileExists(p):
        d.playbackQueue.delete(i)
        removed.inc
      else:
        i.inc
    if removed > 0:
      d.regenShuffleIfNeeded()
      d.sendQueueEvent()
    result["removed"] = %removed
  of dckQueueList:
    var arr = newJArray()
    for p in d.playbackQueue:
      arr.add(%p)
    result["queue"] = arr
  of dckQueueSetCursor:
    d.shuffleIndex = cmd.intArg
    result["cursor"] = %d.shuffleIndex
  of dckAddFavourite:
    if d.lib != nil:
      d.lib.addFavourite(int64(cmd.intArg))
  of dckRemoveFavourite:
    if d.lib != nil:
      d.lib.removeFavourite(int64(cmd.intArg))
  of dckGetFavourites:
    if d.lib != nil:
      var arr = newJArray()
      for t in d.lib.getFavourites():
        arr.add(%t)
      result["favourites"] = arr
  of dckGetFullState:
    result["shuffle"] = %d.shuffleEnabled
    result["repeat"] = %d.repeatMode
    result["sleep_timer"] = %d.sleepTimerRemaining
    result["volume"] = %d.player.volume
    result["time_pos"] = %d.player.timePos
    result["duration"] = %d.player.duration
    result["track_path"] = %d.currentTrackPath
    result["track_title"] = %d.currentTrackTitle
    result["track_channel"] = %d.currentTrackChannel
    result["track_album"] = %d.player.metadata.album
    result["crossfading"] = %d.player.getStatusFlags().crossfading
    result["master_ended"] = %d.player.getStatusFlags().masterEnded
    var qArr = newJArray()
    for p in d.playbackQueue:
      qArr.add(%p)
    result["queue"] = qArr
    var soArr = newJArray()
    for i in d.shuffleOrder:
      soArr.add(%i)
    result["shuffleOrder"] = soArr
    result["shuffleIndex"] = %d.shuffleIndex
    result["version"] = %d.stateVersion
    result["crossfadeDuration"] = %d.crossfadeDuration
    result["crossfadeCurve"] = %d.crossfadeCurve
    result["crossfadePrepared"] = %d.crossfadePrepared
    result["crossfadeStarted"] = %d.crossfadeStarted
    result["crossfadeNextPath"] = %d.crossfadeNextPath
    let st = case d.player.state
      of 0: "stopped"
      of 1: "playing"
      of 2: "paused"
      else: "unknown"
    result["state"] = %st
  of dckYtSearch:
    if d.ytSearchActive:
      try: d.ytSearchProcess.terminate() except: discard
      close(d.ytSearchProcess)
    d.ytSearchBuf = ""
    d.ytSearchResults = @[]
    d.ytSearchQuery = cmd.strArg
    d.ytSearchActive = startYoutubeSearch(cmd.strArg, d.ytSearchProcess, d.ytCookieSource, cmd.intArg, d.ytCookieFilePath)
    if d.ytSearchActive and d.lib != nil:
      d.lib.addSearchQuery(cmd.strArg)
    result["active"] = %d.ytSearchActive
  of dckYtSearchPoll:
    # Main loop auto-polls; just return current accumulated results
    var arr = newJArray()
    for r in d.ytSearchResults:
      arr.add(%*{"title": %r.title, "url": %r.url, "duration": %r.duration, "channel": %r.channel, "kind": %r.kind.int})
    result["results"] = arr
    result["done"] = %(not d.ytSearchActive)
  of dckYtSearchCancel:
    if d.ytSearchActive:
      try: d.ytSearchProcess.terminate() except: discard
      close(d.ytSearchProcess)
    d.ytSearchActive = false
    d.ytSearchBuf = ""
    d.ytSearchResults = @[]
  of dckYtResolveStream:
    d.ytStreamBuf = ""
    d.ytStreamResultUrl = ""
    d.ytStreamPendingTitle = cmd.strArg2
    d.ytStreamPendingChannel = cmd.strArg3
    let (cSrc, cPath) = cookiesForUrl(d, cmd.strArg)
    d.ytStreamActive = startStreamUrlFetch(cmd.strArg, d.ytStreamProcess, cSrc, d.ytJsRuntime, cPath)
    result["active"] = %d.ytStreamActive
  of dckYtResolveStreamPoll:
    # Main loop auto-polls; just return current state
    result["url"] = %d.ytStreamResultUrl
    result["title"] = %d.ytStreamPendingTitle
    result["channel"] = %d.ytStreamPendingChannel
    result["done"] = %(not d.ytStreamActive)
  of dckYtDownload:
    if cmd.strArg.len > 0:
      var task: DownloadTask
      let (cSrc, cPath) = cookiesForUrl(d, cmd.strArg)
      if startDownload(YtSearchResult(url: cmd.strArg, title: cmd.strArg2, channel: cmd.strArg3), d.ytDownloadDir, task.process, cSrc, d.ytJsRuntime, cPath):
        task.title = cmd.strArg2
        task.url = cmd.strArg
        task.channel = cmd.strArg3
        task.outputDir = d.ytDownloadDir
        task.completed = false
        task.startedAt = epochTime()
        d.ytDownloadTasks.add(task)
        result["started"] = %true
      else:
        result["started"] = %false
    else:
      result["started"] = %false
  of dckYtDownloadPoll:
    # Main loop auto-polls; just return current accumulated state
    result["done"] = %(d.ytDownloadTasks.len == 0)
    if d.ytLastCompletedPath.len > 0:
      result["path"] = %d.ytLastCompletedPath
      result["url"] = %d.ytLastCompletedUrl
      d.ytLastCompletedPath = ""
      d.ytLastCompletedUrl = ""
    var activeArr = newJArray()
    for t in d.ytDownloadTasks:
      activeArr.add(%*{"url": %t.url, "title": %t.title, "started": %t.startedAt})
    result["active"] = activeArr
    var completedArr = newJArray()
    if d.lib != nil:
      for dl in d.lib.getDownloads():
        completedArr.add(%*{"url": %dl.url, "path": %dl.path, "title": %dl.title})
    result["completed"] = completedArr
  of dckYtCancelDownload:
    for i in 0..<d.ytDownloadTasks.len:
      if d.ytDownloadTasks[i].url == cmd.strArg:
        try: d.ytDownloadTasks[i].process.terminate() except: discard
        close(d.ytDownloadTasks[i].process)
        d.ytDownloadTasks.delete(i)
        break
  of dckYtListDownloads:
    var arr = newJArray()
    if d.lib != nil:
      for dl in d.lib.getDownloads():
        arr.add(%*{"url": %dl.url, "path": %dl.path, "title": %dl.title})
    result["downloads"] = arr
  of dckYtFetchPlaylist:
    if d.ytPlaylistActive:
      result["ok"] = %false
      result["error"] = %"playlist fetch already in progress"
    else:
      let (cSrc, cPath) = cookiesForUrl(d, cmd.strArg)
      if startPlaylistFetch(cmd.strArg, d.ytPlaylistProcess, cSrc, d.ytJsRuntime, cPath):
        d.ytPlaylistActive = true
        d.ytPlaylistBuf = ""
        d.ytPlaylistUrl = cmd.strArg
        d.ytPlaylistResult = YtPlaylistDetail(url: cmd.strArg)
        result["ok"] = %true
        result["pending"] = %true
      else:
        result["ok"] = %false
        result["error"] = %"failed to start playlist fetch"
  of dckYtFetchPlaylistPoll:
    # Main loop auto-polls; just return current state
    if not d.ytPlaylistActive and d.ytPlaylistResult.tracks.len == 0:
      result["ok"] = %false
      result["error"] = %"no active playlist fetch"
    elif d.ytPlaylistActive:
      result["ok"] = %true
      result["pending"] = %true
    else:
      var tracksArr = newJArray()
      for t in d.ytPlaylistResult.tracks:
        tracksArr.add(%*{"title": %t.title, "url": %t.url, "duration": %t.duration, "channel": %t.channel, "kind": %t.kind.int})
      result["title"] = %d.ytPlaylistResult.title
      result["tracks"] = tracksArr
      result["track_count"] = %d.ytPlaylistResult.tracks.len
      result["done"] = %true
  of dckYtSetConfig:
    d.ytCookieSource = cmd.strArg
    d.ytJsRuntime = cmd.strArg2
    if cmd.strArg3.len > 0: d.ytDownloadDir = cmd.strArg3
    if cmd.intArg > 0: d.ytMaxConcurrentDownloads = cmd.intArg
    result["cookie_source"] = %d.ytCookieSource
    result["js_runtime"] = %d.ytJsRuntime
    result["download_dir"] = %d.ytDownloadDir
    result["max_concurrent"] = %d.ytMaxConcurrentDownloads
  of dckSpSetConfig:
    d.spCookieSource = cmd.strArg
    d.spCookieFilePath = cmd.strArg2
    if cmd.strArg3.len > 0: d.spAudioFormat = cmd.strArg3
    result["cookie_source"] = %d.spCookieSource
    result["cookie_path"] = %d.spCookieFilePath
    result["audio_format"] = %d.spAudioFormat
  of dckSpListDownloads:
    var arr = newJArray()
    if d.lib != nil:
      for dl in d.lib.getDownloads():
        if "spotify.com" in dl.url:
          arr.add(%*{"url": %dl.url, "path": %dl.path, "title": %dl.title})
    result["downloads"] = arr
  of dckYtGetSearchHistory:
    var arr = newJArray()
    if d.lib != nil:
      for q in d.lib.getSearchHistory():
        arr.add(%q)
    result["history"] = arr
  of dckYtClearSearchHistory:
    if d.lib != nil:
      d.lib.clearSearchHistory()
  of dckListEqPresets:
    result["presets"] = %["Flat", "Rock", "Pop", "Classical", "Jazz", "HipHop", "Vocal", "BassBoost", "Headphones", "Laptop", "Electronic", "Acoustic", "Podcast", "Dance", "Soul", "Metal", "Reggae", "Blues", "Country", "Folk", "ClassicalAlt", "Speech", "Loudness", "TrebleBoost", "FullBass", "Soft", "Custom"]
  of dckGetCoverArt:
    if cmd.strArg.len > 0 and fileExists(cmd.strArg):
      let (coverData, coverMime) = extractCoverArt(cmd.strArg)
      if coverData.len > 0:
        result["cover_data"] = %encode(coverData)
        result["cover_mime"] = %coverMime
    else:
      result["cover_data"] = %""
  of dckGetLyrics:
    let lrc = resolveLyrics(cmd.strArg, cmd.strArg2, cmd.strArg3, cmd.strArg4, cmd.floatArg)
    if lrc.lines.len > 0:
      result["ok"] = %true
      result["title"] = %lrc.title
      result["artist"] = %lrc.artist
      result["album"] = %lrc.album
      var arr = newJArray()
      for ln in lrc.lines:
        arr.add(%*{"ts": %ln.timestamp, "text": %ln.text})
      result["lines"] = arr
    else:
      result["ok"] = %false
  of dckSearchLyrics:
    let results = searchLrclib(cmd.strArg, cmd.strArg2)
    var arr = newJArray()
    for r in results:
      arr.add(%*{"id": %r.id, "artist": %r.artist, "title": %r.title, "album": %r.album, "duration": %r.duration})
    result["results"] = arr
  of dckDeleteTrack:
    if d.lib == nil or cmd.intArg <= 0:
      result["ok"] = %false
      result["error"] = %"invalid track_id"
    else:
      let trackId = int64(cmd.intArg)
      let permanent = cmd.intArg2 != 0
      let origPath = d.lib.getTrackPath(trackId)
      if origPath.len == 0 or not fileExists(origPath):
        result["ok"] = %false
        result["error"] = %"track not found or file missing"
      else:
        if permanent:
          try: removeFile(origPath) except: discard
          d.lib.deleteTrack(trackId)
          result["ok"] = %true
        else:
          let trashDir = dataDir() / "trash"
          if not dirExists(trashDir): createDir(trashDir)
          let (_, name, ext) = splitFile(origPath)
          let trashName = name & "." & $epochTime().int & ext
          let trashPath = trashDir / trashName
          try:
            moveFile(origPath, trashPath)
            d.lib.trashTrack(trackId, origPath, trashPath)
            d.lib.deleteTrack(trackId)
            result["ok"] = %true
          except:
            result["ok"] = %false
            result["error"] = %"failed to move file to trash"
  of dckRestoreTrack:
    if d.lib == nil or cmd.intArg <= 0:
      result["ok"] = %false
      result["error"] = %"invalid trash_id"
    else:
      let trashId = cmd.intArg
      let (trackId, origPath, trashPath) = d.lib.restoreTrack(trashId)
      if origPath.len > 0 and trashPath.len > 0:
        if fileExists(trashPath):
          let dir = origPath.parentDir()
          if not dirExists(dir): createDir(dir)
          try:
            moveFile(trashPath, origPath)
            result["ok"] = %true
            result["track_id"] = %trackId
            result["path"] = %origPath
          except:
            result["ok"] = %false
            result["error"] = %"failed to restore file"
        else:
          result["ok"] = %true
          result["track_id"] = %trackId
          result["path"] = %origPath
      else:
        result["ok"] = %false
        result["error"] = %"trash entry not found"
  of dckPermanentDelete:
    if d.lib != nil and cmd.intArg > 0:
      let trashPath = d.lib.getTrashPath(cmd.intArg)
      if trashPath.len > 0:
        try: removeFile(trashPath) except: discard
      d.lib.permanentDeleteTrash(cmd.intArg)
      result["ok"] = %true
    else:
      result["ok"] = %false
      result["error"] = %"invalid trash_id"
  of dckListTrash:
    if d.lib != nil:
      var arr = newJArray()
      for item in d.lib.listTrash():
        arr.add(%*{"id": item.id, "track_id": item.trackId, "original_path": item.originalPath, "trash_path": item.trashPath, "trashed_at": item.trashedAt, "expires_at": item.expiresAt})
      result["trash"] = arr
    result["ok"] = %true
  of dckPurgeTrash:
    if d.lib != nil:
      var purged = 0
      for item in d.lib.purgeExpiredTrash():
        if fileExists(item.trashPath):
          try: removeFile(item.trashPath) except: discard
        purged.inc
      result["purged"] = %purged
    result["ok"] = %true
  of dckPing:
    result["pong"] = %true


proc trySend(client: Socket, data: string): bool =
  if data.len == 0: return true
  var remaining = data
  var retries = 20
  while remaining.len > 0 and retries > 0:
    let n = posix.send(client.getFd, unsafeAddr remaining[0], remaining.len.cint, 0.cint)
    if n > 0:
      remaining = remaining[n..^1]
    elif n == 0:
      return true
    else:
      let err = osLastError()
      if err.int32 == 11 or err.int32 == 10035:
        os.sleep(10)
        retries.dec
      else:
        try: client.close() except: discard
        return false
  if remaining.len > 0:
    try: client.close() except: discard
    return false
  return true

proc cleanupClientState(d: Daemon) =
  if d.ytSearchActive:
    try: d.ytSearchProcess.terminate() except: discard
    close(d.ytSearchProcess)
  if d.ytStreamActive:
    try: d.ytStreamProcess.terminate() except: discard
    close(d.ytStreamProcess)
  d.ytSearchActive = false
  d.ytSearchBuf = ""
  d.ytSearchResults = @[]
  d.ytStreamActive = false
  d.ytStreamBuf = ""
  d.ytStreamResultUrl = ""
  d.ytStreamPendingTitle = ""
  d.ytStreamPendingChannel = ""
  d.ytStreamPendingDuration = ""

proc runDaemon*() =
  let debugMode = "--debug" in os.commandLineParams()
  let dir = stateDir()
  if not dirExists(dir): createDir(dir)
  let cacheDir = getEnv("XDG_CACHE_HOME", getEnv("HOME", "") & "/.cache") & "/gtm"
  if not dirExists(cacheDir): createDir(cacheDir)
  let crashPath = cacheDir / "crash.log"
  var crashFile: File
  if crashFile.open(crashPath, fmAppend):
    let crashFd = crashFile.getFileHandle
    if debugMode:
      let debugPath = cacheDir / "debug.log"
      var debugFile: File
      if debugFile.open(debugPath, fmAppend):
        let debugFd = debugFile.getFileHandle
        discard dup2(cint(debugFd), cint(1))
        discard dup2(cint(debugFd), cint(2))
        debugFile.writeLine("[gtmd] GTM Daemon v" & GTM_VERSION & " starting — pid: " & $getpid() & ", socket: " & sockPath())
      else:
        stderr.writeLine("[gtmd] GTM Daemon v" & GTM_VERSION & " starting — pid: " & $getpid() & ", socket: " & sockPath())
    else:
      discard dup2(cint(crashFd), cint(1))
      discard dup2(cint(crashFd), cint(2))
  when not defined(macosx):
    discard prctl(15.cint, "gtmd")
  else:
    discard pthread_setname_np("gtmd")
  if not acquirePidLock():
    stderr.writeLine("[gtmd] Another daemon instance is already running")
    quit(1)
  writePidFile()
  setupSignalHandlers()
  var player: AudioBackend
  when defined(useFFmpeg):
    player = newMixerBackend()
    if not player.working:
      echo "[gtm] Mixer backend unavailable (ALSA?), trying FFmpeg fallback"
      player = newFfmpegBackend()
    if not player.working:
      echo "[gtm] FFmpeg backend unavailable"
  else:
    player = nil
  if player == nil or not player.working:
    stderr.writeLine("[gtm] All audio backends unavailable")
  let defaultDownloadDir = dataDir() & "/audio"
  var daemon = Daemon(
    player: player,
    running: true,
    idleTimeout: 300,
    clients: @[],
    shuffleEnabled: false,
    repeatMode: 0,
    sleepTimerRemaining: 0,
    sleepTimerFrames: 0,
    persistFrames: 0,
    playbackQueue: @[],
    trackHistory: @[],
    shuffleOrder: @[],
    shuffleIndex: 0,
    crossfadeDuration: 6,
    crossfadeCurve: 3,
    crossfadePrepared: false,
    crossfadeStarted: false,
    crossfadeNextPath: "",
    scanningDir: "",
    scanningFiles: @[],
    scanningIdx: 0,
    ytCookieSource: "",
    ytCookieFilePath: "",
    ytJsRuntime: "",
    ytDownloadDir: defaultDownloadDir,
    ytMaxConcurrentDownloads: 4,
    spCookieSource: "",
    spCookieFilePath: "",
    spAudioFormat: "opus",
    ytSearchActive: false,
    ytStreamActive: false,
    ytStreamResultUrl: "",
    ytStreamResolvedUrl: "",
    ytStreamResolvedFor: "",
    ytLastCompletedPath: "",
    ytLastCompletedUrl: "",
    ytPlaylistActive: false,
    ytPlaylistBuf: "",
    ytPlaylistUrl: "",
    ytSearchResults: @[],
    ytDownloadTasks: @[],
    lastConsumedFromQueue: @[],
    lastTrackDuration: 0.0,
    stateVersion: 0
  )
  when defined(useMpris):
    initMpris(daemon)
  let libPath = dataDir() & "/gtm.db"
  if not dirExists(dataDir()):
    createDir(dataDir())
  let trashDir2 = dataDir() / "trash"
  if not dirExists(trashDir2): createDir(trashDir2)
  daemon.lib = openLibrary(libPath)
  if daemon.lib != nil:
    daemon.lib.initSchema()
    let volStr = daemon.lib.getPlaybackState("volume")
    if volStr.len > 0 and daemon.player != nil:
      try: daemon.player.setVolume(parseInt(volStr)) except: discard
    let shuffleStr = daemon.lib.getPlaybackState("shuffle")
    if shuffleStr.len > 0:
      try: daemon.shuffleEnabled = shuffleStr == "true" except: discard
    let repeatStr = daemon.lib.getPlaybackState("repeat")
    if repeatStr.len > 0:
      try: daemon.repeatMode = parseInt(repeatStr) except: discard
    let sleepStr = daemon.lib.getPlaybackState("sleep_timer")
    if sleepStr.len > 0:
      try: daemon.sleepTimerRemaining = parseInt(sleepStr) except: discard
    let cfStr = daemon.lib.getPlaybackState("crossfade_duration")
    if cfStr.len > 0:
      try: daemon.crossfadeDuration = parseInt(cfStr) except: discard
    let cfcStr = daemon.lib.getPlaybackState("crossfade_curve")
    if cfcStr.len > 0:
      try: daemon.crossfadeCurve = parseInt(cfcStr) except: discard
    if daemon.player != nil:
      daemon.player.setCrossfadeCurve(daemon.crossfadeCurve)
    let ytCookie = daemon.lib.getPlaybackState("yt_cookie_source")
    if ytCookie.len > 0: daemon.ytCookieSource = ytCookie
    let ytCookieFile = daemon.lib.getPlaybackState("yt_cookie_file_path")
    if ytCookieFile.len > 0: daemon.ytCookieFilePath = ytCookieFile
    let ytJs = daemon.lib.getPlaybackState("yt_js_runtime")
    if ytJs.len > 0: daemon.ytJsRuntime = ytJs
    let ytDlDir = daemon.lib.getPlaybackState("yt_download_dir")
    if ytDlDir.len > 0: daemon.ytDownloadDir = ytDlDir
    let ytMax = daemon.lib.getPlaybackState("yt_max_concurrent")
    if ytMax.len > 0:
      try: daemon.ytMaxConcurrentDownloads = parseInt(ytMax) except: discard
    let spCookie = daemon.lib.getPlaybackState("sp_cookie_source")
    if spCookie.len > 0: daemon.spCookieSource = spCookie
    let spCookieFile = daemon.lib.getPlaybackState("sp_cookie_file_path")
    if spCookieFile.len > 0: daemon.spCookieFilePath = spCookieFile
    let spAudio = daemon.lib.getPlaybackState("sp_audio_format")
    if spAudio.len > 0: daemon.spAudioFormat = spAudio
    # Completed downloads are queried from DB on demand
    let queueStr = daemon.lib.getPlaybackState("queue_json")
    if queueStr.len > 0:
      try:
        let qj = parseJson(queueStr)
        daemon.playbackQueue = @[]
        for p in qj:
          daemon.playbackQueue.add(p.getStr(""))
      except: discard
    # Restore shuffle cursor
    let siStr = daemon.lib.getPlaybackState("shuffle_index")
    if siStr.len > 0:
      try: daemon.shuffleIndex = parseInt(siStr) except: discard
    # Validate restored queue paths
    var i = 0
    while i < daemon.playbackQueue.len:
      let p = daemon.playbackQueue[i]
      if p.len > 0 and not isYtWatchUrl(p) and not fileExists(p):
        daemon.playbackQueue.delete(i)
      else:
        i.inc
    # Auto-scan download directory for files not yet in library
    if dirExists(daemon.ytDownloadDir):
      let existing = scanDirectoryRecursive(daemon.ytDownloadDir)
      for p in existing:
        if daemon.lib.findTrackByPath(p) == 0:
          let (ftitle, fartist) = parseFilenameForMetadata(p)
          discard daemon.lib.addTrack(p, ftitle, fartist, "", 0.0, 0, 0, "")
  removeFile(sockPath())
  let srvFd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  daemon.server = newSocket(srvFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
  daemon.server.bindUnix(sockPath())
  daemon.server.listen()
  while daemon.running:
    when defined(useMpris):
      pollMpris()
    var readFds: seq[SocketHandle] = @[daemon.server.getFd]
    for c in daemon.clients:
      readFds.add(c.sock.getFd)
    if selectRead(readFds, 16) > 0:
      if daemon.server.getFd in readFds:
        var clientAddr: posix.Sockaddr_un
        var addrLen = posix.SockLen(sizeof(clientAddr))
        let cliFd = posix.accept(daemon.server.getFd,
          cast[ptr posix.SockAddr](addr(clientAddr)), addr(addrLen))
        if cliFd.int >= 0:
          var newClient = ClientState(
            sock: newSocket(cliFd, Domain.AF_UNIX, SockType.SOCK_STREAM),
            buf: ""
          )
          setBlocking(newClient.sock.getFd, false)
          daemon.clients.add(newClient)
          daemon.idleFrames = 0
      # Read from all clients
      var ci = 0
      while ci < daemon.clients.len:
        if daemon.clients[ci].sock.getFd in readFds:
          var tmp: array[4096, char]
          let n = posix.recv(daemon.clients[ci].sock.getFd, addr tmp[0], tmp.len.cint, 0)
          if n < 0:
            let err = osLastError()
            if err.int32 != 11 and err.int32 != 10035:
              daemon.clients[ci].sock.close()
              daemon.clients.delete(ci)
              continue
            else:
              ci.inc
              continue
          elif n == 0:
            daemon.clients[ci].sock.close()
            daemon.clients.delete(ci)
            continue
          else:
            let old = daemon.clients[ci].buf.len
            daemon.clients[ci].buf.setLen(old + n)
            copyMem(addr daemon.clients[ci].buf[old], addr tmp[0], n)
            while true:
              let nli = daemon.clients[ci].buf.find('\n')
              if nli < 0: break
              let line = daemon.clients[ci].buf[0..<nli]
              daemon.clients[ci].buf = daemon.clients[ci].buf[nli+1..^1]
              if line.len > 0:
                if debugMode: stderr.writeLine("[gtm] daemon recv: " & line)
                let cmdJson = parseJson(line)
                let cmd = parseDaemonCommand(line)
                let resp = try:
                  executeCommand(daemon, cmd)
                except Exception as ex:
                  if debugMode: stderr.writeLine("[gtm] command error: " & ex.msg)
                  %*{"ok": false, "error": ex.msg}
                if cmdJson.hasKey("seq"):
                  resp["seq"] = cmdJson["seq"]
                let respStr = $resp & "\n"
                if debugMode: stderr.writeLine("[gtm] daemon resp: " & respStr.strip())
                if not trySend(daemon.clients[ci].sock, respStr):
                  daemon.clients[ci].sock.close()
                  daemon.clients.delete(ci)
                  break
                if not daemon.running: break
        ci.inc
    try:
      let daemonEvents = if daemon.player != nil: daemon.player.pollEvents() else: @[]
      if daemonEvents.len > 0:
        daemon.stateVersion.inc
        if daemon.clients.len > 0:
          let evJson = %*{"events": serializeEvents(daemonEvents, daemon)}
          daemon.broadcastAll($evJson & "\n")
      # Reset auto-advance flag after playback started event is broadcast
      for ev in daemonEvents:
        if ev.kind == evPlaybackStarted:
          daemon.autoAdvancing = false
      # Auto-advance on track ended
      for ev in daemonEvents:
        if ev.kind == evTrackEnded:
          if daemon.crossfadeNextPath.len > 0:
            daemon.currentTrackPath = daemon.crossfadeNextPath
            daemon.upNextSent = false
            # Fetch metadata for the crossfaded track
            if daemon.lib != nil and isYtWatchUrl(daemon.crossfadeNextPath):
              let meta = daemon.lib.getDownloadMetaByUrl(daemon.crossfadeNextPath)
              if meta.title.len > 0:
                daemon.currentTrackTitle = meta.title
                daemon.currentTrackChannel = meta.channel
            elif daemon.lib != nil:
              let cfId = daemon.lib.findTrackByPath(daemon.crossfadeNextPath)
              if cfId > 0:
                daemon.lib.updatePlayCount(cfId)
            # Consume queue now that crossfade completed
            if daemon.repeatMode == 2:
              daemon.crossfadeNextPath = ""
              daemon.crossfadePrepared = false
              daemon.crossfadeConsumed = false
            elif not daemon.shuffleEnabled and daemon.playbackQueue.len > 0:
              daemon.playbackQueue.delete(0)
              if daemon.repeatMode == 1:
                daemon.playbackQueue.add(daemon.crossfadeNextPath)
            daemon.crossfadePrepared = false
            daemon.crossfadeStarted = false
            daemon.crossfadeConsumed = false
            daemon.crossfadeNextPath = ""
            daemon.sendQueueEvent()
            daemon.pushFullState()
          elif daemon.playbackQueue.len > 0:
            discard daemon.advanceToNextTrack(true)
            daemon.sendQueueEvent()
            daemon.pushFullState()
          when defined(useMpris):
            emitMprisPlayerChanged(daemon)
      # Monitor duration changes — broadcast if duration becomes known during playback (e.g. streams)
      let currentDur = daemon.player.duration
      if currentDur > 0 and abs(currentDur - daemon.lastTrackDuration) > 0.5:
        daemon.lastTrackDuration = currentDur
        daemon.stateVersion.inc
        let durEv = %*{"events": [%*{"kind": %evDurationChanged.int, "duration": %currentDur, "version": %daemon.stateVersion}]}
        daemon.broadcastAll($durEv & "\n")
    except Exception as ex:
      if debugMode: stderr.writeLine("[gtmd] event processing error: " & ex.msg)

    # yt-dlp download task management (poll BEFORE retry so completed downloads are visible)
    let dlTimeout = 600.0
    var dlDone: seq[int] = @[]
    for i in 0..<daemon.ytDownloadTasks.len:
      if not daemon.ytDownloadTasks[i].completed:
        let p = daemon.ytDownloadTasks[i].process
        if epochTime() - daemon.ytDownloadTasks[i].startedAt > dlTimeout:
          try: p.terminate() except: discard
          close(p)
          daemon.ytDownloadTasks[i].completed = true
          dlDone.add(i)
        elif not p.running():
          var path = ""
          try: path = pollDownload(daemon.ytDownloadTasks[i].process, daemon.ytDownloadTasks[i].buf)
          except: discard
          daemon.ytDownloadTasks[i].completed = true
          dlDone.add(i)
          if path.len > 0:
            let dlUrl = daemon.ytDownloadTasks[i].url
            daemon.ytLastCompletedPath = path
            daemon.ytLastCompletedUrl = dlUrl
            if daemon.lib != nil:
              daemon.lib.addDownload(dlUrl, path, daemon.ytDownloadTasks[i].title, daemon.ytDownloadTasks[i].channel)
              daemon.lib.updateTrackPath(dlUrl, path, daemon.ytDownloadTasks[i].title)
              # Add as a new library track if not already present
              let existingId = daemon.lib.findTrackByPath(path)
              if existingId == 0:
                discard daemon.lib.addTrack(path, daemon.ytDownloadTasks[i].title,
                  daemon.ytDownloadTasks[i].channel, "", 0.0, 0, 0, "")
            let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "yt_download_done", "url": %dlUrl, "path": %path, "title": %daemon.ytDownloadTasks[i].title}]}
            daemon.broadcastAll($ev & "\n")
      else:
        dlDone.add(i)
    for i in countdown(dlDone.len - 1, 0):
      daemon.ytDownloadTasks.delete(dlDone[i])

    # yt-dlp stream URL resolution for queue items
    if daemon.ytStreamResolving:
      if not daemon.ytStreamResolveProcess.running():
        let url = pollStreamUrlFetch(daemon.ytStreamResolveProcess, daemon.ytStreamResolveBuf)
        daemon.ytStreamResolving = false
        daemon.ytStreamResolveBuf = ""
        if url.len > 0:
          daemon.ytStreamResolvedFor = daemon.ytStreamResolveUrl
          daemon.ytStreamResolvedUrl = url
          daemon.ytStreamResolveUrl = ""

    # Auto-poll yt-dlp search results & broadcast via events (no client polling needed)
    if daemon.ytSearchActive:
      let newResults = pollYoutubeSearch(daemon.ytSearchProcess, daemon.ytSearchBuf)
      for r in newResults:
        daemon.ytSearchResults.add(r)
      if newResults.len > 0 and daemon.ytSearchResults.len > 0:
        var arr = newJArray()
        for r in daemon.ytSearchResults:
          arr.add(%*{"title": %r.title, "url": %r.url, "duration": %r.duration, "channel": %r.channel, "kind": %r.kind.int})
        let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "yt_search_partial", "results": arr}]}
        daemon.broadcastAll($ev & "\n")
      if not daemon.ytSearchProcess.running():
        let finalResults = finishYoutubeSearch(daemon.ytSearchProcess, daemon.ytSearchBuf)
        for r in finalResults:
          daemon.ytSearchResults.add(r)
        daemon.ytSearchActive = false
        daemon.ytSearchBuf = ""
        var arr = newJArray()
        for r in daemon.ytSearchResults:
          arr.add(%*{"title": %r.title, "url": %r.url, "duration": %r.duration, "channel": %r.channel, "kind": %r.kind.int})
        let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "yt_search_done", "results": arr}]}
        daemon.broadcastAll($ev & "\n")
        daemon.ytSearchResults = @[]

    # Auto-poll yt-dlp playlist fetch results & broadcast via events
    if daemon.ytPlaylistActive:
      let newTracks = pollPlaylistFetch(daemon.ytPlaylistProcess, daemon.ytPlaylistBuf)
      for t in newTracks:
        daemon.ytPlaylistResult.tracks.add(t)
      if not daemon.ytPlaylistProcess.running():
        let finalTracks = finishPlaylistFetch(daemon.ytPlaylistProcess, daemon.ytPlaylistBuf)
        for t in finalTracks:
          daemon.ytPlaylistResult.tracks.add(t)
        # Parse title/channel from first result
        if daemon.ytPlaylistResult.tracks.len > 0:
          let first = daemon.ytPlaylistResult.tracks[0]
          if daemon.ytPlaylistResult.title.len == 0:
            daemon.ytPlaylistResult.title = "Playlist"
            daemon.ytPlaylistResult.channel = first.channel
        daemon.ytPlaylistActive = false
        daemon.ytPlaylistBuf = ""
        # Broadcast playlist fetched event
        var tracksArr = newJArray()
        for t in daemon.ytPlaylistResult.tracks:
          tracksArr.add(%*{"title": %t.title, "url": %t.url, "duration": %t.duration, "channel": %t.channel, "kind": %t.kind.int})
        let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "yt_playlist_fetched",
          "title": %daemon.ytPlaylistResult.title, "tracks": tracksArr}]}
        daemon.broadcastAll($ev & "\n")

    # Auto-poll explicit stream URL resolution (for user-initiated "Play" on search result)
    if daemon.ytStreamActive:
      if not daemon.ytStreamProcess.running():
        daemon.ytStreamResultUrl = pollStreamUrlFetch(daemon.ytStreamProcess, daemon.ytStreamBuf)
        daemon.ytStreamActive = false
        daemon.ytStreamBuf = ""
        let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "yt_stream_resolved",
          "url": %daemon.ytStreamResultUrl,
          "title": %daemon.ytStreamPendingTitle,
          "channel": %daemon.ytStreamPendingChannel}]}
        daemon.broadcastAll($ev & "\n")

    # Retry advancing if player stopped with items pending (e.g. waiting for YT download)
    try:
      if daemon.currentTrackPath.len > 0 and daemon.player.state == 0 and daemon.playbackQueue.len > 0:
        if daemon.advanceToNextTrack(true):
          daemon.sendQueueEvent()
    except Exception as ex:
      if debugMode: stderr.writeLine("[gtmd] retry advance error: " & ex.msg)

    # Determine next queue path for up_next and crossfade scheduling
    var nextQueuedPath = ""
    if daemon.player.state == 1:
      if daemon.shuffleEnabled and daemon.shuffleOrder.len > 0 and daemon.shuffleIndex < daemon.shuffleOrder.len:
        nextQueuedPath = daemon.playbackQueue[daemon.shuffleOrder[daemon.shuffleIndex]]
      elif not daemon.shuffleEnabled and daemon.playbackQueue.len > 0:
        nextQueuedPath = daemon.playbackQueue[0]

    # Send "up_next" notification when near end of current track
    try:
      if nextQueuedPath.len > 0 and not daemon.upNextSent:
        let dur = daemon.player.duration
        let tpos = daemon.player.timePos
        if dur > 0.0 and tpos >= 0.0:
          let timeRemaining = dur - tpos
          if timeRemaining <= 8.0 and timeRemaining > 0.0:
            daemon.upNextSent = true
            var nextTitle = ""; var nextChannel = ""
            if isYtWatchUrl(nextQueuedPath) and daemon.lib != nil:
              let meta = daemon.lib.getDownloadMetaByUrl(nextQueuedPath)
              nextTitle = meta.title; nextChannel = meta.channel
            let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "up_next",
              "next_path": %nextQueuedPath, "next_title": %nextTitle, "next_channel": %nextChannel}]}
            daemon.broadcastAll($ev & "\n")
    except Exception as ex:
      if debugMode: stderr.writeLine("[gtmd] up_next error: " & ex.msg)

    # Crossfade scheduling
    try:
      if daemon.player.state == 1 and daemon.crossfadeDuration > 0:
        if nextQueuedPath.len > 0:
          let dur = daemon.player.duration
          let tpos = daemon.player.timePos
          if dur > 0.0 and tpos >= 0.0:
            let timeRemaining = dur - tpos
            if timeRemaining > 0.0:
              let prepareThreshold = float(daemon.crossfadeDuration) + 2.0
              if not daemon.crossfadePrepared and timeRemaining <= prepareThreshold:
                var loadNextPath = nextQueuedPath
                if isYtWatchUrl(nextQueuedPath) and daemon.lib != nil:
                  let meta = daemon.lib.getDownloadMetaByUrl(nextQueuedPath)
                  if meta.path.len > 0:
                    loadNextPath = meta.path
                  elif daemon.ytStreamResolvedFor == nextQueuedPath and daemon.ytStreamResolvedUrl.len > 0:
                    loadNextPath = daemon.ytStreamResolvedUrl
                daemon.player.prepareNext(loadNextPath)
                daemon.crossfadePrepared = true
                daemon.crossfadeNextPath = loadNextPath
              if daemon.crossfadePrepared and not daemon.crossfadeStarted and timeRemaining <= float(daemon.crossfadeDuration):
                daemon.upNextSent = true
                if daemon.shuffleEnabled and not daemon.crossfadeConsumed:
                  daemon.crossfadeConsumed = true
                  daemon.shuffleIndex.inc
                daemon.player.startCrossfade(float(daemon.crossfadeDuration))
                daemon.crossfadeStarted = true
    except Exception as ex:
      if debugMode: stderr.writeLine("[gtmd] crossfade error: " & ex.msg)
    # Background scan: process up to 10 files per iteration
    if daemon.scanningDir.len > 0 and daemon.scanningFiles.len > 0:
      let batchEnd = min(daemon.scanningIdx + 10, daemon.scanningFiles.len)
      while daemon.scanningIdx < batchEnd:
        let p = daemon.scanningFiles[daemon.scanningIdx]
        if daemon.lib != nil:
          let (ftitle, fartist) = parseFilenameForMetadata(p)
          discard daemon.lib.addTrack(p, ftitle, fartist, "", 0.0, 0, 0, "")
        daemon.scanningIdx.inc
      if daemon.scanningIdx >= daemon.scanningFiles.len:
        daemon.scanningDir = ""
        daemon.scanningFiles = @[]
        daemon.scanningIdx = 0
        let ev = %*{"events": [%*{"kind": %evCustomEvent.int, "event": "scan_done"}]}
        daemon.broadcastAll($ev & "\n")

    if daemon.sleepTimerRemaining > 0:
      daemon.sleepTimerFrames.inc
      if daemon.sleepTimerFrames >= 60:
        daemon.sleepTimerFrames = 0
        daemon.sleepTimerRemaining.dec
        if daemon.sleepTimerRemaining <= 0:
          daemon.savePlaybackState()
          when defined(useMpris):
            shutdownMpris()
          if daemon.lib != nil:
            daemon.lib.closeDb()
          daemon.player.shutdown()
          daemon.running = false
          break
    daemon.persistFrames.inc
    if daemon.persistFrames >= 1800:
      daemon.persistFrames = 0
      daemon.savePlaybackState()
    daemon.trashPurgeFrames.inc
    if daemon.trashPurgeFrames >= 18000:
      daemon.trashPurgeFrames = 0
      if daemon.lib != nil:
        for item in daemon.lib.purgeExpiredTrash():
          if fileExists(item.trashPath):
            try: removeFile(item.trashPath) except: discard
    daemon.idleFrames.inc
    if daemon.player != nil and daemon.idleFrames > daemon.idleTimeout * 60 and daemon.player.state == 0:
      daemon.savePlaybackState()
      when defined(useMpris):
        shutdownMpris()
      if daemon.lib != nil:
        daemon.lib.closeDb()
      daemon.player.shutdown()
      break
  for c in daemon.clients:
    try: c.sock.close() except: discard
  daemon.server.close()
  removeFile(sockPath())
  removePidFile()

import os, json, strutils, net, posix, random, osproc, streams, times, tables
from nativesockets import setBlocking, selectRead, SocketHandle
proc prctl(option: cint, arg2: cstring): cint {.importc, header: "<sys/prctl.h>".}
import audio, state, visualizer, library, ytdlp

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
    dckQueueAdd, dckQueueRemove, dckQueueRemovePath, dckQueueClear, dckQueueList, dckQueueSetCursor,
    dckAddFavourite, dckRemoveFavourite, dckGetFavourites, dckGetFullState,
    dckYtSearch, dckYtSearchPoll, dckYtSearchCancel,
    dckYtResolveStream, dckYtResolveStreamPoll,
    dckYtDownload, dckYtDownloadPoll, dckYtCancelDownload,
    dckYtListDownloads, dckYtFetchPlaylist, dckYtFetchPlaylistPoll,
    dckYtSetConfig, dckYtGetSearchHistory, dckYtClearSearchHistory,
    dckListEqPresets,
    dckPing

  DaemonCmd* = object
    kind*: DaemonCmdKind
    strArg*: string
    floatArg*: float
    intArg*: int
    strArg2*: string
    strArg3*: string

  Daemon* = ref object
    player: AudioBackend
    lib: LibraryDb
    viz: Visualizer
    running: bool
    server: Socket
    client: Socket
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
    playbackQueue*: seq[string]
    shuffleOrder*: seq[int]
    shuffleIndex*: int
    crossfadeDuration*: int
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
    ytJsRuntime: string
    ytDownloadDir: string
    ytMaxConcurrentDownloads: int
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
    ytStreamUrls: Table[string, string]
    ytStreamResolveProcess: Process
    ytStreamResolveBuf: string
    ytStreamResolveUrl: string
    ytStreamResolving: bool
    ytDownloadTasks: seq[DownloadTask]
    ytDownloaded: Table[string, string]
    ytDownloadedMeta: Table[string, tuple[title, channel: string]]
    ytLastCompletedPath: string
    ytLastCompletedUrl: string
    ytPlaylistProcess: Process
    ytPlaylistBuf: string
    ytPlaylistActive: bool
    ytPlaylistResult: YtPlaylistDetail
    ytPlaylistUrl: string

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
    of "list_eq_presets":
      result.kind = dckListEqPresets
    of "ping":
      result.kind = dckPing
    else: result.kind = dckStatus
  except:
    result.kind = dckStatus

proc serializeEvents(events: seq[AudioEvent]; d: Daemon = nil): JsonNode =
  result = newJArray()
  for ev in events:
    var obj = %*{"kind": %ev.kind.int}
    case ev.kind
    of aekPositionChanged: obj["time_pos"] = %ev.floatVal
    of aekDurationChanged: obj["duration"] = %ev.floatVal
    of aekVolumeChanged: obj["volume"] = %ev.intVal
    of aekPlaybackStarted:
      obj["state"] = %"playing"
      if d != nil:
        obj["track_path"] = %d.currentTrackPath
        obj["track_title"] = %d.currentTrackTitle
        obj["track_channel"] = %d.currentTrackChannel
        obj["auto_advanced"] = %d.autoAdvancing
    of aekPlaybackPaused: obj["state"] = %"paused"
    of aekPlaybackStopped: obj["state"] = %"stopped"
    of aekTrackEnded: obj["reason"] = %"eof"
    of aekMetadataChanged:
      if ev.strVal.len > 0: obj["event"] = %ev.strVal
    else: discard
    result.add(obj)

proc sendQueueEvent(d: Daemon) =
  if d.client == nil: return
  var qArr = newJArray()
  for p in d.playbackQueue: qArr.add(%p)
  var soArr = newJArray()
  for i in d.shuffleOrder: soArr.add(%i)
  let ev = %*{"events": [%*{"kind": %aekCustomEvent.int, "event": "queue_changed",
    "queue": qArr, "shuffleOrder": soArr, "shuffleIndex": %d.shuffleIndex}]}
  discard trySend(d.client, $ev & "\n")

proc savePlaybackState(d: Daemon) =
  if d.lib != nil:
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
    d.lib.setPlaybackState("yt_cookie_source", d.ytCookieSource)
    d.lib.setPlaybackState("yt_js_runtime", d.ytJsRuntime)
    d.lib.setPlaybackState("yt_download_dir", d.ytDownloadDir)
    d.lib.setPlaybackState("yt_max_concurrent", $(d.ytMaxConcurrentDownloads))
    var qArr = newJArray()
    for p in d.playbackQueue:
      qArr.add(%p)
    d.lib.setPlaybackState("queue_json", $qArr)


proc shuffleOrder(count: int): seq[int] =
  result = newSeq[int](count)
  for i in 0..<count:
    result[i] = i
  for i in countup(0, count - 2):
    let j = rand(i..<count)
    swap(result[i], result[j])

proc nextTrackFromQueue(d: Daemon): string =
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
      if nextCandidate in d.ytDownloaded:
        loadPath = d.ytDownloaded[nextCandidate]
        if nextCandidate in d.ytDownloadedMeta:
          d.currentTrackTitle = d.ytDownloadedMeta[nextCandidate].title
          d.currentTrackChannel = d.ytDownloadedMeta[nextCandidate].channel
      elif nextCandidate in d.ytStreamUrls:
        loadPath = d.ytStreamUrls[nextCandidate]
        # Ensure download is running in background
        var alreadyDL = false
        for t in d.ytDownloadTasks:
          if t.url == nextCandidate: alreadyDL = true; break
        if not alreadyDL and d.lib != nil:
          var meta = if nextCandidate in d.ytDownloadedMeta: d.ytDownloadedMeta[nextCandidate] else: (title: "", channel: "")
          var task: DownloadTask
          if startDownload(YtSearchResult(url: nextCandidate, title: meta.title, channel: meta.channel), d.ytDownloadDir, task.process, d.ytCookieSource, d.ytJsRuntime):
            task.title = meta.title; task.url = nextCandidate; task.channel = meta.channel
            task.outputDir = d.ytDownloadDir; task.completed = false; task.startedAt = epochTime()
            d.ytDownloadTasks.add(task)
      else:
        # Start resolving stream URL and retry next frame
        if not d.ytStreamResolving or d.ytStreamResolveUrl != nextCandidate:
          try: d.ytStreamResolveProcess.terminate() except: discard
          close(d.ytStreamResolveProcess)
          d.ytStreamResolveBuf = ""
          d.ytStreamResolveUrl = nextCandidate
          discard startStreamUrlFetch(nextCandidate, d.ytStreamResolveProcess, d.ytCookieSource, d.ytJsRuntime)
          d.ytStreamResolving = true
        return false
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
      d.player.loadFile(loadPath)
      d.currentTrackPath = loadPath
      d.player.play()
    d.idleFrames = 0
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
      d.player.stop()
      d.player.loadFile(cmd.strArg)
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
    d.player.play(); d.idleFrames = 0
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckPause:
    d.player.pause(); d.viz.clear()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckTogglePause:
    d.player.togglePause(); d.idleFrames = 0
    if d.player.state == 2: d.viz.clear()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckStop:
    d.player.stop()
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckSeek:
    d.player.seek(cmd.floatArg)
    when defined(useMpris):
      let pos = int64(d.player.timePos * 1_000_000)
      emitMprisSeeked(pos)
  of dckNext:
    d.autoAdvancing = false
    discard d.advanceToNextTrack(true)
    when defined(useMpris):
      emitMprisPlayerChanged(d)
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
        d.player.startCrossfade(float(d.crossfadeDuration))
        d.currentTrackPath = prevPath
        d.currentTrackTitle = ""
        d.currentTrackChannel = ""
        d.crossfadePrepared = false
        d.crossfadeStarted = false
        d.crossfadeNextPath = ""
        d.crossfadeConsumed = false
      else:
        d.player.stop()
        d.player.loadFile(prevPath)
        d.currentTrackPath = prevPath
        d.currentTrackTitle = ""
        d.currentTrackChannel = ""
        d.player.play()
      d.idleFrames = 0
      when defined(useMpris):
        emitMprisPlayerChanged(d)
      if d.lib != nil:
        var trackId = d.lib.findTrackByPath(prevPath)
        if trackId > 0:
          d.lib.updatePlayCount(trackId)
          result["track_id"] = %trackId
    else:
      d.player.stop()
      d.idleFrames = 0
      when defined(useMpris):
        emitMprisPlayerChanged(d)
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
    d.viz.stopCapture()
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
    when defined(useMpris):
      emitMprisPlayerChanged(d)
  of dckSetRepeat:
    d.repeatMode = cmd.intArg
    result["repeat"] = %d.repeatMode
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
            if isYtWatchUrl(path) and path notin d.ytDownloaded:
              var alreadyDL = false
              for task in d.ytDownloadTasks:
                if task.url == path:
                  alreadyDL = true
                  break
              if not alreadyDL:
                var task: DownloadTask
                if startDownload(YtSearchResult(url: path, title: title, channel: channel), d.ytDownloadDir, task.process, d.ytCookieSource, d.ytJsRuntime):
                  task.title = title
                  task.url = path
                  task.channel = channel
                  task.outputDir = d.ytDownloadDir
                  task.completed = false
                  task.startedAt = epochTime()
                  d.ytDownloadTasks.add(task)
                else:
                  stderr.writeLine("[gtm] Failed to start download for: " & path)
              # Also start resolving stream URL for instant playback
              if path notin d.ytStreamUrls and not d.ytStreamResolving:
                d.ytStreamResolveBuf = ""
                d.ytStreamResolveUrl = path
                discard startStreamUrlFetch(path, d.ytStreamResolveProcess, d.ytCookieSource, d.ytJsRuntime)
                d.ytStreamResolving = true
        result["queue_length"] = %d.playbackQueue.len
      except: stderr.writeLine("[gtm] queueAdd error: " & getCurrentExceptionMsg())
  of dckQueueRemove:
    if cmd.intArg >= 0 and cmd.intArg < d.playbackQueue.len:
      d.playbackQueue.delete(cmd.intArg)
  of dckQueueRemovePath:
    if cmd.strArg.len > 0:
      let idx = d.playbackQueue.find(cmd.strArg)
      if idx >= 0:
        d.playbackQueue.delete(idx)
  of dckQueueClear:
    d.playbackQueue = @[]
    d.shuffleOrder = @[]
    d.shuffleIndex = 0
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
    result["crossfadeDuration"] = %d.crossfadeDuration
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
    d.ytSearchActive = startYoutubeSearch(cmd.strArg, d.ytSearchProcess, d.ytCookieSource, cmd.intArg)
    if d.ytSearchActive and d.lib != nil:
      d.lib.addSearchQuery(cmd.strArg)
    result["active"] = %d.ytSearchActive
  of dckYtSearchPoll:
    if d.ytSearchActive:
      let newResults = pollYoutubeSearch(d.ytSearchProcess, d.ytSearchBuf)
      for r in newResults:
        d.ytSearchResults.add(r)
      if not d.ytSearchProcess.running():
        let finalResults = finishYoutubeSearch(d.ytSearchProcess, d.ytSearchBuf)
        for r in finalResults:
          d.ytSearchResults.add(r)
        d.ytSearchActive = false
        d.ytSearchBuf = ""
      var arr = newJArray()
      for r in d.ytSearchResults:
        arr.add(%*{"title": %r.title, "url": %r.url, "duration": %r.duration, "channel": %r.channel, "kind": %r.kind.int})
      result["results"] = arr
      result["done"] = %(not d.ytSearchActive)
    else:
      result["done"] = %true
      result["results"] = newJArray()
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
    d.ytStreamActive = startStreamUrlFetch(cmd.strArg, d.ytStreamProcess, d.ytCookieSource, d.ytJsRuntime)
    result["active"] = %d.ytStreamActive
  of dckYtResolveStreamPoll:
    if d.ytStreamActive:
      if not d.ytStreamProcess.running():
        d.ytStreamResultUrl = pollStreamUrlFetch(d.ytStreamProcess, d.ytStreamBuf)
        d.ytStreamActive = false
        d.ytStreamBuf = ""
      result["url"] = %d.ytStreamResultUrl
      result["title"] = %d.ytStreamPendingTitle
      result["channel"] = %d.ytStreamPendingChannel
      result["done"] = %(not d.ytStreamActive)
    else:
      result["done"] = %true
      result["url"] = %""
  of dckYtDownload:
    if cmd.strArg.len > 0:
      var task: DownloadTask
      if startDownload(YtSearchResult(url: cmd.strArg, title: cmd.strArg2, channel: cmd.strArg3), d.ytDownloadDir, task.process, d.ytCookieSource, d.ytJsRuntime):
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
    let timeout = 600.0
    var done: seq[int] = @[]
    for i in 0..<d.ytDownloadTasks.len:
      if not d.ytDownloadTasks[i].completed:
        let p = d.ytDownloadTasks[i].process
        if epochTime() - d.ytDownloadTasks[i].startedAt > timeout:
          try: p.terminate() except: discard
          close(p)
          d.ytDownloadTasks[i].completed = true
          done.add(i)
        elif not p.running():
          var path = ""
          try: path = pollDownload(d.ytDownloadTasks[i].process, d.ytDownloadTasks[i].buf)
          except: discard
          d.ytDownloadTasks[i].completed = true
          done.add(i)
          if path.len > 0:
            d.ytDownloaded[d.ytDownloadTasks[i].url] = path
            d.ytLastCompletedPath = path
            d.ytLastCompletedUrl = d.ytDownloadTasks[i].url
            if d.lib != nil:
              d.lib.addDownload(d.ytDownloadTasks[i].url, path, d.ytDownloadTasks[i].title, d.ytDownloadTasks[i].channel)
              d.lib.updateTrackPath(d.ytDownloadTasks[i].url, path, d.ytDownloadTasks[i].title)
      else:
        done.add(i)
    for i in countdown(done.len - 1, 0):
      d.ytDownloadTasks.delete(done[i])
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
    for url, path in d.ytDownloaded:
      completedArr.add(%*{"url": %url, "path": %path})
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
      if startPlaylistFetch(cmd.strArg, d.ytPlaylistProcess, d.ytCookieSource, d.ytJsRuntime):
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
    if not d.ytPlaylistActive:
      result["ok"] = %false
      result["error"] = %"no active playlist fetch"
    else:
      let p = d.ytPlaylistProcess
      let tracks = pollPlaylistFetch(d.ytPlaylistProcess, d.ytPlaylistBuf)
      for t in tracks:
        d.ytPlaylistResult.tracks.add(t)
      if not p.running():
        # Drain remaining output
        let finalTracks = finishPlaylistFetch(d.ytPlaylistProcess, d.ytPlaylistBuf)
        for t in finalTracks:
          d.ytPlaylistResult.tracks.add(t)
        # Parse title/channel from first result
        if d.ytPlaylistResult.tracks.len > 0:
          let first = d.ytPlaylistResult.tracks[0]
          if d.ytPlaylistResult.title.len == 0:
            # Try to get playlist title from first result metadata or URL
            d.ytPlaylistResult.title = "Playlist"
            d.ytPlaylistResult.channel = first.channel
        # Build response with all accumulated tracks
        var tracksArr = newJArray()
        for t in d.ytPlaylistResult.tracks:
          tracksArr.add(%*{"title": %t.title, "url": %t.url, "duration": %t.duration, "channel": %t.channel, "kind": %t.kind.int})
        result["title"] = %d.ytPlaylistResult.title
        result["channel"] = %d.ytPlaylistResult.channel
        result["tracks"] = tracksArr
        result["track_count"] = %d.ytPlaylistResult.trackCount
        result["done"] = %true
        d.ytPlaylistActive = false
        d.ytPlaylistBuf = ""
      else:
        result["ok"] = %true
        result["pending"] = %true
  of dckYtSetConfig:
    d.ytCookieSource = cmd.strArg
    d.ytJsRuntime = cmd.strArg2
    if cmd.strArg3.len > 0: d.ytDownloadDir = cmd.strArg3
    if cmd.intArg > 0: d.ytMaxConcurrentDownloads = cmd.intArg
    result["cookie_source"] = %d.ytCookieSource
    result["js_runtime"] = %d.ytJsRuntime
    result["download_dir"] = %d.ytDownloadDir
    result["max_concurrent"] = %d.ytMaxConcurrentDownloads
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
    result["presets"] = %["Flat", "Rock", "Pop", "Classical", "Jazz", "HipHop", "Vocal", "BassBoost", "Headphones", "Laptop"]
  of dckPing:
    result["pong"] = %true


proc trySend(client: Socket, data: string): bool =
  if data.len == 0: return true
  var remaining = data
  var retries = 200
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
      stderr.writeLine("[gtmd] GTM Daemon v" & GTM_VERSION & " starting — pid: " & $getpid() & ", socket: " & sockPath())
    else:
      discard dup2(cint(crashFd), cint(1))
      discard dup2(cint(crashFd), cint(2))
  discard prctl(15.cint, "gtmd")
  writePidFile()
  setupSignalHandlers()
  var player: AudioBackend
  when defined(useFFmpeg):
    player = newMixerBackend()
    if not player.working:
      echo "[gtm] Mixer backend unavailable (ALSA?), trying FFmpeg fallback"
      player = newFfmpegBackend()
    if not player.working:
      echo "[gtm] FFmpeg backend unavailable, trying process backend (mpv/ffplay)"
      player = newProcessBackend()
  else:
    player = nil
  if player == nil or not player.working:
    stderr.writeLine("[gtm] All audio backends unavailable")
  let defaultDownloadDir = dataDir() & "/audio"
  var daemon = Daemon(
    player: player,
    viz: newVisualizer(),
    running: true,
    idleTimeout: 300,
    shuffleEnabled: false,
    repeatMode: 0,
    sleepTimerRemaining: 0,
    sleepTimerFrames: 0,
    persistFrames: 0,
    playbackQueue: @[],
    trackHistory: @[],
    shuffleOrder: @[],
    shuffleIndex: 0,
    crossfadeDuration: 0,
    crossfadePrepared: false,
    crossfadeStarted: false,
    crossfadeNextPath: "",
    scanningDir: "",
    scanningFiles: @[],
    scanningIdx: 0,
    ytCookieSource: "",
    ytJsRuntime: "",
    ytDownloadDir: defaultDownloadDir,
    ytMaxConcurrentDownloads: 4,
    ytSearchActive: false,
    ytStreamActive: false,
    ytStreamResultUrl: "",
    ytDownloaded: initTable[string, string](),
    ytDownloadedMeta: initTable[string, tuple[title, channel: string]](),
    ytLastCompletedPath: "",
    ytLastCompletedUrl: "",
    ytPlaylistActive: false,
    ytPlaylistBuf: "",
    ytPlaylistUrl: ""
  )
  daemon.viz.startCapture()
  when defined(useMpris):
    initMpris(daemon)
  let libPath = dataDir() & "/gtm.db"
  if not dirExists(dataDir()):
    createDir(dataDir())
  daemon.lib = openLibrary(libPath)
  if daemon.lib != nil:
    daemon.lib.initSchema()
    let volStr = daemon.lib.getPlaybackState("volume")
    if volStr.len > 0:
      try: daemon.player.setVolume(parseInt(volStr)) except: discard
    let trackPath = daemon.lib.getPlaybackState("track_path")
    let trackTitle = daemon.lib.getPlaybackState("track_title")
    let trackChannel = daemon.lib.getPlaybackState("track_channel")
    if trackPath.len > 0 and fileExists(trackPath):
      daemon.player.loadFile(trackPath)
      daemon.currentTrackPath = trackPath
      daemon.currentTrackTitle = trackTitle
      daemon.currentTrackChannel = trackChannel
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
    let ytCookie = daemon.lib.getPlaybackState("yt_cookie_source")
    if ytCookie.len > 0: daemon.ytCookieSource = ytCookie
    let ytJs = daemon.lib.getPlaybackState("yt_js_runtime")
    if ytJs.len > 0: daemon.ytJsRuntime = ytJs
    let ytDlDir = daemon.lib.getPlaybackState("yt_download_dir")
    if ytDlDir.len > 0: daemon.ytDownloadDir = ytDlDir
    let ytMax = daemon.lib.getPlaybackState("yt_max_concurrent")
    if ytMax.len > 0:
      try: daemon.ytMaxConcurrentDownloads = parseInt(ytMax) except: discard
    # Restore completed downloads from database
    for dl in daemon.lib.getDownloads():
      daemon.ytDownloaded[dl.url] = dl.path
    let queueStr = daemon.lib.getPlaybackState("queue_json")
    if queueStr.len > 0:
      try:
        let qj = parseJson(queueStr)
        daemon.playbackQueue = @[]
        for p in qj:
          daemon.playbackQueue.add(p.getStr(""))
      except: discard
    # Auto-scan download directory for files not yet in library
    if dirExists(daemon.ytDownloadDir):
      let existing = scanDirectoryRecursive(daemon.ytDownloadDir)
      for p in existing:
        if daemon.lib.findTrackByPath(p) == 0:
          let (_, name, _) = p.splitFile()
          discard daemon.lib.addTrack(p, name, "", "", 0.0, 0, 0, "")
  removeFile(sockPath())
  let srvFd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  daemon.server = newSocket(srvFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
  daemon.server.bindUnix(sockPath())
  daemon.server.listen()
  var buf = ""
  while daemon.running:
    when defined(useMpris):
      pollMpris()
    var readFds: seq[SocketHandle] = @[daemon.server.getFd]
    if daemon.client != nil:
      readFds.add(daemon.client.getFd)
    if selectRead(readFds, 16) > 0:
      if daemon.server.getFd in readFds:
        var clientAddr: posix.Sockaddr_un
        var addrLen = posix.SockLen(sizeof(clientAddr))
        let cliFd = posix.accept(daemon.server.getFd,
          cast[ptr posix.SockAddr](addr(clientAddr)), addr(addrLen))
        if cliFd.int >= 0:
          if daemon.client != nil:
            daemon.client.close()
          daemon.cleanupClientState()
          daemon.client = newSocket(cliFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
          setBlocking(daemon.client.getFd, false)
          buf = ""
          daemon.idleFrames = 0
      if daemon.client != nil and daemon.client.getFd in readFds:
        var tmp: array[4096, char]
        let n = posix.recv(daemon.client.getFd, addr tmp[0], tmp.len.cint, 0)
        if n < 0:
          let err = osLastError()
          if err.int32 != 11 and err.int32 != 10035:
            daemon.client.close()
            daemon.cleanupClientState()
            daemon.client = nil
            buf = ""
        elif n == 0:
          daemon.client.close()
          daemon.cleanupClientState()
          daemon.client = nil
          buf = ""
        else:
          let old = buf.len; buf.setLen(old + n); copyMem(addr buf[old], addr tmp[0], n)
          while true:
            let nli = buf.find('\n')
            if nli < 0: break
            let line = buf[0..<nli]
            buf = buf[nli+1..^1]
            if line.len > 0:
              if debugMode: stderr.writeLine("[gtm] daemon recv: " & line)
              let cmd = parseDaemonCommand(line)
              let resp = try:
                executeCommand(daemon, cmd)
              except Exception as ex:
                if debugMode: stderr.writeLine("[gtm] command error: " & ex.msg)
                %*{"ok": false, "error": ex.msg}
              let respStr = $resp & "\n"
              if debugMode: stderr.writeLine("[gtm] daemon resp: " & respStr.strip())
              if not trySend(daemon.client, respStr):
                daemon.cleanupClientState()
                daemon.client = nil
                buf = ""
              if not daemon.running: break
    let daemonEvents = daemon.player.pollEvents()
    if daemonEvents.len > 0 and daemon.client != nil:
      let evJson = %*{"events": serializeEvents(daemonEvents, daemon)}
      if not trySend(daemon.client, $evJson & "\n"):
        daemon.cleanupClientState()
        daemon.client = nil
    # Auto-advance on track ended
    for ev in daemonEvents:
      if ev.kind == aekTrackEnded:
        if daemon.crossfadeNextPath.len > 0:
          daemon.currentTrackPath = daemon.crossfadeNextPath
          daemon.upNextSent = false
          if daemon.lib != nil:
            let cfId = daemon.lib.findTrackByPath(daemon.crossfadeNextPath)
            if cfId > 0:
              daemon.lib.updatePlayCount(cfId)
          daemon.crossfadePrepared = false
          daemon.crossfadeStarted = false
          daemon.crossfadeConsumed = false
          daemon.crossfadeNextPath = ""
          daemon.sendQueueEvent()
        elif daemon.playbackQueue.len > 0:
          discard daemon.advanceToNextTrack(true)
          daemon.sendQueueEvent()
        when defined(useMpris):
          emitMprisPlayerChanged(daemon)

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
            daemon.ytDownloaded[dlUrl] = path
            daemon.ytDownloadedMeta[dlUrl] = (title: daemon.ytDownloadTasks[i].title, channel: daemon.ytDownloadTasks[i].channel)
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
            if daemon.client != nil:
              let ev = %*{"events": [%*{"kind": %aekCustomEvent.int, "event": "yt_download_done", "url": %dlUrl, "path": %path, "title": %daemon.ytDownloadTasks[i].title}]}
              if not trySend(daemon.client, $ev & "\n"):
                daemon.cleanupClientState()
                daemon.client = nil
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
          daemon.ytStreamUrls[daemon.ytStreamResolveUrl] = url
          daemon.ytStreamResolveUrl = ""

    # Retry advancing if player stopped with items pending (e.g. waiting for YT download)
    if daemon.player.state == 0 and daemon.playbackQueue.len > 0:
      if daemon.advanceToNextTrack(true):
        daemon.sendQueueEvent()

    # Determine next queue path for up_next and crossfade scheduling
    var nextQueuedPath = ""
    if daemon.player.state == 1:
      if daemon.shuffleEnabled and daemon.shuffleOrder.len > 0 and daemon.shuffleIndex < daemon.shuffleOrder.len:
        nextQueuedPath = daemon.playbackQueue[daemon.shuffleOrder[daemon.shuffleIndex]]
      elif not daemon.shuffleEnabled and daemon.playbackQueue.len > 0:
        nextQueuedPath = daemon.playbackQueue[0]

    # Send "up_next" notification when near end of current track
    if nextQueuedPath.len > 0 and not daemon.upNextSent:
      let dur = daemon.player.duration
      let tpos = daemon.player.timePos
      if dur > 0.0 and tpos >= 0.0:
        let timeRemaining = dur - tpos
        if timeRemaining <= 8.0 and timeRemaining > 0.0:
          daemon.upNextSent = true
          var nextTitle = ""; var nextChannel = ""
          if isYtWatchUrl(nextQueuedPath) and nextQueuedPath in daemon.ytDownloadedMeta:
            nextTitle = daemon.ytDownloadedMeta[nextQueuedPath].title
            nextChannel = daemon.ytDownloadedMeta[nextQueuedPath].channel
          if daemon.client != nil:
            let ev = %*{"events": [%*{"kind": %aekCustomEvent.int, "event": "up_next",
              "next_path": %nextQueuedPath, "next_title": %nextTitle, "next_channel": %nextChannel}]}
            discard trySend(daemon.client, $ev & "\n")

    # Crossfade scheduling
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
              if isYtWatchUrl(nextQueuedPath) and nextQueuedPath in daemon.ytDownloaded:
                loadNextPath = daemon.ytDownloaded[nextQueuedPath]
              elif isYtWatchUrl(nextQueuedPath) and nextQueuedPath in daemon.ytStreamUrls:
                loadNextPath = daemon.ytStreamUrls[nextQueuedPath]
              daemon.player.prepareNext(loadNextPath)
              daemon.crossfadePrepared = true
              daemon.crossfadeNextPath = loadNextPath
            if daemon.crossfadePrepared and not daemon.crossfadeStarted and timeRemaining <= float(daemon.crossfadeDuration):
              daemon.upNextSent = true
              if not daemon.crossfadeConsumed:
                daemon.crossfadeConsumed = true
                if daemon.shuffleEnabled:
                  daemon.shuffleIndex.inc
                elif daemon.playbackQueue.len > 0 and daemon.playbackQueue[0] == daemon.crossfadeNextPath:
                  daemon.playbackQueue.delete(0)
                  if daemon.repeatMode == 1:
                    daemon.playbackQueue.add(daemon.crossfadeNextPath)
              daemon.player.startCrossfade(float(daemon.crossfadeDuration))
              daemon.crossfadeStarted = true
              daemon.sendQueueEvent()
    # Background scan: process up to 10 files per iteration
    if daemon.scanningDir.len > 0 and daemon.scanningFiles.len > 0:
      let batchEnd = min(daemon.scanningIdx + 10, daemon.scanningFiles.len)
      while daemon.scanningIdx < batchEnd:
        let p = daemon.scanningFiles[daemon.scanningIdx]
        let (_, name, _) = p.splitFile()
        if daemon.lib != nil:
          discard daemon.lib.addTrack(p, name, "", "", 0.0, 0, 0, "")
        daemon.scanningIdx.inc
      if daemon.scanningIdx >= daemon.scanningFiles.len:
        daemon.scanningDir = ""
        daemon.scanningFiles = @[]
        daemon.scanningIdx = 0
        if daemon.client != nil:
          let ev = %*{"events": [%*{"kind": %aekCustomEvent.int, "event": "scan_done"}]}
          discard trySend(daemon.client, $ev & "\n")

    daemon.viz.readPcm()
    var pcmBuf: seq[float32] = @[]
    daemon.player.readPcmFrames(pcmBuf, 512)
    if pcmBuf.len > 0:
      daemon.viz.writePcm(pcmBuf)
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
          daemon.viz.stopCapture()
          daemon.player.shutdown()
          daemon.running = false
          break
    daemon.persistFrames.inc
    if daemon.persistFrames >= 1800:
      daemon.persistFrames = 0
      daemon.savePlaybackState()
    daemon.idleFrames.inc
    if daemon.idleFrames > daemon.idleTimeout * 60 and daemon.player.state == 0:
      daemon.savePlaybackState()
      when defined(useMpris):
        shutdownMpris()
      if daemon.lib != nil:
        daemon.lib.closeDb()
      daemon.viz.stopCapture()
      daemon.player.shutdown()
      break
  if daemon.client != nil: daemon.client.close()
  daemon.server.close()
  removeFile(sockPath())
  removePidFile()

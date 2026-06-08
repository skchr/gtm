import os, json, strutils, net, posix
from nativesockets import setBlocking, selectRead, SocketHandle
proc prctl(option: cint, arg2: cstring): cint {.importc, header: "<sys/prctl.h>".}
import audio, state, visualizer, library

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
    dckGetLibrary, dckAddTrack

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
    idleFrames: int
    idleTimeout: int
    shuffleEnabled*: bool
    repeatMode*: int
    sleepTimerRemaining*: int
    sleepTimerFrames*: int

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
    else: result.kind = dckStatus
  except:
    result.kind = dckStatus

proc serializeEvents(events: seq[AudioEvent]): JsonNode =
  result = newJArray()
  for ev in events:
    var obj = %*{"kind": %ev.kind.int}
    case ev.kind
    of aekPositionChanged: obj["time_pos"] = %ev.floatVal
    of aekDurationChanged: obj["duration"] = %ev.floatVal
    of aekVolumeChanged: obj["volume"] = %ev.intVal
    of aekPlaybackStarted: obj["state"] = %"playing"
    of aekPlaybackPaused: obj["state"] = %"paused"
    of aekPlaybackStopped: obj["state"] = %"stopped"
    of aekTrackEnded: obj["reason"] = %"eof"
    else: discard
    result.add(obj)

proc executeCommand(d: Daemon, cmd: DaemonCmd): JsonNode =
  result = %*{"ok": true}
  if d.player == nil:
    result["ok"] = %false
    result["error"] = %"no audio backend"
    return
  case cmd.kind
  of dckLoadFile:
    if cmd.strArg.len > 0:
      d.player.stop()
      d.player.loadFile(cmd.strArg)
      d.currentTrackPath = cmd.strArg
      d.currentTrackTitle = cmd.strArg2
      d.currentTrackChannel = cmd.strArg3
      d.player.play()
      d.idleFrames = 0
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
  of dckPlay:
    d.player.play(); d.idleFrames = 0
  of dckPause:
    d.player.pause(); d.viz.clear()
  of dckTogglePause:
    d.player.togglePause(); d.idleFrames = 0
    if d.player.state == 2: d.viz.clear()
  of dckStop:
    d.player.stop()
  of dckSeek:
    d.player.seek(cmd.floatArg)
  of dckNext, dckPrev:
    d.player.stop()
    d.idleFrames = 0
  of dckSetVolume:
    d.player.setVolume(cmd.intArg)
  of dckGetVolume:
    result["volume"] = %d.player.volume
  of dckQuit:
    let stateStr = $(d.player.state)
    if d.lib != nil:
      d.lib.setPlaybackState("volume", $d.player.volume)
      d.lib.setPlaybackState("time_pos", $d.player.timePos)
      d.lib.setPlaybackState("track_path", d.currentTrackPath)
      d.lib.setPlaybackState("track_title", d.currentTrackTitle)
      d.lib.setPlaybackState("track_channel", d.currentTrackChannel)
      d.lib.setPlaybackState("state", stateStr)
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
      let paths = scanDirectoryRecursive(cmd.strArg)
      for p in paths:
        let (_, name, _) = p.splitFile()
        if d.lib != nil:
          discard d.lib.addTrack(p, name, "", "", 0.0, 0, 0, "")
  of dckSetShuffle:
    d.shuffleEnabled = cmd.intArg != 0
    result["shuffle"] = %d.shuffleEnabled
  of dckSetRepeat:
    d.repeatMode = cmd.intArg
    result["repeat"] = %d.repeatMode
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

proc trySend(client: Socket, data: string): bool =
  if data.len == 0: return true
  let n = posix.send(client.getFd, addr data[0], data.len.cint, 0.cint)
  if n >= 0: return true
  let err = osLastError()
  if err.int32 == 11 or err.int32 == 10035:
    return true
  try: client.close() except: discard
  return false

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
    if not debugMode:
      discard dup2(cint(crashFd), cint(1))
    discard dup2(cint(crashFd), cint(2))
  discard prctl(15.cint, "gtmd")
  writePidFile()
  setupSignalHandlers()
  var player: AudioBackend
  when defined(useFFmpeg):
    player = newMixerBackend()
    if not player.working:
      player = newFfmpegBackend()
  else:
    player = nil
  if player == nil or not player.working:
    stderr.writeLine("[gtm] FFmpeg unavailable, trying process backend (mpv/ffplay)")
    player = newProcessBackend()
  var daemon = Daemon(
    player: player,
    viz: newVisualizer(),
    running: true,
    idleTimeout: 300,
    shuffleEnabled: false,
    repeatMode: 0,
    sleepTimerRemaining: 0,
    sleepTimerFrames: 0
  )
  daemon.viz.startCapture()
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
  removeFile(sockPath())
  let srvFd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  daemon.server = newSocket(srvFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
  daemon.server.bindUnix(sockPath())
  daemon.server.listen()
  var buf = ""
  while daemon.running:
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
          daemon.client = newSocket(cliFd, Domain.AF_UNIX, SockType.SOCK_STREAM)
          setBlocking(daemon.client.getFd, false)
      if daemon.client != nil and daemon.client.getFd in readFds:
        var tmp: array[4096, char]
        let n = posix.recv(daemon.client.getFd, addr tmp[0], tmp.len.cint, 0)
        if n < 0:
          let err = osLastError()
          if err.int32 != 11 and err.int32 != 10035:
            daemon.client.close()
            daemon.client = nil
            buf = ""
        elif n == 0:
          daemon.client.close()
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
                daemon.client = nil
                buf = ""
              if not daemon.running: break
    let daemonEvents = daemon.player.pollEvents()
    if daemonEvents.len > 0 and daemon.client != nil:
      let evJson = %*{"events": serializeEvents(daemonEvents)}
      if not trySend(daemon.client, $evJson & "\n"):
        daemon.client = nil
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
          if daemon.lib != nil:
            daemon.lib.setPlaybackState("volume", $daemon.player.volume)
            daemon.lib.setPlaybackState("time_pos", $daemon.player.timePos)
            daemon.lib.setPlaybackState("track_path", daemon.currentTrackPath)
            daemon.lib.setPlaybackState("track_title", daemon.currentTrackTitle)
            daemon.lib.setPlaybackState("track_channel", daemon.currentTrackChannel)
            daemon.lib.closeDb()
          daemon.viz.stopCapture()
          daemon.player.shutdown()
          daemon.running = false
          break
    daemon.idleFrames.inc
    if daemon.idleFrames > daemon.idleTimeout * 60 and daemon.player.state == 0:
      if daemon.lib != nil:
        daemon.lib.setPlaybackState("volume", $daemon.player.volume)
        daemon.lib.setPlaybackState("time_pos", $daemon.player.timePos)
        daemon.lib.setPlaybackState("track_path", daemon.currentTrackPath)
        daemon.lib.setPlaybackState("track_title", daemon.currentTrackTitle)
        daemon.lib.setPlaybackState("track_channel", daemon.currentTrackChannel)
        daemon.lib.closeDb()
      daemon.viz.stopCapture()
      daemon.player.shutdown()
      break
  if daemon.client != nil: daemon.client.close()
  daemon.server.close()
  removeFile(sockPath())
  removePidFile()

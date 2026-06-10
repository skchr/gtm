import os, json, strutils, net, osproc, posix
from nativesockets import setBlocking
import state, audio

type
  DaemonClient* = ref object of AudioBackend
    sock: Socket
    connected*: bool
    buf: string
    sleepTimerRemaining*: int
    lastTrackId*: int64
    drainedEvents: seq[AudioEvent]

proc daemonIsRunning*(): bool =
  let p = pidPath()
  if fileExists(p):
    try:
      let pid = readFile(p).strip().parseInt()
      if pid > 0:
        result = posix.kill(pid.cint, 0) == 0
    except:
      result = false

proc startDaemonProcess*() =
  let selfPath = getAppFilename()
  let daemonBin = selfPath.parentDir() / "gtmd"
  let daemonArgs = if debugMode: @["--debug"] else: @[]
  if fileExists(daemonBin):
    discard startProcess(daemonBin, args = daemonArgs,
      options = {poUsePath, poParentStreams})
  elif fileExists(findExe("gtmd")):
    discard startProcess("gtmd", args = daemonArgs,
      options = {poUsePath, poParentStreams})
  else:
    stderr.writeLine("[gtm] gtmd not found, trying fallback to self")
    discard startProcess(selfPath, args = @["daemon"] & daemonArgs,
      options = {poUsePath, poParentStreams})

proc connectToDaemon*(cli: DaemonClient): bool =
  if cli.connected and cli.sock != nil:
    try: cli.sock.close() except: stderr.writeLine("[gtm] connectToDaemon close: " & getCurrentExceptionMsg())
  cli.connected = false
  try:
    let fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
    cli.sock = newSocket(fd, Domain.AF_UNIX, SockType.SOCK_STREAM)
    cli.sock.connectUnix(sockPath())
    setBlocking(cli.sock.getFd, false)
    cli.connected = true
    cli.backendType = abtDaemon
    return true
  except:
    cli.sock = nil
    return false

proc ensureDaemon*(cli: DaemonClient) =
  if cli == nil: return
  if cli.connected: return
  if not daemonIsRunning():
    startDaemonProcess()
    for i in 0..30:
      os.sleep(20)
      if daemonIsRunning(): break
  for i in 0..15:
    if connectToDaemon(cli): return
    os.sleep(20)

proc drainEventLines(cli: DaemonClient, buf: var string) =
  cli.drainedEvents = @[]
  while true:
    let nli = buf.find('\n')
    if nli < 0: break
    let line = buf[0..<nli]
    buf = buf[nli+1..^1]
    if line.len == 0: continue
    try:
      let j = parseJson(line)
      if not j.hasKey("events"):
        buf = line & "\n" & buf
        break
      for evJson in j["events"]:
        var ev = AudioEvent()
        let k = evJson{"kind"}.getInt(0)
        ev.kind = AudioEventKind(k)
        case ev.kind
        of aekPositionChanged: ev.floatVal = evJson{"time_pos"}.getFloat(0.0)
        of aekDurationChanged: ev.floatVal = evJson{"duration"}.getFloat(0.0)
        of aekVolumeChanged: ev.intVal = evJson{"volume"}.getInt(0)
        else: discard
        cli.drainedEvents.add(ev)
    except:
      buf = line & "\n" & buf
      break

proc sendDaemonCmd*(cli: DaemonClient, cmd: JsonNode): JsonNode =
  if cli == nil or cli.sock == nil: return %*{"ok": false, "error": "not connected"}
  try:
    drainEventLines(cli, cli.buf)
    let data = $cmd & "\n"
    cli.sock.send(data)
    var tmp: array[16384, char]
    for attempt in 0..<20:
      var rfds: posix.TFdSet
      FD_ZERO(rfds)
      FD_SET(cli.sock.getFd, rfds)
      var tv: posix.Timeval
      tv.tv_sec = 0.Time
      tv.tv_usec = 50_000.Suseconds
      let sel = posix.select(cint(int(cli.sock.getFd) + 1), addr(rfds), nil, nil, addr(tv))
      if sel > 0:
        let n = posix.recv(cli.sock.getFd, addr tmp[0], tmp.len, 0.cint)
        if n > 0:
          let old = cli.buf.len; cli.buf.setLen(old + n); copyMem(addr cli.buf[old], addr tmp[0], n)
      while true:
        let nli = cli.buf.find('\n')
        if nli < 0: break
        let line = cli.buf[0..<nli]
        cli.buf = cli.buf[nli+1..^1]
        if line.len == 0: continue
        let j = parseJson(line)
        if not j.hasKey("events"):
          return j
  except:
    cli.connected = false
  return %*{"ok": false, "error": "no response"}

proc daemonSimpleCmd*(cli: DaemonClient, cmd: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": cmd})

method loadFile*(cli: DaemonClient, path: string) =
  cli.ensureDaemon()
  let resp = sendDaemonCmd(cli, %*{"cmd": "load_file", "path": path})
  cli.lastTrackId = 0
  if resp.hasKey("track_id"):
    cli.lastTrackId = resp["track_id"].getInt().int64
  if resp.hasKey("time_pos"):
    cli.timePos = resp["time_pos"].getFloat(0.0)
  if resp.hasKey("duration"):
    cli.duration = resp["duration"].getFloat(0.0)
  if resp.hasKey("state"):
    let s = resp["state"].getStr()
    cli.state = (if s == "playing": 1 elif s == "paused": 2 else: 0)

method play*(cli: DaemonClient) =
  cli.ensureDaemon()
  discard daemonSimpleCmd(cli, "play")

method pause*(cli: DaemonClient) =
  cli.ensureDaemon()
  discard daemonSimpleCmd(cli, "pause")

method stop*(cli: DaemonClient) =
  cli.ensureDaemon()
  discard daemonSimpleCmd(cli, "stop")

method seek*(cli: DaemonClient, seconds: float) =
  cli.ensureDaemon()
  discard sendDaemonCmd(cli, %*{"cmd": "seek", "seconds": seconds})

method setVolume*(cli: DaemonClient, vol: int) =
  cli.ensureDaemon()
  if cli.sock == nil: return
  discard sendDaemonCmd(cli, %*{"cmd": "set_volume", "volume": vol})

method prepareNext*(cli: DaemonClient, path: string) =
  cli.ensureDaemon()
  discard sendDaemonCmd(cli, %*{"cmd": "prepare_next", "path": path})

method getStatusFlags*(cli: DaemonClient): tuple[crossfading, masterEnded: bool] =
  cli.ensureDaemon()
  let resp = daemonSimpleCmd(cli, "status")
  (resp{"crossfading"}.getBool(false), resp{"master_ended"}.getBool(false))

method startCrossfade*(cli: DaemonClient, durationSeconds: float) =
  cli.ensureDaemon()
  discard sendDaemonCmd(cli, %*{"cmd": "crossfade", "duration": durationSeconds})

method setEqBand*(cli: DaemonClient, band: int, gainDb: float) =
  cli.ensureDaemon()
  discard sendDaemonCmd(cli, %*{"cmd": "set_eq_band", "band": band, "gain_db": gainDb})

method setEqPreset*(cli: DaemonClient, name: string) =
  cli.ensureDaemon()
  discard sendDaemonCmd(cli, %*{"cmd": "set_eq_preset", "name": name})

method togglePause*(cli: DaemonClient) =
  cli.ensureDaemon()
  discard daemonSimpleCmd(cli, "toggle_pause")

method pollEvents*(cli: DaemonClient): seq[AudioEvent] =
  result = cli.drainedEvents
  cli.drainedEvents = @[]
  if not cli.connected: return
  try:
    var tmp: array[16384, char]
    var rfds: posix.TFdSet
    FD_ZERO(rfds)
    FD_SET(cli.sock.getFd, rfds)
    var tv: posix.Timeval
    tv.tv_sec = 0.Time
    tv.tv_usec = 0.Suseconds
    let sel = posix.select(cint(int(cli.sock.getFd) + 1), addr(rfds), nil, nil, addr(tv))
    if sel > 0:
      let n = posix.recv(cli.sock.getFd, addr tmp[0], tmp.len, 0.cint)
      if n > 0:
        let old = cli.buf.len; cli.buf.setLen(old + n); copyMem(addr cli.buf[old], addr tmp[0], n)
    while true:
      let nli = cli.buf.find('\n')
      if nli < 0: break
      let line = cli.buf[0..<nli]
      cli.buf = cli.buf[nli+1..^1]
      if line.len == 0: continue
      let json = parseJson(line)
      if json.hasKey("events"):
        for evJson in json["events"]:
          var ev = AudioEvent()
          let k = evJson{"kind"}.getInt(0)
          ev.kind = AudioEventKind(k)
          case ev.kind
          of aekPositionChanged:
            ev.floatVal = evJson{"time_pos"}.getFloat(0.0)
            cli.timePos = ev.floatVal
          of aekDurationChanged: ev.floatVal = evJson{"duration"}.getFloat(0.0)
          of aekVolumeChanged: ev.intVal = evJson{"volume"}.getInt(0)
          else: discard
          result.add(ev)
      if json.hasKey("time_pos"):
        cli.timePos = json["time_pos"].getFloat(0.0)
      if json.hasKey("duration"):
        cli.duration = json["duration"].getFloat(0.0)
      if json.hasKey("volume"):
        cli.volume = json["volume"].getInt(80)
      if json.hasKey("state"):
        let s = json["state"].getStr()
        cli.state = (if s == "playing": 1 elif s == "paused": 2 else: 0)
      if json.hasKey("audio_working"):
        cli.working = json["audio_working"].getBool(true)
      if json.hasKey("sleep_timer"):
        cli.sleepTimerRemaining = json["sleep_timer"].getInt(0)
  except:
    cli.connected = false

method getVolume*(cli: DaemonClient): int =
  cli.ensureDaemon()
  let resp = daemonSimpleCmd(cli, "get_volume")
  if resp.hasKey("volume"):
    return resp["volume"].getInt(80)
  return 80

method shutdown*(cli: DaemonClient) =
  discard daemonSimpleCmd(cli, "quit")
  if cli.sock != nil:
    try: cli.sock.close() except: stderr.writeLine("[gtm] shutdown close: " & getCurrentExceptionMsg())

proc sendQuitDaemon*(cli: DaemonClient) =
  discard daemonSimpleCmd(cli, "quit")

proc createPlaylist*(cli: DaemonClient, name: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "create_playlist", "name": name})

proc deletePlaylist*(cli: DaemonClient, playlistId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "delete_playlist", "playlist_id": playlistId})

proc renamePlaylist*(cli: DaemonClient, playlistId: int64, name: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "rename_playlist", "playlist_id": playlistId, "name": name})

proc addToPlaylist*(cli: DaemonClient, playlistId, trackId: int64, position: int = 0): JsonNode =
  cli.ensureDaemon()
  let data = %*{"playlist_id": playlistId, "track_id": trackId, "position": position}
  sendDaemonCmd(cli, %*{"cmd": "add_to_playlist", "data": data})

proc removeFromPlaylist*(cli: DaemonClient, playlistId, trackId: int64): JsonNode =
  cli.ensureDaemon()
  let data = %*{"playlist_id": playlistId, "track_id": trackId}
  sendDaemonCmd(cli, %*{"cmd": "remove_from_playlist", "data": data})

proc listPlaylists*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "list_playlists"})

proc getPlaylistTracks*(cli: DaemonClient, playlistId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_playlist_tracks", "playlist_id": playlistId})

proc setShuffle*(cli: DaemonClient, enabled: bool): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_shuffle", "enabled": enabled.int})

proc setRepeat*(cli: DaemonClient, mode: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_repeat", "mode": mode})

proc setSleepTimer*(cli: DaemonClient, minutes: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "set_sleep_timer", "minutes": minutes})

proc getDaemonState*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_state"})

proc resumePlayback*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "resume"})

proc getLibrary*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_library"})

proc addTrack*(cli: DaemonClient, data: JsonNode): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "add_track", "data": data})

proc updateTrackPath*(cli: DaemonClient, oldPath, newPath, newTitle: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "update_track_path", "data": {"old_path": oldPath, "new_path": newPath, "title": newTitle}})

proc scanDir*(cli: DaemonClient, path: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "scan", "path": path})

proc queueAdd*(cli: DaemonClient, paths: seq[string]): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue_add", "data": %paths})

proc queueRemove*(cli: DaemonClient, index: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue_remove", "index": index})

proc queueClear*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue_clear"})

proc queueList*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue_list"})

proc queueSetCursor*(cli: DaemonClient, index: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "queue_set_cursor", "index": index})

proc addFavourite*(cli: DaemonClient, trackId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "add_favourite", "track_id": trackId})

proc removeFavourite*(cli: DaemonClient, trackId: int64): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "remove_favourite", "track_id": trackId})

proc getFavouritesFromDaemon*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_favourites"})

proc getFullState*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "get_full_state"})

proc ytSearch*(cli: DaemonClient, query: string, pageSize: int = 10): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_search", "query": query, "page_size": pageSize})

proc ytSearchPoll*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_search_poll"})

proc ytSearchCancel*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_search_cancel"})

proc ytResolveStream*(cli: DaemonClient, url: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_resolve_stream", "url": url})

proc ytResolveStreamPoll*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_resolve_stream_poll"})

proc ytDownload*(cli: DaemonClient, url, title, channel: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_download", "url": url, "title": title, "channel": channel})

proc ytDownloadPoll*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_download_poll"})

proc ytCancelDownload*(cli: DaemonClient, url: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_cancel_download", "url": url})

proc ytListDownloads*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_list_downloads"})

proc ytFetchPlaylist*(cli: DaemonClient, url: string): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_fetch_playlist", "url": url})

proc ytSetConfig*(cli: DaemonClient, cookieSource, jsRuntime, downloadDir: string, maxConcurrent: int): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_set_config", "cookie_source": cookieSource, "js_runtime": jsRuntime, "download_dir": downloadDir, "max_concurrent": maxConcurrent})

proc ytGetSearchHistory*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_get_search_history"})

proc ytClearSearchHistory*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "yt_clear_search_history"})

proc getEqPresets*(cli: DaemonClient): JsonNode =
  cli.ensureDaemon()
  sendDaemonCmd(cli, %*{"cmd": "list_eq_presets"})

proc newDaemonClient*(): DaemonClient =
  DaemonClient(
    volume: 80, state: 0, running: false,
    connected: false, buf: "", backendType: abtDaemon,
    working: true, sleepTimerRemaining: 0
  )

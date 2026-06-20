## DaemonClient — IPC transport for TUI ↔ daemon communication
##
## DaemonClient extends AudioBackend so the TUI can use the same
## pollEvents() interface the daemon uses for the real backends.
## Communication is JSON-over-Unix-socket with newline framing.
##
## ┌─────────────────────────────────────────────────────┐
## │  DaemonClient (TUI side)                            │
## │                                                     │
## │  send(cmd, args) ──► writeLine(json)                │
## │         │                  │                         │
## │         │          ┌───────┴────────┐               │
## │         │          │  Unix socket   │               │
## │         │          │  (AF_UNIX)     │               │
## │         │          └───────┬────────┘               │
## │         │                  │                         │
## │         ▼                  ▼                         │
## │  resp: pending callback ← readLine(json)            │
## │  events: drainedEvents ← readLine(json events)      │
## │                                                     │
## │  pollEvents(): drain events from in-memory buffer   │
## │  that was filled by the read thread / select loop   │
## │                                                     │
## │  Reconnect: if ping fails, spawn daemon and retry   │
## └─────────────────────────────────────────────────────┘

import os, json, strutils, net, osproc, posix, tables
from nativesockets import setBlocking
import state, audio

type
  PendingRequest* = object
    seqNo: int
    callback: proc(resp: JsonNode) {.closure.}

  DaemonClient* = ref object of AudioBackend
    sock: Socket
    connected*: bool
    buf: string
    sleepTimerRemaining*: int
    lastTrackId*: int64
    drainedEvents: seq[AudioEvent]
    ipcTimeoutSec*: float
    pingMissed*: int
    reconnectCooldown*: int
    nextSeq: int
    pending: seq[PendingRequest]

proc daemonIsRunning*(): bool =
  let p = pidPath()
  if fileExists(p):
    try:
      let pid = readFile(p).strip().parseInt()
      if pid > 0:
        result = posix.kill(pid.cint, 0) == 0
        if not result:
          # Stale PID — remove file
          try: removeFile(p) except: discard
    except:
      try: removeFile(p) except: discard
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
  if cli.reconnectCooldown > 0:
    cli.reconnectCooldown.dec
    return
  if daemonIsRunning():
    if connectToDaemon(cli):
      cli.reconnectCooldown = 0
    else:
      cli.reconnectCooldown = 10
  else:
    startDaemonProcess()
    cli.reconnectCooldown = 10

proc drainEventLinesFromJson(j: JsonNode, cli: DaemonClient) =
  if not j.hasKey("events"): return
  for evJson in j["events"]:
    var ev = AudioEvent()
    let k = evJson{"kind"}.getInt(0)
    ev.kind = AudioEventKind(k)
    ev.version = evJson{"version"}.getInt(0)
    case ev.kind
    of evPositionChanged: ev.floatVal = evJson{"time_pos"}.getFloat(0.0)
    of evDurationChanged: ev.floatVal = evJson{"duration"}.getFloat(0.0)
    of evVolumeChanged: ev.intVal = evJson{"volume"}.getInt(0)
    of evPlaybackStarted:
      if evJson.hasKey("track_path"):
        ev.metadata["track_path"] = evJson{"track_path"}.getStr("")
        ev.metadata["track_title"] = evJson{"track_title"}.getStr("")
        ev.metadata["track_channel"] = evJson{"track_channel"}.getStr("")
      ev.metadata["auto_advanced"] = $(evJson{"auto_advanced"}.getBool(false))
    of evMetadataChanged: ev.strVal = evJson{"event"}.getStr("")
    of evCustomEvent:
      ev.strVal = evJson{"event"}.getStr("")
      if evJson.hasKey("shuffleIndex"): ev.intVal = evJson["shuffleIndex"].getInt(0)
      for key in ["url", "path", "title", "channel", "next_path", "next_title", "next_channel", "cover_data", "cover_mime"]:
        if evJson.hasKey(key): ev.metadata[key] = evJson[key].getStr("")
      for key in ["queue", "results", "tracks", "lines"]:
        if evJson.hasKey(key): ev.metadata[key] = $evJson[key]
      if evJson.hasKey("shuffle"): ev.metadata["shuffle"] = $(evJson["shuffle"].getBool(false))
      if evJson.hasKey("repeat"): ev.metadata["repeat"] = $(evJson["repeat"].getInt(0))
      if evJson.hasKey("ok"): ev.metadata["ok"] = $(evJson["ok"].getBool(false))
      # Extract full_state_sync fields from the event itself
      if ev.strVal == "full_state_sync":
        for f in ["state", "track_path", "track_title", "track_channel"]:
          if evJson.hasKey(f): ev.metadata[f] = evJson[f].getStr("")
        for f in ["time_pos", "duration"]:
          if evJson.hasKey(f): ev.metadata[f] = $evJson[f].getFloat(0.0)
        for f in ["volume", "sleep_timer"]:
          if evJson.hasKey(f): ev.metadata[f] = $evJson[f].getInt(0)
        if evJson.hasKey("shuffle"): ev.metadata["full_shuffle"] = $(evJson["shuffle"].getBool(false))
        if evJson.hasKey("repeat"): ev.metadata["full_repeat"] = $(evJson["repeat"].getInt(0))
    else: discard
    cli.drainedEvents.add(ev)

proc readLineFromBuf(buf: var string): string =
  let nli = buf.find('\n')
  if nli < 0: return ""
  result = buf[0..<nli]
  buf = buf[nli+1..^1]

proc drainEventLines(cli: DaemonClient, buf: var string) =
  cli.drainedEvents = @[]
  while true:
    let line = readLineFromBuf(buf)
    if line.len == 0: break
    try:
      let j = parseJson(line)
      if not j.hasKey("events"):
        buf = line & "\n" & buf
        break
      drainEventLinesFromJson(j, cli)
    except:
      buf = line & "\n" & buf
      break

proc clearPending*(cli: DaemonClient)

proc readAvailable(cli: DaemonClient, timeoutUsec: int): int =
  ## Returns bytes read (>0), 0 on timeout, -1 on disconnect
  var tmp: array[16384, char]
  var rfds: posix.TFdSet
  FD_ZERO(rfds)
  FD_SET(cli.sock.getFd, rfds)
  var tv: posix.Timeval
  tv.tv_sec = 0.Time
  tv.tv_usec = timeoutUsec.Suseconds
  let sel = posix.select(cint(int(cli.sock.getFd) + 1), addr(rfds), nil, nil, addr(tv))
  if sel <= 0: return 0
  let n = posix.recv(cli.sock.getFd, addr tmp[0], tmp.len, 0.cint)
  if n > 0:
    let old = cli.buf.len; cli.buf.setLen(old + n); copyMem(addr cli.buf[old], addr tmp[0], n)
    return n
  return if n == 0: -1 else: n

proc sendDaemonCmd*(cli: DaemonClient, cmd: JsonNode): JsonNode =
  cli.ensureDaemon()
  if cli == nil or cli.sock == nil or not cli.connected: return %*{"ok": false, "error": "not connected"}
  try:
    drainEventLines(cli, cli.buf)
    let seqNo = cli.nextSeq
    cli.nextSeq.inc
    cmd["seq"] = %seqNo
    cli.sock.send($cmd & "\n")
    let timeout = if cli.ipcTimeoutSec > 0: cli.ipcTimeoutSec else: 3.0
    var totalWait = 0.0
    while totalWait < timeout:
      let n = readAvailable(cli, 100_000)
      if n < 0:
        cli.connected = false
        cli.clearPending()
        return %*{"ok": false, "error": "connection closed"}
      while n > 0:
        let line = readLineFromBuf(cli.buf)
        if line.len == 0: break
        if line.len == 0: continue
        let j = parseJson(line)
        if j.hasKey("seq") and j["seq"].getInt(-1) == seqNo:
          return j
        if j.hasKey("events"):
          drainEventLinesFromJson(j, cli)
          continue
        if j.hasKey("state"): continue
      totalWait += 0.1
  except:
    cli.connected = false
    cli.clearPending()
  return %*{"ok": false, "error": "no response"}

proc sendOnly*(cli: DaemonClient, cmd: JsonNode) =
  cli.ensureDaemon()
  if cli == nil or cli.sock == nil or not cli.connected: return
  try:
    drainEventLines(cli, cli.buf)
    cmd["seq"] = %cli.nextSeq
    cli.nextSeq.inc
    cli.sock.send($cmd & "\n")
  except:
    cli.connected = false
    cli.clearPending()

proc daemonSimpleCmd*(cli: DaemonClient, cmd: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": cmd})

proc sendAsync*(cli: DaemonClient, cmd: JsonNode, callback: proc(resp: JsonNode) {.closure.}) =
  if cli == nil or cli.sock == nil or not cli.connected: return
  try:
    drainEventLines(cli, cli.buf)
    let seqNo = cli.nextSeq
    cli.nextSeq.inc
    cmd["seq"] = %seqNo
    cli.pending.add(PendingRequest(seqNo: seqNo, callback: callback))
    let data = $cmd & "\n"
    cli.sock.send(data)
  except:
    discard

method loadFile*(cli: DaemonClient, path: string, title: string = "", channel: string = ""): bool =
  let resp = sendDaemonCmd(cli, %*{"cmd": "load_file", "path": path, "title": title, "channel": channel})
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
  result = resp.hasKey("ok") and resp["ok"].getBool(false)

method play*(cli: DaemonClient) =
  cli.sendOnly(%*{"cmd": "play"})

method pause*(cli: DaemonClient) =
  cli.sendOnly(%*{"cmd": "pause"})

method stop*(cli: DaemonClient) =
  cli.sendOnly(%*{"cmd": "stop"})

method seek*(cli: DaemonClient, seconds: float) =
  cli.sendOnly(%*{"cmd": "seek", "seconds": seconds})

method setVolume*(cli: DaemonClient, vol: int) =
  if cli.sock == nil: return
  cli.sendOnly(%*{"cmd": "set_volume", "volume": vol})

method prepareNext*(cli: DaemonClient, path: string) =
  cli.sendOnly(%*{"cmd": "prepare_next", "path": path})

method getStatusFlags*(cli: DaemonClient): tuple[crossfading, masterEnded: bool] =
  let resp = daemonSimpleCmd(cli, "status")
  (resp{"crossfading"}.getBool(false), resp{"master_ended"}.getBool(false))

method startCrossfade*(cli: DaemonClient, durationSeconds: float) {.base.} =
  cli.sendOnly(%*{"cmd": "crossfade", "duration": durationSeconds})

method setEqBand*(cli: DaemonClient, band: int, gainDb: float) =
  cli.sendOnly(%*{"cmd": "set_eq_band", "band": band, "gain_db": gainDb})

method setEqPreset*(cli: DaemonClient, name: string) =
  cli.sendOnly(%*{"cmd": "set_eq_preset", "name": name})

method setSpatialWidth*(cli: DaemonClient, width: float) =
  cli.sendOnly(%*{"cmd": "set_spatial_width", "width": width})

method setCrossfadeDuration*(cli: DaemonClient, duration: int) {.base.} =
  cli.sendOnly(%*{"cmd": "set_crossfade_duration", "duration": duration})

method setCrossfadeCurve*(cli: DaemonClient, curveType: int) =
  cli.sendOnly(%*{"cmd": "set_crossfade_curve", "curve_type": curveType})

method togglePause*(cli: DaemonClient) =
  cli.sendOnly(%*{"cmd": "toggle_pause"})

method pollEvents*(cli: DaemonClient): seq[AudioEvent] =
  result = cli.drainedEvents
  cli.drainedEvents = @[]
  if not cli.connected: return
  try:
    discard readAvailable(cli, 0)
    while true:
      let line = readLineFromBuf(cli.buf)
      if line.len == 0: break
      let json = parseJson(line)
      if json.hasKey("events"):
        let prevDrained = cli.drainedEvents.len
        drainEventLinesFromJson(json, cli)
        # Newly drained events go to result, and update cli state fields
        for i in prevDrained..<cli.drainedEvents.len:
          let ev = cli.drainedEvents[i]
          if ev.kind == evPositionChanged:
            cli.timePos = ev.floatVal
          elif ev.kind == evPlaybackStarted:
            if ev.metadata.hasKey("time_pos"):
              try: cli.timePos = parseFloat(ev.metadata["time_pos"]) except: discard
            if ev.metadata.hasKey("duration"):
              try: cli.duration = parseFloat(ev.metadata["duration"]) except: discard
          result.add(ev)
      elif json.hasKey("state"):
        let s = json["state"].getStr()
        cli.state = (if s == "playing": 1 elif s == "paused": 2 else: 0)
        if json.hasKey("time_pos"):
          cli.timePos = json["time_pos"].getFloat(0.0)
        if json.hasKey("duration"):
          cli.duration = json["duration"].getFloat(0.0)
        if json.hasKey("volume"):
          cli.volume = json["volume"].getInt(80)
        if json.hasKey("audio_working"):
          cli.working = json["audio_working"].getBool(true)
        if json.hasKey("sleep_timer"):
          cli.sleepTimerRemaining = json["sleep_timer"].getInt(0)
      elif json.hasKey("seq"):
        let seqNo = json["seq"].getInt(-1)
        var i = 0
        while i < cli.pending.len:
          if cli.pending[i].seqNo == seqNo:
            let cb = cli.pending[i].callback
            cli.pending.delete(i)
            cb(json)
            break
          i.inc
      else:
        # Skip stray command response lines (leftover from timed-out commands)
        discard
  except:
    cli.connected = false
    cli.clearPending()

method getVolume*(cli: DaemonClient): int =
  let resp = daemonSimpleCmd(cli, "get_volume")
  if resp.hasKey("volume"):
    return resp["volume"].getInt(80)
  return 80

proc clearPending*(cli: DaemonClient) =
  cli.pending = @[]

method shutdown*(cli: DaemonClient) =
  cli.clearPending()
  if cli.sock != nil:
    try: cli.sock.close() except: discard
  cli.connected = false

proc sendQuitDaemon*(cli: DaemonClient) =
  sendOnly(cli, %*{"cmd": "quit"})

proc createPlaylist*(cli: DaemonClient, name: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "create_playlist", "name": name})

proc deletePlaylist*(cli: DaemonClient, playlistId: int64): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "delete_playlist", "playlist_id": playlistId})

proc renamePlaylist*(cli: DaemonClient, playlistId: int64, name: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "rename_playlist", "playlist_id": playlistId, "name": name})

proc addToPlaylist*(cli: DaemonClient, playlistId, trackId: int64, position: int = 0): JsonNode =
  let data = %*{"playlist_id": playlistId, "track_id": trackId, "position": position}
  sendDaemonCmd(cli, %*{"cmd": "add_to_playlist", "data": data})

proc removeFromPlaylist*(cli: DaemonClient, playlistId, trackId: int64): JsonNode =
  let data = %*{"playlist_id": playlistId, "track_id": trackId}
  sendDaemonCmd(cli, %*{"cmd": "remove_from_playlist", "data": data})

proc listPlaylists*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "list_playlists"})

proc getPlaylistTracks*(cli: DaemonClient, playlistId: int64): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "get_playlist_tracks", "playlist_id": playlistId})

proc setShuffle*(cli: DaemonClient, enabled: bool): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "set_shuffle", "enabled": enabled.int})

proc setRepeat*(cli: DaemonClient, mode: int): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "set_repeat", "mode": mode})

proc setSleepTimer*(cli: DaemonClient, minutes: int): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "set_sleep_timer", "minutes": minutes})

proc getDaemonState*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "get_state"})

proc resumePlayback*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "resume"})

proc getLibrary*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "get_library"})

proc addTrack*(cli: DaemonClient, data: JsonNode): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "add_track", "data": data})

proc updateTrackPath*(cli: DaemonClient, oldPath, newPath, newTitle: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "update_track_path", "data": {"old_path": oldPath, "new_path": newPath, "title": newTitle}})

proc scanDir*(cli: DaemonClient, path: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "scan", "path": path})

proc queueAdd*(cli: DaemonClient, items: seq[tuple[path, title, channel: string]]): JsonNode =
  var arr = newJArray()
  for (path, title, channel) in items:
    arr.add(%*{"path": path, "title": title, "channel": channel})
  sendDaemonCmd(cli, %*{"cmd": "queue_add", "data": arr})

proc queueRemove*(cli: DaemonClient, index: int): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "queue_remove", "index": index})

proc queueRemovePath*(cli: DaemonClient, path: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "queue_remove_path", "path": path})

proc queueClear*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "queue_clear"})

proc queueValidate*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "queue_validate"})

proc queueList*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "queue_list"})

proc queueSetCursor*(cli: DaemonClient, index: int): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "queue_set_cursor", "index": index})

proc addFavourite*(cli: DaemonClient, trackId: int64): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "add_favourite", "track_id": trackId})

proc removeFavourite*(cli: DaemonClient, trackId: int64): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "remove_favourite", "track_id": trackId})

proc getFavouritesFromDaemon*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "get_favourites"})

proc getFullState*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "get_full_state"})

proc ytSearch*(cli: DaemonClient, query: string, pageSize: int = 10) =
  sendOnly(cli, %*{"cmd": "yt_search", "query": query, "page_size": pageSize})

proc ytSearchPoll*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_search_poll"})

proc ytSearchCancel*(cli: DaemonClient) =
  sendOnly(cli, %*{"cmd": "yt_search_cancel"})

proc ytResolveStream*(cli: DaemonClient, url: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_resolve_stream", "url": url})

proc ytResolveStreamPoll*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_resolve_stream_poll"})

proc ytDownload*(cli: DaemonClient, url, title, channel: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_download", "url": url, "title": title, "channel": channel})

proc ytDownloadPoll*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_download_poll"})

proc ytCancelDownload*(cli: DaemonClient, url: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_cancel_download", "url": url})

proc ytListDownloads*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_list_downloads"})

proc ytFetchPlaylist*(cli: DaemonClient, url: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_fetch_playlist", "url": url})

proc ytFetchPlaylistPoll*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_fetch_playlist_poll"})

proc ping*(cli: DaemonClient): bool =
  let resp = sendDaemonCmd(cli, %*{"cmd": "ping"})
  result = resp.hasKey("pong") and resp["pong"].getBool(false)

proc ytSetConfig*(cli: DaemonClient, cookieSource, jsRuntime, downloadDir: string, maxConcurrent: int): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_set_config", "cookie_source": cookieSource, "js_runtime": jsRuntime, "download_dir": downloadDir, "max_concurrent": maxConcurrent})

proc ytGetSearchHistory*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_get_search_history"})

proc ytClearSearchHistory*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "yt_clear_search_history"})

proc spSetConfig*(cli: DaemonClient, cookieSource, cookiePath, audioFormat: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "sp_set_config", "cookie_source": cookieSource, "cookie_path": cookiePath, "audio_format": audioFormat})

proc spListDownloads*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "sp_list_downloads"})

proc spOAuthUrl*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "sp_oauth_url"})

proc spOAuthCallback*(cli: DaemonClient, code: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "sp_oauth_callback", "code": code})

proc spFeed*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "sp_feed"})

proc spDisconnect*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "sp_disconnect"})

proc getCoverArt*(cli: DaemonClient, path: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "get_cover_art", "path": path})

proc getLyrics*(cli: DaemonClient, path, title, artist, album: string, duration: float): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "get_lyrics", "path": path, "title": title, "artist": artist, "album": album, "duration": duration})

proc searchLyrics*(cli: DaemonClient, title, artist: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "search_lyrics", "title": title, "artist": artist})

proc getEqPresets*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "list_eq_presets"})

proc deleteTrack*(cli: DaemonClient, trackId: int64, permanent: bool = false): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "delete_track", "track_id": trackId, "permanent": permanent.int})

proc restoreTrack*(cli: DaemonClient, trashId: int): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "restore_track", "trash_id": trashId})

proc permanentDeleteTrash*(cli: DaemonClient, trashId: int): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "permanent_delete_trash", "trash_id": trashId})

proc listTrash*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "list_trash"})

proc purgeTrash*(cli: DaemonClient): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": "purge_trash"})

proc newDaemonClient*(): DaemonClient =
  DaemonClient(
    volume: 80, state: 0, running: false,
    connected: false, buf: "", backendType: abtDaemon,
    working: true, sleepTimerRemaining: 0,
    ipcTimeoutSec: 3.0, pingMissed: 0, reconnectCooldown: 0,
    nextSeq: 0, pending: @[]
  )

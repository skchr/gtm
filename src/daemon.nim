import os, json, strutils, net, posix
from nativesockets import setBlocking, selectRead, SocketHandle
import audio, state, visualizer, library

type
  DaemonCmdKind* = enum
    dckPlay, dckPause, dckStop, dckSeek, dckNext, dckPrev,
    dckSetVolume, dckGetVolume, dckLoadFile, dckTogglePause,
    dckQuit, dckStatus, dckScan, dckNowPlaying

  DaemonCmd* = object
    kind*: DaemonCmdKind
    strArg*: string
    floatArg*: float
    intArg*: int

  Daemon* = ref object
    player: AudioBackend
    lib: LibraryDb
    viz: Visualizer
    running: bool
    server: Socket
    client: Socket
    currentTrackPath: string
    idleFrames: int
    idleTimeout: int

proc writePidFile() =
  let dir = stateDir()
  if not dirExists(dir): createDir(dir)
  writeFile(pidPath(), $getpid())

proc removePidFile() =
  try: removeFile(pidPath()) except: discard

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
    of "quit": result.kind = dckQuit
    of "status": result.kind = dckStatus
    of "now_playing": result.kind = dckNowPlaying
    else: result.kind = dckStatus
  except:
    result.kind = dckStatus

proc serializeEvents(events: seq[AudioEvent]): JsonNode =
  result = newJArray()
  for ev in events:
    var obj = %*{"kind": $(ev.kind.int)}
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
  case cmd.kind
  of dckLoadFile:
    if cmd.strArg.len > 0:
      d.player.loadFile(cmd.strArg)
      d.currentTrackPath = cmd.strArg
      d.player.play()
      d.idleFrames = 0
      result["state"] = %"playing"
  of dckPlay:
    d.player.play(); d.idleFrames = 0
  of dckPause:
    d.player.pause()
  of dckTogglePause:
    d.player.togglePause(); d.idleFrames = 0
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
  of dckScan:
    if cmd.strArg.len > 0 and dirExists(cmd.strArg):
      let paths = scanDirectoryRecursive(cmd.strArg)
      for p in paths:
        let (_, name, _) = p.splitFile()
        if d.lib != nil:
          discard d.lib.addTrack(p, name, "", "", 0.0, 0, 0, "")

proc runDaemon*() =
  let dir = stateDir()
  if not dirExists(dir): createDir(dir)
  writePidFile()
  setupSignalHandlers()
  var daemon = Daemon(
    player: newMiniAudioBackend(),
    viz: newVisualizer(),
    running: true,
    idleTimeout: 300
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
    if trackPath.len > 0 and fileExists(trackPath):
      daemon.player.loadFile(trackPath)
      daemon.currentTrackPath = trackPath
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
          for i in 0..<n: buf.add(tmp[i])
          while true:
            let nli = buf.find('\n')
            if nli < 0: break
            let line = buf[0..<nli]
            buf = buf[nli+1..^1]
            if line.len > 0:
              stderr.writeLine("[gtm] daemon recv: " & line)
              let cmd = parseDaemonCommand(line)
              let resp = executeCommand(daemon, cmd)
              let events = daemon.player.pollEvents()
              if events.len > 0:
                resp["events"] = serializeEvents(events)
              let respStr = $resp & "\n"
              stderr.writeLine("[gtm] daemon resp: " & respStr.strip())
              daemon.client.send(respStr)
              if not daemon.running: break
    daemon.viz.readPcm()
    daemon.idleFrames.inc
    if daemon.idleFrames > daemon.idleTimeout * 60 and daemon.player.state == 0:
      if daemon.lib != nil:
        daemon.lib.setPlaybackState("volume", $daemon.player.volume)
        daemon.lib.setPlaybackState("time_pos", $daemon.player.timePos)
        daemon.lib.setPlaybackState("track_path", daemon.currentTrackPath)
        daemon.lib.closeDb()
      daemon.viz.stopCapture()
      daemon.player.shutdown()
      break
  if daemon.client != nil: daemon.client.close()
  daemon.server.close()
  removeFile(sockPath())
  removePidFile()

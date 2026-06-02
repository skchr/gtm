import os, json, strutils, net, osproc, posix
from nativesockets import setBlocking
import state, audio

type
  DaemonClient* = ref object of AudioBackend
    sock: Socket
    connected*: bool
    buf: string

proc daemonIsRunning*(): bool =
  let p = pidPath()
  if fileExists(p):
    try:
      let pid = readFile(p).strip().parseInt()
      if pid > 0:
        result = execCmd("kill -0 " & $pid & " 2>/dev/null") == 0
    except:
      result = false

proc startDaemonProcess*() =
  let selfPath = getAppFilename()
  discard startProcess(selfPath, args = @["daemon"],
    options = {poUsePath, poParentStreams})

proc connectToDaemon*(cli: DaemonClient): bool =
  if cli.connected and cli.sock != nil:
    try: cli.sock.close() except: discard
  cli.connected = false
  let s = sockPath()
  if not symlinkExists(s) and not fileExists(s):
    return false
  try:
    let fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
    cli.sock = newSocket(fd, Domain.AF_UNIX, SockType.SOCK_STREAM)
    cli.sock.connectUnix(s)
    setBlocking(cli.sock.getFd, false)
    cli.connected = true
    cli.backendType = abtDaemon
    return true
  except:
    return false

proc ensureDaemon*(cli: DaemonClient) =
  if cli.connected: return
  if not daemonIsRunning():
    startDaemonProcess()
    for i in 0..30:
      os.sleep(20)
      if daemonIsRunning(): break
  for i in 0..15:
    if connectToDaemon(cli): return
    os.sleep(20)

proc sendDaemonCmd*(cli: DaemonClient, cmd: JsonNode): JsonNode =
  if cli.sock == nil: return %*{"ok": false, "error": "not connected"}
  try:
    let data = $cmd & "\n"
    cli.sock.send(data)
    var tmp: array[16384, char]
    for attempt in 0..30:
      let n = recv(cli.sock, addr tmp[0], tmp.len, 0)
      if n > 0:
        for i in 0..<n: cli.buf.add(tmp[i])
        break
      os.sleep(1)
    let nli = cli.buf.find('\n')
    if nli >= 0:
      let line = cli.buf[0..<nli]
      cli.buf = cli.buf[nli+1..^1]
      if line.len > 0: return parseJson(line)
  except:
    cli.connected = false
  return %*{"ok": false, "error": "no response"}

proc daemonSimpleCmd*(cli: DaemonClient, cmd: string): JsonNode =
  sendDaemonCmd(cli, %*{"cmd": cmd})

method loadFile*(cli: DaemonClient, path: string) =
  cli.ensureDaemon()
  discard sendDaemonCmd(cli, %*{"cmd": "load_file", "path": path})

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
  discard sendDaemonCmd(cli, %*{"cmd": "set_volume", "volume": vol})

method togglePause*(cli: DaemonClient) =
  cli.ensureDaemon()
  discard daemonSimpleCmd(cli, "toggle_pause")

method pollEvents*(cli: DaemonClient): seq[AudioEvent] =
  result = @[]
  if not cli.connected: return
  let resp = daemonSimpleCmd(cli, "status")
  if resp.hasKey("events"):
    for evJson in resp["events"]:
      var ev = AudioEvent()
      let k = evJson{"kind"}.getInt(0)
      ev.kind = AudioEventKind(k)
      case ev.kind
      of aekPositionChanged: ev.floatVal = evJson{"time_pos"}.getFloat(0.0)
      of aekDurationChanged: ev.floatVal = evJson{"duration"}.getFloat(0.0)
      of aekVolumeChanged: ev.intVal = evJson{"volume"}.getInt(0)
      else: discard
      result.add(ev)
  if resp.hasKey("time_pos"):
    cli.timePos = resp["time_pos"].getFloat(0.0)
  if resp.hasKey("duration"):
    cli.duration = resp["duration"].getFloat(0.0)
  if resp.hasKey("volume"):
    cli.volume = resp["volume"].getInt(80)
  if resp.hasKey("state"):
    let s = resp["state"].getStr()
    cli.state = (if s == "playing": 1 elif s == "paused": 2 else: 0)

method shutdown*(cli: DaemonClient) =
  discard daemonSimpleCmd(cli, "quit")
  if cli.sock != nil:
    try: cli.sock.close() except: discard

proc sendQuitDaemon*(cli: DaemonClient) =
  discard daemonSimpleCmd(cli, "quit")

proc newDaemonClient*(): DaemonClient =
  DaemonClient(
    volume: 80, state: 0, running: false,
    connected: false, buf: "", backendType: abtDaemon
  )

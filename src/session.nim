## DaemonSession — IPC transport for TUI ↔ daemon communication
##
## Owns the Unix socket connection, JSON framing, event polling,
## and reconnection logic. No AudioBackend inheritance — this is a
## pure IPC transport. State is updated from daemon events only.
##
## ┌──────────────────────────────────────────────────┐
## │  DaemonSession (TUI side)                        │
## │                                                   │
## │  send(cmd) ──► writeLine(json)                    │
## │  request(cmd) ──► writeLine(json) + read response │
## │  drainEvents() ──► non-blocking read → events[]   │
## │                                                   │
## │  Reconnection:                                    │
## │    ensureRunning() → daemonIsRunning()?            │
## │      ── spawn daemon if not                       │
## │      ── connectUnix, set nonblocking              │
## └──────────────────────────────────────────────────┘

import os, json, strutils, net, osproc, posix, tables
from nativesockets import setBlocking
import audio

var debugMode*: bool

proc stateDir*(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = "/tmp/gtm-" & getEnv("USER", "unknown")

proc configDir*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = getEnv("HOME", "") & "/.config/gtm"

proc dataDir*(): string =
  let xdg = getEnv("XDG_DATA_HOME", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = getEnv("HOME", "") & "/.local/share/gtm"

proc pidPath*(): string = stateDir() & "/gtmd.pid"
proc sockPath*(): string = stateDir() & "/gtmd.sock"

type
  DaemonSession* = ref object
    sock: Socket
    connected*: bool
    buf: string
    sleepTimerRemaining*: int
    lastTrackId*: int64
    ipcTimeoutSec*: float
    pingMissed*: int
    reconnectCooldown*: int
    nextSeq: int
    timePos*: float
    duration*: float
    volume*: int
    state*: int
    working*: bool

proc daemonIsRunning*(): bool =
  let p = pidPath()
  if fileExists(p):
    try:
      let pid = readFile(p).strip().parseInt()
      if pid > 0:
        result = posix.kill(pid.cint, 0) == 0
        if not result:
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

proc connect*(s: DaemonSession): bool =
  if s.connected and s.sock != nil:
    try: s.sock.close() except: discard
  s.connected = false
  try:
    let fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
    s.sock = newSocket(fd, Domain.AF_UNIX, SockType.SOCK_STREAM)
    s.sock.connectUnix(sockPath())
    setBlocking(s.sock.getFd, false)
    s.connected = true
    return true
  except:
    s.sock = nil
    return false

proc ensureRunning*(s: DaemonSession) =
  if s == nil: return
  if s.connected: return
  if s.reconnectCooldown > 0:
    s.reconnectCooldown.dec
    return
  if daemonIsRunning():
    if connect(s):
      s.reconnectCooldown = 0
    else:
      s.reconnectCooldown = 10
  else:
    startDaemonProcess()
    s.reconnectCooldown = 10

proc drainEventLinesFromJson(j: JsonNode, s: DaemonSession): seq[AudioEvent] =
  result = @[]
  if not j.hasKey("events"): return
  for evJson in j["events"]:
    var ev = AudioEvent()
    let k = evJson{"kind"}.getInt(0)
    ev.kind = AudioEventKind(k)
    ev.version = evJson{"version"}.getInt(0)
    case ev.kind
    of evPositionChanged:
      ev.floatVal = evJson{"time_pos"}.getFloat(0.0)
    of evDurationChanged:
      ev.floatVal = evJson{"duration"}.getFloat(0.0)
    of evVolumeChanged:
      ev.intVal = evJson{"volume"}.getInt(0)
    of evPlaybackStarted:
      if evJson.hasKey("track_path"):
        ev.metadata["track_path"] = evJson{"track_path"}.getStr("")
        ev.metadata["track_title"] = evJson{"track_title"}.getStr("")
        ev.metadata["track_channel"] = evJson{"track_channel"}.getStr("")
      ev.metadata["auto_advanced"] = $(evJson{"auto_advanced"}.getBool(false))
    of evMetadataChanged:
      ev.strVal = evJson{"event"}.getStr("")
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
    result.add(ev)

proc drainEvents*(s: DaemonSession): seq[AudioEvent] =
  result = @[]
  if not s.connected: return
  try:
    var tmp: array[16384, char]
    var rfds: posix.TFdSet
    FD_ZERO(rfds)
    FD_SET(s.sock.getFd, rfds)
    var tv: posix.Timeval
    tv.tv_sec = 0.Time
    tv.tv_usec = 0.Suseconds
    let sel = posix.select(cint(int(s.sock.getFd) + 1), addr(rfds), nil, nil, addr(tv))
    if sel > 0:
      let n = posix.recv(s.sock.getFd, addr tmp[0], tmp.len, 0.cint)
      if n > 0:
        let old = s.buf.len; s.buf.setLen(old + n); copyMem(addr s.buf[old], addr tmp[0], n)
    while true:
      let nli = s.buf.find('\n')
      if nli < 0: break
      let line = s.buf[0..<nli]
      s.buf = s.buf[nli+1..^1]
      if line.len == 0: continue
      let json = parseJson(line)
      if json.hasKey("events"):
        let events = drainEventLinesFromJson(json, s)
        for ev in events:
          if ev.kind == evPositionChanged:
            s.timePos = ev.floatVal
          elif ev.kind == evPlaybackStarted:
            if ev.metadata.hasKey("time_pos"):
              try: s.timePos = parseFloat(ev.metadata["time_pos"]) except: discard
            if ev.metadata.hasKey("duration"):
              try: s.duration = parseFloat(ev.metadata["duration"]) except: discard
        result.add(events)
      elif json.hasKey("state"):
        let st = json["state"].getStr()
        s.state = (if st == "playing": 1 elif st == "paused": 2 else: 0)
        if json.hasKey("time_pos"):
          s.timePos = json["time_pos"].getFloat(0.0)
        if json.hasKey("duration"):
          s.duration = json["duration"].getFloat(0.0)
        if json.hasKey("volume"):
          s.volume = json["volume"].getInt(80)
        if json.hasKey("audio_working"):
          s.working = json["audio_working"].getBool(true)
        if json.hasKey("sleep_timer"):
          s.sleepTimerRemaining = json["sleep_timer"].getInt(0)
      elif json.hasKey("seq"):
        discard
      else:
        discard
  except:
    s.connected = false

proc send*(s: DaemonSession, cmd: JsonNode) =
  if s == nil or s.sock == nil or not s.connected: return
  try:
    cmd["seq"] = %s.nextSeq
    s.nextSeq.inc
    let data = $cmd & "\n"
    s.sock.send(data)
  except:
    s.connected = false

proc request*(s: DaemonSession, cmd: JsonNode): JsonNode =
  if s == nil or s.sock == nil or not s.connected: return %*{"ok": false, "error": "not connected"}
  try:
    let seqNo = s.nextSeq
    s.nextSeq.inc
    cmd["seq"] = %seqNo
    let data = $cmd & "\n"
    s.sock.send(data)
    var tmp: array[16384, char]
    let timeout = if s.ipcTimeoutSec > 0: s.ipcTimeoutSec else: 3.0
    var totalWait = 0.0
    while totalWait < timeout:
      var rfds: posix.TFdSet
      FD_ZERO(rfds)
      FD_SET(s.sock.getFd, rfds)
      var tv: posix.Timeval
      tv.tv_sec = 0.Time
      tv.tv_usec = 100_000.Suseconds
      let sel = posix.select(cint(int(s.sock.getFd) + 1), addr(rfds), nil, nil, addr(tv))
      if sel > 0:
        let n = posix.recv(s.sock.getFd, addr tmp[0], tmp.len, 0.cint)
        if n > 0:
          let old = s.buf.len; s.buf.setLen(old + n); copyMem(addr s.buf[old], addr tmp[0], n)
        elif n == 0:
          s.connected = false
          return %*{"ok": false, "error": "connection closed"}
      while true:
        let nli = s.buf.find('\n')
        if nli < 0: break
        let line = s.buf[0..<nli]
        s.buf = s.buf[nli+1..^1]
        if line.len == 0: continue
        let j = parseJson(line)
        if j.hasKey("seq") and j["seq"].getInt(-1) == seqNo:
          return j
        if j.hasKey("events"):
          for ev in drainEventLinesFromJson(j, s):
            if ev.kind == evPositionChanged:
              s.timePos = ev.floatVal
        if j.hasKey("state"): continue
      totalWait += 0.1
  except:
    s.connected = false
  return %*{"ok": false, "error": "no response"}

proc sendOnly*(s: DaemonSession, cmd: JsonNode) {.inline.} =
  s.send(cmd)

proc daemonSimpleCmd*(s: DaemonSession, cmd: string): JsonNode =
  s.ensureRunning()
  s.request(%*{"cmd": cmd})

proc newDaemonSession*(): DaemonSession =
  DaemonSession(
    volume: 80, state: 0,
    connected: false, buf: "",
    working: true, sleepTimerRemaining: 0,
    ipcTimeoutSec: 3.0, pingMissed: 0, reconnectCooldown: 0
  )

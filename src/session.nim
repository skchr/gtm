## DaemonSession — IPC transport for TUI ↔ daemon communication
##
## Extends AudioBackend so the TUI can use the same pollEvents() interface
## the daemon uses for the real backends. Communication is JSON-over-Unix-socket
## with newline framing.
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
import audio, state, wire

proc monotonicTime*(): float =
  ## Wall-clock-independent monotonic time (std::chrono::steady_clock).
  var ts: posix.Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  result = ts.tv_sec.float + ts.tv_nsec.float * 1e-9

type
  DaemonSession* = ref object of AudioBackend
    sock: Socket
    connected*: bool
    buf: string
    sleepTimerRemaining*: int
    lastTrackId*: int64
    ipcTimeoutSec*: float
    pingMissed*: int
    reconnectCooldown*: int
    nextSeq: int
    # Local time extrapolation state
    extrapolatedPos*: float
    posBaseTime: float
    posBaseValue: float
    clockSkew: float
    extrapolating: bool
    # Wire protocol negotiation
    wireNegotiated: bool
    lastVersion*: int
    # RTT tracking
    rttEstimate*: float
    lastSendTime: float
    recoveryWindow: float

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
    var flags = posix.fcntl(s.sock.getFd, posix.F_GETFL, 0)
    discard posix.fcntl(s.sock.getFd, posix.F_SETFL, flags or posix.O_NONBLOCK)
    s.connected = true
    s.wireNegotiated = false
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
      if evJson.hasKey("time_pos"):
        ev.metadata["time_pos"] = $evJson["time_pos"].getFloat(0.0)
      if evJson.hasKey("duration"):
        ev.metadata["duration"] = $evJson["duration"].getFloat(0.0)
    of evMetadataChanged:
      ev.strVal = evJson{"event"}.getStr("")
    of evCustomEvent:
      ev.strVal = evJson{"event"}.getStr("")
      if evJson.hasKey("shuffleIndex"): ev.intVal = evJson["shuffleIndex"].getInt(0)
      for key in ["url", "path", "title", "channel", "next_path", "next_title", "next_channel", "cover_data", "cover_mime"]:
        if evJson.hasKey(key): ev.metadata[key] = evJson[key].getStr("")
      for key in ["queue", "results", "tracks", "lines", "duration", "curve"]:
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
        if evJson.hasKey("shuffleIndex"): ev.metadata["full_shuffle_index"] = $evJson["shuffleIndex"].getInt(0)
        if evJson.hasKey("crossfadeDuration"): ev.metadata["full_crossfade_duration"] = $evJson["crossfadeDuration"].getInt(0)
        if evJson.hasKey("crossfadeCurve"): ev.metadata["full_crossfade_curve"] = $evJson["crossfadeCurve"].getInt(0)
    else: discard
    result.add(ev)

proc applyPositionCorrection(s: DaemonSession, authPos: float) =
  ## Three-tier position correction: snap (>1s), smooth (10ms–1s), ignore (<10ms).
  ## Uses RTT-compensated error for authoritative position.
  let now = monotonicTime()
  if s.extrapolating and s.state == 1:
    let halfRtt = s.rttEstimate * 0.5
    let expected = s.posBaseValue + (now - s.posBaseTime) * s.clockSkew
    let err = authPos + halfRtt - expected
    let absErr = abs(err)
    if absErr > 1.0:
      s.posBaseTime = now
      s.posBaseValue = authPos + halfRtt
      s.clockSkew = 1.0
    elif absErr > 0.01:
      let dt = now - s.posBaseTime
      if dt > 0.001:
        s.clockSkew = s.clockSkew + err * 0.5 / dt
        s.clockSkew = s.clockSkew.clamp(0.8, 1.2)
  else:
    s.posBaseTime = now
    s.posBaseValue = authPos
  s.extrapolatedPos = authPos
  s.timePos = authPos

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
      if nli >= 0:
        let line = s.buf[0..<nli]
        s.buf = s.buf[nli+1..^1]
        if line.len == 0: continue
        let json = parseJson(line)
        if json.hasKey("events"):
          let events = drainEventLinesFromJson(json, s)
          for ev in events:
            if ev.version > s.lastVersion:
              s.lastVersion = ev.version
            if ev.kind == evPositionChanged:
              s.applyPositionCorrection(ev.floatVal)
            elif ev.kind == evPlaybackStarted:
              s.extrapolating = true
              s.clockSkew = 1.0
              let now = monotonicTime()
              if ev.metadata.hasKey("time_pos"):
                try:
                  let tp = parseFloat(ev.metadata["time_pos"])
                  s.timePos = tp
                  s.extrapolatedPos = tp
                  s.posBaseValue = tp
                except: discard
              else:
                s.timePos = 0.0
                s.extrapolatedPos = 0.0
                s.posBaseValue = 0.0
              s.posBaseTime = now
              if ev.metadata.hasKey("duration"):
                try: s.duration = parseFloat(ev.metadata["duration"]) except: discard
            elif ev.kind == evPlaybackPaused or ev.kind == evPlaybackStopped:
              s.extrapolating = false
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
      elif s.buf.len >= 6 and s.buf[0].byte == WireMagic:
        let totalLen = (int(s.buf[1]) shl 24) or (int(s.buf[2]) shl 16) or
                       (int(s.buf[3]) shl 8) or int(s.buf[4])
        if s.buf.len >= totalLen:
          let binData = s.buf[0..<totalLen]
          s.buf = s.buf[totalLen..^1]
          let events = deserializeEvents(cast[seq[byte]](binData))
          for ev in events:
            if ev.version > s.lastVersion:
              s.lastVersion = ev.version
            if ev.kind == evPositionChanged:
              s.applyPositionCorrection(ev.floatVal)
            elif ev.kind == evPlaybackStarted:
              s.extrapolating = true
              s.clockSkew = 1.0
              let now = monotonicTime()
              if ev.metadata.hasKey("time_pos"):
                try:
                  let tp = parseFloat(ev.metadata["time_pos"])
                  s.timePos = tp
                  s.extrapolatedPos = tp
                  s.posBaseValue = tp
                except: discard
              else:
                s.timePos = 0.0
                s.extrapolatedPos = 0.0
                s.posBaseValue = 0.0
              s.posBaseTime = now
              if ev.metadata.hasKey("duration"):
                try: s.duration = parseFloat(ev.metadata["duration"]) except: discard
            elif ev.kind == evPlaybackPaused or ev.kind == evPlaybackStopped:
              s.extrapolating = false
          result.add(events)
        else:
          break
      else:
        break
  except:
    s.connected = false

proc send*(s: DaemonSession, cmd: JsonNode) =
  if s == nil or s.sock == nil or not s.connected: return
  try:
    if not s.wireNegotiated:
      cmd["wire"] = %2
      if s.lastVersion > 0:
        cmd["lastVersion"] = %s.lastVersion
      s.wireNegotiated = true
    cmd["seq"] = %s.nextSeq
    s.nextSeq.inc
    let data = $cmd & "\n"
    s.sock.send(data)
    s.lastSendTime = monotonicTime()
  except:
    s.connected = false

proc request*(s: DaemonSession, cmd: JsonNode): JsonNode =
  if s == nil or s.sock == nil or not s.connected: return %*{"ok": false, "error": "not connected"}
  try:
    if not s.wireNegotiated:
      cmd["wire"] = %2
      if s.lastVersion > 0:
        cmd["lastVersion"] = %s.lastVersion
      s.wireNegotiated = true
    let seqNo = s.nextSeq
    s.nextSeq.inc
    cmd["seq"] = %seqNo
    let data = $cmd & "\n"
    s.sock.send(data)
    s.lastSendTime = monotonicTime()
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
          let rtt = monotonicTime() - s.lastSendTime
          if rtt > 0 and rtt < 10.0:
            s.rttEstimate = s.rttEstimate * 0.75 + rtt * 0.25
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

# ── AudioBackend method implementations ──────────────────────

method loadFile*(s: DaemonSession, path: string, title: string = "", channel: string = ""): bool =
  s.ensureRunning()
  s.send(%*{"cmd": "load_file", "path": path, "title": title, "channel": channel})
  s.send(%*{"cmd": "play"})
  s.lastState = 1
  return true

method play*(s: DaemonSession) =
  s.ensureRunning()
  s.send(%*{"cmd": "play"})
  s.state = 1

method pause*(s: DaemonSession) =
  s.ensureRunning()
  s.send(%*{"cmd": "pause"})
  s.state = 2

method stop*(s: DaemonSession) =
  s.send(%*{"cmd": "stop"})
  s.state = 0
  s.timePos = 0.0

method seek*(s: DaemonSession, seconds: float) =
  s.send(%*{"cmd": "seek", "seconds": seconds})

method setVolume*(s: DaemonSession, vol: int) =
  s.volume = max(0, min(100, vol))
  s.send(%*{"cmd": "set_volume", "volume": s.volume})

method getVolume*(s: DaemonSession): int =
  s.volume

method togglePause*(s: DaemonSession) =
  s.ensureRunning()
  s.send(%*{"cmd": "toggle_pause"})

method pollEvents*(s: DaemonSession): seq[AudioEvent] =
  s.ensureRunning()
  result = s.drainEvents()
  if s.extrapolating and s.state == 1:
    let now = monotonicTime()
    let elapsed = now - s.posBaseTime
    if elapsed > 0.01:
      let newPos = s.posBaseValue + elapsed * s.clockSkew
      if abs(newPos - s.extrapolatedPos) > 0.01:
        s.extrapolatedPos = newPos
        s.timePos = newPos
        result.add(AudioEvent(kind: evPositionChanged, floatVal: newPos))
  s.lastState = s.state

method shutdown*(s: DaemonSession) =
  s.send(%*{"cmd": "quit"})
  s.connected = false

method getMetadata*(b: DaemonSession, path: string): TrackMetadata =
  let (_, stem, _) = path.splitFile()
  result = TrackMetadata(title: stem)
  let resp = b.daemonSimpleCmd("get_metadata")
  if resp.hasKey("title") and resp["title"].getStr("") != "":
    result.title = resp["title"].getStr("")
  if resp.hasKey("artist"): result.artist = resp["artist"].getStr("")
  if resp.hasKey("album"): result.album = resp["album"].getStr("")
  if resp.hasKey("duration"): result.duration = resp["duration"].getFloat(0.0)
  if result.artist.len == 0 and result.album.len == 0:
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

method readPcmFrames*(s: DaemonSession, output: var seq[float32], maxCount: int) = discard

method prepareNext*(s: DaemonSession, path: string) =
  s.send(%*{"cmd": "prepare_next", "path": path})

method startCrossfade*(s: DaemonSession, durationSeconds: float, reverse: bool = false) =
  s.send(%*{"cmd": "start_crossfade", "duration": durationSeconds, "reverse": reverse})

method getStatusFlags*(s: DaemonSession): tuple[crossfading, masterEnded: bool] =
  let resp = s.daemonSimpleCmd("get_status_flags")
  (crossfading: resp{"crossfading"}.getBool(false), masterEnded: resp{"master_ended"}.getBool(false))

method setEqBand*(s: DaemonSession, band: int, gainDb: float) =
  s.send(%*{"cmd": "set_eq_band", "band": band, "value": gainDb})

method setEqPreset*(s: DaemonSession, name: string) =
  s.send(%*{"cmd": "set_eq_preset", "preset": name})

method setCrossfadeCurve*(s: DaemonSession, curveType: int) =
  s.send(%*{"cmd": "set_crossfade_curve", "curve_type": curveType})

method setSpatialWidth*(s: DaemonSession, width: float) =
  s.send(%*{"cmd": "set_spatial_width", "width": width})

proc newDaemonSession*(): DaemonSession =
  DaemonSession(
    volume: 80, state: 0, backendType: abtDaemon,
    connected: false, buf: "",
    working: true, sleepTimerRemaining: 0,
    ipcTimeoutSec: 3.0, pingMissed: 0, reconnectCooldown: 0,
    extrapolating: false, clockSkew: 1.0, wireNegotiated: false,
    lastVersion: 0, rttEstimate: 0.0, recoveryWindow: 0.5
  )

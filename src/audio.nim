import os, math, posix, tables, json, strutils, osproc

type
  AudioBackendType* = enum abtNone, abtMiniAudio, abtDaemon, abtProcess

  AudioEventKind* = enum
    aekNone, aekPlaybackStarted, aekPlaybackPaused, aekPlaybackStopped,
    aekTrackEnded, aekPositionChanged, aekDurationChanged,
    aekVolumeChanged, aekMetadataChanged, aekError

  AudioEvent* = object
    kind*: AudioEventKind
    floatVal*: float
    intVal*: int
    strVal*: string
    metadata*: Table[string, string]

  TrackMetadata* = object
    title*, artist*, album*: string
    duration*: float
    bitrate*, sampleRate*: int
    extra*: Table[string, string]

  AudioBackend* = ref object of RootObj
    running*: bool
    volume*: int
    timePos*: float
    duration*: float
    state*: int
    metadata*: TrackMetadata
    backendType*: AudioBackendType
    working*: bool

method loadFile*(b: AudioBackend, path: string) {.base.} = discard
method play*(b: AudioBackend) {.base.} = discard
method pause*(b: AudioBackend) {.base.} = discard
method stop*(b: AudioBackend) {.base.} = discard
method seek*(b: AudioBackend, seconds: float) {.base.} = discard
method setVolume*(b: AudioBackend, vol: int) {.base.} = discard
method getVolume*(b: AudioBackend): int {.base.} = 80
method togglePause*(b: AudioBackend) {.base.} = discard
method pollEvents*(b: AudioBackend): seq[AudioEvent] {.base.} = @[]
method shutdown*(b: AudioBackend) {.base.} = discard
method getMetadata*(b: AudioBackend, path: string): TrackMetadata {.base.} = TrackMetadata()

type
  ProcessBackend* = ref object of AudioBackend
    procHandle: Process
    lastPath: string
    paused: bool

method loadFile*(b: ProcessBackend, path: string) =
  b.stop()
  b.timePos = 0.0
  b.duration = 0.0
  b.lastPath = path
  b.state = 0

method play*(b: ProcessBackend) =
  if b.lastPath.len == 0: return
  b.stop()
  let vol = max(0, min(100, b.volume))
  if fileExists(findExe("mpv")):
    b.procHandle = startProcess("mpv", args = @["--no-video", "--volume=" & $vol, b.lastPath],
      options = {poUsePath, poParentStreams})
    b.state = 1; b.running = true; b.paused = false
  elif fileExists(findExe("ffplay")):
    b.procHandle = startProcess("ffplay", args = @["-nodisp", "-autoexit", "-volume=" & $vol, b.lastPath],
      options = {poUsePath, poParentStreams})
    b.state = 1; b.running = true; b.paused = false
  else:
    stderr.writeLine("[gtm] no external player found (mpv or ffplay)")

method pause*(b: ProcessBackend) =
  if b.procHandle != nil:
    discard posix.kill(b.procHandle.processID.cint, posix.SIGSTOP)
    b.paused = true
    if b.state == 1: b.state = 2

method stop*(b: ProcessBackend) =
  if b.procHandle != nil:
    b.procHandle.kill()
    b.procHandle.close()
    b.procHandle = nil
  b.state = 0; b.timePos = 0.0; b.running = false; b.paused = false

method seek*(b: ProcessBackend, seconds: float) = discard

method setVolume*(b: ProcessBackend, vol: int) =
  b.volume = max(0, min(100, vol))

method togglePause*(b: ProcessBackend) =
  if b.paused:
    if b.procHandle != nil:
      discard posix.kill(b.procHandle.processID.cint, posix.SIGCONT)
    b.paused = false; b.state = 1
  else:
    b.pause()

method pollEvents*(b: ProcessBackend): seq[AudioEvent] =
  result = @[]
  if b.running and b.procHandle != nil:
    let status = b.procHandle.peekExitCode()
    if status != -1:
      result.add(AudioEvent(kind: aekTrackEnded))
      b.running = false; b.state = 0

method shutdown*(b: ProcessBackend) = b.stop()

proc newProcessBackend*(): ProcessBackend =
  result = ProcessBackend(
    volume: 80, state: 0, running: false,
    backendType: abtProcess, working: true
  )

when defined(useMiniAudio):
  {.compile: "vendor/miniaudio/miniaudio_impl.c".}
  {.passC: "-Ivendor/miniaudio".}
  {.passL: "-lm -ldl -lpthread".}

  type
    GtmAudioCtx = ptr object

  proc gtm_audio_init(): GtmAudioCtx {.importc.}
  proc gtm_audio_uninit(ctx: GtmAudioCtx) {.importc.}
  proc gtm_audio_load(ctx: GtmAudioCtx, path: cstring): cint {.importc.}
  proc gtm_audio_start(ctx: GtmAudioCtx) {.importc.}
  proc gtm_audio_stop(ctx: GtmAudioCtx) {.importc.}
  proc gtm_audio_seek(ctx: GtmAudioCtx, seconds: cdouble) {.importc.}
  proc gtm_audio_set_volume(ctx: GtmAudioCtx, volume: cfloat) {.importc.}
  proc gtm_audio_get_time(ctx: GtmAudioCtx): cdouble {.importc.}
  proc gtm_audio_get_duration(ctx: GtmAudioCtx): cdouble {.importc.}
  proc gtm_audio_is_playing(ctx: GtmAudioCtx): cint {.importc.}

  type
    MiniAudioBackend* = ref object of AudioBackend
      ctx: GtmAudioCtx
      lastTime: float
      lastPlaying: bool

  method loadFile*(b: MiniAudioBackend, path: string) =
    b.stop()
    b.timePos = 0.0
    b.duration = 0.0
    b.lastTime = 0.0
    b.lastPlaying = false
    stderr.writeLine("[gtm] MiniAudioBackend.loadFile: " & path)
    if b.ctx == nil:
      stderr.writeLine("[gtm] ctx is nil, can't load")
      b.state = 0
      return
    if gtm_audio_load(b.ctx, path.cstring) == 0:
      stderr.writeLine("[gtm] gtm_audio_load returned 0 for: " & path)
      b.state = 0
      return
    b.metadata = b.getMetadata(path)
    b.duration = gtm_audio_get_duration(b.ctx)
    stderr.writeLine("[gtm] loaded: " & path & ", duration: " & $b.duration)
    b.state = 0

  method play*(b: MiniAudioBackend) =
    gtm_audio_start(b.ctx)
    b.state = 1
    b.running = true

  method pause*(b: MiniAudioBackend) =
    gtm_audio_stop(b.ctx)
    if b.state == 1: b.state = 2

  method stop*(b: MiniAudioBackend) =
    gtm_audio_stop(b.ctx)
    b.state = 0
    b.timePos = 0.0
    b.running = false
    b.lastPlaying = false

  method seek*(b: MiniAudioBackend, seconds: float) =
    gtm_audio_seek(b.ctx, seconds)
    b.timePos = gtm_audio_get_time(b.ctx)
    if seconds > 0 and b.state == 1: discard

  method setVolume*(b: MiniAudioBackend, vol: int) =
    b.volume = max(0, min(100, vol))
    gtm_audio_set_volume(b.ctx, float(b.volume) / 100.0)

  method togglePause*(b: MiniAudioBackend) =
    case b.state
    of 1: b.pause()
    of 2: b.play()
    else: discard

  method pollEvents*(b: MiniAudioBackend): seq[AudioEvent] =
    result = @[]
    if b.ctx == nil: return
    let nowPlaying = gtm_audio_is_playing(b.ctx) != 0
    let nowTime = gtm_audio_get_time(b.ctx)
    if nowPlaying and not b.lastPlaying:
      result.add(AudioEvent(kind: aekPlaybackStarted))
      if b.duration == 0.0:
        b.duration = gtm_audio_get_duration(b.ctx)
        result.add(AudioEvent(kind: aekDurationChanged, floatVal: b.duration))
    elif not nowPlaying and b.lastPlaying:
      result.add(AudioEvent(kind: aekPlaybackStopped))
    if nowPlaying and abs(nowTime - b.lastTime) > 0.01:
      result.add(AudioEvent(kind: aekPositionChanged, floatVal: nowTime))
    b.lastPlaying = nowPlaying
    b.lastTime = nowTime
    b.timePos = nowTime
    b.state = if nowPlaying: 1 elif b.state != 0: 2 else: 0

  method shutdown*(b: MiniAudioBackend) =
    b.stop()
    if b.ctx != nil:
      gtm_audio_uninit(b.ctx)
      b.ctx = nil

  method getMetadata*(b: MiniAudioBackend, path: string): TrackMetadata =
    result = TrackMetadata(title: path.splitPath().tail)
    let output = execProcess("ffprobe", args = @["-v", "quiet", "-print_format", "json", "-show_format", path],
                             options = {poUsePath})
    if output.len == 0: return
    try:
      let j = parseJson(output)
      let fmt = j{"format"}
      if fmt.isNil: return
      if fmt.hasKey("duration"):
        result.duration = fmt["duration"].getFloat(0.0)
      if fmt.hasKey("bit_rate"):
        result.bitrate = fmt["bit_rate"].getInt(0)
      let tags = fmt{"tags"}
      if not tags.isNil:
        if tags.hasKey("title"): result.title = tags["title"].getStr(result.title)
        if tags.hasKey("artist"): result.artist = tags["artist"].getStr("")
        if tags.hasKey("album"): result.album = tags["album"].getStr("")
    except:
      discard

  proc newMiniAudioBackend*(): MiniAudioBackend =
    result = MiniAudioBackend(
      volume: 80, state: 0, running: false,
      backendType: abtMiniAudio, working: false
    )
    result.ctx = gtm_audio_init()
    result.working = result.ctx != nil
    if not result.working:
      stderr.writeLine("[gtm] miniaudio init failed: no audio device available")

proc newAudioBackend*(backendType: AudioBackendType): AudioBackend =
  case backendType
  of abtMiniAudio:
    result = newMiniAudioBackend()
  else:
    result = nil

proc formatTime*(seconds: float): string =
  if seconds <= 0: return "0:00"
  let total = seconds.int
  let m = total div 60
  let s = total mod 60
  $m & ":" & (if s < 10: "0" else: "") & $s

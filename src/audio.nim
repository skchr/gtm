import os, math, posix, tables

type
  AudioBackendType* = enum abtNone, abtMiniAudio, abtDaemon

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
    b.metadata.title = path.splitPath().tail
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

  proc newMiniAudioBackend*(): MiniAudioBackend =
    result = MiniAudioBackend(
      volume: 80, state: 0, running: false,
      backendType: abtMiniAudio
    )
    result.ctx = gtm_audio_init()
    if result.ctx == nil:
      stderr.writeLine("[gtm] miniaudio init failed: no audio device available")

else:
  type
    MiniAudioBackend* = ref object of AudioBackend
      dummy: bool

  proc newMiniAudioBackend*(): MiniAudioBackend =
    MiniAudioBackend(
      volume: 80, state: 0, running: false, backendType: abtMiniAudio
    )

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

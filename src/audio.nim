import os, math, posix, tables, osproc

type
  AudioBackendType* = enum abtNone, abtFFmpeg, abtDaemon, abtProcess, abtMixer

  AudioEventKind* = enum
    aekNone, aekPlaybackStarted, aekPlaybackPaused, aekPlaybackStopped,
    aekTrackEnded, aekPositionChanged, aekDurationChanged,
    aekVolumeChanged, aekMetadataChanged, aekError,
    aekCustomEvent

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
    lastState*: int
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
method readPcmFrames*(b: AudioBackend, output: var seq[float32], maxCount: int) {.base.} = discard
method prepareNext*(b: AudioBackend, path: string) {.base.} = discard
method startCrossfade*(b: AudioBackend, durationSeconds: float) {.base.} = discard
method getStatusFlags*(b: AudioBackend): tuple[crossfading, masterEnded: bool] {.base.} = (false, false)
method setEqBand*(b: AudioBackend, band: int, gainDb: float) {.base.} = discard
method setEqPreset*(b: AudioBackend, name: string) {.base.} = discard

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

when defined(useFFmpeg):
  {.compile: "vendor/ffmpeg/ffmpeg_impl.c".}
  {.passL: staticExec("pkg-config --libs libavformat libavcodec libavutil libswresample alsa").}
  {.passC: staticExec("pkg-config --cflags libavformat libavcodec libavutil libswresample alsa").}

  type
    FfmpegCtx = ptr object

  proc ffmpeg_audio_init(): FfmpegCtx {.importc.}
  proc ffmpeg_audio_uninit(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_audio_load(ctx: FfmpegCtx, path: cstring): cint {.importc.}
  proc ffmpeg_audio_start(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_audio_pause(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_audio_stop(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_audio_seek(ctx: FfmpegCtx, seconds: cdouble) {.importc.}
  proc ffmpeg_audio_set_volume(ctx: FfmpegCtx, volume: cfloat) {.importc.}
  proc ffmpeg_audio_get_time(ctx: FfmpegCtx): cdouble {.importc.}
  proc ffmpeg_audio_get_duration(ctx: FfmpegCtx): cdouble {.importc.}
  proc ffmpeg_audio_is_playing(ctx: FfmpegCtx): cint {.importc.}
  proc ffmpeg_audio_read_pcm(ctx: FfmpegCtx, output: ptr float32, count: cint): cint {.importc.}
  proc ffmpeg_audio_get_metadata(ctx: FfmpegCtx, title, artist, album: ptr cstring, duration: ptr cdouble) {.importc.}

  proc ffmpeg_mixer_init(): FfmpegCtx {.importc.}
  proc ffmpeg_mixer_uninit(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_mixer_load_master(ctx: FfmpegCtx, path: cstring): cint {.importc.}
  proc ffmpeg_mixer_load_slave(ctx: FfmpegCtx, path: cstring): cint {.importc.}
  proc ffmpeg_mixer_start(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_mixer_pause(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_mixer_stop(ctx: FfmpegCtx) {.importc.}
  proc ffmpeg_mixer_seek(ctx: FfmpegCtx, seconds: cdouble) {.importc.}
  proc ffmpeg_mixer_set_volume(ctx: FfmpegCtx, volume: cfloat) {.importc.}
  proc ffmpeg_mixer_get_time(ctx: FfmpegCtx): cdouble {.importc.}
  proc ffmpeg_mixer_get_duration(ctx: FfmpegCtx): cdouble {.importc.}
  proc ffmpeg_mixer_is_playing(ctx: FfmpegCtx): cint {.importc.}
  proc ffmpeg_mixer_is_crossfading(ctx: FfmpegCtx): cint {.importc.}
  proc ffmpeg_mixer_master_ended(ctx: FfmpegCtx): cint {.importc.}
  proc ffmpeg_mixer_read_pcm(ctx: FfmpegCtx, output: ptr float32, count: cint): cint {.importc.}
  proc ffmpeg_mixer_get_metadata(ctx: FfmpegCtx, title, artist, album: ptr cstring, duration: ptr cdouble) {.importc.}
  proc ffmpeg_mixer_start_crossfade(ctx: FfmpegCtx, duration_frames: cint) {.importc.}
  proc ffmpeg_mixer_set_eq_band(ctx: FfmpegCtx, band: cint, gain_db: cfloat): cint {.importc.}
  proc ffmpeg_mixer_set_eq_preset(ctx: FfmpegCtx, name: cstring): cint {.importc.}

  type
    FfmpegBackend* = ref object of AudioBackend
      ctx: FfmpegCtx
      lastTime: float
      lastPlaying: bool

  method readPcmFrames*(b: FfmpegBackend, output: var seq[float32], maxCount: int) =
    if b.ctx == nil: return
    output.setLen(maxCount)
    let framesRead = ffmpeg_audio_read_pcm(b.ctx, addr output[0], maxCount.cint)
    if framesRead > 0:
      output.setLen(framesRead)
    else:
      output.setLen(0)

  method loadFile*(b: FfmpegBackend, path: string) =
    b.stop()
    b.timePos = 0.0
    b.duration = 0.0
    b.lastTime = 0.0
    b.lastPlaying = false
    if b.ctx == nil:
      b.state = 0
      return
    if ffmpeg_audio_load(b.ctx, path.cstring) == 0:
      b.state = 0
      return
    b.metadata = b.getMetadata(path)
    b.duration = ffmpeg_audio_get_duration(b.ctx)
    b.state = 0

  method play*(b: FfmpegBackend) =
    ffmpeg_audio_start(b.ctx)
    b.state = 1
    b.running = true

  method pause*(b: FfmpegBackend) =
    ffmpeg_audio_pause(b.ctx)
    if b.state == 1: b.state = 2

  method stop*(b: FfmpegBackend) =
    ffmpeg_audio_stop(b.ctx)
    b.state = 0
    b.timePos = 0.0
    b.running = false
    b.lastPlaying = false

  method seek*(b: FfmpegBackend, seconds: float) =
    ffmpeg_audio_seek(b.ctx, seconds)
    b.timePos = ffmpeg_audio_get_time(b.ctx)

  method setVolume*(b: FfmpegBackend, vol: int) =
    b.volume = max(0, min(100, vol))
    ffmpeg_audio_set_volume(b.ctx, float(b.volume) / 100.0)

  method togglePause*(b: FfmpegBackend) =
    case b.state
    of 1: b.pause()
    of 2: b.play()
    of 0: b.play()
    else: b.play()

  method pollEvents*(b: FfmpegBackend): seq[AudioEvent] =
    result = @[]
    if b.ctx == nil: return
    let nowPlaying = ffmpeg_audio_is_playing(b.ctx) != 0
    let nowTime = ffmpeg_audio_get_time(b.ctx)
    let nowState = if nowPlaying: 1 elif b.state != 0: 2 else: 0
    if b.lastState == 1 and nowState == 2:
      result.add(AudioEvent(kind: aekPlaybackPaused))
    elif b.lastState == 2 and nowState == 1:
      result.add(AudioEvent(kind: aekPlaybackStarted))
    elif b.lastState == 1 and nowState == 0:
      result.add(AudioEvent(kind: aekPlaybackStopped))
    elif b.lastState == 0 and nowState == 1:
      result.add(AudioEvent(kind: aekPlaybackStarted))
    if nowState == 1 and abs(nowTime - b.lastTime) > 1.0:
      result.add(AudioEvent(kind: aekPositionChanged, floatVal: nowTime))
      b.lastTime = nowTime
    b.lastPlaying = nowPlaying
    b.timePos = nowTime
    b.lastState = nowState
    b.state = nowState

  method shutdown*(b: FfmpegBackend) =
    b.stop()
    if b.ctx != nil:
      ffmpeg_audio_uninit(b.ctx)
      b.ctx = nil

  method getMetadata*(b: FfmpegBackend, path: string): TrackMetadata =
    result = TrackMetadata(title: path.splitPath().tail)
    if b.ctx == nil: return
    var ctitle, cartist, calbum: cstring
    var cduration: cdouble
    ffmpeg_audio_get_metadata(b.ctx, addr ctitle, addr cartist, addr calbum, addr cduration)
    if ctitle != nil and $ctitle != "": result.title = $ctitle
    if cartist != nil: result.artist = $cartist
    if calbum != nil: result.album = $calbum
    if cduration > 0: result.duration = cduration

  proc newFfmpegBackend*(): FfmpegBackend =
    result = FfmpegBackend(
      volume: 80, state: 0, running: false,
      backendType: abtFFmpeg, working: true
    )
    result.ctx = ffmpeg_audio_init()
    result.working = result.ctx != nil
    if not result.working:
      stderr.writeLine("[gtm] FFmpeg init failed: could not allocate context")

  type
    MixerBackend* = ref object of AudioBackend
      ctx: FfmpegCtx
      lastTime: float
      lastPlaying: bool
      lastCrossfading: bool

  method readPcmFrames*(b: MixerBackend, output: var seq[float32], maxCount: int) =
    if b.ctx == nil: return
    output.setLen(maxCount)
    let framesRead = ffmpeg_mixer_read_pcm(b.ctx, addr output[0], maxCount.cint)
    if framesRead > 0:
      output.setLen(framesRead)
    else:
      output.setLen(0)

  method loadFile*(b: MixerBackend, path: string) =
    b.stop()
    b.timePos = 0.0
    b.duration = 0.0
    b.lastTime = 0.0
    b.lastPlaying = false
    b.lastCrossfading = false
    if b.ctx == nil:
      b.state = 0
      return
    if ffmpeg_mixer_load_master(b.ctx, path.cstring) == 0:
      b.state = 0
      return
    b.metadata = b.getMetadata(path)
    b.duration = ffmpeg_mixer_get_duration(b.ctx)
    b.state = 0

  method play*(b: MixerBackend) =
    ffmpeg_mixer_start(b.ctx)
    b.state = 1
    b.running = true

  method pause*(b: MixerBackend) =
    ffmpeg_mixer_pause(b.ctx)
    if b.state == 1: b.state = 2

  method stop*(b: MixerBackend) =
    ffmpeg_mixer_stop(b.ctx)
    b.state = 0
    b.timePos = 0.0
    b.running = false
    b.lastPlaying = false
    b.lastCrossfading = false

  method seek*(b: MixerBackend, seconds: float) =
    ffmpeg_mixer_seek(b.ctx, seconds)
    b.timePos = ffmpeg_mixer_get_time(b.ctx)

  method setVolume*(b: MixerBackend, vol: int) =
    b.volume = max(0, min(100, vol))
    ffmpeg_mixer_set_volume(b.ctx, float(b.volume) / 100.0)

  method togglePause*(b: MixerBackend) =
    case b.state
    of 1: b.pause()
    of 2: b.play()
    of 0: b.play()
    else: b.play()

  method prepareNext*(b: MixerBackend, path: string) =
    discard ffmpeg_mixer_load_slave(b.ctx, path.cstring)

  method startCrossfade*(b: MixerBackend, durationSeconds: float) =
    if b.ctx == nil or b.duration <= 0: return
    let sampleRate = 44100  # default, matched to master
    let frames = (durationSeconds * sampleRate.float32).cint
    ffmpeg_mixer_start_crossfade(b.ctx, frames)

  method getStatusFlags*(b: MixerBackend): tuple[crossfading, masterEnded: bool] =
    if b.ctx == nil: return (false, false)
    result = (
      ffmpeg_mixer_is_crossfading(b.ctx) != 0,
      ffmpeg_mixer_master_ended(b.ctx) != 0
    )

  method setEqBand*(b: MixerBackend, band: int, gainDb: float) =
    discard ffmpeg_mixer_set_eq_band(b.ctx, band.cint, gainDb.cfloat)

  method setEqPreset*(b: MixerBackend, name: string) =
    discard ffmpeg_mixer_set_eq_preset(b.ctx, name.cstring)

  method pollEvents*(b: MixerBackend): seq[AudioEvent] =
    result = @[]
    if b.ctx == nil: return
    let nowPlaying = ffmpeg_mixer_is_playing(b.ctx) != 0
    let nowTime = ffmpeg_mixer_get_time(b.ctx)
    let nowCrossfading = ffmpeg_mixer_is_crossfading(b.ctx) != 0
    let nowState = if nowPlaying: 1 elif b.state != 0: 2 else: 0
    if b.lastState == 1 and nowState == 2:
      result.add(AudioEvent(kind: aekPlaybackPaused))
    elif b.lastState == 2 and nowState == 1:
      result.add(AudioEvent(kind: aekPlaybackStarted))
    elif b.lastState == 1 and nowState == 0:
      result.add(AudioEvent(kind: aekPlaybackStopped))
    elif b.lastState == 0 and nowState == 1:
      result.add(AudioEvent(kind: aekPlaybackStarted))
    if nowState == 1 and abs(nowTime - b.lastTime) > 1.0:
      result.add(AudioEvent(kind: aekPositionChanged, floatVal: nowTime))
      b.lastTime = nowTime
    if nowCrossfading and not b.lastCrossfading:
      result.add(AudioEvent(kind: aekMetadataChanged, strVal: "crossfade_started"))
    elif not nowCrossfading and b.lastCrossfading:
      result.add(AudioEvent(kind: aekMetadataChanged, strVal: "crossfade_ended"))
    if ffmpeg_mixer_master_ended(b.ctx) != 0 and b.lastPlaying:
      result.add(AudioEvent(kind: aekTrackEnded))
    b.lastPlaying = nowPlaying
    b.lastCrossfading = nowCrossfading
    b.timePos = nowTime
    b.lastState = nowState
    b.state = nowState

  method shutdown*(b: MixerBackend) =
    b.stop()
    if b.ctx != nil:
      ffmpeg_mixer_uninit(b.ctx)
      b.ctx = nil

  method getMetadata*(b: MixerBackend, path: string): TrackMetadata =
    result = TrackMetadata(title: path.splitPath().tail)
    if b.ctx == nil: return
    var ctitle, cartist, calbum: cstring
    var cduration: cdouble
    ffmpeg_mixer_get_metadata(b.ctx, addr ctitle, addr cartist, addr calbum, addr cduration)
    if ctitle != nil and $ctitle != "": result.title = $ctitle
    if cartist != nil: result.artist = $cartist
    if calbum != nil: result.album = $calbum
    if cduration > 0: result.duration = cduration

  proc newMixerBackend*(): MixerBackend =
    result = MixerBackend(
      volume: 80, state: 0, running: false,
      backendType: abtMixer, working: true
    )
    result.ctx = ffmpeg_mixer_init()
    result.working = result.ctx != nil
    if not result.working:
      stderr.writeLine("[gtm] Mixer init failed: could not allocate context")

proc newAudioBackend*(backendType: AudioBackendType): AudioBackend =
  case backendType
  of abtFFmpeg:
    result = newFfmpegBackend()
  of abtMixer:
    when defined(useFFmpeg):
      result = newMixerBackend()
    else:
      result = nil
  else:
    result = nil

proc formatTime*(seconds: float): string =
  if seconds <= 0: return "0:00"
  let total = seconds.int
  let h = total div 3600
  let m = (total mod 3600) div 60
  let s = total mod 60
  if h > 0:
    $h & ":" & (if m < 10: "0" else: "") & $m & ":" & (if s < 10: "0" else: "") & $s
  else:
    $m & ":" & (if s < 10: "0" else: "") & $s

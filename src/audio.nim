## Audio backend abstraction and event system
##
## Defines the polymorphic AudioBackend type hierarchy and the event
## protocol used to communicate playback state changes (position,
## volume, metadata, errors) from the backend to the daemon's main loop.
##
## ┌──────────────────────────────────────────────────────────┐
## │  AudioBackend (ref object of RootObj)                     │
## │                                                          │
## │  Fields: running, volume, timePos, duration, paused, ... │
## │  ┌────────────────────────────────────────────────┐      │
## │  │  pollEvents(): seq[AudioEvent]                 │      │
## │  │  (called every ~16ms by daemon main loop)      │      │
## │  └────────────────────────────────────────────────┘      │
## │                       ▲                                  │
## │                       │ (inherits)                       │
## │         ┌─────────────┴─────────────┐                    │
## │         ▼                           ▼                    │
## │  ┌──────────────┐          ┌──────────────┐              │
## │  │FfmpegBackend │          │ MixerBackend │              │
## │  │ (spawns      │          │ (ALSA mixing │              │
## │  │  ffplay via  │          │  + internal   │              │
## │  │  popen/pipe) │          │  decoder)     │              │
## │  └──────────────┘          └──────────────┘              │
## │                                                          │
## │  DummyBackend — no-op stub (unused)                      │
## │  DaemonClient (in client.nim) inherits AudioBackend      │
## │    to expose the same pollEvents() interface for TUI     │
## └──────────────────────────────────────────────────────────┘

import os, math, strutils, posix, tables

type
  AudioBackendType* = enum abtNone, abtFFmpeg, abtDaemon, abtMixer

  AudioEventKind* = enum
    evNone, evPlaybackStarted, evPlaybackPaused, evPlaybackStopped,
    evTrackEnded, evPositionChanged, evDurationChanged,
    evVolumeChanged, evMetadataChanged, evError,
    evCustomEvent

  AudioEvent* = object
    kind*: AudioEventKind
    floatVal*: float
    intVal*: int
    strVal*: string
    version*: int
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

method loadFile*(b: AudioBackend, path: string, title: string = "", channel: string = ""): bool {.base, gcsafe.} = false
method play*(b: AudioBackend) {.base, gcsafe.} = discard
method pause*(b: AudioBackend) {.base, gcsafe.} = discard
method stop*(b: AudioBackend) {.base, gcsafe.} = discard
method seek*(b: AudioBackend, seconds: float) {.base, gcsafe.} = discard
method setVolume*(b: AudioBackend, vol: int) {.base, gcsafe.} = discard
method getVolume*(b: AudioBackend): int {.base, gcsafe.} = 80
method togglePause*(b: AudioBackend) {.base, gcsafe.} = discard
method pollEvents*(b: AudioBackend): seq[AudioEvent] {.base, gcsafe.} = @[]
method shutdown*(b: AudioBackend) {.base, gcsafe.} = discard
method getMetadata*(b: AudioBackend, path: string): TrackMetadata {.base, gcsafe.} = TrackMetadata()
method readPcmFrames*(b: AudioBackend, output: var seq[float32], maxCount: int) {.base, gcsafe.} = discard
method prepareNext*(b: AudioBackend, path: string) {.base, gcsafe.} = discard
method startCrossfade*(b: AudioBackend, durationSeconds: float, reverse: bool = false) {.base, gcsafe.} = discard
method getStatusFlags*(b: AudioBackend): tuple[crossfading, masterEnded: bool] {.base, gcsafe.} = (false, false)
method setEqBand*(b: AudioBackend, band: int, gainDb: float) {.base, gcsafe.} = discard
method setEqPreset*(b: AudioBackend, name: string) {.base, gcsafe.} = discard
method setCrossfadeCurve*(b: AudioBackend, curveType: int) {.base, gcsafe.} = discard
method setSpatialWidth*(b: AudioBackend, width: float) {.base, gcsafe.} = discard

when defined(useFFmpeg):
  {.compile: "vendor/ffmpeg/ffmpeg_impl.c".}
  when defined(staticFfmpeg) or defined(android):
    when defined(android):
      {.passL: staticExec("pkg-config --static --libs libavformat libavcodec libavutil libswresample").}
      {.passC: staticExec("pkg-config --cflags libavformat libavcodec libavutil libswresample").}
    else:
      {.passL: staticExec("pkg-config --static --libs libavformat libavcodec libavutil libswresample") & " " & staticExec("pkg-config --libs alsa").}
      {.passC: staticExec("pkg-config --cflags libavformat libavcodec libavutil libswresample") & " " & staticExec("pkg-config --cflags alsa").}
  elif defined(macosx):
    {.passL: staticExec("pkg-config --libs libavformat libavcodec libavutil libswresample").}
    {.passC: staticExec("pkg-config --cflags libavformat libavcodec libavutil libswresample").}
  else:
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
  proc ffmpeg_extract_cover(path: cstring, outData: ptr pointer, outSize: ptr cuint, outMime: ptr cstring): cint {.importc.}
  proc ffmpeg_free_cover_data(data: pointer, mime: cstring) {.importc.}

  proc extractCoverArt*(path: string): tuple[data: seq[byte], mime: string] =
    var outData: pointer
    var outSize: cuint
    var outMime: cstring
    if ffmpeg_extract_cover(path.cstring, addr outData, addr outSize, addr outMime) != 0:
      if outData != nil and outSize > 0:
        var bytes = newSeq[byte](outSize)
        copyMem(addr bytes[0], outData, outSize)
        let mime = if outMime != nil: $outMime else: "image/jpeg"
        ffmpeg_free_cover_data(outData, outMime)
        return (bytes, mime)
      if outMime != nil: ffmpeg_free_cover_data(nil, outMime)
    result = (@[], "")

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
  proc ffmpeg_mixer_get_sample_rate(ctx: FfmpegCtx): cint {.importc.}
  proc ffmpeg_mixer_read_pcm(ctx: FfmpegCtx, output: ptr float32, count: cint): cint {.importc.}
  proc ffmpeg_mixer_get_metadata(ctx: FfmpegCtx, title, artist, album: ptr cstring, duration: ptr cdouble) {.importc.}
  proc ffmpeg_mixer_start_crossfade(ctx: FfmpegCtx, duration_frames: cint, reverse: cint = 0) {.importc.}
  proc ffmpeg_mixer_set_crossfade_curve(ctx: FfmpegCtx, curve_type: cint) {.importc.}
  proc ffmpeg_mixer_set_eq_band(ctx: FfmpegCtx, band: cint, gain_db: cfloat): cint {.importc.}
  proc ffmpeg_mixer_set_eq_preset(ctx: FfmpegCtx, name: cstring): cint {.importc.}
  proc ffmpeg_mixer_set_spatial_width(ctx: FfmpegCtx, width: cfloat): cint {.importc.}

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

  method loadFile*(b: FfmpegBackend, path: string, title: string = "", channel: string = ""): bool =
    b.stop()
    b.timePos = 0.0
    b.duration = 0.0
    b.lastTime = 0.0
    b.lastPlaying = false
    if b.ctx == nil:
      b.state = 0
      return false
    if ffmpeg_audio_load(b.ctx, path.cstring) == 0:
      b.state = 0
      return false
    b.metadata = b.getMetadata(path)
    b.duration = ffmpeg_audio_get_duration(b.ctx)
    b.state = 0
    return true

  method play*(b: FfmpegBackend) =
    if b.ctx == nil: return
    ffmpeg_audio_start(b.ctx)
    b.state = 1
    b.running = true

  method pause*(b: FfmpegBackend) =
    if b.ctx == nil: return
    ffmpeg_audio_pause(b.ctx)
    if b.state == 1: b.state = 2

  method stop*(b: FfmpegBackend) =
    if b.ctx == nil: return
    ffmpeg_audio_stop(b.ctx)
    b.state = 0
    b.timePos = 0.0
    b.running = false
    b.lastPlaying = false

  method seek*(b: FfmpegBackend, seconds: float) =
    if b.ctx == nil: return
    ffmpeg_audio_seek(b.ctx, seconds)
    b.timePos = ffmpeg_audio_get_time(b.ctx)

  method setVolume*(b: FfmpegBackend, vol: int) =
    if b.ctx == nil: return
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
      result.add(AudioEvent(kind: evPlaybackPaused))
    elif b.lastState == 2 and nowState == 1:
      result.add(AudioEvent(kind: evPlaybackStarted))
    elif b.lastState == 1 and nowState == 0:
      result.add(AudioEvent(kind: evPlaybackStopped))
    elif b.lastState == 0 and nowState == 1:
      result.add(AudioEvent(kind: evPlaybackStarted))
    if nowState == 1 and abs(nowTime - b.lastTime) > 0.1:
      result.add(AudioEvent(kind: evPositionChanged, floatVal: nowTime))
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
    let (_, stem, _) = path.splitFile()
    result = TrackMetadata(title: stem)
    if b.ctx == nil: return
    var ctitle, cartist, calbum: cstring
    var cduration: cdouble
    ffmpeg_audio_get_metadata(b.ctx, addr ctitle, addr cartist, addr calbum, addr cduration)
    if ctitle != nil and $ctitle != "": result.title = $ctitle
    if cartist != nil: result.artist = $cartist
    if calbum != nil: result.album = $calbum
    if cduration > 0: result.duration = cduration
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

  method loadFile*(b: MixerBackend, path: string, title: string = "", channel: string = ""): bool =
    b.stop()
    b.timePos = 0.0
    b.duration = 0.0
    b.lastTime = 0.0
    b.lastPlaying = false
    b.lastCrossfading = false
    if b.ctx == nil:
      b.state = 0
      return false
    if ffmpeg_mixer_load_master(b.ctx, path.cstring) == 0:
      b.state = 0
      return false
    b.metadata = b.getMetadata(path)
    b.duration = ffmpeg_mixer_get_duration(b.ctx)
    b.state = 0
    return true

  method play*(b: MixerBackend) =
    if b.ctx == nil: return
    ffmpeg_mixer_start(b.ctx)
    b.state = 1
    b.running = true

  method pause*(b: MixerBackend) =
    if b.ctx == nil: return
    ffmpeg_mixer_pause(b.ctx)
    if b.state == 1: b.state = 2

  method stop*(b: MixerBackend) =
    if b.ctx == nil: return
    ffmpeg_mixer_stop(b.ctx)
    b.state = 0
    b.timePos = 0.0
    b.running = false
    b.lastPlaying = false
    b.lastCrossfading = false

  method seek*(b: MixerBackend, seconds: float) =
    if b.ctx == nil: return
    ffmpeg_mixer_seek(b.ctx, seconds)
    b.timePos = ffmpeg_mixer_get_time(b.ctx)

  method setVolume*(b: MixerBackend, vol: int) =
    if b.ctx == nil: return
    b.volume = max(0, min(100, vol))
    ffmpeg_mixer_set_volume(b.ctx, float(b.volume) / 100.0)

  method togglePause*(b: MixerBackend) =
    case b.state
    of 1: b.pause()
    of 2: b.play()
    of 0: b.play()
    else: b.play()

  method prepareNext*(b: MixerBackend, path: string) =
    if b.ctx == nil: return
    discard ffmpeg_mixer_load_slave(b.ctx, path.cstring)

  method startCrossfade*(b: MixerBackend, durationSeconds: float, reverse: bool = false) =
    if b.ctx == nil or b.duration <= 0: return
    let sampleRate = ffmpeg_mixer_get_sample_rate(b.ctx)
    if sampleRate <= 0: return
    let framesFloat = durationSeconds * sampleRate.float32
    let frames = if framesFloat <= 0.0: 0.cint else: framesFloat.cint
    if frames <= 0: return
    ffmpeg_mixer_start_crossfade(b.ctx, frames, reverse.cint)

  method getStatusFlags*(b: MixerBackend): tuple[crossfading, masterEnded: bool] =
    if b.ctx == nil: return (false, false)
    result = (
      ffmpeg_mixer_is_crossfading(b.ctx) != 0,
      ffmpeg_mixer_master_ended(b.ctx) != 0
    )

  method setEqBand*(b: MixerBackend, band: int, gainDb: float) =
    if b.ctx == nil: return
    discard ffmpeg_mixer_set_eq_band(b.ctx, band.cint, gainDb.cfloat)

  method setEqPreset*(b: MixerBackend, name: string) =
    if b.ctx == nil: return
    discard ffmpeg_mixer_set_eq_preset(b.ctx, name.cstring)

  method setCrossfadeCurve*(b: MixerBackend, curveType: int) =
    if b.ctx == nil: return
    ffmpeg_mixer_set_crossfade_curve(b.ctx, curveType.cint)

  method setSpatialWidth*(b: MixerBackend, width: float) =
    if b.ctx == nil: return
    discard ffmpeg_mixer_set_spatial_width(b.ctx, width.cfloat)

  method pollEvents*(b: MixerBackend): seq[AudioEvent] =
    result = @[]
    if b.ctx == nil: return
    let nowPlaying = ffmpeg_mixer_is_playing(b.ctx) != 0
    let nowTime = ffmpeg_mixer_get_time(b.ctx)
    let nowCrossfading = ffmpeg_mixer_is_crossfading(b.ctx) != 0
    let masterEnded = ffmpeg_mixer_master_ended(b.ctx) != 0
    let nowState = if nowPlaying: 1 elif masterEnded: 0 elif b.state != 0: 2 else: 0
    if b.lastState == 1 and nowState == 2:
      result.add(AudioEvent(kind: evPlaybackPaused))
    elif b.lastState == 2 and nowState == 1:
      result.add(AudioEvent(kind: evPlaybackStarted))
    elif b.lastState == 1 and nowState == 0:
      result.add(AudioEvent(kind: evPlaybackStopped))
    elif b.lastState == 0 and nowState == 1:
      result.add(AudioEvent(kind: evPlaybackStarted))
    if nowState == 1 and abs(nowTime - b.lastTime) > 0.1:
      result.add(AudioEvent(kind: evPositionChanged, floatVal: nowTime))
      b.lastTime = nowTime
    if nowCrossfading and not b.lastCrossfading:
      result.add(AudioEvent(kind: evMetadataChanged, strVal: "crossfade_started"))
    elif not nowCrossfading and b.lastCrossfading:
      result.add(AudioEvent(kind: evMetadataChanged, strVal: "crossfade_ended"))
    if ffmpeg_mixer_master_ended(b.ctx) != 0 and b.lastPlaying:
      result.add(AudioEvent(kind: evTrackEnded))
      # After crossfade auto-promotion, the new master is already playing
      # but no PlaybackStarted is emitted because state stays 1→1
      if ffmpeg_mixer_is_playing(b.ctx) != 0:
        result.add(AudioEvent(kind: evPlaybackStarted))
      b.duration = ffmpeg_mixer_get_duration(b.ctx)
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
    let (_, stem, _) = path.splitFile()
    result = TrackMetadata(title: stem)
    if b.ctx == nil: return
    var ctitle, cartist, calbum: cstring
    var cduration: cdouble
    ffmpeg_mixer_get_metadata(b.ctx, addr ctitle, addr cartist, addr calbum, addr cduration)
    if ctitle != nil and $ctitle != "": result.title = $ctitle
    if cartist != nil: result.artist = $cartist
    if calbum != nil: result.album = $calbum
    if cduration > 0: result.duration = cduration
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

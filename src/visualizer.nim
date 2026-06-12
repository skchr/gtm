import math, posix

const
  FFT_SIZE* = 1024
  MAX_VIS_BARS* = 64
  MIN_VIS_BARS* = 4
  PCM_RING_SIZE* = FFT_SIZE * 8
  WATERFALL_COLS* = 256
  FFT_HOP_SIZE* = FFT_SIZE div 2

type
  PcmRingBuffer* = object
    data: ptr UncheckedArray[float32]
    writePos: ptr int32
    readPos: ptr int32
    size: int32
    fd: cint
    shmName: string

  Visualizer* = ref object
    shm: PcmRingBuffer
    bins*: array[MAX_VIS_BARS, float]
    smoothBins*: array[MAX_VIS_BARS, float]
    peakVals*: array[MAX_VIS_BARS, float]
    running*: bool
    barCount*: int
    pcmBuf: seq[float32]
    overlapBuf: seq[float32]
    waterfall*: seq[array[MAX_VIS_BARS, float]]
    waterfallHead*: int
    waterfallLen*: int
    fftReal: seq[float]
    fftImag: seq[float]

proc createShm*(name: string): PcmRingBuffer =
  result.shmName = name
  let totalSize = sizeof(float32) * PCM_RING_SIZE + sizeof(int32) * 2 + sizeof(int32)
  result.fd = shm_open(name.cstring, O_RDWR or O_CREAT, 0o600)
  if result.fd < 0:
    return
  discard ftruncate(result.fd, totalSize)
  let mem = mmap(nil, totalSize, PROT_READ or PROT_WRITE, MAP_SHARED, result.fd, 0)
  if mem == MAP_FAILED:
    discard close(result.fd)
    return
  result.data = cast[ptr UncheckedArray[float32]](mem)
  result.writePos = cast[ptr int32](cast[int](mem) + sizeof(float32) * PCM_RING_SIZE)
  result.readPos = cast[ptr int32](cast[int](mem) + sizeof(float32) * PCM_RING_SIZE + sizeof(int32))
  result.size = PCM_RING_SIZE
  result.writePos[] = 0
  result.readPos[] = 0

proc openShm*(name: string): PcmRingBuffer =
  result.shmName = name
  let totalSize = sizeof(float32) * PCM_RING_SIZE + sizeof(int32) * 2 + sizeof(int32)
  result.fd = shm_open(name.cstring, O_RDONLY, 0)
  if result.fd < 0:
    return
  let mem = mmap(nil, totalSize, PROT_READ, MAP_SHARED, result.fd, 0)
  if mem == MAP_FAILED:
    discard close(result.fd)
    return
  result.data = cast[ptr UncheckedArray[float32]](mem)
  result.writePos = cast[ptr int32](cast[int](mem) + sizeof(float32) * PCM_RING_SIZE)
  result.readPos = cast[ptr int32](cast[int](mem) + sizeof(float32) * PCM_RING_SIZE + sizeof(int32))
  result.size = PCM_RING_SIZE

proc writePcm*(shm: var PcmRingBuffer, samples: openArray[float32]) =
  if shm.data == nil: return
  let wp = shm.writePos[]
  let rp = shm.readPos[]
  let sz = shm.size
  for i in 0..<samples.len:
    let idx = (wp + int32(i)) mod sz
    if idx == rp and i > 0:
      break
    shm.data[idx] = samples[i]
  shm.writePos[] = (wp + int32(samples.len)) mod sz

proc readPcm*(shm: var PcmRingBuffer, output: var seq[float32], maxCount: int) =
  if shm.data == nil: return
  let wp = shm.writePos[]
  let rp = shm.readPos[]
  var count = 0
  var pos = rp
  while pos != wp and count < maxCount:
    output.add(shm.data[pos])
    pos = (pos + 1) mod shm.size
    count.inc
  shm.readPos[] = pos

proc destroyShm*(shm: var PcmRingBuffer) =
  if shm.data != nil:
    let totalSize = sizeof(float32) * PCM_RING_SIZE + sizeof(int32) * 2 + sizeof(int32)
    discard munmap(shm.data, totalSize)
    discard close(shm.fd)
    discard shm_unlink(shm.shmName.cstring)

proc shmPath*(): string = "/gtm-pcm"

proc newVisualizer*(): Visualizer =
  var wf = newSeq[array[MAX_VIS_BARS, float]](WATERFALL_COLS)
  for i in 0..<WATERFALL_COLS:
    for j in 0..<MAX_VIS_BARS:
      wf[i][j] = 0.0
  Visualizer(
    pcmBuf: newSeq[float32](),
    overlapBuf: newSeq[float32](),
    waterfall: wf,
    waterfallHead: 0,
    waterfallLen: 0,
    running: true,
    barCount: 32,
    fftReal: newSeq[float](FFT_SIZE),
    fftImag: newSeq[float](FFT_SIZE)
  )

proc clear*(v: Visualizer) =
  if v.shm.data != nil:
    zeroMem(v.shm.data, sizeof(float32) * PCM_RING_SIZE)
    v.shm.writePos[] = 0
    v.shm.readPos[] = 0
  v.pcmBuf.setLen(0)
  v.overlapBuf.setLen(0)
  for i in 0..<MAX_VIS_BARS:
    v.bins[i] = 0.0
    v.smoothBins[i] = 0.0
    v.peakVals[i] = 0.0
  for i in 0..<WATERFALL_COLS:
    for j in 0..<MAX_VIS_BARS:
      v.waterfall[i][j] = 0.0
  v.waterfallHead = 0
  v.waterfallLen = 0

proc startCapture*(v: Visualizer) =
  v.shm = createShm(shmPath())
  v.running = true

proc stopCapture*(v: Visualizer) =
  v.running = false

proc hanning(i, n: int): float =
  0.5 * (1.0 - cos(2.0 * PI * float(i) / float(n - 1)))

proc processOneFft(v: Visualizer, samples: openArray[float32]) =
  let n = FFT_SIZE
  for i in 0..<n:
    let w = hanning(i, n)
    v.fftReal[i] = float(samples[i]) * w
    v.fftImag[i] = 0.0

  var bits = 0
  var tmp = n
  while tmp > 1:
    tmp = tmp shr 1
    bits.inc
  for i in 0..<n:
    var j = 0
    var ti = i
    for _ in 0..<bits:
      j = (j shl 1) or (ti and 1)
      ti = ti shr 1
    if j > i:
      swap(v.fftReal[i], v.fftReal[j])
      swap(v.fftImag[i], v.fftImag[j])
  var step = 1
  while step < n:
    let halfStep = step
    step = step shl 1
    let angleStep = -2.0 * PI / float(step)
    for group in countup(0, n - 1, step):
      for pair in 0..<halfStep:
        let idx = group + pair
        let angle = angleStep * float(pair)
        let wr = cos(angle)
        let wi = sin(angle)
        let tRe = wr * v.fftReal[idx + halfStep] - wi * v.fftImag[idx + halfStep]
        let tIm = wr * v.fftImag[idx + halfStep] + wi * v.fftReal[idx + halfStep]
        v.fftReal[idx + halfStep] = v.fftReal[idx] - tRe
        v.fftImag[idx + halfStep] = v.fftImag[idx] - tIm
        v.fftReal[idx] = v.fftReal[idx] + tRe
        v.fftImag[idx] = v.fftImag[idx] + tIm

  let bars = max(MIN_VIS_BARS, min(MAX_VIS_BARS, v.barCount))
  let nyquist = n div 2
  let invN = 1.0 / float(n)
  for bar in 0..<bars:
    let logLo = ln(float(nyquist) * 0.02 + 1.0)
    let logHi = ln(float(nyquist) + 1.0)
    let loFrac = float(bar) / float(bars)
    let hiFrac = float(bar + 1) / float(bars)
    let startBin = int(exp(logLo + loFrac * (logHi - logLo)) - 1.0)
    let endBin = int(exp(logLo + hiFrac * (logHi - logLo)) - 1.0).int
    let s = max(1, startBin)
    let e = min(nyquist - 1, max(endBin, s + 1))
    var sum = 0.0
    for b in s..e:
      sum += sqrt(v.fftReal[b] * v.fftReal[b] + v.fftImag[b] * v.fftImag[b])
    let avg = sum / float(max(e - s + 1, 1))
    let normalized = avg * invN * 2.0
    let db = 20.0 * log10(max(normalized, 1e-10))
    let raw = max(0.0, min(1.0, (db + 70.0) / 70.0))
    let compressed = pow(raw, 1.5)
    v.bins[bar] = compressed
    let attack = 0.4
    let release = 0.85
    if compressed > v.smoothBins[bar]:
      v.smoothBins[bar] = v.smoothBins[bar] * (1.0 - attack) + compressed * attack
    else:
      v.smoothBins[bar] = v.smoothBins[bar] * (1.0 - release) + compressed * release
    v.peakVals[bar] = max(v.smoothBins[bar], v.peakVals[bar] * 0.94)

  let head = v.waterfallHead
  for bar in 0..<bars:
    v.waterfall[head][bar] = v.smoothBins[bar]
  for bar in bars..<MAX_VIS_BARS:
    v.waterfall[head][bar] = 0.0
  v.waterfallHead = (head + 1) mod WATERFALL_COLS
  if v.waterfallLen < WATERFALL_COLS:
    v.waterfallLen.inc

proc processFft*(v: Visualizer) =
  if v.pcmBuf.len == 0: return
  var combined = v.overlapBuf & v.pcmBuf
  v.overlapBuf.setLen(0)
  v.pcmBuf.setLen(0)
  var pos = 0
  while pos + FFT_SIZE <= combined.len:
    processOneFft(v, combined[pos..<pos + FFT_SIZE])
    pos += FFT_HOP_SIZE
  let remaining = combined.len - pos
  if remaining > 0:
    v.overlapBuf = combined[pos..^1]
  else:
    v.overlapBuf.setLen(0)

proc writePcm*(v: Visualizer, samples: openArray[float32]) =
  writePcm(v.shm, samples)

proc readPcm*(v: Visualizer) =
  if not v.running: return
  readPcm(v.shm, v.pcmBuf, FFT_SIZE * 4)
  if v.pcmBuf.len >= FFT_HOP_SIZE:
    processFft(v)

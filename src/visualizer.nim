import math, posix

const
  FFT_SIZE* = 1024
  MAX_VIS_BARS* = 64
  MIN_VIS_BARS* = 4
  PCM_RING_SIZE* = FFT_SIZE * 8

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
    running*: bool
    barCount*: int
    pcmBuf: seq[float32]

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
    discard shm_open(shm.shmName.cstring, O_RDONLY, 0)

proc shmPath*(): string = "/gtm-pcm"

proc newVisualizer*(): Visualizer =
  Visualizer(
    pcmBuf: newSeq[float32](),
    running: true,
    barCount: 32
  )

proc startCapture*(v: Visualizer) =
  v.shm = createShm(shmPath())
  v.running = true

proc stopCapture*(v: Visualizer) =
  v.running = false

proc hanning(i, n: int): float =
  0.5 * (1.0 - cos(2.0 * PI * float(i) / float(n - 1)))

proc processFft*(v: Visualizer) =
  let n = min(FFT_SIZE, v.pcmBuf.len)
  if n < 64: return
  var real = newSeq[float](n)
  var imag = newSeq[float](n)
  for i in 0..<n:
    let w = hanning(i, n)
    real[i] = float(v.pcmBuf[i]) * w
    imag[i] = 0.0
  v.pcmBuf = v.pcmBuf[n..^1]
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
      swap(real[i], real[j])
      swap(imag[i], imag[j])
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
        let tRe = wr * real[idx + halfStep] - wi * imag[idx + halfStep]
        let tIm = wr * imag[idx + halfStep] + wi * real[idx + halfStep]
        real[idx + halfStep] = real[idx] - tRe
        imag[idx + halfStep] = imag[idx] - tIm
        real[idx] = real[idx] + tRe
        imag[idx] = imag[idx] + tIm
  let bars = max(MIN_VIS_BARS, min(MAX_VIS_BARS, v.barCount))
  let binsPerBar = (n div 2) div bars
  for bar in 0..<bars:
    var sum = 0.0
    let startBin = bar * binsPerBar
    let endBin = if bar == bars - 1: (n div 2) - 1 else: startBin + binsPerBar
    for b in startBin..endBin:
      sum += sqrt(real[b] * real[b] + imag[b] * imag[b])
    let avg = sum / float(max(endBin - startBin + 1, 1))
    let db = 20.0 * log10(max(avg, 1e-10))
    let raw = max(0.0, min(1.0, (db + 60.0) / 60.0))
    v.bins[bar] = raw
    v.smoothBins[bar] = v.smoothBins[bar] * 0.7 + raw * 0.3

proc readPcm*(v: Visualizer) =
  if not v.running: return
  readPcm(v.shm, v.pcmBuf, FFT_SIZE * 4)
  while v.pcmBuf.len >= FFT_SIZE:
    processFft(v)

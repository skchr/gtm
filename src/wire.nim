## Binary wire protocol for daemon → client event streaming
##
## Frame format:
##   [4 bytes: total_len (big-endian int32)]
##   [1 byte: event_count]
##   [event_0] [event_1] ... [event_N]
##
## Each event:
##   [1 byte: kind]
##   [4 bytes: version (big-endian int32)]
##   kind-specific fields
##
## Kind-specific field layouts:
##   evPositionChanged (5):  [8 bytes: time_pos (float64)]
##   evDurationChanged  (6):  [8 bytes: duration (float64)]
##   evVolumeChanged    (7):  [4 bytes: volume (int32)]
##   evPlaybackStarted  (1):  [str: track_path] [str: track_title] [str: track_channel]
##                            [1 byte: auto_advanced] [8: time_pos] [8: duration]
##   evPlaybackPaused   (2):  no extra fields
##   evPlaybackStopped  (3):  no extra fields
##   evTrackEnded       (4):  no extra fields
##   evMetadataChanged  (8):  [str: event_name]
##   evCustomEvent     (10):  [str: event_name] [1 byte: kv_count]
##                            for each kv: [str: key] [str: val]
##
## Strings: [2 bytes: len (uint16)] [data]

import endians, tables, strutils, audio

const WireMagic* = 0xFB.byte

type
  WireBuffer* = object
    data: seq[byte]
    pos: int

proc initWireBuffer*(capacity: int = 4096): WireBuffer =
  result.data = newSeq[byte](capacity)
  result.pos = 0

proc ensureSpace(buf: var WireBuffer, n: int) =
  let needed = buf.pos + n
  if needed > buf.data.len:
    buf.data.setLen(max(needed, buf.data.len * 2))

template w8(buf: var WireBuffer, v: byte) =
  ensureSpace(buf, 1)
  buf.data[buf.pos] = v
  buf.pos += 1

template w16(buf: var WireBuffer, v: uint16) =
  ensureSpace(buf, 2)
  var val = v
  var be = val
  bigEndian16(addr be, addr val)
  buf.data[buf.pos] = byte(be shr 8)
  buf.data[buf.pos+1] = byte(be and 0xFF)
  buf.pos += 2

template w32(buf: var WireBuffer, v: int32) =
  ensureSpace(buf, 4)
  var val = v
  var be = val
  bigEndian32(addr be, addr val)
  buf.data[buf.pos] = byte(be shr 24)
  buf.data[buf.pos+1] = byte((be shr 16) and 0xFF)
  buf.data[buf.pos+2] = byte((be shr 8) and 0xFF)
  buf.data[buf.pos+3] = byte(be and 0xFF)
  buf.pos += 4

template w64(buf: var WireBuffer, v: int64) =
  ensureSpace(buf, 8)
  var val = v
  var be = val
  bigEndian64(addr be, addr val)
  for i in 0..7:
    buf.data[buf.pos + i] = byte((be shr ((7-i)*8)) and 0xFF)
  buf.pos += 8

template wFloat(buf: var WireBuffer, v: float64) =
  w64(buf, cast[int64](v))

template wStr(buf: var WireBuffer, s: string) =
  let l = min(s.len, 65535)
  w16(buf, l.uint16)
  if l > 0:
    ensureSpace(buf, l)
    var s2 = s
    copyMem(addr buf.data[buf.pos], addr s2[0], l)
    buf.pos += l

proc r8(buf: var WireBuffer): byte =
  result = buf.data[buf.pos]
  buf.pos += 1

proc r16(buf: var WireBuffer): uint16 =
  result = (uint16(buf.data[buf.pos]) shl 8) or uint16(buf.data[buf.pos+1])
  buf.pos += 2

proc r32(buf: var WireBuffer): int32 =
  result = (int32(buf.data[buf.pos]) shl 24) or
           (int32(buf.data[buf.pos+1]) shl 16) or
           (int32(buf.data[buf.pos+2]) shl 8) or
            int32(buf.data[buf.pos+3])
  buf.pos += 4

proc r64(buf: var WireBuffer): int64 =
  for i in 0..7:
    result = (result shl 8) or int64(buf.data[buf.pos + i])
  buf.pos += 8

proc rFloat(buf: var WireBuffer): float64 =
  cast[float64](r64(buf))

template rStr(buf: var WireBuffer): string =
  let l = r16(buf).int
  if l > 0:
    var s = newString(l)
    copyMem(addr s[0], addr buf.data[buf.pos], l)
    buf.pos += l
    s
  else:
    ""

proc serializeEvents*(events: seq[AudioEvent]): seq[byte] =
  var buf = initWireBuffer(4096)
  # Reserve space for magic + total length + event count; fill later
  w8(buf, WireMagic)
  buf.pos += 4
  w8(buf, byte(events.len))
  for ev in events:
    w8(buf, byte(ev.kind))
    w32(buf, ev.version.int32)
    case ev.kind
    of evPositionChanged:
      wFloat(buf, ev.floatVal)
    of evDurationChanged:
      wFloat(buf, ev.floatVal)
    of evVolumeChanged:
      w32(buf, ev.intVal.int32)
    of evPlaybackStarted:
      wStr(buf, ev.metadata.getOrDefault("track_path", ""))
      wStr(buf, ev.metadata.getOrDefault("track_title", ""))
      wStr(buf, ev.metadata.getOrDefault("track_channel", ""))
      w8(buf, byte(if ev.metadata.getOrDefault("auto_advanced", "false") == "true": 1 else: 0))
      try:
        wFloat(buf, parseFloat(ev.metadata.getOrDefault("time_pos", "0.0")))
      except:
        wFloat(buf, 0.0)
      try:
        wFloat(buf, parseFloat(ev.metadata.getOrDefault("duration", "0.0")))
      except:
        wFloat(buf, 0.0)
    of evPlaybackPaused:
      discard
    of evPlaybackStopped:
      discard
    of evTrackEnded:
      discard
    of evMetadataChanged:
      wStr(buf, ev.strVal)
    of evCustomEvent:
      wStr(buf, ev.strVal)
      var kvPairs: seq[(string, string)]
      for k, v in ev.metadata:
        kvPairs.add((k, v))
      w8(buf, byte(min(kvPairs.len, 255)))
      for (k, v) in kvPairs:
        wStr(buf, k)
        wStr(buf, v)
    else: discard
  let totalLen = buf.pos
  buf.pos = 1
  w32(buf, totalLen.int32)
  buf.pos = totalLen
  buf.data.setLen(totalLen)
  result = buf.data

proc deserializeEvents*(data: openArray[byte]): seq[AudioEvent] =
  if data.len < 6: return
  if data[0] != WireMagic: return
  var buf = WireBuffer(data: @(data), pos: 5)
  let count = r8(buf).int
  result = @[]
  for i in 0..<count:
    if buf.pos + 5 > buf.data.len: break
    var ev = AudioEvent()
    ev.kind = AudioEventKind(r8(buf))
    ev.version = r32(buf).int
    case ev.kind
    of evPositionChanged:
      if buf.pos + 8 > buf.data.len: break
      ev.floatVal = rFloat(buf)
    of evDurationChanged:
      if buf.pos + 8 > buf.data.len: break
      ev.floatVal = rFloat(buf)
    of evVolumeChanged:
      if buf.pos + 4 > buf.data.len: break
      ev.intVal = r32(buf).int
    of evPlaybackStarted:
      if buf.pos + 2 > buf.data.len: break
      let path = rStr(buf)
      let title = rStr(buf)
      let channel = rStr(buf)
      if buf.pos + 1 > buf.data.len: break
      let autoAdv = r8(buf) == 1
      if buf.pos + 16 > buf.data.len: break
      let tp = rFloat(buf)
      let dur = rFloat(buf)
      if path.len > 0: ev.metadata["track_path"] = path
      if title.len > 0: ev.metadata["track_title"] = title
      if channel.len > 0: ev.metadata["track_channel"] = channel
      ev.metadata["auto_advanced"] = $(autoAdv)
      ev.metadata["time_pos"] = $tp
      ev.metadata["duration"] = $dur
    of evPlaybackPaused, evPlaybackStopped, evTrackEnded:
      discard
    of evMetadataChanged:
      if buf.pos + 2 > buf.data.len: break
      ev.strVal = rStr(buf)
    of evCustomEvent:
      if buf.pos + 2 > buf.data.len: break
      ev.strVal = rStr(buf)
      if buf.pos + 1 > buf.data.len: break
      let kvCount = r8(buf).int
      for j in 0..<kvCount:
        if buf.pos + 2 > buf.data.len: break
        let k = rStr(buf)
        let v = rStr(buf)
        ev.metadata[k] = v
    else: discard
    result.add(ev)

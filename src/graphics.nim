import os, strutils, base64, posix, times

const
  KittyChunkSize = 3584
  CoverImageId* = 1
  HoverImageId* = 2

proc supportsKittyGraphics*(): bool =
  let tp = getEnv("TERM_PROGRAM", "")
  if tp.toLowerAscii() in ["kitty", "wezterm", "ghostty", "foot", "konsole"]:
    return true
  let term = getEnv("TERM", "")
  if "kitty" in term:
    return true
  let kittyWindow = getEnv("KITTY_WINDOW_ID", "")
  if kittyWindow.len > 0:
    return true
  let kittyProto = getEnv("KITTY_PROTOCOL_INSTANCE", "")
  if kittyProto.len > 0:
    return true
  let wezterm = getEnv("WEZTERM_EXECUTABLE", "")
  if wezterm.len > 0:
    return true
  let ghostty = getEnv("GHOSTTY_RESOURCES_DIR", "")
  if ghostty.len > 0:
    return true
  # Escape sequence probe: query terminal for Kitty protocol support
  let probe = "\e_Ga=q,i=1,s=1,v=1\e\\"
  let oldFd = stdin.getFileHandle()
  var oldFlags = fcntl(oldFd, F_GETFL, 0)
  if oldFlags != -1:
    discard fcntl(oldFd, F_SETFL, oldFlags or O_NONBLOCK)
  stdout.write(probe)
  flushFile(stdout)
  var buf: array[64, char]
  let pollStart = epochTime()
  var gotResponse = false
  while epochTime() - pollStart < 0.05:
    let n = posix.read(oldFd.cint, addr buf, buf.len)
    if n > 0:
      let resp = $buf[0..<n]
      if "\e_Gi=1;OK" in resp or "\e_G" in resp:
        gotResponse = true
        break
    elif n == 0:
      break
    else:
      let err = osLastError()
      if err.int32 != 11 and err.int32 != 4:  # EAGAIN, EINTR
        break
  if oldFlags != -1:
    discard fcntl(oldFd, F_SETFL, oldFlags)
  if gotResponse:
    return true
  false

proc mimeToFormat*(mime: string): int =
  case mime.toLowerAscii()
  of "image/png": 100
  of "image/jpeg", "image/jpg": 38
  of "image/gif": 32
  of "image/webp": 57
  of "image/bmp": 0
  of "image/tiff": 41
  else: 100

proc transmitImage*(data: seq[byte], mime: string, imageId: int) =
  let fmt = mimeToFormat(mime)
  let encoded = encode(data)
  var offset = 0
  while offset < encoded.len:
    let chunkSize = min(KittyChunkSize, encoded.len - offset)
    let chunk = encoded[offset ..< offset + chunkSize]
    let isLast = (offset + chunkSize >= encoded.len)
    var esc: string
    if offset == 0:
      esc = "\e_Ga=T,i=" & $imageId & ",f=" & $fmt & ",m="
    else:
      esc = "\e_Ga=T,i=" & $imageId & ",m="
    if isLast:
      esc &= "0;"
    else:
      esc &= "1;"
    stdout.write(esc & chunk & "\e\\")
    offset += chunkSize
  flushFile(stdout)

proc placeImage*(x, y: int, imageId: int, cellWidth: int = 0, cellHeight: int = 0) =
  var esc = "\e_Ga=p,i=" & $imageId & ",X=" & $x & ",Y=" & $y & ",c=1"
  if cellWidth > 0:
    esc &= ",w=-" & $cellWidth
  if cellHeight > 0:
    esc &= ",h=-" & $cellHeight
  esc &= ";\e\\"
  stdout.write(esc)
  flushFile(stdout)

proc deleteImage*(imageId: int) =
  stdout.write("\e_Ga=d,i=" & $imageId & ";\e\\")
  flushFile(stdout)

proc clearAllImages*() =
  stdout.write("\e_Ga=d,d=I;\e\\")
  flushFile(stdout)

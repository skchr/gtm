import os, strutils, base64

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

import os, strutils, base64

const
  KittyChunkSize = 3584
  CoverImageId* = 1

proc supportsKittyGraphics*(): bool =
  let tp = getEnv("TERM_PROGRAM", "")
  if tp.toLowerAscii() in ["kitty", "wezterm", "ghostty", "foot", "konsole"]:
    return true
  let term = getEnv("TERM", "")
  if "kitty" in term:
    return true
  false

proc transmitImage*(data: string, imageId: int) =
  var offset = 0
  while offset < data.len:
    let chunkSize = min(KittyChunkSize, data.len - offset)
    let chunk = data[offset ..< offset + chunkSize]
    let b64 = encode(chunk)
    let isLast = (offset + chunkSize >= data.len)
    var esc: string
    if offset == 0:
      esc = "\e_Ga=T,i=" & $imageId & ",f=100,m="
    else:
      esc = "\e_Ga=T,i=" & $imageId & ",m="
    if isLast:
      esc &= "0;"
    else:
      esc &= "1;"
    stdout.write(esc & b64 & "\e\\")
    offset += chunkSize
  flushFile(stdout)

proc placeImage*(x, y: int, imageId: int, cellWidth: int = 0) =
  var esc = "\e_Ga=p,i=" & $imageId & ",X=" & $x & ",Y=" & $y & ",c=1"
  if cellWidth > 0:
    esc &= ",w=-" & $cellWidth
  esc &= ";\e\\"
  stdout.write(esc)
  flushFile(stdout)

proc deleteImage*(imageId: int) =
  stdout.write("\e_Ga=d,i=" & $imageId & ";\e\\")
  flushFile(stdout)

proc clearAllImages*() =
  stdout.write("\e_Ga=d,d=I;\e\\")
  flushFile(stdout)

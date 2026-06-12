import os, strutils, httpclient, json, osproc, times

type AnsiArt* = object
  data*: string
  lines*: int

proc artCacheDir*(): string =
  let data = getEnv("XDG_DATA_HOME", getEnv("HOME", "") / ".local" / "share") / "gtm" / "covers"
  if not dirExists(data): createDir(data)
  result = data

proc cachedAnsiPath*(key: string): string =
  artCacheDir() / key.replace("/", "_").replace(":", "_") & ".art"

proc extractArtFromFile*(audioPath: string): string =
  if not fileExists(audioPath): return ""
  let cacheDir = artCacheDir()
  let artPath = cacheDir / audioPath.replace("/", "_").replace(":", "_") & ".jpg"
  if fileExists(artPath): return artPath
  let cmd = "ffmpeg -y -i " & audioPath.quoteShell & " -an -c:v copy -map 0:v:0 " & artPath.quoteShell & " 2>/dev/null"
  if execCmd(cmd) == 0 and fileExists(artPath):
    return artPath
  result = ""

proc downloadOnlineArt(artist, album: string): string =
  let cacheDir = artCacheDir()
  let key = (artist & " - " & album).strip()
  if key.len == 0: return ""
  let term = key.replace(" ", "+")
  try:
    let client = newHttpClient()
    client.headers = newHttpHeaders({"User-Agent": "gtm/1.0"})
    let url = "https://itunes.apple.com/search?term=" & term & "&limit=1&entity=album"
    let resp = client.getContent(url)
    let j = parseJson(resp)
    if j["resultCount"].getInt(0) > 0:
      let artUrl = j["results"][0]["artworkUrl100"].getStr("")
      if artUrl.len > 0:
        let bigUrl = artUrl.replace("100x100bb", "600x600bb")
        let tmpPath = cacheDir / "online_" & ($epochTime()).replace(".", "_") & ".jpg"
        client.downloadFile(bigUrl, tmpPath)
        if fileExists(tmpPath):
          result = tmpPath
    client.close()
  except: discard

proc getArtForTrack*(audioPath: string; ytThumbnail: string = ""; artist: string = ""; album: string = ""; width: int = 16; height: int = 8): AnsiArt =
  let cacheKey = if ytThumbnail.len > 0: ytThumbnail else: audioPath
  let ansiPath = cachedAnsiPath(cacheKey)
  if fileExists(ansiPath):
    try:
      result.data = readFile(ansiPath)
      result.lines = result.data.countLines
      if result.lines > 0: return
    except: discard
  var artFile: string
  if ytThumbnail.len > 0 and fileExists(ytThumbnail):
    artFile = ytThumbnail
  else:
    artFile = extractArtFromFile(audioPath)
  if artFile.len == 0 or not fileExists(artFile):
    if artist.len > 0 or album.len > 0:
      let dl = downloadOnlineArt(artist, album)
      if dl.len > 0:
        artFile = dl
  if artFile.len == 0 or not fileExists(artFile): return
  var cmd = "chafa --format kitty --size " & $width & "x" & $height & " " & artFile.quoteShell & " 2>/dev/null"
  var (outp, code) = execCmdEx(cmd)
  if code != 0 or outp.len == 0:
    cmd = "chafa --format symbols --symbols vhalf --size " & $width & "x" & $height & " " & artFile.quoteShell & " 2>/dev/null"
    (outp, code) = execCmdEx(cmd)
  if code == 0 and outp.len > 0:
    result.data = outp
    result.lines = outp.countLines
    try: writeFile(ansiPath, outp) except: discard
  if artFile != ytThumbnail and artFile.startsWith(artCacheDir() / "online_"):
    try: removeFile(artFile) except: discard

proc computeArtSize*(termW, termH: int): tuple[charW, charH: int] =
  let maxCharW = termW div 3
  let maxCharH = termH div 3
  if maxCharW >= 16 and maxCharH >= 8:
    result = (16, 8)
  elif maxCharW >= 12 and maxCharH >= 6:
    result = (12, 6)
  elif maxCharW >= 8 and maxCharH >= 4:
    result = (8, 4)
  else:
    result = (0, 0)

proc writeCachedArt*(data: string, x, y: int) =
  if data.len == 0: return
  stdout.write("\e[" & $(y + 1) & ";" & $(x + 1) & "H" & data)
  stdout.flushFile()

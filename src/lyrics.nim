import os, strutils, httpclient, json, uri, algorithm, tables, times

import state

var
  searchCache: Table[string, tuple[results: seq[tuple[id: int, artist, title, album: string, duration: float]], fetchedAt: float]]
  searchCacheTtl: float = 300.0  # 5 min

proc findLrcSidecar*(trackPath: string): string =
  let dir = trackPath.parentDir()
  let (_, name, _) = trackPath.splitFile()
  for candidate in [dir / name & ".lrc", dir / name & ".txt"]:
    if fileExists(candidate):
      return candidate
  ""

proc parseLrcFromText(content: string): LrcData =
  result = LrcData(lines: @[])
  for line in content.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    if trimmed.startsWith("[ti:"):
      result.title = trimmed[4..^2].strip()
      continue
    if trimmed.startsWith("[ar:"):
      result.artist = trimmed[4..^2].strip()
      continue
    if trimmed.startsWith("[al:"):
      result.album = trimmed[4..^2].strip()
      continue
    let brPos = trimmed.find(']')
    if brPos < 0: continue
    let timeTag = trimmed[1..<brPos]
    let text = trimmed[brPos+1..^1].strip()
    if text.len == 0: continue
    let parts = timeTag.split(':')
    var secs: float = 0.0
    if parts.len == 2:
      try:
        secs = parts[0].parseInt().float * 60 + parts[1].replace(',', '.').parseFloat()
      except: continue
    elif parts.len == 3:
      try:
        secs = parts[0].parseInt().float * 3600 + parts[1].parseInt().float * 60 + parts[2].replace(',', '.').parseFloat()
      except: continue
    else:
      continue
    result.lines.add(LrcLine(timestamp: secs, text: text))
  result.lines.sort(proc(a, b: LrcLine): int = cmp(a.timestamp, b.timestamp))

proc parseLrc*(path: string): LrcData =
  if not fileExists(path): return LrcData(lines: @[])
  parseLrcFromText(readFile(path))

proc parseLrcString*(content: string): LrcData =
  parseLrcFromText(content)

proc currentLrcLine*(lyrics: LrcData, timePos: float): int =
  if lyrics.lines.len == 0: return -1
  for i in countdown(lyrics.lines.len - 1, 0):
    if timePos >= lyrics.lines[i].timestamp:
      return i
  -1

proc searchLrclib*(artist, title: string): seq[tuple[id: int, artist, title, album: string, duration: float]] =
  result = @[]
  if artist.len == 0 and title.len == 0: return
  let cacheKey = artist & " :: " & title
  if searchCache.hasKey(cacheKey):
    let (cached, fetchedAt) = searchCache[cacheKey]
    if epochTime() - fetchedAt < searchCacheTtl:
      return cached
  try:
    let query = encodeQuery({"q": title, "artist_name": artist, "q_artist": artist})
    let client = newHttpClient(timeout = 5000)
    let resp = client.get("https://lrclib.net/api/search?" & query)
    if resp.code == Http200:
      let j = parseJson(resp.body())
      for item in j.items:
        result.add((
          id: item{"id"}.getInt(0),
          artist: item{"artistName"}.getStr(""),
          title: item{"trackName"}.getStr(""),
          album: item{"albumName"}.getStr(""),
          duration: item{"duration"}.getFloat(0.0)
        ))
    client.close()
    searchCache[cacheKey] = (result, epochTime())
  except:
    discard

proc fetchLrclib*(id: int): string =
  try:
    let client = newHttpClient(timeout = 5000)
    let resp = client.get("https://lrclib.net/api/get/" & $id)
    if resp.code == Http200:
      let j = parseJson(resp.body())
      result = j{"syncedLyrics"}.getStr("")
      if result.len == 0:
        result = j{"plainLyrics"}.getStr("")
    client.close()
  except:
    discard

proc fetchLrclibByParams*(artist, title, album: string, duration: float): string =
  try:
    var query = "?"
    var params: seq[string] = @[]
    if artist.len > 0: params.add("artist_name=" & encodeUrl(artist))
    if title.len > 0: params.add("track_name=" & encodeUrl(title))
    if album.len > 0: params.add("album_name=" & encodeUrl(album))
    if duration > 0: params.add("duration=" & $(duration.int))
    query &= params.join("&")
    let client = newHttpClient(timeout = 5000)
    let resp = client.get("https://lrclib.net/api/get" & query)
    if resp.code == Http200:
      let j = parseJson(resp.body())
      result = j{"syncedLyrics"}.getStr("")
      if result.len == 0:
        result = j{"plainLyrics"}.getStr("")
    client.close()
  except:
    discard

proc resolveLyrics*(trackPath, artist, title, album: string, duration: float): LrcData =
  result = LrcData(title: title, artist: artist, album: album, lines: @[])
  # Step 1: Check sidecar .lrc file
  let sidecar = findLrcSidecar(trackPath)
  if sidecar.len > 0:
    result = parseLrc(sidecar)
    if result.lines.len > 0:
      return
  # Step 2: Search LRCLIB
  let lrcText = fetchLrclibByParams(artist, title, album, duration)
  if lrcText.len > 0:
    result = parseLrcString(lrcText)
    if result.lines.len > 0:
      return
  # Step 3: Search LRCLIB by query
  let results = searchLrclib(artist, title)
  if results.len > 0:
    let lrcText2 = fetchLrclib(results[0].id)
    if lrcText2.len > 0:
      result = parseLrcString(lrcText2)

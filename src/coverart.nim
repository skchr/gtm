import os, strutils, httpclient, json, uri, tables, times

const
  deezerSearchUrl = "https://api.deezer.com/search/album"
  requestDelay = 1.0
  searchCacheTtl = 600.0

var
  searchCache: Table[string, tuple[url: string, fetchedAt: float]]
  lastRequestAt: float = 0.0

proc rateLimit() =
  let now = epochTime()
  let elapsed = now - lastRequestAt
  if elapsed < requestDelay:
    sleep(int((requestDelay - elapsed) * 1000))
  lastRequestAt = epochTime()

proc searchDeezerAlbum*(artist, album: string): string =
  if artist.len == 0 and album.len == 0: return ""
  let cacheKey = "deezer:" & artist & "::" & album
  if searchCache.hasKey(cacheKey):
    let (cached, fetchedAt) = searchCache[cacheKey]
    if epochTime() - fetchedAt < searchCacheTtl and cached.len > 0:
      return cached
  rateLimit()
  try:
    var query = ""
    var parts: seq[string] = @[]
    if artist.len > 0:
      parts.add("artist:\"" & artist & "\"")
    if album.len > 0:
      parts.add("album:\"" & album & "\"")
    query = encodeQuery({"q": parts.join(" ")})
    let client = newHttpClient(timeout = 5000)
    let resp = client.get(deezerSearchUrl & "?" & query)
    if resp.code == Http200:
      let j = parseJson(resp.body())
      if j.hasKey("data") and j["data"].len > 0:
        let first = j["data"][0]
        if first.hasKey("cover_big"):
          result = first["cover_big"].getStr("")
        if result.len == 0 and first.hasKey("cover_medium"):
          result = first["cover_medium"].getStr("")
        if result.len == 0 and first.hasKey("cover"):
          result = first["cover"].getStr("")
    client.close()
    searchCache[cacheKey] = (result, epochTime())
  except:
    discard

proc searchDeezerByTrack*(artist, title: string): string =
  if artist.len == 0 and title.len == 0: return ""
  let cacheKey = "deezer_track:" & artist & "::" & title
  if searchCache.hasKey(cacheKey):
    let (cached, fetchedAt) = searchCache[cacheKey]
    if epochTime() - fetchedAt < searchCacheTtl and cached.len > 0:
      return cached
  rateLimit()
  try:
    var parts: seq[string] = @[]
    if artist.len > 0: parts.add("artist:\"" & artist & "\"")
    if title.len > 0: parts.add("track:\"" & title & "\"")
    let query = encodeQuery({"q": parts.join(" ")})
    let client = newHttpClient(timeout = 5000)
    let resp = client.get("https://api.deezer.com/search/track?" & query)
    if resp.code == Http200:
      let j = parseJson(resp.body())
      if j.hasKey("data") and j["data"].len > 0:
        let first = j["data"][0]
        if first.hasKey("album") and first["album"].kind == JObject:
          if first["album"].hasKey("cover_big"):
            result = first["album"]["cover_big"].getStr("")
          if result.len == 0 and first["album"].hasKey("cover_medium"):
            result = first["album"]["cover_medium"].getStr("")
    client.close()
    searchCache[cacheKey] = (result, epochTime())
  except:
    discard

proc fetchImage*(url: string): tuple[data: seq[byte], mime: string] =
  if url.len == 0: return (@[], "")
  try:
    let client = newHttpClient(timeout = 10000)
    let resp = client.get(url)
    if resp.code == Http200:
      let body = resp.body()
      result.data = cast[seq[byte]](body)
      var mime = ""
      try:
        let ct = resp.headers.getOrDefault("Content-Type")
        if ct.len > 0: mime = $ct
      except: discard
      if mime.len > 0:
        result.mime = mime
      else:
        let ext = url.splitFile().ext.toLowerAscii()
        if ext == ".png": result.mime = "image/png"
        elif ext == ".webp": result.mime = "image/webp"
        elif ext == ".gif": result.mime = "image/gif"
        else: result.mime = "image/jpeg"
    client.close()
  except:
    discard

proc resolveCoverWeb*(artist, album, title: string): tuple[data: seq[byte], mime: string] =
  if artist.len == 0 and album.len == 0 and title.len == 0:
    return (@[], "")
  var coverUrl = searchDeezerAlbum(artist, album)
  if coverUrl.len == 0:
    coverUrl = searchDeezerAlbum(artist, title)
  if coverUrl.len == 0 and title.len > 0:
    coverUrl = searchDeezerByTrack(artist, title)
  if coverUrl.len > 0:
    result = fetchImage(coverUrl)

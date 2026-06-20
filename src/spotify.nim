import std/[json, httpclient, strutils, base64, os, uri, asyncdispatch, asyncnet, tables, times]

const
  SpotifyAuthUrl* = "https://accounts.spotify.com/authorize"
  SpotifyTokenUrl* = "https://accounts.spotify.com/api/token"
  SpotifyApiBase* = "https://api.spotify.com/v1"
  SpotifyClientIdDefault* = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
  SpotifyRedirectUri* = "http://localhost:18080/callback"

  Scopes* = "user-read-recently-played user-top-read user-library-read playlist-read-private user-follow-read"

type
  SpotifyTokens* = object
    accessToken*: string
    refreshToken*: string
    expiresAt*: float

  SpotifyTrack* = object
    id*, name*, artist*, album*, url*: string
    durationMs*: int
    playedAt*: string

  SpotifyFeed* = object
    recentlyPlayed*: seq[SpotifyTrack]
    topTracks*: seq[SpotifyTrack]
    newReleases*: seq[SpotifyTrack]
    playlists*: seq[tuple[id, name: string]]
    fetchedAt*: float

  SpotifyClient* = ref object
    clientId*: string
    tokens*: SpotifyTokens
    http*: HttpClient
    connected*: bool

proc newSpotifyClient*(clientId: string = SpotifyClientIdDefault): SpotifyClient =
  result = SpotifyClient(clientId: clientId, http: newHttpClient(), connected: false)

proc tokenFilePath*(): string =
  let home = getEnv("HOME")
  let cfgDir = home / ".config" / "gtm"
  if not dirExists(cfgDir): createDir(cfgDir)
  cfgDir / "spotify_tokens.json"

proc saveTokens*(sc: SpotifyClient) =
  let j = %*{"access_token": sc.tokens.accessToken, "refresh_token": sc.tokens.refreshToken, "expires_at": sc.tokens.expiresAt}
  writeFile(tokenFilePath(), $j)

proc loadTokens*(sc: SpotifyClient): bool =
  let path = tokenFilePath()
  if fileExists(path):
    try:
      let j = parseFile(path)
      sc.tokens.accessToken = j["access_token"].getStr("")
      sc.tokens.refreshToken = j["refresh_token"].getStr("")
      sc.tokens.expiresAt = j["expires_at"].getFloat(0.0)
      sc.connected = sc.tokens.accessToken.len > 0
      return sc.connected
    except: discard
  false

proc refreshAccessToken(sc: SpotifyClient): bool =
  if sc.tokens.refreshToken.len == 0: return false
  try:
    let body = "grant_type=refresh_token&refresh_token=" & encodeUrl(sc.tokens.refreshToken) & "&client_id=" & sc.clientId
    let resp = sc.http.request(SpotifyTokenUrl, httpMethod = HttpPost, body = body,
                               headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"}))
    if resp.status == "200 OK":
      let j = parseJson(resp.body)
      sc.tokens.accessToken = j["access_token"].getStr("")
      if j.hasKey("refresh_token"):
        sc.tokens.refreshToken = j["refresh_token"].getStr("")
      sc.tokens.expiresAt = epochTime() + j["expires_in"].getInt(3600).float
      sc.connected = true
      saveTokens(sc)
      return true
  except: discard
  false

proc ensureToken(sc: SpotifyClient): bool =
  if not sc.connected: return false
  if epochTime() >= sc.tokens.expiresAt - 60:
    result = refreshAccessToken(sc)
  else:
    result = true

proc apiGet(sc: SpotifyClient, endpoint: string): JsonNode =
  if not ensureToken(sc): return nil
  try:
    let resp = sc.http.request(SpotifyApiBase & endpoint,
                               headers = newHttpHeaders({"Authorization": "Bearer " & sc.tokens.accessToken}))
    if resp.status == "200 OK":
      return parseJson(resp.body)
    elif resp.status == "401 Unauthorized":
      if refreshAccessToken(sc):
        return apiGet(sc, endpoint)
  except: discard
  nil

proc startOAuthServer*(): int =
  ## Start a temporary HTTP server to receive the OAuth callback.
  ## Returns the port number.
  result = 18080

proc finishOAuth*(sc: SpotifyClient, code: string): bool =
  try:
    let auth = encode("$1:$2" % [sc.clientId, ""])
    let body = "grant_type=authorization_code&code=" & encodeUrl(code) & "&redirect_uri=" & encodeUrl(SpotifyRedirectUri) & "&client_id=" & sc.clientId
    let resp = sc.http.request(SpotifyTokenUrl, httpMethod = HttpPost, body = body,
                               headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded",
                                                         "Authorization": "Basic " & auth}))
    if resp.status == "200 OK":
      let j = parseJson(resp.body)
      sc.tokens.accessToken = j["access_token"].getStr("")
      sc.tokens.refreshToken = j["refresh_token"].getStr("")
      sc.tokens.expiresAt = epochTime() + j["expires_in"].getInt(3600).float
      sc.connected = true
      saveTokens(sc)
      return true
  except: discard
  false

proc disconnect*(sc: SpotifyClient) =
  sc.tokens = SpotifyTokens()
  sc.connected = false
  let path = tokenFilePath()
  if fileExists(path): removeFile(path)

proc fetchRecentlyPlayed*(sc: SpotifyClient, limit: int = 10): seq[SpotifyTrack] =
  let j = apiGet(sc, "/me/player/recently-played?limit=" & $limit)
  if j == nil: return
  for item in j["items"]:
    let track = item["track"]
    result.add(SpotifyTrack(
      id: track["id"].getStr(""),
      name: track["name"].getStr(""),
      artist: (if track["artists"].len > 0: track["artists"][0]["name"].getStr("") else: ""),
      album: track["album"]["name"].getStr(""),
      url: track["external_urls"]["spotify"].getStr(""),
      durationMs: track["duration_ms"].getInt(0),
      playedAt: item["played_at"].getStr("")
    ))

proc fetchTopTracks*(sc: SpotifyClient, timeRange: string = "medium_term", limit: int = 10): seq[SpotifyTrack] =
  let j = apiGet(sc, "/me/top/tracks?time_range=" & timeRange & "&limit=" & $limit)
  if j == nil: return
  for track in j["items"]:
    result.add(SpotifyTrack(
      id: track["id"].getStr(""),
      name: track["name"].getStr(""),
      artist: (if track["artists"].len > 0: track["artists"][0]["name"].getStr("") else: ""),
      album: track["album"]["name"].getStr(""),
      url: track["external_urls"]["spotify"].getStr(""),
      durationMs: track["duration_ms"].getInt(0)
    ))

proc fetchNewReleases*(sc: SpotifyClient, limit: int = 10): seq[SpotifyTrack] =
  let j = apiGet(sc, "/browse/new-releases?limit=" & $limit)
  if j == nil: return
  for album in j["albums"]["items"]:
    result.add(SpotifyTrack(
      id: album["id"].getStr(""),
      name: album["name"].getStr(""),
      artist: (if album["artists"].len > 0: album["artists"][0]["name"].getStr("") else: ""),
      album: album["name"].getStr(""),
      url: album["external_urls"]["spotify"].getStr(""),
      durationMs: 0
    ))

proc fetchUserPlaylists*(sc: SpotifyClient, limit: int = 10): seq[tuple[id, name: string]] =
  let j = apiGet(sc, "/me/playlists?limit=" & $limit)
  if j == nil: return
  for pl in j["items"]:
    result.add((id: pl["id"].getStr(""), name: pl["name"].getStr("")))

proc fetchFeed*(sc: SpotifyClient): SpotifyFeed =
  if not ensureToken(sc): return
  result.recentlyPlayed = fetchRecentlyPlayed(sc, 10)
  result.topTracks = fetchTopTracks(sc, "medium_term", 10)
  result.newReleases = fetchNewReleases(sc, 5)
  result.playlists = fetchUserPlaylists(sc, 10)
  result.fetchedAt = epochTime()

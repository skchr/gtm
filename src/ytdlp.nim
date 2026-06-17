import os, json, strutils, osproc, streams, posix
import state

proc readFd(fd: cint, buf: pointer, count: cint): cint {.importc: "read", header: "<unistd.h>".}

proc findYtdlp*(): string =
  result = findExe("yt-dlp")
  if result.len == 0:
    result = findExe("youtube-dl")

proc parseYtJsonLine*(line: string): YtSearchResult =
  try:
    let j = parseJson(line)
    var dur = ""
    if j.hasKey("duration"):
      let d = j["duration"].getFloat(0.0)
      let m = int(d) div 60
      let s = int(d) mod 60
      dur = $m & ":" & ($s).align(2, '0')
    let ieKey = if j.hasKey("ie_key"): j["ie_key"].getStr("") else: ""
    let extractor = if j.hasKey("extractor"): j["extractor"].getStr("") else: ""
    let isPlaylist = ieKey == "YoutubePlaylist" or extractor == "youtube:playlist" or
      (j.hasKey("_type") and j["_type"].getStr("") == "playlist")
    let t = if j.hasKey("title"): j["title"].getStr("") else: ""
    let u = if j.hasKey("webpage_url"): j["webpage_url"].getStr("")
            elif j.hasKey("url"): j["url"].getStr("")
            else: ""
    let c = if j.hasKey("channel"): j["channel"].getStr("")
            elif j.hasKey("uploader"): j["uploader"].getStr("")
            else: ""
    let plTitle = if j.hasKey("playlist_title"): j["playlist_title"].getStr("") else: ""
    result = YtSearchResult(title: t, url: u, duration: dur, channel: c,
      playlistTitle: plTitle, kind: if isPlaylist: srkPlaylist else: srkVideo)
  except:
    discard

proc parseYtJsonLines(buf: var string): seq[YtSearchResult] =
  ## Parse complete JSON lines from buf, return results, keep incomplete tail in buf.
  result = @[]
  while true:
    let nli = buf.find('\n')
    if nli < 0: break
    let line = buf[0..<nli]
    buf = buf[nli+1..^1]
    if line.len > 0:
      let r = parseYtJsonLine(line)
      if r.title.len > 0:
        result.add(r)

proc detectBrowserCookieSource*(): string =
  let home = getEnv("HOME", "")
  try:
    if dirExists(home & "/.mozilla/firefox"):
      for kind, path in walkDir(home & "/.mozilla/firefox"):
        if kind == pcDir and path.contains("default"):
          if fileExists(path & "/cookies.sqlite"):
            return "firefox"
  except: discard
  for dir in ["chromium", "google-chrome", "google-chrome-stable", "chromium-browser", "microsoft-edge", "BraveSoftware/Brave-Browser"]:
    if fileExists(home & "/.config/" & dir & "/Default/Cookies"):
      let name = dir.substr(dir.rfind('/') + 1)
      return name
  try:
    let flat = home & "/.var/app/org.mozilla.firefox/.mozilla/firefox"
    if dirExists(flat):
      for kind, path in walkDir(flat):
        if kind == pcDir and path.contains("default"):
          if fileExists(path & "/cookies.sqlite"):
            return "firefox"
  except: discard
  for dir in ["chromium", "google-chrome", "google-chrome-stable", "chromium-browser", "microsoft-edge", "BraveSoftware/Brave-Browser"]:
    let snap = home & "/snap/" & dir & "/current/.config/" & dir & "/Default/Cookies"
    if fileExists(snap):
      let name = dir.substr(dir.rfind('/') + 1)
      return name
  result = ""

proc cookieFlags*(source: string; filePath: string = ""): string =
  if filePath.len > 0 and fileExists(filePath):
    result = " --cookies " & quoteShell(filePath)
  elif source.len == 0: return ""
  elif source.contains("/") or source.contains("."):
    result = " --cookies " & quoteShell(source)
  else:
    result = " --cookies-from-browser " & source

proc jsRuntimeFlags*(runtime: string): string =
  if runtime.len == 0: return ""
  result = " --js-runtimes " & runtime & " --remote-components ejs:github"

proc startYoutubeSearch*(query: string; p: var Process; cookieSource: string = ""; pageSize: int = 20; cookieFilePath: string = ""): bool =
  let yt = findYtdlp()
  if yt.len == 0: return false
  let searchQuery = "ytsearch" & $pageSize & ":" & query
  let cmd = yt & " " & quoteShell(searchQuery) & " --dump-json --no-warnings" & cookieFlags(cookieSource, cookieFilePath) & " 2>/dev/null"
  try:
    p = startProcess(cmd, options = {poUsePath, poEvalCommand})
    return true
  except:
    return false

proc pollYoutubeSearch*(p: var Process, buf: var string): seq[YtSearchResult] =
  ## Non-blocking read of yt-dlp stdout for --dump-json output.
  ## Reads whatever data is available, parses complete JSON lines, returns partial results.
  ## Does NOT close the process. Incomplete JSON lines stay in buf.
  result = @[]
  try:
    let outFd = p.outputHandle()
    var rfds: TFdSet
    FD_ZERO(rfds)
    FD_SET(outFd, rfds)
    var tv: Timeval
    tv.tv_sec = 0.Time
    tv.tv_usec = 0.Suseconds
    if select(cint(outFd) + 1, addr(rfds), nil, nil, addr(tv)) > 0:
      var tmp: array[16384, char]
      let n = readFd(outFd, addr tmp[0], tmp.len.cint)
      if n > 0:
        let old = buf.len; buf.setLen(old + n); copyMem(addr buf[old], addr tmp[0], n)
    result = parseYtJsonLines(buf)
  except:
    discard

proc finishYoutubeSearch*(p: var Process, buf: var string): seq[YtSearchResult] =
  ## Drains remaining stdout data, closes process, returns any final results.
  result = @[]
  try:
    let outFd = p.outputHandle()
    var rfds: TFdSet
    FD_ZERO(rfds)
    FD_SET(outFd, rfds)
    var tv: Timeval
    tv.tv_sec = 0.Time
    tv.tv_usec = 0.Suseconds
    while select(cint(outFd) + 1, addr(rfds), nil, nil, addr(tv)) > 0:
      var tmp: array[16384, char]
      let n = readFd(outFd, addr tmp[0], tmp.len.cint)
      if n <= 0: break
      let old = buf.len; buf.setLen(old + n); copyMem(addr buf[old], addr tmp[0], n)
      FD_ZERO(rfds)
      FD_SET(outFd, rfds)
  except:
    discard
  close(p)
  result = parseYtJsonLines(buf)

proc startStreamUrlFetch*(url: string; p: var Process; cookieSource: string = ""; jsRuntime: string = "node"; cookieFilePath: string = ""): bool =
  let yt = findYtdlp()
  if yt.len == 0: return false
  let cmd = yt & " -f \"ba\" -g --no-playlist --no-check-formats --no-warnings" & cookieFlags(cookieSource, cookieFilePath) & jsRuntimeFlags(jsRuntime) & " --user-agent \"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36\" --add-headers \"Referer:https://www.youtube.com/\" " & quoteShell(url) & " 2>/dev/null"
  try:
    p = startProcess(cmd, options = {poUsePath, poEvalCommand})
    return true
  except:
    return false

proc pollStreamUrlFetch*(p: var Process, buf: var string): string =
  if p.running(): return ""
  try:
    buf.add(p.outputStream.readAll())
  except:
    discard
  let code = try: p.peekExitCode except: -1
  close(p)
  if code != 0:
    return ""
  let raw = buf.strip()
  for line in raw.splitLines:
    let trimmed = line.strip()
    if trimmed.startsWith("http://") or trimmed.startsWith("https://"):
      # Guard: skip URLs that are webpage URLs, not direct stream URLs
      if not (trimmed.contains("googlevideo.com") or trimmed.contains("youtube.com/videoplayback") or
              trimmed.contains("manifest.googlevideo.com") or trimmed.contains("yt-video") or
              trimmed.contains("rr") or trimmed.contains("redirector")):
        if trimmed.contains("youtube.com/watch") or trimmed.contains("youtu.be/") or
           trimmed.contains("youtube.com/playlist"):
          continue
      return trimmed
  result = ""

proc startDownload*(item: YtSearchResult; outputDir: string; p: var Process; cookieSource: string = ""; jsRuntime: string = "node"; cookieFilePath: string = ""): bool =
  let yt = findYtdlp()
  if yt.len == 0: return false
  if not dirExists(outputDir): createDir(outputDir)
  let cmd = yt & " -f bestaudio --extract-audio --audio-format opus --no-playlist --print after_move:filepath --no-check-formats --no-warnings --user-agent \"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36\" --add-headers \"Referer:https://www.youtube.com/\"" & cookieFlags(cookieSource, cookieFilePath) & jsRuntimeFlags(jsRuntime) & " -o " &
    quoteShell(outputDir / "%(title)s.%(ext)s") & " " & quoteShell(item.url) & " 2>&1"
  try:
    p = startProcess(cmd, options = {poUsePath, poEvalCommand})
    return true
  except:
    return false

proc pollDownload*(p: var Process, buf: var string): string =
  if p.running(): return ""
  let code = try: p.peekExitCode except: -1
  try:
    buf.add(p.outputStream.readAll())
  except:
    discard
  close(p)
  if code != 0:
    return ""
  for line in buf.splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0 and fileExists(trimmed):
      return trimmed
  result = ""

proc startPlaylistFetch*(url: string; p: var Process; cookieSource: string = ""; jsRuntime: string = "node"; cookieFilePath: string = ""): bool =
  let yt = findYtdlp()
  if yt.len == 0: return false
  let cmd = yt & " --dump-json --no-playlist --flat-playlist --no-warnings" & cookieFlags(cookieSource, cookieFilePath) & jsRuntimeFlags(jsRuntime) & " " & quoteShell(url) & " 2>/dev/null"
  try:
    p = startProcess(cmd, options = {poUsePath, poEvalCommand})
    return true
  except:
    return false

proc pollPlaylistFetch*(p: var Process, buf: var string): seq[YtSearchResult] =
  ## Non-blocking read of playlist fetch stdout. Reads available data,
  ## parses complete JSON lines, returns partial results.
  result = @[]
  try:
    let outFd = p.outputHandle()
    var rfds: TFdSet
    FD_ZERO(rfds)
    FD_SET(outFd, rfds)
    var tv: Timeval
    tv.tv_sec = 0.Time
    tv.tv_usec = 0.Suseconds
    if select(cint(outFd) + 1, addr(rfds), nil, nil, addr(tv)) > 0:
      var tmp: array[16384, char]
      let n = readFd(outFd, addr tmp[0], tmp.len.cint)
      if n > 0:
        let old = buf.len; buf.setLen(old + n); copyMem(addr buf[old], addr tmp[0], n)
    result = parseYtJsonLines(buf)
  except:
    discard

proc finishPlaylistFetch*(p: var Process, buf: var string): seq[YtSearchResult] =
  ## Drains remaining stdout data, closes process, returns any final results.
  result = @[]
  try:
    let outFd = p.outputHandle()
    var rfds: TFdSet
    FD_ZERO(rfds)
    FD_SET(outFd, rfds)
    var tv: Timeval
    tv.tv_sec = 0.Time
    tv.tv_usec = 0.Suseconds
    while select(cint(outFd) + 1, addr(rfds), nil, nil, addr(tv)) > 0:
      var tmp: array[16384, char]
      let n = readFd(outFd, addr tmp[0], tmp.len.cint)
      if n <= 0: break
      let old = buf.len; buf.setLen(old + n); copyMem(addr buf[old], addr tmp[0], n)
      FD_ZERO(rfds)
      FD_SET(outFd, rfds)
  except:
    discard
  close(p)
  result = parseYtJsonLines(buf)

proc fetchPlaylistTracks*(url: string; cookieSource: string = ""; jsRuntime: string = "node"): YtPlaylistDetail =
  ## Legacy blocking version — still used for backward compat but UNCHANGED internally.
  ## New code should use startPlaylistFetch/pollPlaylistFetch/finishPlaylistFetch.
  let yt = findYtdlp()
  if yt.len == 0: return YtPlaylistDetail()
  let cmd = yt & " --dump-json --no-playlist --flat-playlist --no-warnings" & cookieFlags(cookieSource) & " " & quoteShell(url) & " 2>/dev/null"
  try:
    let p = startProcess(cmd, options = {poUsePath, poEvalCommand})
    if p.running():
      discard p.waitForExit()
    let output = p.outputStream.readAll()
    close(p)
    let lines = output.splitLines
    if lines.len > 0:
      let firstLine = lines[0]
      if firstLine.len > 0:
        try:
          let j = parseJson(firstLine)
          let title = if j.hasKey("title"): j["title"].getStr("") else: "Unknown Playlist"
          let channel = if j.hasKey("channel"): j["channel"].getStr("")
                       elif j.hasKey("uploader"): j["uploader"].getStr("")
                       else: ""
          result.title = title
          result.url = url
          result.channel = channel
        except: discard
      for line in lines:
        if line.len > 0:
          let r = parseYtJsonLine(line)
          if r.title.len > 0:
            result.tracks.add(r)
      result.trackCount = result.tracks.len
  except:
    discard



import os, json, strutils, osproc, streams, posix
import state

proc readFd(fd: cint, buf: pointer, count: cint): cint {.importc: "read", header: "<unistd.h>".}

proc findYtdlp*(): string =
  result = findExe("yt-dlp")
  if result.len == 0:
    result = findExe("youtube-dl")

proc parseYtPrintLines(lines: seq[string], start: int): (YtSearchResult, int) =
  ## Parse 4 --print output lines (title, url, duration, channel) starting at `start`.
  ## Returns (result, next_index) or (default, -1) if fewer than 4 lines remain.
  if start + 3 >= lines.len:
    return (YtSearchResult(), -1)
  let title = lines[start]
  let url = lines[start+1]
  if title.len == 0 or url.len == 0:
    return (YtSearchResult(), start + 4)
  let durRaw = lines[start+2]
  let channel = lines[start+3]
  var dur = ""
  if durRaw.len > 0:
    try:
      let d = parseFloat(durRaw)
      let m = int(d) div 60
      let s = int(d) mod 60
      dur = $m & ":" & ($s).align(2, '0')
    except: discard
  let isPlaylist = url.contains("playlist?list=")
  result = (YtSearchResult(title: title, url: url, duration: dur, channel: channel,
    kind: if isPlaylist: srkPlaylist else: srkVideo), start + 4)

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
    result = YtSearchResult(title: t, url: u, duration: dur, channel: c, kind: if isPlaylist: srkPlaylist else: srkVideo)
  except:
    discard

proc detectBrowserCookieSource*(): string =
  let home = getEnv("HOME", "")
  try:
    if dirExists(home & "/.mozilla/firefox"):
      for kind, path in walkDir(home & "/.mozilla/firefox"):
        if kind == pcDir and path.contains("default"):
          if fileExists(path & "/cookies.sqlite"):
            return "firefox"
  except: discard
  for dir in ["chromium", "google-chrome", "BraveSoftware/Brave-Browser"]:
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
  for dir in ["chromium", "google-chrome", "BraveSoftware/Brave-Browser"]:
    let snap = home & "/snap/" & dir & "/current/.config/" & dir & "/Default/Cookies"
    if fileExists(snap):
      let name = dir.substr(dir.rfind('/') + 1)
      return name
  result = ""

proc cookieFlags*(source: string): string =
  if source.len == 0: return ""
  if source.contains("/") or source.contains("."):
    result = " --cookies " & quoteShell(source)
  else:
    result = " --cookies-from-browser " & source

proc jsRuntimeFlags*(runtime: string): string =
  if runtime.len == 0: return ""
  result = " --js-runtimes " & runtime & " --remote-components ejs:github"

proc startYoutubeSearch*(query: string; p: var Process; cookieSource: string = ""; pageSize: int = 10): bool =
  let yt = findYtdlp()
  if yt.len == 0: return false
  let searchQuery = "ytsearch" & $pageSize & ":" & query
  let cmd = yt & " " & quoteShell(searchQuery) & " --no-playlist --print \"title\" --print \"webpage_url\" --print \"duration\" --print \"channel\" --no-warnings" & cookieFlags(cookieSource) & " 2>/dev/null"
  try:
    p = startProcess(cmd, options = {poUsePath, poEvalCommand})
    return true
  except:
    return false

proc parseYtPrintBuf(buf: var string): seq[YtSearchResult] =
  ## Parse all complete 4-line groups from buf, leaving incomplete tail in buf.
  result = @[]
  let lines = buf.splitLines()
  if lines.len == 0: return
  var idx = 0
  while true:
    let (r, next) = parseYtPrintLines(lines, idx)
    if next < 0: break
    if r.title.len > 0:
      result.add(r)
    idx = next
  if idx < lines.len:
    buf = lines[idx..^1].join("\n")
  else:
    buf = ""

proc pollYoutubeSearch*(p: var Process, buf: var string): seq[YtSearchResult] =
  ## Non-blocking read of yt-dlp stdout. Reads whatever data is available,
  ## parses complete 4-line groups (title, url, duration, channel), returns
  ## partial results. Does NOT close the process. Incomplete groups stay in buf.
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
      var tmp: array[4096, char]
      let n = readFd(outFd, addr tmp[0], tmp.len.cint)
      if n > 0:
        let old = buf.len; buf.setLen(old + n); copyMem(addr buf[old], addr tmp[0], n)
    result = parseYtPrintBuf(buf)
  except:
    discard

proc finishYoutubeSearch*(p: var Process, buf: var string): seq[YtSearchResult] =
  ## Drains remaining stdout data, closes process, returns any final results.
  ## Call this once when p.running() is false.
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
      var tmp: array[4096, char]
      let n = readFd(outFd, addr tmp[0], tmp.len.cint)
      if n <= 0: break
      let old = buf.len; buf.setLen(old + n); copyMem(addr buf[old], addr tmp[0], n)
      FD_ZERO(rfds)
      FD_SET(outFd, rfds)
  except:
    discard
  close(p)
  result = parseYtPrintBuf(buf)

proc startStreamUrlFetch*(url: string; p: var Process; cookieSource: string = ""; jsRuntime: string = "node"): bool =
  let yt = findYtdlp()
  if yt.len == 0: return false
  let cmd = yt & " -f \"ba\" -g --no-playlist --no-check-formats --no-warnings" & cookieFlags(cookieSource) & jsRuntimeFlags(jsRuntime) & " --user-agent \"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36\" --add-headers \"Referer:https://www.youtube.com/\" " & quoteShell(url) & " 2>/dev/null"
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

proc startDownload*(item: YtSearchResult; outputDir: string; p: var Process; cookieSource: string = ""; jsRuntime: string = "node"): bool =
  let yt = findYtdlp()
  if yt.len == 0: return false
  if not dirExists(outputDir): createDir(outputDir)
  let cmd = yt & " -f bestaudio --extract-audio --audio-format opus --no-playlist --print after_move:filepath --no-check-formats --no-warnings --user-agent \"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36\" --add-headers \"Referer:https://www.youtube.com/\"" & cookieFlags(cookieSource) & jsRuntimeFlags(jsRuntime) & " -o " &
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

proc fetchPlaylistTracks*(url: string; cookieSource: string = ""; jsRuntime: string = "node"): YtPlaylistDetail =
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



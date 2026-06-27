import illwave as iw
import ../vendor/nimwave/nimwave as nw
from unicode import runeLen, toRunes, Rune
import colors, sequtils, math, strutils, tables, sets, os, times, posix, osproc, options, terminal
import state, theme, audio, library, icons, commands, graphics, hashes, store, daemonservice

type State* = Store
include ../vendor/nimwave/nimwave/prelude

template state*(ctx: nw.Context[Store]): var AppState = ctx.data.app

var gTermCellW*: int = 8
var gTermCellH*: int = 16

proc blendBg*(fg: colors.Color, alpha: float): colors.Color =
  ## Blend a color with black background at the given opacity
  let raw = int(fg)
  let r = uint8(float(raw shr 16 and 0xff) * alpha)
  let g = uint8(float(raw shr 8 and 0xff) * alpha)
  let b = uint8(float(raw and 0xff) * alpha)
  iw.toColor(r, g, b)

proc initHighlightGroups*(theme: Theme, transparentBg: bool = false): HighlightGroups =
  template bg(c: colors.Color): Option[colors.Color] =
    if transparentBg: none(colors.Color) else: some(c)
  result.Normal = HighlightAttr(fg: some(theme.text), bg: bg(theme.base))
  result.TabBar = HighlightAttr(fg: some(theme.subtext0), bg: bg(theme.mantle))
  result.TabBarActive = HighlightAttr(fg: some(theme.mauve), bg: bg(theme.surface2))
  result.TabBarInactive = HighlightAttr(fg: some(theme.subtext0), bg: bg(theme.mantle))
  result.NowPlayingTitle = HighlightAttr(fg: some(theme.text))
  result.NowPlayingArtist = HighlightAttr(fg: some(theme.subtext0))
  result.NowPlayingProgress = HighlightAttr(fg: some(theme.mauve))
  result.NowPlayingProgressFill = HighlightAttr(fg: some(theme.mauve), bg: bg(theme.surface2))
  result.NowPlayingStatus = HighlightAttr(fg: some(theme.green))
  result.NowPlayingUpNext = HighlightAttr(fg: some(theme.text))
  result.NowPlayingUpNextCursor = HighlightAttr(fg: some(theme.yellow), bg: bg(theme.surface2))
  result.NowPlayingUpNextHeader = HighlightAttr(fg: some(theme.sky))
  result.LibrarySidebar = HighlightAttr(fg: some(theme.subtext0), bg: bg(theme.mantle))
  result.LibrarySidebarActive = HighlightAttr(fg: some(theme.blue))
  result.LibrarySidebarSelected = HighlightAttr(fg: some(theme.text), bg: bg(theme.surface2))
  result.LibraryContentHeader = HighlightAttr(fg: some(theme.subtext0), bg: bg(theme.mantle))
  result.LibraryContentRow = HighlightAttr(fg: some(theme.text))
  result.LibraryContentRowSelected = HighlightAttr(fg: some(theme.blue), bg: bg(theme.surface2))
  result.SettingsSidebar = HighlightAttr(fg: some(theme.subtext0), bg: bg(theme.mantle))
  result.SettingsContentRow = HighlightAttr(fg: some(theme.subtext0))
  result.SettingsContentRowSelected = HighlightAttr(fg: some(theme.text), bg: bg(theme.surface0))
  result.SettingsSectionHeader = HighlightAttr(fg: some(theme.mauve), bg: bg(theme.crust))
  result.StatusBar = HighlightAttr(fg: some(theme.subtext0), bg: bg(theme.mantle))
  result.StatusBarHints = HighlightAttr(fg: some(theme.subtext0))
  result.StatusBarModule = HighlightAttr(fg: some(theme.subtext0))
  result.FilterBar = HighlightAttr(fg: some(theme.text), bg: bg(theme.surface1))
  result.ProgressBar = HighlightAttr(fg: some(theme.mauve), bg: bg(theme.crust))
  result.ProgressBarTime = HighlightAttr(fg: some(theme.sky))
  result.OverlayBorder = HighlightAttr(fg: some(theme.mauve))
  result.OverlayTitle = HighlightAttr(fg: some(theme.mauve))
  result.OverlayInput = HighlightAttr(fg: some(theme.text), bg: bg(theme.surface1))
  result.OverlayRow = HighlightAttr(fg: some(theme.text))
  result.OverlayRowSelected = HighlightAttr(fg: some(theme.blue), bg: bg(theme.surface2))
  result.OverlayFooter = HighlightAttr(fg: some(theme.subtext0))
  result.Scrollbar = HighlightAttr(fg: some(theme.surface2))
  result.ErrorMsg = HighlightAttr(fg: some(theme.red))
  result.WarningMsg = HighlightAttr(fg: some(theme.peach))
  result.InfoMsg = HighlightAttr(fg: some(theme.blue))
  result.SuccessMsg = HighlightAttr(fg: some(theme.green))
  result.VolumeCue = HighlightAttr(fg: some(theme.green), bg: bg(theme.surface0))
  result.FeedbackCue = HighlightAttr(fg: some(theme.blue), bg: bg(theme.surface0))
  result.NowPlayingCue = HighlightAttr(fg: some(theme.blue), bg: bg(theme.surface0))
  result.UpNextCue = HighlightAttr(fg: some(theme.peach), bg: bg(theme.surface0))
  result.EqualizerBar = HighlightAttr(fg: some(theme.blue))

template hl*(state: AppState, group: untyped): colors.Color =
  state.highlightGroups.`group`.fg.get(state.theme.text)

template hlBg*(state: AppState, group: untyped): colors.Color =
  state.highlightGroups.`group`.bg.get(state.theme.base)

proc wordWrap*(text: string, maxWidth: int): seq[string] =
  if maxWidth <= 0 or text.runeLen == 0: return @[text]
  result = @[]
  for line in text.splitLines:
    if line.runeLen <= maxWidth:
      result.add(line)
    else:
      var remaining = line
      while remaining.runeLen > maxWidth:
        let r = remaining.toRunes
        var breakIdx = maxWidth
        for i in countdown(maxWidth, 0):
          if i < r.len and $r[i] == " ":
            breakIdx = i
            break
        if breakIdx == 0:
          breakIdx = maxWidth
        result.add($r[0..<breakIdx])
        remaining = ($r[breakIdx..^1]).strip(leading = true)
      if remaining.runeLen > 0:
        result.add(remaining)

const
  statusBarHeight = 1
  minGridW = 40
  minGridH = 10

  SYS_GIT_HASH* = staticExec("git rev-parse --short=7 HEAD 2>/dev/null").strip

proc sysCmd(cmd: string): string =
  try:
    let (outp, _) = execCmdEx(cmd)
    outp.strip
  except:
    ""

type SysInfo = object
  kernel, os, cpu, cpuCount, memTotal, memAvail, term: string
  ffmpeg, gcc, nim, ytdlp, node, bun, deno: string

var sysInfoInitialized: bool
var sysInfo: SysInfo

proc ensureSysInfo =
  if not sysInfoInitialized:
    sysInfoInitialized = true
    sysInfo = SysInfo(
      kernel: sysCmd("uname -srmo 2>/dev/null"),
      os: block:
        let v = sysCmd("cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'")
        if v.len > 0: v
        else:
          let av = sysCmd("grep ro.build.version.release /system/build.prop 2>/dev/null | cut -d= -f2 | head -1")
          if av.len > 0: "Android " & av else: "",
      cpu: sysCmd("grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ *//'"),
      cpuCount: sysCmd("grep -c ^processor /proc/cpuinfo 2>/dev/null"),
      memTotal: sysCmd("grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2/1024/1024}'"),
      memAvail: sysCmd("grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2/1024/1024}'"),
      term: getEnv("TERM", ""),
      ffmpeg: sysCmd("ffmpeg -version 2>/dev/null | head -1 | sed 's/.*ffmpeg version //i; s/ .*//'"),
      gcc: sysCmd("gcc --version 2>/dev/null | head -1 | sed 's/.* //'"),
      nim: sysCmd("nim --version 2>/dev/null | head -1 | sed 's/.*Version //; s/ .*//'"),
      ytdlp: sysCmd("yt-dlp --version 2>/dev/null"),
      node: sysCmd("node --version 2>/dev/null"),
      bun: sysCmd("bun --version 2>/dev/null"),
      deno: sysCmd("deno --version 2>/dev/null | head -1"),
    )

proc SYS_KERNEL*: string = (ensureSysInfo(); sysInfo.kernel)
proc SYS_OS*: string = (ensureSysInfo(); sysInfo.os)
proc SYS_CPU*: string = (ensureSysInfo(); sysInfo.cpu)
proc SYS_CPU_COUNT*: string = (ensureSysInfo(); sysInfo.cpuCount)
proc SYS_MEM_TOTAL*: string = (ensureSysInfo(); sysInfo.memTotal)
proc SYS_MEM_AVAIL*: string = (ensureSysInfo(); sysInfo.memAvail)
proc SYS_TERM*: string = (ensureSysInfo(); sysInfo.term)
proc SYS_FFMPEG*: string = (ensureSysInfo(); sysInfo.ffmpeg)
proc SYS_GCC_VER*: string = (ensureSysInfo(); sysInfo.gcc)
proc SYS_NIM_VER*: string = (ensureSysInfo(); sysInfo.nim)
proc SYS_YTDLP*: string = (ensureSysInfo(); sysInfo.ytdlp)
proc SYS_NODE*: string = (ensureSysInfo(); sysInfo.node)
proc SYS_BUN*: string = (ensureSysInfo(); sysInfo.bun)
proc SYS_DENO*: string = (ensureSysInfo(); sysInfo.deno)

type TrackColumns = object
  xTitle, wTitle: int
  xArtist, wArtist: int
  xAlbum, wAlbum: int
  xDuration: int

proc calcTrackCols(w: int): TrackColumns =
  let avail = max(16, w - 8)
  result.xTitle = 1
  result.wTitle = avail * 35 div 100
  result.xArtist = result.xTitle + result.wTitle + 1
  result.wArtist = avail * 30 div 100
  result.xAlbum = result.xArtist + result.wArtist + 1
  result.wAlbum = avail * 25 div 100
  result.xDuration = max(1, w - 7)

proc filteredCount*(state: AppState): int =
  if state.filteredIndices.len > 0: state.filteredIndices.len
  else: state.displayItems.len

proc filteredIndex*(state: AppState, idx: int): int =
  if state.filteredIndices.len > 0: state.filteredIndices[idx] else: idx

proc selectedItem*(state: AppState): LibraryItem =
  let items = state.displayItems
  if state.filteredIndices.len > 0:
    if state.selectIndex >= 0 and state.selectIndex < state.filteredIndices.len:
      let realIdx = state.filteredIndices[state.selectIndex]
      if realIdx >= 0 and realIdx < items.len:
        return items[realIdx]
  else:
    if state.selectIndex >= 0 and state.selectIndex < items.len:
      return items[state.selectIndex]
  LibraryItem(kind: likTrack, label: "", trackIdx: -1)

proc fillBg(tb: var iw.TerminalBuffer, x1, y1, x2, y2: int, col: colors.Color) =
  for y in y1..y2:
    for x in x1..x2:
      var cell = tb[x, y]
      cell.bgTruecolor = col
      cell.bg = iw.bgNone
      cell.ch = " ".toRunes[0]
      tb[x, y] = cell
  tb.setBackgroundColor(col)

proc writeStr(tb: var iw.TerminalBuffer, x, y: int, text: string, fg: colors.Color) =
  tb.setForegroundColor(fg)
  tb.write(x, y, text)

proc writeStrBg(tb: var iw.TerminalBuffer, x, y: int, text: string, fg, bg: colors.Color) =
  tb.setForegroundColor(fg)
  tb.setBackgroundColor(bg)
  tb.write(x, y, text)
  tb.setBackgroundColor(iw.bgNone)

proc truncateAt(s: string, maxRunes: int): string =
  if maxRunes <= 0: return ""
  let rl = s.runeLen
  if rl <= maxRunes: return s
  let allRunes = s.toRunes
  result = ""
  for i in 0..<min(maxRunes - 1, allRunes.len - 1):
    result.add($allRunes[i])
  result.add("\u2026")

proc drawBorder*(tb: var iw.TerminalBuffer, x1, y1, x2, y2: int, col: colors.Color, style: BorderStyle = bsRounded) =
  if x2 - x1 < 2 or y2 - y1 < 2: return
  if style == bsNone: return
  tb.setForegroundColor(col)
  let w = x2 - x1
  let h = y2 - y1
  let (tl, tr, bl, br, hz, vt) =
    case style
    of bsRounded: ("\u256D", "\u256E", "\u2570", "\u256F", "\u2500", "\u2502")
    of bsSharp:   ("\u250C", "\u2510", "\u2514", "\u2518", "\u2500", "\u2502")
    of bsDouble:  ("\u2554", "\u2557", "\u255A", "\u255D", "\u2550", "\u2551")
    of bsBold:    ("\u250F", "\u2513", "\u2517", "\u251B", "\u2501", "\u2503")
    of bsDotted:  ("\u250C", "\u2510", "\u2514", "\u2518", "\u2504", "\u250A")
    of bsCurved:  ("\u256D", "\u256E", "\u2570", "\u256F", "\u2500", "\u2502")
    of bsNone:    (" ", " ", " ", " ", " ", " ")
  tb.write(x1, y1, tl)
  tb.write(x1 + w, y1, tr)
  tb.write(x1, y1 + h, bl)
  tb.write(x1 + w, y1 + h, br)
  for x in x1 + 1..<x2:
    tb.write(x, y1, hz)
    tb.write(x, y1 + h, hz)
  for y in y1 + 1..<y2:
    tb.write(x1, y, vt)
    tb.write(x2, y, vt)

proc overlayBackground*(tb: var iw.TerminalBuffer, w, h: int, col: colors.Color) =
  fillBg(tb, 0, 0, w - 1, h - 1, col)

proc renderHoverPreview*(ctx: var nw.Context[State]) =
  let state = ctx.state
  let theme = state.theme
  let h = state.hoverState
  if not h.active or h.trackIdx < 0: return
  let w = iw.width(ctx.tb)
  let hh = iw.height(ctx.tb)
  let hasCover = h.coverData.len > 0 and state.hasKittyGraphics
  let imgW = if hasCover: 6 else: 0
  let imgH = if hasCover: 6 else: 0
  let textH = 5
  let boxH = max(textH, imgH) + 2
  let boxW = min(48, w div 3 + 14)
  let boxX = min(h.rowX + 4, w - boxW - 1)
  let boxY = min(h.rowY, hh - boxH - 2)
  if boxX < 0 or boxY < 0: return
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.mauve, state.borderStyle)
  fillBg(ctx.tb, boxX + 1, boxY + 1, boxX + boxW - 2, boxY + boxH - 2, theme.surface0)
  # Kitty image on right side
  if hasCover:
    let imgX = boxX + boxW - imgW - 2
    let imgY = boxY + 1
    deleteImage(HoverImageId)
    transmitImage(h.coverData, h.coverMime, HoverImageId)
    placeImage(imgX, imgY, HoverImageId, imgW)
    for y in imgY..min(imgY + imgH - 1, boxY + boxH - 2):
      for x in imgX..min(imgX + imgW - 1, boxX + boxW - 2):
        var cell = ctx.tb[x, y]
        cell.protected = true
        ctx.tb[x, y] = cell
  # Text metadata on left side
  var ly = boxY + 1
  let textX = boxX + 2
  let maxTextW = if imgW > 0: boxW - imgW - 5 else: boxW - 4
  writeStr(ctx.tb, textX, ly, truncateAt(h.title, maxTextW), theme.text); ly.inc
  if h.album.len > 0:
    writeStr(ctx.tb, textX, ly, truncateAt(h.album, maxTextW), theme.subtext0); ly.inc
  if h.channel.len > 0:
    writeStr(ctx.tb, textX, ly, truncateAt(h.channel, maxTextW), theme.subtext0); ly.inc
  if h.duration > 0:
    writeStr(ctx.tb, textX, ly, "Duration: " & formatTime(h.duration), theme.subtext0); ly.inc
  let srcLabel = if h.path.startsWith("http"): "YouTube" else: "Local"
  writeStr(ctx.tb, textX, ly, srcLabel, theme.sky)

type TabBar = ref object of nw.Node
method render*(node: TabBar, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  if w < 4: return
  let theme = ctx.state.theme
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  let ic = currentIcons()
  let tabIcons = [ic.headphone, ic.library, ic.settings]
  let tabs = [
    "Now Playing", "Library",
    "Settings"
  ]
  var x = 1
  let tabKeys = ["1", "2", "3"]
  for i, name in tabs:
    let key = tabKeys[i]
    let tab = AppTab(i)
    let isActive = ctx.state.tab == tab
    let display = "[" & key & "]" & tabIcons[i] & " " & name
    let segLen = display.runeLen + 1
    if isActive:
      fillBg(ctx.tb, x, 0, x + segLen, 0, theme.surface2)
      writeStr(ctx.tb, x, 0, display, theme.mauve)
    else:
      ctx.tb.setBackgroundColor(theme.mantle)
      writeStr(ctx.tb, x, 0, display, theme.subtext0)
    x += segLen
  writeStr(ctx.tb, w - 12, 0, " gtm " & GTM_VERSION & " ", theme.overlay2)

var gCursorX, gCursorY: int = -1

proc showInputCursor*(state: var AppState, w, h: int) =
  let shouldShow = state.overlay.kind in {okYtSearch, okCommandPalette, okThemePicker, okEqPresetPicker, okQueuePicker, okPlaylistSearch, okQueueOverlay, okFuzzyFinder, okSpotifyUrlInput, okSpotifySearch, okLyricsSearch} or
    (state.overlay.kind == okNone and (state.playlistInputActive or state.mode == imFilter or state.mode == imLeaderMode))
  if shouldShow == state.cursorVisible: return
  state.cursorVisible = shouldShow
  if shouldShow:
    var cx = 1
    var cy = 1
    case state.overlay.kind
    of okYtSearch, okCommandPalette, okThemePicker, okQueuePicker, okPlaylistSearch, okQueueOverlay, okSpotifyUrlInput, okSpotifySearch, okLyricsSearch:
      let boxW = min(60, w - 4)
      let boxH = min(h - 4, 20)
      let boxX = (w - boxW) div 2
      let boxY = (h - boxH) div 2
      cx = boxX + 4
      cy = boxY + 2
    of okNone:
      if state.playlistInputActive:
        let boxW = min(50, w - 8)
        let boxH = 5
        let boxX = (w - boxW) div 2
        let boxY = (h - boxH) div 2
        cx = boxX + 3
        cy = boxY + 3
      elif state.mode == imFilter or state.mode == imLeaderMode:
        cx = 9
        cy = 1
    else: discard
    if cx != gCursorX or cy != gCursorY:
      stdout.write("\e[?25h\e[" & $cy & ";" & $cx & "H")
      gCursorX = cx
      gCursorY = cy
  else:
    stdout.write("\e[?25l")
    gCursorX = -1
    gCursorY = -1

type NowPlayingView = ref object of nw.Node
method render*(node: NowPlayingView, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  var state = ctx.state
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  var track = if state.ytStreamTitle.len > 0:
    Track(title: state.ytStreamTitle, artist: state.ytStreamChannel, duration: 0.0, path: state.currentPlayingPath)
  elif state.currentPlayingPath.len > 0:
    state.getPlayingTrack()
  elif state.status == psPlaying or state.status == psPaused:
    Track()
  elif state.libraryTracks.len > 0 and
    state.selectIndex >= 0 and state.selectIndex < state.libraryTracks.len:
    state.libraryTracks[state.selectIndex]
  else:
    Track()
  if track.path.len == 0 and state.currentPlayingPath.len > 0:
    track = Track(path: state.currentPlayingPath,
      title: state.currentPlayingTitle, artist: state.currentPlayingChannel)
  if track.path.len == 0 and state.currentPlayingPath.len == 0:
    writeStr(ctx.tb, 1, 1, "No track selected", theme.subtext0)
    if not state.audioAvailable:
      writeStr(ctx.tb, 1, 2, truncateAt("Audio device unavailable — no sound output", w - 2), theme.red)
    writeStr(ctx.tb, 1, 3, truncateAt("Add music with: gtm <file|url>", w - 2), theme.subtext0)
    return
  let artPad = 1
  var line = 0
  # Title row
  fillBg(ctx.tb, 0, line, w - 1, line, theme.base)
  let title = track.displayName()
  let titleTrunc = if title.runeLen > w - artPad - 3: truncateAt(title, w - artPad - 2) else: title
  writeStr(ctx.tb, artPad, line, titleTrunc, theme.text)
  line.inc
  # Artist — Album row
  let artistStr = track.displayArtist()
  let albumStr = track.displayAlbum()
  let artistAlbum = artistStr & "  \u2014  " & albumStr
  writeStr(ctx.tb, artPad, line, truncateAt(artistAlbum, w - artPad - 2), theme.subtext0)
  line.inc
  # Codec extension
  let codecExt = splitFile(track.path).ext
  if codecExt.len > 1:
    let codecStr = codecExt[1..^1]
    writeStr(ctx.tb, artPad, line, codecStr, theme.overlay0)
    line.inc
  # Status row
  let ic = currentIcons()
  let statusIcon = if state.status == psPlaying: ic.play elif state.status == psPaused: ic.pause else: ic.stop
  let statusColor =
    if state.status == psPlaying: theme.green
    elif state.status == psPaused: theme.yellow
    else: theme.surface2
  writeStr(ctx.tb, artPad, line, statusIcon & (
    if state.status == psPlaying: "Playing"
    elif state.status == psPaused: "Paused"
    else: "Stopped"), statusColor)
  line.inc
  # Progress bar
  if state.duration > 0:
    let elapsed = formatTime(state.timePos)
    let remaining = formatTime(max(0.0, state.duration - state.timePos))
    if state.progressStyle == 0:
      # Block bar (original style)
      let timeStr = elapsed & " / -" & remaining
      writeStr(ctx.tb, artPad, line, ic.time & " " & timeStr, theme.mauve)
      let barW = min(w - timeStr.runeLen - 14, 30)
      if barW > 4:
        let progress = min(1.0, state.timePos / state.duration)
        let barStart = artPad + timeStr.runeLen + 6
        writeStr(ctx.tb, barStart, line, "\u2588".repeat(barW), theme.surface2)
        for i in 0..<barW:
          let frac = float(i) / float(max(barW - 1, 1))
          if frac < progress:
            writeStr(ctx.tb, barStart + i, line, "\u2588", theme.mauve)
          else:
            writeStr(ctx.tb, barStart + i, line, "\u2591", theme.surface2)
      line.inc
    else:
      # Thumb+Track style
      let pct = int(min(1.0, state.timePos / state.duration) * 100)
      let timeStr = elapsed & " / -" & remaining
      writeStr(ctx.tb, artPad, line, ic.time & " " & timeStr, theme.mauve)
      let barW = min(w - timeStr.runeLen - 20, 28)
      if barW > 6:
        let progress = min(1.0, state.timePos / state.duration)
        let filled = int(progress * float(barW - 2))
        let barStart = artPad + timeStr.runeLen + 6
        writeStr(ctx.tb, barStart, line, "\u2503", theme.mauve)
        for i in 0..<barW - 2:
          if i < filled:
            writeStr(ctx.tb, barStart + 1 + i, line, "\u2501", theme.mauve)
          elif i == filled:
            writeStr(ctx.tb, barStart + 1 + i, line, "\u25CF", theme.peach)
          else:
            writeStr(ctx.tb, barStart + 1 + i, line, "\u2501", theme.surface2)
        writeStr(ctx.tb, barStart + barW - 1, line, "\u2503", theme.mauve)
        let pctStr = $pct & "%"
        writeStr(ctx.tb, barStart + barW + 2, line, pctStr, theme.subtext0)
      line.inc
  line.inc
  writeStr(ctx.tb, artPad, line, "\u2500".repeat(min(w - 2, 36)), theme.surface2)
  line.inc
  # Album cover art (Kitty protocol)
  if state.hasKittyGraphics:
    if state.currentPlayingPath.len > 0:
      let cacheKey = hash(state.currentPlayingPath).toHex
      if state.coverCache.hasKey(cacheKey) and state.coverCache[cacheKey].data.len > 0:
        let (coverBytes, coverMime) = state.coverCache[cacheKey]
        let coverW = min(18, (w div 3) - 1)
        if coverW >= 8:
          let coverX = w - coverW - 1
          let coverY = 1
          if ctx.state.coverImageId < 0:
            deleteImage(CoverImageId)
            transmitImage(coverBytes, coverMime, CoverImageId)
            ctx.state.coverImageId = CoverImageId
          placeImage(coverX, coverY, ctx.state.coverImageId, coverW)
    elif ctx.state.coverImageId >= 0:
      deleteImage(ctx.state.coverImageId)
      ctx.state.coverImageId = -1
  # Lyrics — synced gradient (togglable)
  if state.lyricsVisible and state.currentLyrics.lines.len > 0:
    let maxLyricLines = 6
    let startLine = max(0, state.lyricsLineIdx - 2)
    let endLine = min(state.currentLyrics.lines.len - 1, startLine + maxLyricLines - 1)
    for idx in startLine..endLine:
      if idx > state.currentLyrics.lines.high: break
      let lyr = state.currentLyrics.lines[idx]
      let dist = abs(idx - state.lyricsLineIdx)
      let lyrColor = if dist == 0: theme.green
                     elif dist == 1: theme.teal
                     else: theme.overlay1
      let prefix = if dist == 0: "\u25B6 " elif dist == 1: " \u25CB " else: "  "
      if dist <= 1:
        ctx.tb.setStyle({styleBright})
      writeStr(ctx.tb, artPad, line, prefix & lyr.text, lyrColor)
      if dist <= 1:
        ctx.tb.setStyle({})
      if dist == 0:
        line.inc
        if line < h - statusBarHeight:
          writeStr(ctx.tb, artPad, line, "", theme.base)
      line.inc
    line.inc
  # Up Next — scrollable
  if w >= 40:
    writeStr(ctx.tb, artPad, line, "Up Next", theme.sky)
    line.inc
    let maxLines = h - line - 1
    let scrollOff = state.upNextScrollOffset.clamp(0, max(0, state.playbackQueue.len - maxLines))
    let visible = min(state.playbackQueue.len, maxLines)
    if visible > 0:
      for visIdx in 0..<visible:
        let qIdx = scrollOff + visIdx
        if qIdx >= state.playbackQueue.len: break
        let tIdx = state.playbackQueue[qIdx]
        let isNowPlaying = qIdx == 0 and state.status == psPlaying
        let isNowPlayingPaused = qIdx == 0 and state.status == psPaused
        let isCursor = qIdx == state.queueCursor
        let upBg = if isCursor: theme.surface2 else: theme.base
        fillBg(ctx.tb, 0, line, w - 1, line, upBg)
        let prefix = if isNowPlaying: "\u25B6 " elif isNowPlayingPaused: "\u23F8 " else: "  "
        let dispName =
          if tIdx >= 0 and tIdx < state.libraryTracks.len:
            state.libraryTracks[tIdx].displayName()
          elif qIdx < state.queuePaths.len and state.queuePaths[qIdx].len > 0:
            state.queuePaths[qIdx].splitFile().name.replace(".", " ")
          else:
            "Unknown track"
        writeStr(ctx.tb, artPad + 2, line, prefix & truncateAt(dispName, w - artPad - 6), if isCursor: theme.yellow elif isNowPlaying: theme.blue elif isNowPlayingPaused: theme.yellow else: theme.text)
        line.inc
      # Scrollbar
      if state.playbackQueue.len > maxLines:
        let scrollbarH = maxLines
        let thumbPos = (scrollOff * scrollbarH) div state.playbackQueue.len
        let thumbH = max(1, (maxLines * maxLines) div state.playbackQueue.len)
        for sy in 0..<scrollbarH:
          let isThumb = sy >= thumbPos and sy < thumbPos + thumbH
          let sbChar = if isThumb: "\u2588" else: "\u2591"
          writeStr(ctx.tb, w - 1, line + sy - visible, sbChar, if isThumb: theme.surface2 else: theme.surface0)
    else:
      if maxLines > 0:
        writeStr(ctx.tb, artPad + 2, line, "No tracks queued", theme.subtext0)
        line.inc

type LibrarySidebar = ref object of nw.Node
method render*(node: LibrarySidebar, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 4: return
  let state = ctx.state
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.mantle)
  let isFocused = state.libraryFocusPanel == lpSidebar
  let ic = currentIcons()
  let spLabel = ic.headphone & " Spotify"
  let spExpand = if state.sidebarSpExpanded: "\u25BC " else: "\u25B6 "
  let entries = if state.sidebarSpExpanded:
    @[
      (scope: fsAll,        label: ic.track & " All Tracks",     count: state.libraryTracks.len),
      (scope: fsArtists,    label: ic.artist & " Artists",       count: state.libraryArtists.len),
      (scope: fsAlbums,     label: ic.album & " Albums",         count: state.libraryAlbums.len),
      (scope: fsPlaylists,  label: ic.playlist & " Playlists",   count: state.libraryPlaylists.len),
      (scope: fsRecent,     label: ic.time & " Recent",          count: state.libraryTracks.len),
      (scope: fsFavourites, label: ic.heart & " Favourites",     count: 0),
      (scope: fsLastPlayed, label: ic.musicNote & " Last Played",count: state.libraryTracks.len),
      (scope: fsMostPlayed, label: ic.arrowUp & " Most Played",  count: state.libraryTracks.len),
      (scope: fsLeastPlayed,label: ic.arrowDown & " Least Played",count: state.libraryTracks.len),
      (scope: fsDownloads,  label: ic.disk & " Downloads",       count: state.downloadCount),
      (scope: fsSpotify,    label: spExpand & spLabel,           count: state.spDownloadCount),
      (scope: fsSpLiked,    label: "  " & ic.heart & " Liked Songs", count: 0),
      (scope: fsSpPlaylists,label: "  " & ic.playlist & " Playlists", count: state.spUserPlaylists.len),
    ]
  else:
    @[
      (scope: fsAll,        label: ic.track & " All Tracks",     count: state.libraryTracks.len),
      (scope: fsArtists,    label: ic.artist & " Artists",       count: state.libraryArtists.len),
      (scope: fsAlbums,     label: ic.album & " Albums",         count: state.libraryAlbums.len),
      (scope: fsPlaylists,  label: ic.playlist & " Playlists",   count: state.libraryPlaylists.len),
      (scope: fsRecent,     label: ic.time & " Recent",          count: state.libraryTracks.len),
      (scope: fsFavourites, label: ic.heart & " Favourites",     count: 0),
      (scope: fsLastPlayed, label: ic.musicNote & " Last Played",count: state.libraryTracks.len),
      (scope: fsMostPlayed, label: ic.arrowUp & " Most Played",  count: state.libraryTracks.len),
      (scope: fsLeastPlayed,label: ic.arrowDown & " Least Played",count: state.libraryTracks.len),
      (scope: fsDownloads,  label: ic.disk & " Downloads",       count: state.downloadCount),
      (scope: fsSpotify,    label: spExpand & spLabel,           count: state.spDownloadCount),
    ]
  var favCount = 0
  for t in state.libraryTracks:
    if t.id in state.favouriteIds or t.isFavourite:
      favCount.inc
  var line = 0
  fillBg(ctx.tb, 0, line, w - 1, line, theme.crust)
  writeStr(ctx.tb, 1, line, "Library", theme.subtext1)
  line.inc
  for i, entry in entries:
    if line >= h: break
    let actualCount = if entry.scope == fsFavourites: favCount elif entry.scope == fsSpLiked: 0 else: entry.count
    let isActive = state.filterScope == entry.scope
    let isSelected = state.librarySidebarSelect == i and isFocused
    let rowBg = if isSelected: theme.surface2 elif isActive: theme.surface0 else: theme.mantle
    fillBg(ctx.tb, 0, line, w - 1, line, rowBg)
    let countStr = $actualCount
    let maxLabelW = max(1, w - countStr.runeLen - 2)
    let label = entry.label
    let display = if label.runeLen > maxLabelW: label[0..<max(1, maxLabelW - 2)] & "\u2026" else: label
    let fg = if isActive: theme.blue elif isSelected: theme.text else: theme.subtext0
    writeStr(ctx.tb, 1, line, display, fg)
    if state.showItemCounts:
      writeStr(ctx.tb, w - countStr.runeLen - 1, line, countStr, theme.overlay0)
    line.inc

type LibraryContentView = ref object of nw.Node
method render*(node: LibraryContentView, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 3: return
  var state = ctx.state
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  let isFocused = state.libraryFocusPanel == lpContent
  let items = state.displayItems
  let count = state.filteredCount()
  var line = 0
  block:
    let pt = state.getPlayingTrack()
    if pt.path.len > 0 and state.status != psStopped:
      let statusIcon = if state.status == psPlaying: "\u25B6 " else: "\u23F8 "
      let avail = max(0, w - 4)
      let label = statusIcon & truncateAt(pt.displayName(), avail)
      writeStr(ctx.tb, 1, line, label, theme.green)
      if pt.displayArtist().len > 0 and 5 + label.runeLen < w:
        writeStr(ctx.tb, 3 + label.runeLen, line, truncateAt("\u2014 " & pt.displayArtist(), avail - label.runeLen), theme.subtext0)
      line.inc
  # Downloads view
  if state.filterScope == fsDownloads:
    fillBg(ctx.tb, 0, line, w - 1, line, theme.mantle)
    writeStr(ctx.tb, 1, line, "Downloading", theme.subtext0)
    writeStr(ctx.tb, w - 10, line, "Status", theme.subtext0)
    line.inc
    var anyItems = false
    for task in state.ytDownloadTasks:
      if line >= h: break
      anyItems = true
      let spinner = ["\u25D0", "\u25D3", "\u25D1", "\u25D2"][state.spinnerFrame mod 4]
      let label = spinner & " " & task.title
      let maxLabelW = max(1, w - 16)
      let displayLabel = if label.runeLen > maxLabelW: label[0..<max(1, maxLabelW - 3)] & "\u2026" else: label
      writeStr(ctx.tb, 1, line, displayLabel, theme.blue)
      writeStr(ctx.tb, w - 14, line, "downloading", theme.green)
      line.inc
    for q in state.ytDownloadQueue:
      if line >= h: break
      anyItems = true
      let label = "\u25CB " & q.title
      let maxLabelW = max(1, w - 12)
      let displayLabel = if label.runeLen > maxLabelW: label[0..<max(1, maxLabelW - 3)] & "\u2026" else: label
      writeStr(ctx.tb, 1, line, displayLabel, theme.subtext0)
      writeStr(ctx.tb, w - 10, line, "queued", theme.overlay0)
      line.inc
    if not anyItems:
      writeStr(ctx.tb, 1, line, "  No active downloads", theme.subtext0)
      line.inc
    fillBg(ctx.tb, 0, line, w - 1, h - 1, theme.base)
    return

  if count == 0:
    if state.libraryLoading:
      writeStr(ctx.tb, 1, line + 1, "Loading library...", theme.subtext0)
    else:
      writeStr(ctx.tb, 1, line + 1, "No items found", theme.subtext0)
    return
  let headerOffset = line
  let isTrackView = state.filterScope in {fsAll, fsTracks}
  let isPlaylistView2 = state.filterScope == fsPlaylists
  fillBg(ctx.tb, 0, line, w - 1, line, theme.mantle)
  if isTrackView:
    let cols = calcTrackCols(w)
    writeStr(ctx.tb, cols.xTitle, line, "Title", theme.subtext0)
    writeStr(ctx.tb, cols.xArtist, line, "Artist", theme.subtext0)
    writeStr(ctx.tb, cols.xAlbum, line, "Album", theme.subtext0)
    writeStr(ctx.tb, cols.xDuration, line, "Time", theme.subtext0)
  elif state.filterScope == fsArtists:
    writeStr(ctx.tb, 1, line, "Artist", theme.subtext0)
    writeStr(ctx.tb, w - 6, line, "Tracks", theme.subtext0)
  elif state.filterScope == fsAlbums:
    writeStr(ctx.tb, 1, line, "Album", theme.subtext0)
    writeStr(ctx.tb, w - 4, line, "Year", theme.subtext0)
  elif isPlaylistView2:
    writeStr(ctx.tb, 1, line, "Playlist", theme.subtext0)
    writeStr(ctx.tb, w - 7, line, "Tracks", theme.subtext0)
  line.inc
  let startIdx = max(0, state.selectIndex - (h - 1 - line) div 2)
  let endIdx = min(count, startIdx + h - line)
  for i in startIdx..<endIdx:
    let realIdx = state.filteredIndex(i)
    let isSelected = (i == state.selectIndex) and isFocused
    let item = if realIdx >= 0 and realIdx < items.len: items[realIdx] else: LibraryItem()
    let rowBg = if isSelected: theme.surface2 elif state.selectMode and realIdx in state.selectedIndices: theme.surface0 else: theme.base
    fillBg(ctx.tb, 0, line, w - 1, line, rowBg)
    if isTrackView:
      if item.trackIdx >= 0 and item.trackIdx < state.libraryTracks.len:
        let track = state.libraryTracks[item.trackIdx]
        let cols = calcTrackCols(w)
        let nameTrunc = if track.displayName().runeLen > cols.wTitle - 2:
          track.displayName()[0..<min(track.displayName().len, max(1, cols.wTitle - 4))] & "\u2026"
        else: track.displayName()
        let artistTrunc = if track.displayArtist().runeLen > cols.wArtist - 2:
          track.displayArtist()[0..<min(track.displayArtist().len, max(1, cols.wArtist - 4))] & "\u2026"
        else: track.displayArtist()
        let albumTrunc = if track.displayAlbum().runeLen > cols.wAlbum - 2:
          track.displayAlbum()[0..<min(track.displayAlbum().len, max(1, cols.wAlbum - 4))] & "\u2026"
        else: track.displayAlbum()
        let time = if track.duration > 0: formatTime(track.duration) else: ""
        let playingMarker = if track.path == state.currentPlayingPath and state.status == psPlaying: "\u25B6 " else: ""
        let playFg = if track.path == state.currentPlayingPath and state.status == psPlaying: theme.green else: (if isSelected: theme.blue else: theme.text)
        writeStr(ctx.tb, cols.xTitle, line, playingMarker & nameTrunc, playFg)
        writeStr(ctx.tb, cols.xArtist, line, artistTrunc, theme.subtext1)
        writeStr(ctx.tb, cols.xAlbum, line, albumTrunc, theme.subtext1)
        writeStr(ctx.tb, cols.xDuration, line, time, theme.overlay0)
    else:
      let ic = currentIcons()
      let prefix = case item.kind
        of likArtist: ic.artist & " "
        of likAlbum: ic.album & " "
        of likPlaylist: ic.playlist & " "
        of likTrack: ic.music & " "
      let label = item.label
      let fg = if isSelected: theme.blue else: theme.text
      let sublabelW = if item.sublabel.len > 0: item.sublabel.runeLen + 2 else: 0
      let maxLabelW = max(1, w - prefix.runeLen - sublabelW - 2)
      let displayLabel = if label.runeLen > maxLabelW: label[0..<max(1, maxLabelW - 2)] & "\u2026" else: label
      writeStr(ctx.tb, 1, line, prefix & displayLabel, fg)
      if item.sublabel.len > 0:
        writeStr(ctx.tb, w - item.sublabel.runeLen - 1, line, item.sublabel, theme.subtext1)
    line.inc
  fillBg(ctx.tb, 0, line, w - 1, h - 1, theme.base)
  let scrollH = h - headerOffset - 1
  if count > scrollH and scrollH > 0:
    let thumbH = max(1, scrollH * scrollH div count)
    let thumbPos = (state.selectIndex * (scrollH - thumbH)) div max(1, count - 1)
    for sy in 0..<thumbH:
      let syAbs = headerOffset + 1 + thumbPos + sy
      if syAbs >= headerOffset and syAbs < h:
        var cell = ctx.tb[w - 1, syAbs]
        cell.bgTruecolor = theme.surface2
        cell.fgTruecolor = theme.surface2
        cell.ch = "\u2588".toRunes[0]
        ctx.tb[w - 1, syAbs] = cell

type
  SettingsCategoryInfo = object
    id: SettingsCategory
    label: string
    icon: string

const settingsCategories* = [
  SettingsCategoryInfo(id: scAudio, label: "Audio", icon: "\u266B"),
  SettingsCategoryInfo(id: scYouTube, label: "YouTube", icon: "\u25B6"),
  SettingsCategoryInfo(id: scAppearance, label: "Appearance", icon: "\u2726"),
  SettingsCategoryInfo(id: scSystem, label: "System", icon: "\u2699"),
  SettingsCategoryInfo(id: scSpotify, label: "Spotify", icon: "\u266C"),
]

type SettingsView = ref object of nw.Node
method render*(node: SettingsView, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  let state = ctx.state
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  let sidebarFocused = state.settingsFocusPanel == lpSidebar

  if w < 55 and sidebarFocused:
    # Collapsed mode: show category list full-width
    fillBg(ctx.tb, 0, 0, w - 1, h - 2, theme.mantle)
    for i, cat in settingsCategories:
      let y = 1 + i * 2
      if y >= h - 2: break
      let isSel = state.settingsCategory == cat.id
      let catBg = if isSel: theme.surface2 else: theme.mantle
      fillBg(ctx.tb, 0, y, w - 1, y, catBg)
      let prefix = if isSel: "\u25B8 " else: "  "
      let fg = if isSel: theme.base else: theme.subtext0
      writeStr(ctx.tb, 2, y, prefix & cat.icon & " " & cat.label, fg)
    fillBg(ctx.tb, 0, h - 1, w - 1, h - 1, theme.base)
    writeStr(ctx.tb, 1, h - 1, " Tab/→:Content ", theme.subtext0)
    return

  let sidebarW = if w < 55: 0 else: max(14, min(22, w div 5))
  let contentX = sidebarW
  let contentW = w - sidebarW

  if w >= 55:
    # Left sidebar: categories
    fillBg(ctx.tb, 0, 0, sidebarW - 1, h - 2, theme.mantle)
    for i, cat in settingsCategories:
      let y = 1 + i * 2
      if y >= h - 2: break
      let isSel = state.settingsCategory == cat.id
      let isFocused = sidebarFocused and isSel
      let catBg = if isSel: (if isFocused: theme.surface2 else: theme.surface0) else: theme.mantle
      fillBg(ctx.tb, 0, y, sidebarW - 1, y, catBg)
      let prefix = if isSel: (if isFocused: "\u25B8 " else: "\u25CB ") else: "  "
      let fg = if isFocused: theme.base else: (if isSel: theme.blue else: theme.subtext0)
      writeStr(ctx.tb, 2, y, prefix & cat.icon & " " & cat.label, fg)

  let descH = 5
  let contentFocused = state.settingsFocusPanel == lpContent
  fillBg(ctx.tb, contentX, 0, w - 1, h - 2 - descH, theme.base)
  var line = 0
  var itemIdx = 0
  template sectionHeader(label: string) =
    fillBg(ctx.tb, contentX, line, w - 1, line, theme.crust)
    writeStr(ctx.tb, contentX + 1, line, "  " & label, theme.mauve)
    line.inc
  template settingsRow(label: string) =
    let isSelected = contentFocused and itemIdx == state.selectIndex
    let rowBg = if isSelected: theme.surface0 else: theme.base
    fillBg(ctx.tb, contentX, line, w - 1, line, rowBg)
    let prefix = if isSelected: "\u25B8 " else: "  "
    writeStr(ctx.tb, contentX + 2, line, prefix & label, if isSelected: theme.text else: theme.subtext0)
    itemIdx.inc
  template sliderWidget(val, maxVal, barW: int) =
    let filled = (val * barW + maxVal div 2) div maxVal
    let bar = "\u2588".repeat(filled) & "\u2591".repeat(barW - filled)
    writeStr(ctx.tb, contentX + contentW - barW - 12, line, bar, theme.peach)
    writeStr(ctx.tb, contentX + contentW - 9, line, $val, theme.subtext0)
  template toggleWidget(isOn: bool) =
    if isOn:
      writeStr(ctx.tb, contentX + contentW - 8, line, "[●] On ", theme.green)
    else:
      writeStr(ctx.tb, contentX + contentW - 8, line, "[○] Off", theme.subtext0)

  case state.settingsCategory
  of scAudio:
    sectionHeader("═══ Audio ═══")
    settingsRow("Volume")
    sliderWidget(state.volume, 100, 14)
    line.inc
    settingsRow("Crossfade Duration")
    sliderWidget(state.crossfadeDuration, 10, 14)
    writeStr(ctx.tb, contentX + contentW - 7, line, "s", theme.subtext0)
    line.inc
    settingsRow("Crossfade Curve")
    let curveIdx = state.crossfadeCurve.ord
    let curveLabel = if curveIdx >= 0 and curveIdx < CrossfadeCurveLabels.len: CrossfadeCurveLabels[curveIdx] else: "Quadratic"
    writeStr(ctx.tb, contentX + contentW - curveLabel.runeLen - 11, line, "[ " & curveLabel & " ▸]", theme.subtext0)
    line.inc
    settingsRow("Daemon")
    if state.daemonConnected:
      writeStr(ctx.tb, contentX + contentW - 10, line, "[●] Connected ", theme.green)
    else:
      writeStr(ctx.tb, contentX + contentW - 12, line, "[○] Disconnected", theme.red)
    line.inc
  of scYouTube:
    sectionHeader("═══ YouTube ═══")
    settingsRow("Cookie Source")
    let cookieLabel = truncateAt(if state.ytCookieSource.len == 0: "none" else: state.ytCookieSource, max(0, contentW - 14))
    writeStr(ctx.tb, contentX + contentW - cookieLabel.runeLen - 11, line, "[ " & cookieLabel & " \u25B8]", theme.subtext0)
    line.inc
    settingsRow("Cookie File")
    let cfLabel = if state.ytCookieFilePath.len == 0: "(none)" else: state.ytCookieFilePath
    writeStr(ctx.tb, contentX + contentW - cfLabel.runeLen - 11, line, "[ " & cfLabel & " \u25B8]", theme.subtext0)
    line.inc
    settingsRow("JS Runtime")
    let rtLabel = if state.ytJsRuntime.len == 0: JsRuntimes[0] else: state.ytJsRuntime
    writeStr(ctx.tb, contentX + contentW - rtLabel.runeLen - 11, line, "[ " & rtLabel & " ▸]", theme.subtext0)
    line.inc
    settingsRow("Max Downloads")
    sliderWidget(state.ytMaxConcurrentDownloads, 10, 14)
    line.inc
    settingsRow("Results Per Page")
    sliderWidget(state.ytSearchPageSize, 50, 14)
    line.inc
    settingsRow("Search History")
    writeStr(ctx.tb, contentX + contentW - 15, line, "[" & $state.ytSearchHistory.len & " entries ▸]", theme.subtext0)
    line.inc
    settingsRow("Batch Mode")
    toggleWidget(state.ytBatchDownloadMode)
    line.inc
    settingsRow("Clear Search History")
    writeStr(ctx.tb, contentX + contentW - 8, line, "[Clear]", theme.peach)
    line.inc
  of scAppearance:
    sectionHeader("═══ Appearance ═══")
    settingsRow("Theme")
    writeStr(ctx.tb, contentX + contentW - state.config.theme.runeLen - 11, line, "[ " & state.config.theme & " ▸]", theme.subtext0)
    line.inc
    settingsRow("Refresh Theme")
    toggleWidget(state.config.refreshTheme)
    line.inc
    settingsRow("Footer Preset")
    let fpLabel = $state.footerPreset
    let fpDisplay = if fpLabel.startsWith("fpn"): fpLabel[3..^1] else: fpLabel
    writeStr(ctx.tb, contentX + contentW - fpDisplay.runeLen - 11, line, "[ " & fpDisplay & " ▸]", theme.subtext0)
    line.inc
    settingsRow("Customize Modules")
    let leftCount = state.footerLeftModules.card
    let rightCount = state.footerRightModules.card
    writeStr(ctx.tb, contentX + contentW - 14, line, "L:" & $leftCount & " R:" & $rightCount, theme.subtext0)
    line.inc
    settingsRow("Transparent BG")
    toggleWidget(state.transparentBg)
    line.inc
    settingsRow("Opacity")
    sliderWidget(int(state.overlayOpacity * 100), 100, 14)
    line.inc
    settingsRow("Icon Style")
    let iconLabel = case state.iconPreference
      of ipAuto: "Auto Detect"
      of ipNerdFont: "Nerd Font"
      of ipEmoji: "Emoji"
    writeStr(ctx.tb, contentX + contentW - iconLabel.runeLen - 11, line, "[ " & iconLabel & " ▸]", theme.subtext0)
    line.inc
    settingsRow("Border Style")
    let borderLabels = ["Rounded", "Sharp", "Double", "Bold", "Dotted", "Curved", "None"]
    let bl = if state.borderStyle.ord < borderLabels.len: borderLabels[state.borderStyle.ord] else: "Rounded"
    writeStr(ctx.tb, contentX + contentW - bl.runeLen - 11, line, "[ " & bl & " ▸]", theme.subtext0)
    line.inc
    settingsRow("Progress Style")
    let progLabels = ["Block", "Thumb+Track"]
    let pLabel = if state.progressStyle < progLabels.len: progLabels[state.progressStyle] else: "Block"
    writeStr(ctx.tb, contentX + contentW - pLabel.runeLen - 11, line, "[ " & pLabel & " ▸]", theme.subtext0)
    line.inc
  of scSystem:
    sectionHeader("═══ System ═══")
    settingsRow("Idle Timeout")
    sliderWidget(state.config.idleTimeout, 600, 14)
    writeStr(ctx.tb, contentX + contentW - 8, line, "s", theme.subtext0)
    line.inc
    settingsRow("Daemon IPC Timeout")
    sliderWidget(state.config.ipcTimeout, 30, 14)
    writeStr(ctx.tb, contentX + contentW - 8, line, "s", theme.subtext0)
    line.inc
    settingsRow("Reset All Settings")
    writeStr(ctx.tb, contentX + contentW - 8, line, "[Reset]", theme.peach)
    line.inc
  of scSpotify:
    sectionHeader("═══ Spotify ═══")
    settingsRow("Cookie Source")
    let spCookieLabel = truncateAt(if state.spCookieSource.len == 0: "none" else: state.spCookieSource, max(0, contentW - 14))
    writeStr(ctx.tb, contentX + contentW - spCookieLabel.runeLen - 11, line, "[ " & spCookieLabel & " \u25B8]", theme.subtext0)
    line.inc
    settingsRow("Cookie File")
    let spCfLabel = if state.spCookieFilePath.len == 0: "(none)" else: state.spCookieFilePath
    writeStr(ctx.tb, contentX + contentW - spCfLabel.runeLen - 11, line, "[ " & spCfLabel & " \u25B8]", theme.subtext0)
    line.inc
    settingsRow("Audio Format")
    let fmtLabel = if state.spAudioFormat.len == 0: SpotifyFormats[0] else: state.spAudioFormat
    writeStr(ctx.tb, contentX + contentW - fmtLabel.runeLen - 11, line, "[ " & fmtLabel & " ▸]", theme.subtext0)
    line.inc
    settingsRow("Max Downloads")
    sliderWidget(state.ytMaxConcurrentDownloads, 10, 14)
    line.inc
    settingsRow("Download History")
    writeStr(ctx.tb, contentX + contentW - 15, line, "[" & $state.spDownloadCount & " tracks ▸]", theme.subtext0)
    line.inc
    settingsRow("Clear History")
    writeStr(ctx.tb, contentX + contentW - 8, line, "[Clear]", theme.peach)
    line.inc
    settingsRow("Import Playlist")
    writeStr(ctx.tb, contentX + contentW - 10, line, "[Import]", theme.green)
    line.inc

  # Description panel at bottom of right pane
  fillBg(ctx.tb, contentX, h - 2 - descH, w - 1, h - 2, theme.mantle)
  var descLine = h - 2 - descH + 1
  writeStr(ctx.tb, contentX + 2, descLine, "Help", theme.mauve)
  descLine.inc
  if sidebarFocused:
    let catDesc = SettingCategoryDescs[state.settingsCategory]
    let wrapped = wordWrap(catDesc, max(1, contentW - 4))
    for wl in wrapped:
      if descLine >= h - 2: break
      writeStr(ctx.tb, contentX + 2, descLine, wl, theme.subtext0)
      descLine.inc
  else:
    let cat = state.settingsCategory
    let descIdx = state.selectIndex
    if descIdx >= 0 and descIdx < SettingDescs[cat].len:
      let wrapped = wordWrap(SettingDescs[cat][descIdx], max(1, contentW - 4))
      for wl in wrapped:
        if descLine >= h - 2: break
        writeStr(ctx.tb, contentX + 2, descLine, wl, theme.subtext0)
        descLine.inc
      let toggleOpt =
        if cat == scAudio and descIdx == 2:
          let cIdx = state.crossfadeCurve.ord
          if cIdx >= 0 and cIdx < CrossfadeCurveLabels.len: some(CrossfadeCurveLabels[cIdx]) else: none(string)
        elif cat == scYouTube and descIdx == 1:
          let rLabel = if state.ytJsRuntime.len == 0: JsRuntimes[0] else: state.ytJsRuntime
          some(rLabel)
        else:
          none(string)
      if toggleOpt.isSome and toggleOpt.get in ToggleOptionDescs:
        let optDesc = ToggleOptionDescs[toggleOpt.get]
        if descLine < h - 2:
          writeStr(ctx.tb, contentX + 2, descLine, "\u2192 " & optDesc, theme.sky)
          descLine.inc

  # Bottom status line (shared) — keybinding hints instead of version
  fillBg(ctx.tb, 0, h - 1, w - 1, h - 1, theme.base)
  let kbLine = "Tracks: " & $state.libraryTracks.len & "  |  " &
    (if sidebarFocused: "Tab/\u2192:Content"
     else: "\u2190/Tab:Category")
  writeStr(ctx.tb, 1, h - 1, truncateAt(kbLine, w - 2), theme.subtext0)

type ProgressBarComp = ref object of nw.Node
method render*(node: ProgressBarComp, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  if w < 6: return
  let state = ctx.state
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.crust)
  let elapsed = formatTime(state.timePos)
  let remaining = formatTime(max(0.0, state.duration - state.timePos))
  let timeText = elapsed & " / -" & remaining
  writeStr(ctx.tb, 1, 0, timeText, theme.sky)
  let barWidth = max(3, w - timeText.runeLen - 8)
  let barStart = timeText.runeLen + 2
  var progress = 0.0
  if state.duration > 0:
    progress = min(1.0, state.timePos / state.duration)
  for i in 0..<barWidth:
    var cell = ctx.tb[barStart + 1 + i, 0]
    let frac = float(i) / float(max(barWidth - 1, 1))
    cell.ch = (if frac < progress: "\u2588" else: "\u2591").toRunes[0]
    cell.fg = iw.fgNone
    cell.bg = iw.bgNone
    if frac < progress:
      cell.fgTruecolor = theme.mauve
    else:
      cell.fgTruecolor = theme.surface2
    ctx.tb[barStart + 1 + i, 0] = cell
  var rightX = w - 2
  if state.sleepTimerRemaining > 0:
    let sleepStr = " \u23F0 " & $state.sleepTimerRemaining & "m"
    writeStr(ctx.tb, rightX - sleepStr.runeLen + 1, 0, sleepStr, theme.peach)
    rightX -= sleepStr.runeLen + 1
  if state.repeatMode > 0:
    let ic = currentIcons()
    let rptIc = if state.repeatMode == 2: ic.repeatOne else: ic.repeatAll
    writeStr(ctx.tb, rightX, 0, rptIc, if state.repeatMode == 1: theme.green else: theme.blue)
    rightX -= 2
  if state.shuffleEnabled:
    let ic = currentIcons()
    writeStr(ctx.tb, rightX, 0, ic.shuffle, theme.peach)
    rightX -= 2

type StatusBarComp = ref object of nw.Node
method render*(node: StatusBarComp, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  if w < 4: return
  let state = ctx.state
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)

  # Determine active modules — custom mode uses individual left/right sets
  let isCustom = state.footerPreset == fpnCustom
  let activeModules = if isCustom:
    state.footerLeftModules + state.footerRightModules
  else:
    FooterPresets.getOrDefault(state.footerPreset, state.footerModules)

  # -- Left-aligned section (anchored at column 1, left-to-right) --
  var leftX = 1

  # 1. Always show elapsed time first — CANNOT be moved
  if state.duration > 0:
    let elapsedText = " " & formatTime(state.timePos) & " "
    writeStrBg(ctx.tb, leftX, 0, elapsedText, theme.base, theme.sky)
    leftX += elapsedText.runeLen

  # 2. Key pressed / command display (fmKeyPressed module, always after elapsed time)
  let showKeyPressed = fmKeyPressed in activeModules
  let isOverlayActive = state.overlay.kind != okNone or state.helpVisible or state.aboutVisible or state.mode == imLeaderMode
  if showKeyPressed and isOverlayActive:
    if state.lastKeyTimer > 0 and state.lastKeyDisplay.len > 0:
      let keyText = " [" & state.lastKeyDisplay & "] "
      writeStrBg(ctx.tb, leftX, 0, keyText, theme.base, theme.surface2)
      leftX += keyText.runeLen
    elif state.lastCommandName.len > 0:
      let ovText = " " & state.lastCommandName & " "
      writeStrBg(ctx.tb, leftX, 0, ovText, theme.base, theme.surface2)
      leftX += ovText.runeLen
  elif showKeyPressed:
    if state.lastKeyTimer > 0 and state.lastCommandName.len > 0:
      let cmdText = " " & state.lastCommandName & " "
      writeStrBg(ctx.tb, leftX, 0, cmdText, theme.base, theme.surface2)
      leftX += cmdText.runeLen

  # 3. Additional left modules (filter, feedback, select mode — always shown)
  if state.mode == imFilter:
    let filterText = "Filter: " & state.filterText
    writeStrBg(ctx.tb, leftX, 0, truncateAt(filterText, w - leftX - 2), theme.text, theme.surface0)
    leftX += filterText.runeLen + 2

  if state.feedbackTimer > 0 and state.feedbackMsg.len > 0:
    let fbText = " " & state.feedbackMsg & " "
    writeStrBg(ctx.tb, leftX, 0, truncateAt(fbText, w - leftX - 2), theme.text, theme.surface1)
    leftX += fbText.runeLen + 2

  if state.selectMode:
    let selText = " [SELECT] "
    writeStrBg(ctx.tb, leftX, 0, selText, theme.base, theme.peach)
    leftX += selText.runeLen

  # -- Right-aligned section (right-to-left) --
  var rightX = w - 1
  template addMod(text: string, col: colors.Color, bgCol: colors.Color) =
    if rightX > text.runeLen + 2:
      rightX -= text.runeLen + 2
      fillBg(ctx.tb, rightX, 0, rightX + text.runeLen + 1, 0, bgCol)
      ctx.tb.setBackgroundColor(bgCol)
      writeStr(ctx.tb, rightX, 0, text, col)
      ctx.tb.setBackgroundColor(iw.bgNone)

  let ic = currentIcons()

  # Determine which modules go on the right
  let rightModules = if isCustom: state.footerRightModules
    else: activeModules

  # Right modules rendered in fixed order (rightmost-first)
  if fmDate in rightModules and fmTime in rightModules:
    addMod(" " & now().format("ddd dd, MMMM") & "  " & now().format("hh:mm tt"), theme.text, theme.surface2)
  elif fmDate in rightModules:
    addMod(" " & now().format("ddd dd, MMMM"), theme.text, theme.surface2)
  elif fmTime in rightModules:
    addMod(" " & now().format("hh:mm tt"), theme.text, theme.surface2)
  if fmSleepTimer in rightModules and state.sleepTimerRemaining > 0:
    addMod(" " & $(state.sleepTimerRemaining) & "m", theme.base, theme.peach)
  # Group repeat, shuffle, playback status into one block with shared bg
  let hasRepeat = fmRepeatShuffle in rightModules and state.repeatMode > 0
  let hasShuffle = fmRepeatShuffle in rightModules and state.shuffleEnabled
  let hasStatus = fmPlayStatus in rightModules
  if hasRepeat or hasShuffle or hasStatus:
    var combined = ""
    if hasRepeat:
      combined &= (if state.repeatMode == 2: ic.repeatOne else: ic.repeatAll)
    if hasShuffle:
      combined &= ic.shuffle
    let stIcon = case state.status
      of psPlaying: ic.play
      of psPaused: ic.pause
      of psStopped: ic.stop
    if hasStatus:
      combined = combined & stIcon
    let bgCol = if hasStatus and state.status == psPlaying: theme.green else: theme.surface2
    var segments: seq[string] = @[]
    var segColors: seq[colors.Color] = @[]
    if hasRepeat:
      segments.add(if state.repeatMode == 2: ic.repeatOne else: ic.repeatAll)
      segColors.add(theme.base)
    if hasShuffle:
      segments.add(ic.shuffle)
      segColors.add(theme.base)
    if hasStatus:
      segments.add(stIcon)
      segColors.add(theme.base)
    if rightX > combined.runeLen + 2:
      rightX -= combined.runeLen + 2
      fillBg(ctx.tb, rightX, 0, rightX + combined.runeLen + 1, 0, bgCol)
      ctx.tb.setBackgroundColor(bgCol)
      var cx = rightX
      for i, seg in segments:
        writeStr(ctx.tb, cx, 0, seg, segColors[i])
        cx += seg.runeLen
      ctx.tb.setBackgroundColor(iw.bgNone)
  if fmSelectCount in rightModules and state.selectedIndices.len > 0:
    addMod(" [" & $state.selectedIndices.len & "] ", theme.base, theme.peach)
  if fmBackend in rightModules:
    let backend = "ALSA"
    addMod(" " & backend, theme.base, theme.mauve)
  if fmDeviceName in rightModules and state.deviceName.len > 0 and state.deviceName != "ALSA":
    addMod(" " & state.deviceName, theme.base, theme.teal)
  if fmVolume in rightModules:
    addMod(" " & $state.volume & "%", theme.base, theme.teal)
  if fmQueueCount in rightModules and state.playbackQueue.len > 0:
    let qPos = min(state.queueCursor + 1, state.playbackQueue.len)
    addMod(" " & $qPos & "/" & $state.playbackQueue.len, theme.base, theme.sapphire)
  if fmEqPreset in rightModules and state.eqPreset.len > 0:
    addMod(" " & state.eqPreset, theme.base, theme.teal)
  if fmCurrentPlaylist in rightModules and state.playlistContentsIdx >= 0 and
     state.playlistContentsIdx < state.libraryPlaylists.len:
    addMod(" " & state.libraryPlaylists[state.playlistContentsIdx].name, theme.base, theme.sky)

type
  PickerItem* = object
    label*: string
    detail*: string
    selected*: bool
    disabled*: bool

  PickerProps* = object
    title*: string
    items*: seq[PickerItem]
    cursor*: int
    query*: string
    showQuery*: bool
    footer*: string
    showFooter*: bool
    maxHeight*: int
    maxWidth*: int

proc renderPicker*(ctx: var nw.Context[State], props: PickerProps) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  let theme = ctx.state.theme
  if w < 20 or h < 8: return
  let boxW = min(props.maxWidth, w - 8)
  let boxH = min(props.maxHeight, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.mauve, ctx.state.borderStyle)
  writeStr(ctx.tb, boxX + 1, boxY, props.title, theme.mauve)
  var curY = boxY + 1
  if props.showQuery and props.query.len > 0:
    let inputText = "> " & props.query
    let paddedInput = inputText & " ".repeat(max(0, boxW - 2 - inputText.runeLen))
    writeStrBg(ctx.tb, boxX + 1, curY, paddedInput, theme.text, theme.surface1)
    ctx.tb.setBackgroundColor(theme.surface0)
    curY.inc
  if props.showQuery:
    writeStr(ctx.tb, boxX + 1, curY, "\u2500".repeat(boxW - 2), theme.surface2)
    curY.inc
  let displayCount = min(props.items.len, boxH - (curY - boxY) - 2)
  for i in 0..<displayCount:
    let item = props.items[i]
    let isSelected = (i == props.cursor)
    let lineY = curY + i
    if lineY >= boxY + boxH - 1: break
    let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
    if isSelected:
      fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
    ctx.tb.setBackgroundColor(ovRowBg)
    let label = if item.disabled: "✗ " & item.label else: item.label
    writeStr(ctx.tb, boxX + 2, lineY, truncateAt(label, boxW - 4), if isSelected: theme.blue elif item.disabled: theme.overlay0 else: theme.text)
    if item.detail.len > 0:
      let det = truncateAt(item.detail, boxW - 4 - label.runeLen)
      writeStr(ctx.tb, boxX + 2 + label.runeLen + 1, lineY, det, theme.subtext0)
  ctx.tb.setBackgroundColor(theme.surface0)
  if props.showFooter and props.footer.len > 0:
    let ft = truncateAt(props.footer, boxW - 2)
    if ft.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, ft, theme.subtext0)

type GenericOverlay* = ref object of nw.Node
method render*(node: GenericOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let ov = ctx.state.overlay
  let theme = ctx.state.theme
  var boxW = min(50, w - 8)
  var boxH = min(22, h - 4)
  var title = ""
  var queryLine = true
  let ic = currentIcons()
  case ov.kind
  of okYtSearch:
    boxW = min(60, w - 8)
    boxH = min(24, h - 4)
    title = ic.search & " YouTube Search"
    if ov.multiMode: title &= " [MULTISELECT]"
  of okSpotifySearch:
    boxW = min(60, w - 8)
    boxH = min(24, h - 4)
    title = ic.search & " Spotify Search"
  of okYtBatch:
    boxH = min(14, h - 4)
    boxW = min(44, w - 8)
    title = ic.queue & " Add " & $ov.batchItems.len & " items to..."
    queryLine = false
  of okQueuePicker:
    title = ic.queue & " Add to Queue"
  of okPlaylistSearch:
    title = if ov.plMode == 1: ic.playlist & " Add to Playlist" else: ic.playlist & " Remove from Playlist"
  of okThemePicker:
    title = ic.headphone & " Change Theme"
  of okEqPresetPicker:
    title = ic.settings & " EQ Presets"
  of okCommandPalette:
    title = ic.commandPalette & " Commands"
  of okQueueOverlay:
    title = ic.queue & " Current Queue (" & $ctx.state.playbackQueue.len & ")"
    queryLine = false
  of okFuzzyFinder:
    title = ic.search & " Fuzzy Finder"
    queryLine = true
  of okSpotifyUrlInput:
    boxW = min(52, w - 8)
    boxH = 7
    title = ic.disk & " Import Spotify Playlist URL"
    queryLine = true
  of okTrashView:
    title = ic.cross & " Trash"
    boxW = min(60, w - 8)
    boxH = min(24, h - 4)
  of okLyricsSearch:
    title = ic.search & " Search Lyrics (artist title)"
    boxW = min(60, w - 8)
    boxH = min(24, h - 4)
  else: return
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  let ovBg = if ctx.state.transparentBg and ctx.state.overlayOpacity < 1.0:
    blendBg(theme.surface0, ctx.state.overlayOpacity)
  else:
    theme.surface0
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, ovBg)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.mauve, ctx.state.borderStyle)
  writeStr(ctx.tb, boxX + 1, boxY, title, theme.mauve)
  var curY = boxY + 1
  if queryLine:
    let inputText = "> " & ov.query
    let paddedInput = inputText & " ".repeat(max(0, boxW - 2 - inputText.runeLen))
    writeStrBg(ctx.tb, boxX + 1, curY, paddedInput, theme.text, theme.surface1)
    ctx.tb.setBackgroundColor(theme.surface0)
    #--- Autocomplete suggestions ---
    if ov.ytAutocompleteVisible and ov.ytAutocompleteSuggestions.len > 0:
      let acH = min(ov.ytAutocompleteSuggestions.len, 5)
      for i in 0..<acH:
        let acY = curY + 1 + i
        if acY >= boxY + boxH - 1: break
        let isAcSelected = (i == ov.ytAutocompleteCursor)
        let acBg = if isAcSelected: theme.surface2 else: theme.surface0
        if isAcSelected:
          fillBg(ctx.tb, boxX + 1, acY, boxX + boxW - 2, acY, acBg)
        ctx.tb.setBackgroundColor(acBg)
        writeStr(ctx.tb, boxX + 2, acY, truncateAt(ov.ytAutocompleteSuggestions[i], boxW - 4), if isAcSelected: theme.blue else: theme.subtext0)
      curY += acH
    curY.inc
  ctx.tb.setBackgroundColor(theme.surface0)
  writeStr(ctx.tb, boxX + 1, curY, "\u2500".repeat(boxW - 2), theme.surface2)
  curY.inc
  #--- YT Search results ---
  if ov.kind == okYtSearch:
    if ov.ytResults.len == 0 and ov.query.len > 0 and ctx.state.ytSearchLoading:
      ctx.tb.setBackgroundColor(theme.surface0)
      writeStr(ctx.tb, boxX + 2, curY, "Searching...", theme.subtext0)
    elif ov.ytResults.len == 0 and ov.query.len > 0:
      ctx.tb.setBackgroundColor(theme.surface0)
      writeStr(ctx.tb, boxX + 2, curY, "No results found", theme.subtext0)
    let availableLines = max(0, (boxY + boxH - 2) - curY)
    let displayCount = min(ov.ytResults.len, availableLines)
    let scrollOff = max(0, min(ov.scrollOffset, max(0, ov.ytResults.len - displayCount)))
    var videoCount = 0
    for i in 0..<displayCount:
      let ri = scrollOff + i
      if ri >= ov.ytResults.len: break
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let r = ov.ytResults[ri]
      let isSelected = (i == ov.cursor)
      let isMarked = i in ov.selected
      let isPlaylistResult = r.kind == srkPlaylist
      # Show playlist entry after 5 songs
      if isPlaylistResult and videoCount >= 5 and not isSelected:
        discard
      else:
        if isPlaylistResult: videoCount = 0 else: videoCount.inc
      let kindIcon = if isPlaylistResult: ic.playlist else: ic.musicNote
      let prefix = if isMarked: "\u25C9 " else: "  "
      let ttl = if r.title.runeLen > boxW - 22: r.title[0..<min(r.title.len, boxW - 25)] & "..." else: r.title
      let meta = r.channel & "  " & r.duration
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let iconColor = if isPlaylistResult: theme.peach else: (if isSelected: theme.blue else: theme.text)
      writeStr(ctx.tb, boxX + 2, lineY, prefix & kindIcon & " " & ttl, if isSelected: theme.blue else: iconColor)
      writeStr(ctx.tb, boxX + boxW - 2 - meta.runeLen, lineY, meta, theme.subtext0)
    let footerW = boxW - 2
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.multiMode:
      let footerText = if footerW < 34: "Enter:Toggle(" & $ov.selected.len & ")  Esc:Cancel"
                       elif footerW < 44: "Enter:Toggle  Ctrl+S:Done  Esc:Cancel"
                       else: "Enter:Toggle  Ctrl+D:Batch(" & $ov.selected.len & ")  Ctrl+S:Done  Esc:Cancel"
      let ft = truncateAt(footerText, boxW - 2)
      if ft.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, ft, theme.subtext0)
    else:
      let pageInfo = if ctx.state.ytSearchPage > 0: " [Page " & $(ctx.state.ytSearchPage + 1) & "]" else: ""
      let footerText = if footerW < 34: "Enter:Play  Esc:Cancel"
                       elif footerW < 44: "Enter:Play  Ctrl+D:Queue  Esc:Cancel"
                       else: "Enter:Play  Ctrl+D:Queue  Ctrl+S:Multi" & pageInfo & "  Esc:Cancel"
      let ft = truncateAt(footerText, boxW - 2)
      if ft.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, ft, theme.subtext0)
  #--- Spotify Search results ---
  if ov.kind == okSpotifySearch:
    if ctx.state.spSearchResults.len == 0 and ov.query.len > 0 and ctx.state.spSearchLoading:
      ctx.tb.setBackgroundColor(theme.surface0)
      writeStr(ctx.tb, boxX + 2, curY, "Searching...", theme.subtext0)
    elif ctx.state.spSearchResults.len == 0 and ov.query.len > 0:
      ctx.tb.setBackgroundColor(theme.surface0)
      writeStr(ctx.tb, boxX + 2, curY, "No results found", theme.subtext0)
    let availableLines = max(0, (boxY + boxH - 2) - curY)
    let displayCount = min(ctx.state.spSearchResults.len, availableLines)
    for i in 0..<displayCount:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let r = ctx.state.spSearchResults[i]
      let isSelected = (i == ov.cursor)
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let ttl = if r.name.runeLen > boxW - 22: r.name[0..<min(r.name.len, boxW - 25)] & "..." else: r.name
      let meta = r.artist & "  " & r.album
      writeStr(ctx.tb, boxX + 2, lineY, "  " & ttl, if isSelected: theme.blue else: theme.text)
      writeStr(ctx.tb, boxX + boxW - 2 - meta.runeLen, lineY, meta, theme.subtext0)
    ctx.tb.setBackgroundColor(theme.surface0)
    let footerText = "Enter:Search YouTube  Esc:Cancel"
    let ft = truncateAt(footerText, boxW - 2)
    if ft.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, ft, theme.subtext0)
  #--- YT Batch picker ---
  elif ov.kind == okYtBatch:
    let options = [ic.queue & " Queue", ic.playlist & " Playlist", ic.folder & " New Playlist"]
    for i, opt in options:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let isSelected = (i == ov.cursor)
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      if ov.batchShowPls and ov.cursor >= 0 and ov.cursor < ctx.state.libraryPlaylists.len:
        let pl = ctx.state.libraryPlaylists[ov.cursor]
        writeStr(ctx.tb, boxX + 2, lineY, ic.playlist & " " & truncateAt(pl.name & " (" & $pl.trackIds.len & " tracks)", boxW - 6), if isSelected: theme.blue else: theme.text)
      elif not ov.batchShowPls:
        writeStr(ctx.tb, boxX + 2, lineY, opt, if isSelected: theme.blue else: theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.batchShowPls:
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("Enter:Add  Esc:Cancel", boxW - 2), theme.subtext0)
    else:
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("Enter:Select  Esc:Cancel", boxW - 2), theme.subtext0)
  #--- Queue Picker / Playlist Search (track list with checkmarks) ---
  elif ov.kind in {okQueuePicker, okPlaylistSearch}:
    let displayCount = min(ov.results.len, boxH - 5)
    for i in 0..<displayCount:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let idx = ov.results[i]
      let isSelected = (i == ov.cursor)
      let track = if idx >= 0 and idx < ctx.state.libraryTracks.len: ctx.state.libraryTracks[idx] else: Track()
      let isChecked = idx in ov.selected
      let checkMark = if isChecked: "\u25C9 " else: "\u25CB "
      let prefix = checkMark & ic.musicNote & " " & track.displayName()
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      writeStr(ctx.tb, boxX + 2, lineY, truncateAt(prefix, boxW - 4), if isSelected: theme.blue else: theme.text)
      if track.displayArtist().len > 0 and 4 + prefix.runeLen < boxW:
        writeStr(ctx.tb, boxX + 2 + prefix.runeLen + 1, lineY, truncateAt(track.displayArtist(), boxW - prefix.runeLen - 5), theme.subtext0)
    ctx.tb.setBackgroundColor(theme.surface0)
    let footer = if ov.kind == okQueuePicker:
      "Space: toggle  Enter: add to queue  Esc: cancel"
    elif ov.plMode == 1:
      "Enter: toggle  a: add to playlist  Esc: cancel"
    else:
      "Enter: toggle  x: remove from playlist  Esc: cancel"
    let ft = truncateAt(footer, boxW - 2)
    if ft.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, ft, theme.subtext0)
  #--- Theme Picker ---
  elif ov.kind == okThemePicker:
    let displayResults = min(12, ov.strResults.len)
    for i in 0..<displayResults:
      let lineY = curY + i
      if lineY >= boxY + boxH - 2: break
      let seed = ov.strResults[i]
      let isSelected = (i == ov.cursor)
      let ovRowBg = if isSelected: theme.blue else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      if isSelected:
        writeStr(ctx.tb, boxX + 2, lineY, seed, if isDarkMode(ctx.state.config.theme): theme.base else: theme.crust)
      else:
        writeStr(ctx.tb, boxX + 2, lineY, seed, theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.query.len > 0:
      writeStrBg(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("> " & ov.query, boxW - 2), theme.text, theme.surface1)
    else:
      let hint = truncateAt("> Type to search...", boxW - 2)
      if hint.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, hint, theme.subtext0)
  #--- EQ Preset Picker ---
  elif ov.kind == okEqPresetPicker:
    let displayResults = min(12, ov.strResults.len)
    for i in 0..<displayResults:
      let lineY = curY + i
      if lineY >= boxY + boxH - 2: break
      let name = ov.strResults[i]
      let isSelected = (i == ov.cursor)
      let isActive = name == ctx.state.eqPreset
      let ovRowBg = if isSelected: theme.blue else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let prefix = if isActive and not isSelected: "\u25C9 " else: "  "
      let label = prefix & name
      if isSelected:
        writeStr(ctx.tb, boxX + 2, lineY, label, if isDarkMode(ctx.state.config.theme): theme.base else: theme.crust)
      elif isActive:
        writeStr(ctx.tb, boxX + 2, lineY, label, theme.green)
      else:
        writeStr(ctx.tb, boxX + 2, lineY, label, theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.query.len > 0:
      writeStrBg(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("> " & ov.query, boxW - 2), theme.text, theme.surface1)
    else:
      let hint = truncateAt("> Type to filter presets...", boxW - 2)
      if hint.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, hint, theme.subtext0)
  #--- Trash View ---
  elif ov.kind == okTrashView:
    let items = ctx.state.trashItems
    let displayCount = min(items.len, boxH - 5)
    let scrollOff = max(0, min(ov.scrollOffset, max(0, items.len - displayCount)))
    for i in 0..<displayCount:
      let ri = scrollOff + i
      if ri >= items.len: break
      let lineY = curY + i
      if lineY >= boxY + boxH - 2: break
      let isSelected = (ri == ov.cursor)
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let item = items[ri]
      let name = item.originalPath.splitPath().tail
      let dateStr = item.trashedAt.fromUnix().format("YYYY-MM-dd")
      let label = truncateAt(name & "  (" & dateStr & ")", boxW - 4)
      writeStr(ctx.tb, boxX + 2, lineY, label, if isSelected: theme.blue else: theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    let footer = "Enter: restore  Del: permanent delete  P: purge expired  Esc: cancel"
    let ft = truncateAt(footer, boxW - 2)
    if ft.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, ft, theme.subtext0)
  #--- Lyrics Search ---
  elif ov.kind == okLyricsSearch:
    let availableLines = max(0, (boxY + boxH - 2) - curY)
    let displayCount = min(ov.lyricsSearchResults.len, availableLines)
    for i in 0..<displayCount:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let r = ov.lyricsSearchResults[i]
      let isSelected = (i == ov.cursor)
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let label = truncateAt(r.title & " \u2014 " & r.artist, boxW - 4)
      writeStr(ctx.tb, boxX + 2, lineY, label, if isSelected: theme.blue else: theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.lyricsSearchResults.len == 0 and ov.query.len > 0:
      writeStr(ctx.tb, boxX + 2, curY, "Searching...", theme.subtext0)
    elif ov.lyricsSearchResults.len == 0:
      writeStr(ctx.tb, boxX + 2, curY, "Type artist and title to search", theme.subtext0)
    let lsFooter = truncateAt("\u23CE Enter: fetch lyrics  Esc: close", boxW - 2)
    if lsFooter.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, lsFooter, theme.subtext0)
  #--- Current Queue Overlay ---
  elif ov.kind == okQueueOverlay:
    let queue = ctx.state.playbackQueue
    let displayCount = min(queue.len, boxH - 4)
    let scrollOff = max(0, min(ov.scrollOffset, max(0, queue.len - displayCount)))
    for i in 0..<displayCount:
      let qi = scrollOff + i
      if qi >= queue.len: break
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let tIdx = queue[qi]
      let isSelected = (i == ov.cursor)
      let t = if tIdx >= 0 and tIdx < ctx.state.libraryTracks.len: ctx.state.libraryTracks[tIdx] else: Track()
      let isNowPlaying = i == 0 and ctx.state.status in {psPlaying, psPaused}
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let icQueue = currentIcons()
      let bullet = if isNowPlaying: icQueue.play & " " else: "  "
      let nameStr = bullet & truncateAt(t.displayName(), boxW - 6)
      writeStr(ctx.tb, boxX + 2, lineY, nameStr, if isSelected: theme.blue elif isNowPlaying: theme.green else: theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if queue.len == 0:
      writeStr(ctx.tb, boxX + 2, curY, "Queue is empty", theme.subtext0)
    let qFooter = truncateAt("d:Remove  a:Add  Enter:Play  Esc:Close", boxW - 2)
    if qFooter.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, qFooter, theme.subtext0)
  #--- Command Palette ---
  elif ov.kind == okCommandPalette:
    let displayResults = min(20, ov.results.len)
    let scrollOff = max(0, min(ov.scrollOffset, max(0, ov.results.len - displayResults)))
    for i in 0..<displayResults:
      let ri = scrollOff + i
      if ri >= ov.results.len: break
      let idx = ov.results[ri]
      if idx < 0 or idx >= ctx.state.commands.len: continue
      let cmd = ctx.state.commands[idx]
      let isSelected = (ri == ov.cursor)
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let icCmd = commandIcon(cmd.id, ic)
      let iconStr = if icCmd.len > 0: icCmd else: cmd.icon
      writeStr(ctx.tb, boxX + 2, lineY, iconStr & " " & cmd.name, if isSelected: (theme.blue) else: theme.text)
      let keys = cmd.defaultKeys.join(", ")
      writeStr(ctx.tb, boxX + boxW - 2 - keys.runeLen, lineY, keys, theme.subtext0)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.query.len > 0:
      writeStrBg(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("> " & ov.query, boxW - 2), theme.text, theme.surface1)
    else:
      let hint = truncateAt("> Type to search...", boxW - 2)
      if hint.len > 0: writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, hint, theme.subtext0)
  #--- Fuzzy Finder ---
  elif ov.kind == okFuzzyFinder:
    let displayResults = min(20, ov.results.len)
    let scrollOff = max(0, min(ov.scrollOffset, max(0, ov.results.len - displayResults)))
    for i in 0..<displayResults:
      let ri = scrollOff + i
      if ri >= ov.results.len: break
      let idx = ov.results[ri]
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let isSelected = (ri == ov.cursor)
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let labelRaw = if ri < ov.strResults.len and ov.strResults[ri].len > 0: ov.strResults[ri]
                     else: ic.track & " Track #" & $idx
      let maxW = max(1, boxW - 4)
      let label = if labelRaw.runeLen > maxW: labelRaw[0..<min(labelRaw.len, maxW - 2)] & "\u2026"
                  else: labelRaw
      writeStr(ctx.tb, boxX + 2, lineY, ic.musicNote & " " & label, if isSelected: theme.blue else: theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.results.len == 0 and ov.query.len > 0:
      writeStr(ctx.tb, boxX + 2, curY, ic.search & " No matches", theme.subtext0)
    elif ov.results.len == 0:
      writeStr(ctx.tb, boxX + 2, curY, ic.search & " Type to search for tracks...", theme.subtext0)
    writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt(ic.play & " Enter:Play  Esc:Cancel", boxW - 2), theme.subtext0)

proc cmdKey(state: AppState, id: string): string =
  let idx = findCommandIdx(state, id)
  if idx >= 0 and state.commands[idx].keyCodes.len > 0:
    bindingDisplay(state.commands[idx].keyCodes[0])
  else: ""

type LeaderMenuOverlay = ref object of nw.Node
method render*(node: LeaderMenuOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let state = ctx.state
  let theme = state.theme
  let boxW = min(44, w - 8)
  let boxH = min(20, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.peach, ctx.state.borderStyle)
  writeStr(ctx.tb, boxX + 1, boxY, "\u2316 Actions", theme.peach)
  let selCount = state.selectedIndices.len
  let actions = if selCount > 0:
    @[(cmdKey(state, "remove_selected"), "Remove " & $selCount & " items"),
      (cmdKey(state, "add_to_playlist"), "Add to playlist..."),
      (cmdKey(state, "play_selected"), "Play selection"),
      ("Esc", "Deselect all")]
  else:
    case state.tab
    of tabLibrary:
      if state.filterScope == fsPlaylists:
        @[(cmdKey(state, "create_playlist"), "New playlist"),
          (cmdKey(state, "delete_playlist"), "Delete playlist"),
          (cmdKey(state, "rename_playlist"), "Rename playlist"),
          (cmdKey(state, "add_to_playlist"), "Add to playlist"),
          (cmdKey(state, "remove_selected"), "Remove from playlist")]
      else:
        @[(cmdKey(state, "play_selected"), "Play selected"),
          (cmdKey(state, "add_to_playlist"), "Add to playlist"),
          (cmdKey(state, "toggle_select_mode"), "Toggle select mode"),
          (cmdKey(state, "select_all"), "Select all"),
          (cmdKey(state, "enter_filter"), "Filter"),
          (cmdKey(state, "quit_background"), "Quit")]
    of tabNowPlaying:
      @[(cmdKey(state, "toggle_play_pause"), "Play/Pause"),
        (cmdKey(state, "stop_playback"), "Stop"),
        (cmdKey(state, "next_track"), "Next Track"),
        (cmdKey(state, "prev_track"), "Previous Track"),
        (cmdKey(state, "volume_up"), "Volume +5"),
        (cmdKey(state, "volume_down"), "Volume -5"),
        (cmdKey(state, "seek_forward"), "Seek +5s"),
        (cmdKey(state, "seek_backward"), "Seek -5s"),
        (cmdKey(state, "toggle_mute"), "Toggle mute"),
        (cmdKey(state, "quit_background"), "Quit")]
    of tabSettings:
      @[("j/Down", "Scroll down"),
        ("k/Up", "Scroll up"),
        (cmdKey(state, "play_selected"), "Toggle item"),
        (cmdKey(state, "quit_background"), "Quit")]
  for i, (key, name) in actions:
    let lineY = boxY + 2 + i
    if lineY >= boxY + boxH - 1: break
    writeStr(ctx.tb, boxX + 2, lineY, name, theme.text)
    writeStr(ctx.tb, boxX + boxW - 2 - key.runeLen, lineY, key, theme.blue)

type HelpOverlay = ref object of nw.Node
method render*(node: HelpOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 10: return
  let theme = ctx.state.theme
  let boxW = min(52, w - 4)
  let boxH = min(26, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.mauve, ctx.state.borderStyle)
  writeStr(ctx.tb, boxX + 2, boxY + 1, " Help — Keybindings ", theme.mauve)
  var y = boxY + 3
  let col1x = boxX + 3
  let col2x = boxX + 17
  let maxDescW = boxX + boxW - col2x - 2
  for cmd in ctx.state.commands:
    if y >= boxY + boxH - 2: break
    if cmd.keyCodes.len == 0: continue
    let keyStr = bindingDisplay(cmd.keyCodes[0])
    writeStr(ctx.tb, col1x, y, keyStr, theme.blue)
    let desc = cmd.name & " \u2014 " & cmd.description
    let wrapped = wordWrap(desc, maxDescW)
    let display = if wrapped.len > 0: wrapped[0] else: ""
    writeStr(ctx.tb, col2x, y, display, theme.text)
    y.inc
    for wi in 1..<wrapped.len:
      if y >= boxY + boxH - 2: break
      writeStr(ctx.tb, col2x, y, wrapped[wi], theme.text)
      y.inc
  if y < boxY + boxH - 2:
    writeStr(ctx.tb, col1x, y, "Esc", theme.blue)
    writeStr(ctx.tb, col2x, y, "Close overlay", theme.text)

type AboutOverlay = ref object of nw.Node
method render*(node: AboutOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 10: return
  let theme = ctx.state.theme
  let boxW = min(66, w - 4)
  let boxH = min(34, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.mauve, ctx.state.borderStyle)
  writeStr(ctx.tb, boxX + 2, boxY + 1, " About gtm ", theme.mauve)

  var y = boxY + 3
  let labelX = boxX + 4
  let valX = boxX + 16

  let maxValW = boxX + boxW - valX - 2
  template line(label, val: string, col = theme.text) =
    if y < boxY + boxH - 2:
      writeStr(ctx.tb, labelX, y, label, theme.subtext0)
      let valLines = val.split('\n')
      var firstValLine = true
      for vline in valLines:
        let wrapped = wordWrap(vline, maxValW)
        for wi, wline in wrapped:
          if not firstValLine:
            y.inc
            if y >= boxY + boxH - 2: break
          writeStr(ctx.tb, valX, y, wline, col)
          firstValLine = false
      y.inc

  template sep() =
    if y < boxY + boxH - 2:
      writeStr(ctx.tb, boxX + 2, y, "\u2500".repeat(boxW - 4), theme.surface2)
      y.inc

  let relType = when defined(release): "release" else: "debug"
  let verStr = "v" & GTM_VERSION & "-" & SYS_GIT_HASH & ":" & relType
  line("Version", verStr, theme.mauve)
  if GTM_BUILD_TIME.len > 0:
    line("Built", GTM_BUILD_TIME)
  sep()

  # OS info
  let sysOs = SYS_OS()
  if sysOs.len > 0:
    line("OS", sysOs)
  let sysKernel = SYS_KERNEL()
  if sysKernel.len > 0:
    let kernelParts = sysKernel.split(' ')
    let kernelShort = if kernelParts.len >= 2: kernelParts[0] & " " & kernelParts[1] else: sysKernel
    line("Kernel", kernelShort)
  let sysCpu = SYS_CPU()
  let sysCpuCount = SYS_CPU_COUNT()
  if sysCpu.len > 0:
    line("CPU", sysCpu & " (" & sysCpuCount & " cores)")
  sep()

  # Dependencies
  let sysNim = SYS_NIM_VER()
  if sysNim.len > 0:
    line("Nim", sysNim)
  let sysGcc = SYS_GCC_VER()
  if sysGcc.len > 0:
    line("GCC", sysGcc)
  let sysFfmpeg = SYS_FFMPEG()
  if sysFfmpeg.len > 0:
    line("FFmpeg", sysFfmpeg)
  else:
    line("FFmpeg", "not found", theme.peach)
  let sysYtdlp = SYS_YTDLP()
  if sysYtdlp.len > 0:
    line("yt-dlp", sysYtdlp)
  else:
    line("yt-dlp", "not found", theme.peach)
  let sysNode = SYS_NODE()
  let sysBun = SYS_BUN()
  let sysDeno = SYS_DENO()
  var jsRuntimeStr = ""
  if sysNode.len > 0: jsRuntimeStr.add("node " & sysNode)
  if sysBun.len > 0: jsRuntimeStr.add(", bun " & sysBun)
  if sysDeno.len > 0: jsRuntimeStr.add(", deno " & sysDeno)
  if jsRuntimeStr.len == 0: jsRuntimeStr = "none"
  line("JS runtime", jsRuntimeStr)
  sep()

  # Paths
  let gtmPath = getAppFilename()
  let gtmdPath = gtmPath.parentDir() / "gtmd"
  let installPaths = gtmPath & "\n" & gtmdPath
  line("Installation path", installPaths)
  line("Download", ctx.state.ytDownloadDir)
  let storageSize = try:
    let (outp, _) = execCmdEx("du -sh " & dataDir() & " 2>/dev/null | cut -f1")
    let s = outp.strip
    if s.len > 0: s else: "(unknown)"
  except: "(unknown)"
  line("Storage", storageSize)
  sep()

  # Audio & playback
  let audioBackendName = if ctx.state.audioBackendName.len > 0:
    ctx.state.audioBackendName
  else:
    case ctx.state.player.backendType
    of abtMixer: "ALSA (Mixer)"
    of abtFFmpeg: "ALSA (FFmpeg)"
    of abtDaemon: "ALSA (Daemon)"
    else: "none"
  line("Audio", audioBackendName)
  let playbackState = case ctx.state.status
    of psPlaying: "Playing"
    of psPaused: "Paused"
    of psStopped: "Stopped"
  line("State", playbackState,
    if ctx.state.status == psPlaying: theme.green
    elif ctx.state.status == psPaused: theme.peach
    else: theme.subtext0)
  if ctx.state.player.backendType == abtDaemon:
    let svc = ctx.data.service
    let daemonStatus = if ctx.state.reconnecting: "Reconnecting"
                       elif svc.isConnected: "Connected"
                       else: "Disconnected"
    let daemonColor = if ctx.state.reconnecting: theme.peach
                      elif svc.isConnected: theme.green
                      else: theme.red
    line("Daemon", daemonStatus, daemonColor)

  if y < boxY + boxH - 2:
    y = boxY + boxH - 2
    writeStr(ctx.tb, labelX, y, "Press any key to close", theme.subtext0)

type VolumeCueOverlay* = ref object of nw.Node
method render*(node: VolumeCueOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  if w < 16 or ctx.state.volumeCueTimer <= 0: return
  let theme = ctx.state.theme
  let vol = ctx.state.volumeCueVolume
  let barWidth = 10
  let filled = (vol * barWidth + 50) div 100
  let bar = (repeat("█", filled) & repeat("░", barWidth - filled))
  let label = if ctx.state.volumeCueVolume == 0: "MUT" else: "VOL"
  let text = label & " " & bar
  let x = w - text.runeLen - 2
  writeStrBg(ctx.tb, x, 0, text, theme.green, theme.surface0)

proc notificationColors(theme: Theme, kind: NotificationKind): tuple[border, fg, bg: colors.Color] =
  case kind
  of nkInfo:    (theme.blue,    theme.blue,    theme.surface0)
  of nkSuccess: (theme.green,   theme.green,   theme.surface0)
  of nkWarning: (theme.peach,   theme.peach,   theme.surface0)
  of nkError:   (theme.red,     theme.red,     theme.surface0)

proc notificationIcon(kind: NotificationKind): string =
  case kind
  of nkInfo:    " \u2139 "
  of nkSuccess: " \u2713 "
  of nkWarning: " \u26A0 "
  of nkError:   " \u2717 "

type FeedbackCueOverlay* = ref object of nw.Node
method render*(node: FeedbackCueOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 16 or h < 4 or ctx.state.notificationTimer <= 0 or ctx.state.notificationMsg.len == 0: return
  let theme = ctx.state.theme
  let kind = ctx.state.notificationKind
  let (_, fgCol, bgCol) = notificationColors(theme, kind)
  let icon = notificationIcon(kind)
  let title = ctx.state.notificationMsg
  let body = ctx.state.notificationBody
  let maxContentW = w div 3 * 2
  let boxW = min(maxContentW, 52)
  let innerW = max(1, boxW - 4)
  let titleLines = wordWrap(title, innerW)
  var bodyLines: seq[string] = @[]
  if body.len > 0:
    bodyLines = wordWrap(body, innerW)
  let boxH = 2 + titleLines.len + bodyLines.len
  let boxX = w - boxW - 2
  let boxY = 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, bgCol)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, if kind == nkError: theme.red elif kind == nkWarning: theme.peach else: theme.blue, ctx.state.borderStyle)
  var curY = boxY + 1
  for idx, line in titleLines:
    let prefix = if idx == 0: icon else: " ".repeat(icon.runeLen)
    writeStr(ctx.tb, boxX + 1, curY, prefix & line, fgCol)
    curY.inc
  for line in bodyLines:
    writeStr(ctx.tb, boxX + 2, curY, line, theme.subtext0)
    curY.inc

type NowPlayingCueOverlay* = ref object of nw.Node
method render*(node: NowPlayingCueOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 3 or ctx.state.nowPlayingCueTimer <= 0 or ctx.state.nowPlayingCueMsg.len == 0: return
  let theme = ctx.state.theme
  let ic = currentIcons()
  let text = ctx.state.nowPlayingCueMsg
  let boxW = min(w div 3 * 2, 52)
  let innerW = max(1, boxW - 4)
  let lines = wordWrap(text, innerW)
  let boxH = 1 + lines.len
  let boxX = 2
  let boxY = 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.blue, ctx.state.borderStyle)
  var curY = boxY + 1
  for idx, line in lines:
    let prefix = if idx == 0: ic.play else: "   "
    writeStr(ctx.tb, boxX + 1, curY, prefix & line, theme.blue)
    curY.inc

type UpNextCueOverlay* = ref object of nw.Node
method render*(node: UpNextCueOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 3 or ctx.state.upNextTimer <= 0 or ctx.state.upNextMsg.len == 0: return
  let theme = ctx.state.theme
  let ic = currentIcons()
  let text = ctx.state.upNextMsg
  let boxW = min(w div 3 * 2, 52)
  let innerW = max(1, boxW - 4)
  let lines = wordWrap(text, innerW)
  let boxH = 1 + lines.len
  let boxX = 2
  let boxY = 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.peach, ctx.state.borderStyle)
  var curY = boxY + 1
  for idx, line in lines:
    let prefix = if idx == 0: " " & ic.nextTrack & " " else: "     "
    writeStr(ctx.tb, boxX + 1, curY, prefix & line, theme.peach)
    curY.inc

type PlaylistInputOverlay* = ref object of nw.Node
method render*(node: PlaylistInputOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let theme = ctx.state.theme
  let boxW = min(50, w - 8)
  let boxH = 5
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.mauve, ctx.state.borderStyle)
  writeStr(ctx.tb, boxX + 1, boxY, ctx.state.playlistInputPrompt, theme.mauve)
  writeStrBg(ctx.tb, boxX + 1, boxY + 2, truncateAt("> " & ctx.state.playlistInputBuffer, boxW - 2), theme.text, theme.surface1)
  let footerText = truncateAt("Enter: confirm  Esc: cancel", boxW - 2)
  if footerText.len > 0:
    writeStr(ctx.tb, boxX + 1, boxY + 4, footerText, theme.subtext0)

type FooterModulePickerOverlay* = ref object of nw.Node
method render*(node: FooterModulePickerOverlay, ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 30 or h < 8: return
  let st = ctx.state
  let theme = st.theme
  let allModules = [fmPlayStatus, fmVolume, fmBackend, fmDeviceName, fmSelectCount, fmTime, fmDate, fmRepeatShuffle, fmSleepTimer, fmKeyPressed, fmQueueCount, fmEqPreset, fmCurrentPlaylist]
  let boxW = min(50, w - 4)
  let boxH = min(allModules.len + 4, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  drawBorder(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.mauve, ctx.state.borderStyle)
  ctx.tb.setBackgroundColor(theme.surface0)
  writeStr(ctx.tb, boxX + 2, boxY + 1, " Footer Modules ", theme.mauve)

  const moduleNames: array[FooterModule, string] = [
    fmPlayStatus: "Play Status",
    fmVolume: "Volume",
    fmBackend: "Audio Backend",
    fmDeviceName: "Device Name",
    fmSelectCount: "Selection Count",
    fmTime: "Time",
    fmDate: "Date",
    fmRepeatShuffle: "Repeat/Shuffle",
    fmSleepTimer: "Sleep Timer",
    fmElapsedTime: "Elapsed Time",
    fmQueueCount: "Queue Count",
    fmEqPreset: "EQ Preset",
    fmCurrentPlaylist: "Current Playlist",
    fmKeyPressed: "Key Pressed"
  ]

  for i, m in allModules:
    let rowY = boxY + 3 + i
    let isSelected = i == st.overlay.cursor
    let rowBg = if isSelected: theme.surface2 else: theme.surface0
    fillBg(ctx.tb, boxX + 1, rowY, boxX + boxW - 2, rowY, rowBg)
    ctx.tb.setBackgroundColor(rowBg)
    let name = moduleNames[m]
    # Module name
    writeStr(ctx.tb, boxX + 2, rowY, name, if isSelected: theme.text else: theme.subtext0)
    # Side indicator (Off / L / R)
    let inLeft = m in st.footerLeftModules
    let inRight = m in st.footerRightModules
    let statusStr = if inLeft: " [L] " elif inRight: " [R] " else: " Off "
    let statusCol = if inLeft or inRight: theme.green else: theme.overlay0
    writeStr(ctx.tb, boxX + boxW - statusStr.runeLen - 2, rowY, statusStr, statusCol)

  # Footer instructions
  ctx.tb.setBackgroundColor(theme.surface0)
  let ftr = truncateAt(" \u2191/\u2192/L:Left  \u2193/\u2190/R:Right  Space:Off  Esc:Save ", boxW - 2)
  if ftr.len > 0:
    writeStr(ctx.tb, boxX + 2, boxY + boxH - 2, ftr, theme.subtext0)

proc renderApp*(ctx: var nw.Context[State]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < minGridW or h < minGridH: return
  let theme = ctx.state.theme
  var sliceCtx: Context[State]
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  var y = 0
  sliceCtx = nw.slice(ctx, 0, y, w, 1); render(TabBar(), sliceCtx)
  y += 3
  let mainH = h - y - statusBarHeight
  if mainH > 0:
    case ctx.state.tab
    of tabNowPlaying:
      sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(NowPlayingView(), sliceCtx)
    of tabLibrary:
      if w < 55:
        if ctx.state.libraryFocusPanel == lpSidebar:
          sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(LibrarySidebar(), sliceCtx)
        else:
          sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(LibraryContentView(), sliceCtx)
      else:
        let sidebarW = max(24, min(32, w div 4))
        let contentW = w - sidebarW
        sliceCtx = nw.slice(ctx, 0, y, sidebarW, mainH); render(LibrarySidebar(), sliceCtx)
        sliceCtx = nw.slice(ctx, sidebarW, y, contentW, mainH); render(LibraryContentView(), sliceCtx)
    of tabSettings:
      sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(SettingsView(), sliceCtx)
  let statY = h - statusBarHeight
  sliceCtx = nw.slice(ctx, 0, statY, w, 1); render(StatusBarComp(), sliceCtx)
  if ctx.state.helpVisible:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(HelpOverlay(), sliceCtx)
  if ctx.state.aboutVisible:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(AboutOverlay(), sliceCtx)
  if ctx.state.mode == imLeaderMode:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(LeaderMenuOverlay(), sliceCtx)
  if ctx.state.playlistInputActive:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(PlaylistInputOverlay(), sliceCtx)
  if ctx.state.overlay.kind == okFooterModulePicker:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(FooterModulePickerOverlay(), sliceCtx)
  if ctx.state.overlay.kind != okNone:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(GenericOverlay(), sliceCtx)
  renderHoverPreview(ctx)
  if ctx.state.volumeCueTimer > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(VolumeCueOverlay(), sliceCtx)
  if ctx.state.notificationTimer > 0 and ctx.state.notificationMsg.len > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(FeedbackCueOverlay(), sliceCtx)
  if ctx.state.nowPlayingCueTimer > 0 and ctx.state.nowPlayingCueMsg.len > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(NowPlayingCueOverlay(), sliceCtx)
  if ctx.state.upNextTimer > 0 and ctx.state.upNextMsg.len > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(UpNextCueOverlay(), sliceCtx)

proc initApp*(state: var AppState) =
  state.theme = getTheme("mocha")
  state.status = psStopped
  state.volume = DefaultVolume
  state.timePos = 0.0
  state.duration = 0.0
  state.dirtyFlags = {}
  state.helpVisible = false
  state.aboutVisible = false
  state.mode = imNormal
  state.filterText = ""
  state.filterScope = fsAll
  state.libraryFocusPanel = lpContent
  state.librarySidebarSelect = 0
  state.settingsCategory = scAudio
  state.settingsFocusPanel = lpSidebar
  state.selectIndex = 0
  state.needsRedraw = true
  state.tab = tabNowPlaying
  state.footerPreset = fpnCompact
  state.selectMode = false
  state.selectedIndices = initHashSet[int]()
  state.selectionAnchor = 0
  state.overlay.clear()
  state.hasKittyGraphics = false
  state.coverCache = initTable[string, tuple[data: seq[byte], mime: string]]()
  state.coverImageId = -1
  state.coverPendingPath = ""
  state.coverFetching = false
  state.currentLyrics = LrcData(lines: @[])
  state.lyricsLineIdx = -1
  state.lyricsVisible = true
  state.daemonStateVersion = 0
  state.daemonConnected = false
  state.daemonPid = 0
  state.audioAvailable = false
  state.volumeCueTimer = 0
  state.volumeCueVolume = DefaultVolume
  state.prevVolume = DefaultVolume
  state.shuffleEnabled = false
  state.shuffleOrder = @[]
  state.shuffleIndex = 0
  state.repeatMode = 0
  state.sleepTimerRemaining = 0
  state.playlistContentsIdx = -1
  state.playlistInputActive = false
  state.playlistInputPrompt = ""
  state.playlistInputBuffer = ""
  state.addingToPlaylistId = -1
  state.addingToPlaylistName = ""
  state.playbackQueue = @[]
  state.queueCursor = 0
  state.queuePendingConfirm = 0
  state.ytDebounceAt = 0
  state.ytDownloadQueue = @[]
  state.ytDownloadTasks = @[]
  state.ytDownloaded = initTable[string, string]()
  state.downloadsTab = dtDownloading
  state.downloadProgress = initTable[string, int]()
  state.ytMaxConcurrentDownloads = 4
  state.ytBatchDownloadMode = false
  state.ytJsRuntime = JsRuntimes[0]
  state.ytDownloadDir = dataDir() & "/audio"
  # Count existing downloaded files
  state.downloadCount = 0
  try:
    if dirExists(state.ytDownloadDir):
      for kind, p in walkDir(state.ytDownloadDir):
        if kind == pcFile:
          let ext = p.splitFile().ext.toLowerAscii()
          if ext in [".mp3", ".flac", ".ogg", ".m4a", ".wav", ".opus", ".aac", ".wma", ".alac", ".aiff", ".ape"]:
            state.downloadCount.inc
  except: discard
  state.footerModules = {fmPlayStatus, fmVolume, fmBackend, fmDeviceName, fmSelectCount, fmTime, fmDate, fmRepeatShuffle, fmSleepTimer}
  state.rawKeybindingsJson = nil
  state.ytJsRuntime = JsRuntimes[0]
  state.ytSearchHistory = @[]
  state.ytSearchHistoryLower = @[]
  state.ytSearchCache = newTable[string, seq[YtSearchResult]]()
  state.ytSearchCacheKeys = @[]
  state.ytSearchPage = 0
  state.ytSearchPageSize = 10
  state.ytSearchLoading = false
  state.ytProgressCurrent = 0
  state.ytProgressTotal = 0
  state.crossfadeDuration = 6
  state.crossfadeCurve = cctAsymmetric
  state.spinnerFrame = 0
  state.reconnecting = false
  state.reconnectAttempts = 0
  state.crossfading = false
  state.upNextScrollOffset = 0
  state.feedbackMsg = ""
  state.feedbackTimer = 0
  state.notificationBody = ""
  state.notificationKind = nkInfo
  state.deviceName = ""
  state.commands = @[]
  state.cmdRegistry = initTable[string, int]()
  state.keybindings = initTable[string, string]()
  state.keyDispatch = initTable[iw.Key, seq[int]]()
  state.multiKeyDispatch = initTable[seq[iw.Key], int]()
  state.pendingSeq = @[]
  state.pendingSeqTimer = 0
  state.configPath = configDir() & "/config.json"
  state.dataDir = dataDir()
  state.eqPreset = "Flat"
  state.eqPresetList = @[]
  state.eqPresetSelect = 0
  state.favouriteIds = initHashSet[int64]()
  state.ytSearchActive = false
  state.ytStreamResolving = false
  state.ytDownloadActive = false
  state.currentPlayingTitle = ""
  state.currentPlayingChannel = ""
  state.cursorVisible = false
  state.showItemCounts = true
  state.volumeSafetyThreshold = 80
  state.volumeSafetyConfirmed = false
  state.libraryLastVersion = 0
  state.borderStyle = bsRounded
  state.progressStyle = 0
  state.lastHoverSelectIdx = -1

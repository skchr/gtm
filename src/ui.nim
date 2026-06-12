import illwave as iw
import nimwave as nw
from unicode import runeLen, toRunes, Rune
import colors, sequtils, math, strutils, tables, sets, os, times, posix, osproc, options
import state, theme, audio, visualizer, library, icons, commands, albumart

type State* = AppState
include nimwave/prelude

var gTermCellW*: int = 8
var gTermCellH*: int = 16

proc initHighlightGroups*(theme: Theme): HighlightGroups =
  result.Normal = HighlightAttr(fg: some(theme.text), bg: some(theme.base))
  result.TabBar = HighlightAttr(fg: some(theme.subtext0), bg: some(theme.mantle))
  result.TabBarActive = HighlightAttr(fg: some(theme.mauve), bg: some(theme.surface2))
  result.TabBarInactive = HighlightAttr(fg: some(theme.subtext0), bg: some(theme.mantle))
  result.NowPlayingTitle = HighlightAttr(fg: some(theme.text))
  result.NowPlayingArtist = HighlightAttr(fg: some(theme.subtext0))
  result.NowPlayingProgress = HighlightAttr(fg: some(theme.mauve))
  result.NowPlayingProgressFill = HighlightAttr(fg: some(theme.mauve), bg: some(theme.surface2))
  result.NowPlayingStatus = HighlightAttr(fg: some(theme.green))
  result.NowPlayingUpNext = HighlightAttr(fg: some(theme.text))
  result.NowPlayingUpNextCursor = HighlightAttr(fg: some(theme.yellow), bg: some(theme.surface2))
  result.NowPlayingUpNextHeader = HighlightAttr(fg: some(theme.sky))
  result.LibrarySidebar = HighlightAttr(fg: some(theme.subtext0), bg: some(theme.mantle))
  result.LibrarySidebarActive = HighlightAttr(fg: some(theme.blue))
  result.LibrarySidebarSelected = HighlightAttr(fg: some(theme.text), bg: some(theme.surface2))
  result.LibraryContentHeader = HighlightAttr(fg: some(theme.subtext0), bg: some(theme.mantle))
  result.LibraryContentRow = HighlightAttr(fg: some(theme.text))
  result.LibraryContentRowSelected = HighlightAttr(fg: some(theme.blue), bg: some(theme.surface2))
  result.SettingsSidebar = HighlightAttr(fg: some(theme.subtext0), bg: some(theme.mantle))
  result.SettingsContentRow = HighlightAttr(fg: some(theme.subtext0))
  result.SettingsContentRowSelected = HighlightAttr(fg: some(theme.text), bg: some(theme.surface0))
  result.SettingsSectionHeader = HighlightAttr(fg: some(theme.mauve), bg: some(theme.crust))
  result.StatusBar = HighlightAttr(fg: some(theme.subtext0), bg: some(theme.mantle))
  result.StatusBarHints = HighlightAttr(fg: some(theme.subtext0))
  result.StatusBarModule = HighlightAttr(fg: some(theme.subtext0))
  result.FilterBar = HighlightAttr(fg: some(theme.text), bg: some(theme.surface1))
  result.ProgressBar = HighlightAttr(fg: some(theme.mauve), bg: some(theme.crust))
  result.ProgressBarTime = HighlightAttr(fg: some(theme.sky))
  result.VisualizerBar = HighlightAttr(fg: some(theme.mauve))
  result.OverlayBorder = HighlightAttr(fg: some(theme.mauve))
  result.OverlayTitle = HighlightAttr(fg: some(theme.mauve))
  result.OverlayInput = HighlightAttr(fg: some(theme.text), bg: some(theme.surface1))
  result.OverlayRow = HighlightAttr(fg: some(theme.text))
  result.OverlayRowSelected = HighlightAttr(fg: some(theme.blue), bg: some(theme.surface2))
  result.OverlayFooter = HighlightAttr(fg: some(theme.subtext0))
  result.Scrollbar = HighlightAttr(fg: some(theme.surface2))
  result.ErrorMsg = HighlightAttr(fg: some(theme.red))
  result.WarningMsg = HighlightAttr(fg: some(theme.peach))
  result.InfoMsg = HighlightAttr(fg: some(theme.blue))
  result.SuccessMsg = HighlightAttr(fg: some(theme.green))
  result.VolumeCue = HighlightAttr(fg: some(theme.green), bg: some(theme.surface0))
  result.FeedbackCue = HighlightAttr(fg: some(theme.blue), bg: some(theme.surface0))
  result.NowPlayingCue = HighlightAttr(fg: some(theme.blue), bg: some(theme.surface0))
  result.UpNextCue = HighlightAttr(fg: some(theme.peach), bg: some(theme.surface0))
  result.EqualizerBar = HighlightAttr(fg: some(theme.blue))

template hl*(state: AppState, group: untyped): colors.Color =
  state.highlightGroups.`group`.fg.get(state.theme.text)

template hlBg*(state: AppState, group: untyped): colors.Color =
  state.highlightGroups.`group`.bg.get(state.theme.base)

proc wordWrap*(text: string, maxWidth: int): seq[string] =
  if maxWidth <= 0 or text.len == 0: return @[text]
  result = @[]
  for line in text.splitLines:
    if line.runeLen <= maxWidth:
      result.add(line)
    else:
      var remaining = line
      while remaining.runeLen > maxWidth:
        var breakPos = maxWidth
        for i in countdown(maxWidth, 0):
          if i < remaining.len and remaining[i] == ' ':
            breakPos = i
            break
        if breakPos == 0:
          breakPos = maxWidth
        result.add(remaining[0..<breakPos])
        remaining = remaining[breakPos..^1].strip(leading = true)
      if remaining.len > 0:
        result.add(remaining)

const
  statusBarHeight = 1
  minGridW = 40
  minGridH = 10

  SYS_KERNEL* = staticExec("uname -srmo 2>/dev/null").strip
  SYS_OS* = staticExec("cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"'").strip
  SYS_CPU* = staticExec("grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ *//'").strip
  SYS_CPU_COUNT* = staticExec("grep -c ^processor /proc/cpuinfo 2>/dev/null").strip
  SYS_MEM_TOTAL* = staticExec("grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2/1024/1024}'").strip
  SYS_MEM_AVAIL* = staticExec("grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2/1024/1024}'").strip
  SYS_TERM* = staticExec("echo $TERM 2>/dev/null").strip
  SYS_FFMPEG* = staticExec("ffmpeg -version 2>/dev/null | head -1 | sed 's/.*ffmpeg version //i; s/ .*//'").strip
  SYS_GCC_VER* = staticExec("gcc --version 2>/dev/null | head -1 | sed 's/.* //'").strip
  SYS_NIM_VER* = staticExec("nim --version 2>/dev/null | head -1 | sed 's/.*Version //; s/ .*//'").strip
  SYS_YTDLP* = staticExec("yt-dlp --version 2>/dev/null").strip
  SYS_NODE* = staticExec("node --version 2>/dev/null").strip
  SYS_BUN* = staticExec("bun --version 2>/dev/null").strip
  SYS_DENO* = staticExec("deno --version 2>/dev/null | head -1").strip
  SYS_GIT_HASH* = staticExec("git rev-parse --short=7 HEAD 2>/dev/null").strip

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

type TabBar = ref object of nw.Node
method render*(node: TabBar, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 4: return
  let theme = ctx.data.theme
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  let ic = currentIcons()
  let tabIcons = [ic.headphone, ic.library, ic.settings]
  let tabs = [
    "Now Playing", "Library",
    "Settings"
  ]
  let narrow = w < 48
  var x = 1
  let tabKeys = ["1", "2", "3"]
  for i, name in tabs:
    let key = tabKeys[i]
    let tab = AppTab(i)
    let isActive = ctx.data.tab == tab
    let display = "[" & key & "]" & tabIcons[i] & (if narrow: "" else: " " & name)
    let segLen = display.runeLen + 1
    if isActive:
      fillBg(ctx.tb, x, 0, x + segLen, 0, theme.surface2)
      writeStr(ctx.tb, x, 0, display, theme.mauve)
    else:
      ctx.tb.setBackgroundColor(theme.mantle)
      writeStr(ctx.tb, x, 0, display, theme.subtext0)
    x += segLen
  writeStr(ctx.tb, w - 12, 0, " gtm " & GTM_VERSION & " ", theme.overlay2)

proc hsvToRgb(h, s, v: float): (int, int, int) =
  let hh = h * 6.0
  let i = hh.int
  let f = hh - float(i)
  let p = v * (1.0 - s)
  let q = v * (1.0 - s * f)
  let t = v * (1.0 - s * (1.0 - f))
  case i mod 6
  of 0: (int(v * 255), int(t * 255), int(p * 255))
  of 1: (int(q * 255), int(v * 255), int(p * 255))
  of 2: (int(p * 255), int(v * 255), int(t * 255))
  of 3: (int(p * 255), int(q * 255), int(v * 255))
  of 4: (int(t * 255), int(p * 255), int(v * 255))
  of 5: (int(v * 255), int(p * 255), int(q * 255))
  else: (0, 0, 0)

var gCursorX, gCursorY: int = -1

proc showInputCursor*(state: var AppState, w, h: int) =
  let shouldShow = state.overlay.kind in {okYtSearch, okCommandPalette, okThemePicker, okQueuePicker, okPlaylistSearch, okQueueOverlay, okFuzzyFinder} or
    (state.overlay.kind == okNone and (state.playlistInputActive or state.mode == imFilter or state.mode == imLeaderMode))
  if shouldShow == state.cursorVisible: return
  state.cursorVisible = shouldShow
  if shouldShow:
    var cx = 1
    var cy = 1
    case state.overlay.kind
    of okYtSearch, okCommandPalette, okThemePicker, okQueuePicker, okPlaylistSearch, okQueueOverlay:
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
method render*(node: NowPlayingView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  let state = ctx.data
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  let track = if state.ytStreamTitle.len > 0:
    Track(title: state.ytStreamTitle, artist: state.ytStreamChannel, duration: 0.0, path: state.currentPlayingPath)
  elif state.currentPlayingPath.len > 0:
    state.getPlayingTrack()
  elif state.libraryTracks.len > 0 and
    state.selectIndex >= 0 and state.selectIndex < state.libraryTracks.len:
    state.libraryTracks[state.selectIndex]
  else:
    Track()
  if track.path.len == 0 and state.currentPlayingPath.len == 0:
    writeStr(ctx.tb, 1, 1, "No track selected", theme.subtext0)
    if not state.audioAvailable:
      writeStr(ctx.tb, 1, 2, truncateAt("Audio device unavailable — no sound output", w - 2), theme.red)
    writeStr(ctx.tb, 1, 3, truncateAt("Add music with: gtm <file|url>", w - 2), theme.subtext0)
    return
  let artSize = computeArtSize(w, h)
  let hasArt = artSize.charW > 0 and artSize.charH > 0
  var artArtist = track.artist
  var artAlbum = track.album
  if artArtist.len == 0:
    let parsed = parseFilenameMetadata(track.path)
    artArtist = parsed.artist
  let artKey = if state.currentThumbnail.len > 0: state.currentThumbnail else: track.path
  if hasArt and state.artAnsiKey != artKey:
    let art = getArtForTrack(track.path, state.currentThumbnail, artArtist, artAlbum, artSize.charW, artSize.charH)
    ctx.data.artAnsi = art.data
    ctx.data.artAnsiLines = art.lines
    ctx.data.artAnsiKey = artKey
  let showArt = ctx.data.artAnsi.len > 0
  let artPad = if showArt: artSize.charW + 2 else: 1
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
  let statusIcon = if state.status == psPlaying: "\u25B6" elif state.status == psPaused: "\u23F8" else: "\u23F9"
  let statusColor =
    if state.status == psPlaying: theme.green
    elif state.status == psPaused: theme.yellow
    else: theme.surface2
  writeStr(ctx.tb, artPad, line, statusIcon & " " & (
    if state.status == psPlaying: "Playing"
    elif state.status == psPaused: "Paused"
    else: "Stopped"), statusColor)
  line.inc
  # Progress bar
  if state.duration > 0:
    let elapsed = formatTime(state.timePos)
    let remaining = formatTime(max(0.0, state.duration - state.timePos))
    let timeStr = elapsed & " / -" & remaining
    writeStr(ctx.tb, artPad, line, "\u23F1 " & timeStr, theme.mauve)
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
  line.inc
  writeStr(ctx.tb, artPad, line, "\u2500".repeat(min(w - 2, 36)), theme.surface2)
  line.inc
  # Up Next
  if w >= 40:
    writeStr(ctx.tb, artPad, line, "Up Next", theme.sky)
    line.inc
    let maxLines = h - line - 1
    var shown = 0
    for qIdx, tIdx in state.playbackQueue:
      if shown >= maxLines: break
      if tIdx >= 0 and tIdx < state.libraryTracks.len:
        let isNowPlaying = qIdx == 0
        let isCursor = qIdx == state.queueCursor
        let t = state.libraryTracks[tIdx]
        let upBg = if isCursor: theme.surface2 else: theme.base
        fillBg(ctx.tb, 0, line, w - 1, line, upBg)
        let prefix = if isNowPlaying: "\u25B6 " else: "  "
        writeStr(ctx.tb, artPad + 2, line, prefix & truncateAt(t.displayName(), w - artPad - 4), if isCursor: theme.yellow elif isNowPlaying: theme.blue else: theme.text)
        line.inc
        shown.inc
    if state.playbackQueue.len == 0:
      let libStart = state.selectIndex + 1
      for i in libStart..<state.libraryTracks.len:
        if shown >= maxLines: break
        if i >= 0 and i < state.libraryTracks.len:
          let t = state.libraryTracks[i]
          writeStr(ctx.tb, artPad + 2, line, truncateAt(t.displayName(), w - artPad - 3), theme.text)
          line.inc
          shown.inc
    if shown == 0:
      writeStr(ctx.tb, artPad + 2, line, "No tracks queued", theme.subtext0)
      line.inc

type
  SidebarEntry = object
    scope: FilterScope
    label: string
    count: int

type LibrarySidebar = ref object of nw.Node
method render*(node: LibrarySidebar, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 4: return
  let state = ctx.data
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.mantle)
  let isFocused = state.libraryFocusPanel == lpSidebar
  let ic = currentIcons()
  let entries = @[
    SidebarEntry(scope: fsAll, label: ic.track & " All Tracks", count: state.libraryTracks.len),
    SidebarEntry(scope: fsArtists, label: ic.artist & " Artists", count: state.libraryArtists.len),
    SidebarEntry(scope: fsAlbums, label: ic.album & " Albums", count: state.libraryAlbums.len),
    SidebarEntry(scope: fsPlaylists, label: ic.playlist & " Playlists", count: state.libraryPlaylists.len),
    SidebarEntry(scope: fsRecent, label: "Recent", count: state.libraryTracks.len),
    SidebarEntry(scope: fsFavourites, label: "Favourites", count: 0),
    SidebarEntry(scope: fsLastPlayed, label: "Last Played", count: state.libraryTracks.len),
    SidebarEntry(scope: fsMostPlayed, label: "Most Played", count: state.libraryTracks.len),
    SidebarEntry(scope: fsLeastPlayed, label: "Least Played", count: state.libraryTracks.len),
    SidebarEntry(scope: fsDownloads, label: "Downloads", count: state.downloadCount),
  ]
  template treePrefix(idx: int): string =
    if idx < 4: ""
    elif idx == entries.len - 1: "  \u2514\u2500 "
    else: "  \u251C\u2500 "
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
    let actualCount = if entry.scope == fsFavourites: favCount else: entry.count
    let isActive = state.filterScope == entry.scope
    let isSelected = state.librarySidebarSelect == i and isFocused
    let rowBg = if isSelected: theme.surface2 elif isActive: theme.surface0 else: theme.mantle
    fillBg(ctx.tb, 0, line, w - 1, line, rowBg)
    let bullet = if isActive: "\u25C9 " else: "\u25CB "
    let countStr = $actualCount
    let prefix = treePrefix(i)
    let maxLabelW = max(1, w - countStr.runeLen - prefix.runeLen - 3)
    let label = entry.label
    let display = prefix & bullet & (if label.runeLen > maxLabelW: label[0..<max(1, maxLabelW - 2)] & "\u2026" else: label)
    let fg = if isActive: theme.blue elif isSelected: theme.text else: theme.subtext0
    writeStr(ctx.tb, 1, line, display, fg)
    writeStr(ctx.tb, w - countStr.runeLen - 1, line, countStr, theme.overlay0)
    line.inc
    # Show Downloads sub-tabs when scope is active
    if entry.scope == fsDownloads and isActive and line + 2 < h:
      let subTabs = [(dtDownloading, "Downloading"), (dtDownloaded, "Downloaded")]
      for (subTab, subLabel) in subTabs:
        let isSubSelected = state.downloadsTab == subTab
        let subBg = if isSubSelected: theme.surface2 else: theme.base
        fillBg(ctx.tb, 2, line, w - 2, line, subBg)
        ctx.tb.setBackgroundColor(subBg)
        let subBullet = if isSubSelected: "\u25B8 " else: "  "
        writeStr(ctx.tb, 3, line, subBullet & subLabel,
          if isSubSelected: theme.mauve else: theme.subtext0)
        line.inc
  line.inc
  if line < h:
    writeStr(ctx.tb, 1, line, "\u2500".repeat(min(w - 2, 16)), theme.surface2)
  line.inc
  if line < h:
    if state.mode == imFilter:
      writeStrBg(ctx.tb, 1, line, "[/] " & truncateAt(state.filterText, max(0, w - 6)), theme.text, theme.surface1)
    else:
      writeStr(ctx.tb, 1, line, "[/] Filter", theme.overlay0)
  fillBg(ctx.tb, 0, line + 1, w - 1, h - 1, theme.mantle)

type LibraryContentView = ref object of nw.Node
method render*(node: LibraryContentView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 3: return
  let state = ctx.data
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
  # Downloads sub-tab: Downloading view
  if state.filterScope == fsDownloads and state.downloadsTab == dtDownloading:
    fillBg(ctx.tb, 0, line, w - 1, line, theme.mantle)
    writeStr(ctx.tb, 1, line, "Downloading", theme.subtext0)
    writeStr(ctx.tb, w - 10, line, "Status", theme.subtext0)
    line.inc
    var anyItems = false
    # Show active downloads
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
    # Show queued downloads
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
    if state.ytDownloadTasks.len > 0 or state.ytDownloadQueue.len > 0:
      ctx.data.markDirty(ceDownloadProgress)
    return

  if count == 0:
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
        writeStr(ctx.tb, cols.xTitle, line, nameTrunc, if isSelected: theme.blue else: theme.text)
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
]

type SettingsView = ref object of nw.Node
method render*(node: SettingsView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  let state = ctx.data
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  let sidebarW = max(14, min(22, w div 5))
  let contentX = sidebarW
  let contentW = w - sidebarW

  # Left sidebar: categories
  fillBg(ctx.tb, 0, 0, sidebarW - 1, h - 2, theme.mantle)
  let sidebarFocused = state.settingsFocusPanel == lpSidebar
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

  # Right pane: content by category
  let contentFocused = state.settingsFocusPanel == lpContent
  fillBg(ctx.tb, contentX, 0, w - 1, h - 2, theme.base)
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
    settingsRow("Visualizer")
    toggleWidget(state.vizVisible)
    line.inc
    settingsRow("Crossfade Duration")
    sliderWidget(state.crossfadeDuration, 10, 14)
    writeStr(ctx.tb, contentX + contentW - 7, line, "s", theme.subtext0)
    line.inc
    settingsRow("Crossfade Curve")
    let curveNames = ["EqualPower", "Quadratic", "Cubic", "Asymmetric"]
    let curveIdx = state.crossfadeCurve.ord
    let curveLabel = if curveIdx >= 0 and curveIdx < curveNames.len: curveNames[curveIdx] else: "Quadratic"
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
    settingsRow("JS Runtime")
    let rtLabel = if state.ytJsRuntime.len == 0: "node" else: state.ytJsRuntime
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

  # Keybinding legend at bottom of content area
  if line + 4 < h - 1:
    fillBg(ctx.tb, contentX, line, w - 1, line, theme.crust)
    writeStr(ctx.tb, contentX + 1, line, "Keybindings", theme.mauve)
    line.inc
    let contentW2 = w - contentX - 2
    if sidebarFocused:
      writeStr(ctx.tb, contentX + 2, line, truncateAt("j/k:Nav  Tab/Enter:Content  \u2190/\u2192:Switch", contentW2), theme.subtext0)
    else:
      writeStr(ctx.tb, contentX + 2, line, truncateAt("j/k:Scroll  \u2190/\u2192:Adjust  Tab:Category  Enter:Open", contentW2), theme.subtext0)
    line.inc

  # Bottom status line (shared)
  fillBg(ctx.tb, 0, h - 1, w - 1, h - 1, theme.base)
  writeStr(ctx.tb, 1, h - 1, "Tracks: " & $state.libraryTracks.len & "  |  gtm " & GTM_VERSION, theme.subtext0)

type ProgressBarComp = ref object of nw.Node
method render*(node: ProgressBarComp, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 6: return
  let state = ctx.data
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
    let sleepStr = "\u23F0 " & $state.sleepTimerRemaining & "m"
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
method render*(node: StatusBarComp, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 4: return
  let state = ctx.data
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  var hints = ""
  if state.helpVisible:
    hints = " ESC/q: Close help "
  elif state.mode == imFilter:
    hints = " Enter: Apply  ESC: Cancel "
  elif state.overlay.kind == okCommandPalette:
    hints = " Enter: Execute  ESC: Cancel "

  elif state.mode == imLeaderMode:
    hints = " Pick an action or ESC to cancel"
  else:
    case state.tab
    of tabNowPlaying:
      hints = " :Commands j/k:Queue y:YouTube i:Enqueue Enter:Play Space:Toggle Ctrl+P:Actions ?:Help"
    of tabLibrary:
      if state.filterScope == fsPlaylists:
        hints = " :Commands j/k:Navigate Enter:Open/Play l:Open h:Back a:New d:Del r:Rename ?:Help"
      else:
        hints = " :Commands j/k:Navigate Enter:Play /:Filter a:Playlist d:Del r:Rename ?:Help"
    of tabSettings:
      hints = " :Commands j/k:Nav ←/→:Adjust Tab:Panel Enter:Activate ?:Help"
  if state.feedbackTimer > 0 and state.feedbackMsg.len > 0:
    hints = state.feedbackMsg & "  " & hints
  if state.selectMode:
    hints = " [SELECT] " & hints
  writeStr(ctx.tb, 1, 0, truncateAt(hints, w - 2), theme.subtext0)
  if state.mode == imFilter:
    writeStrBg(ctx.tb, 1, 0, truncateAt("Filter: " & state.filterText, w - 2), theme.text, theme.surface0)
  if state.lastKeyTimer > 0 and state.lastKeyDisplay.len > 0:
    writeStrBg(ctx.tb, 1, 0, " [" & state.lastKeyDisplay & "] ", theme.base, theme.surface2)

  # Right-aligned footer modules with colorful module backgrounds
  var rightX = w - 1
  template addMod(text: string, col: colors.Color, bgCol: colors.Color) =
    if rightX > text.runeLen + 2:
      rightX -= text.runeLen + 1
      fillBg(ctx.tb, rightX, 0, rightX + text.runeLen, 0, bgCol)
      ctx.tb.setBackgroundColor(bgCol)
      writeStr(ctx.tb, rightX, 0, text, col)
      ctx.tb.setBackgroundColor(iw.bgNone)

  let ic = currentIcons()

  let activeModules = FooterPresets.getOrDefault(state.footerPreset, state.footerModules)
  # Render modules from right to left (Date/SleepTimer hide first, PlayStatus persists longest)
  if fmDate in activeModules:
    addMod(" " & now().format("ddd dd, MMMM"), theme.text, theme.surface2)
  if fmSleepTimer in activeModules and state.sleepTimerRemaining > 0:
    let s = " \u23F0 " & $(state.sleepTimerRemaining) & "m"
    addMod(s, theme.base, theme.peach)
  if fmTime in activeModules:
    addMod(" " & now().format("hh:mm tt"), theme.text, theme.surface2)
  if fmRepeatShuffle in activeModules:
    if state.repeatMode > 0:
      let rptIc = if state.repeatMode == 2: ic.repeatOne else: ic.repeatAll
      addMod(rptIc, theme.base, if state.repeatMode == 1: theme.green else: theme.blue)
    if state.shuffleEnabled:
      addMod(ic.shuffle, theme.base, theme.peach)
  if fmSelectCount in activeModules and state.selectedIndices.len > 0:
    addMod(" [" & $state.selectedIndices.len & "] ", theme.base, theme.peach)
  if fmNextTrack in activeModules and state.playbackQueue.len > 0:
    let qIdx = state.playbackQueue[0]
    if qIdx >= 0 and qIdx < state.libraryTracks.len:
      let nextTitle = state.libraryTracks[qIdx].title
      if nextTitle.len > 0:
        let maxLen = (rightX - 15) div 2
        let truncd = if nextTitle.runeLen > maxLen: nextTitle.substr(0, maxLen - 2) & ".." else: nextTitle
        addMod(" \u25B6 " & truncd, theme.base, theme.sky)
  if fmBackend in activeModules:
    let backend = case state.player.backendType
      of abtDaemon: "SOCK"
      of abtMixer: "MIX"
      of abtFFmpeg: "FFMPEG"
      of abtProcess: "PROC"
      else: "?"
    addMod(" " & backend, theme.base, theme.mauve)
  if fmVolume in activeModules:
    addMod(" " & $state.volume & "%", theme.base, theme.teal)
  if fmPlayStatus in activeModules:
    let stIcon = case state.status
      of psPlaying: "\u25B6"
      of psPaused: "\u23F8"
      of psStopped: "\u25A0"
    addMod(" " & stIcon, theme.base, if state.status == psPlaying: theme.green else: theme.surface2)

type VisualizerView = ref object of nw.Node
method render*(node: VisualizerView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 2: return
  if not ctx.data.vizVisible or ctx.data.viz == nil: return
  let viz = ctx.data.viz
  if viz.waterfallLen < 1: return
  let bars = max(MIN_VIS_BARS, min(MAX_VIS_BARS, h * 4))
  viz.barCount = bars
  let cols = max(1, w - 2)
  let rows = h
  let bandsPerRow = bars div rows
  if bandsPerRow < 1: return
  let startCol = if viz.waterfallLen >= cols: 0 else: cols - viz.waterfallLen
  const dotRowBits = [0xC0, 0x24, 0x12, 0x09]
  for col in 0..<cols:
    let visCol = col - startCol
    if visCol < 0: continue
    let wfIdx = (viz.waterfallHead - viz.waterfallLen + visCol + WATERFALL_COLS) mod WATERFALL_COLS
    let bx = 1 + col
    for row in 0..<rows:
      let bandStart = row * bandsPerRow
      let bandEnd = min(bars, bandStart + bandsPerRow)
      if bandStart >= bars: break
      let subBandSize = max(1, (bandEnd - bandStart) div 4)
      var maxIntensity = 0.0
      var bits = 0
      for sb in 0..<4:
        let sbStart = bandStart + sb * subBandSize
        let sbEnd = min(bandEnd, sbStart + subBandSize)
        if sbEnd <= sbStart: continue
        var sbSum = 0.0
        for b in sbStart..<sbEnd:
          let val = viz.waterfall[wfIdx][b]
          sbSum += val
          if val > maxIntensity: maxIntensity = val
        let sbAvg = sbSum / float(sbEnd - sbStart)
        if sbAvg > 0.15:
          bits = bits or dotRowBits[sb]
      let t = clamp(maxIntensity, 0.0, 1.0)
      let hue = 240.0 * (1.0 - t)
      let sat = 0.5 + 0.5 * t
      let val2 = 0.2 + 0.8 * t
      let (r, g, b2) = hsvToRgb(hue / 360.0, sat, val2)
      let col = iw.toColor(uint8(r), uint8(g), uint8(b2))
      var cell = ctx.tb[bx, row]
      cell.ch = Rune(0x2800 + bits)
      cell.fgTruecolor = col
      cell.fg = iw.fgNone
      cell.bg = iw.bgNone
      ctx.tb[bx, row] = cell

type GenericOverlay* = ref object of nw.Node
method render*(node: GenericOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let ov = ctx.data.overlay
  let theme = ctx.data.theme
  var boxW = min(50, w - 8)
  var boxH = min(22, h - 4)
  var title = ""
  var queryLine = true
  case ov.kind
  of okYtSearch:
    boxW = min(60, w - 8)
    boxH = min(24, h - 4)
    let subTabStr = if ov.ytSubTab == ystAll: "All" else: "Playlists"
    title = "YouTube Search [" & subTabStr & "]"
    if ov.multiMode: title &= " [MULTISELECT]"
  of okYtBatch:
    boxH = min(14, h - 4)
    boxW = min(44, w - 8)
    title = "Add " & $ov.batchItems.len & " items to..."
    queryLine = false
  of okQueuePicker:
    title = "Add to Queue"
  of okPlaylistSearch:
    title = if ov.plMode == 1: "Add to Playlist" else: "Remove from Playlist"
  of okThemePicker:
    title = "Change Theme"
  of okCommandPalette:
    title = "\u2328 Commands"
  of okQueueOverlay:
    title = "Current Queue"
    queryLine = false
  of okFuzzyFinder:
    title = "Fuzzy Finder"
    queryLine = true
  else: return
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  if ov.kind == okYtSearch or ov.kind == okYtBatch:
    # Opaque full-screen background so text doesn't interfere with rendered content
    fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.crust)
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
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
  #--- Sub-tab bar ---
  if ov.kind == okYtSearch:
    let subTabs = ["All", "Playlists"]
    var tabX = boxX + 1
    for i, st in subTabs:
      let isActive = (i == 0 and ov.ytSubTab == ystAll) or (i == 1 and ov.ytSubTab == ystPlaylists)
      let display = " [" & st & "] "
      let subTabBg = if isActive: theme.surface2 else: theme.surface0
      if isActive:
        fillBg(ctx.tb, tabX, curY, tabX + display.runeLen - 1, curY, subTabBg)
      ctx.tb.setBackgroundColor(subTabBg)
      if isActive:
        writeStr(ctx.tb, tabX, curY, display, theme.mauve)
      else:
        writeStr(ctx.tb, tabX, curY, display, theme.subtext0)
      tabX += display.runeLen
    curY.inc
  #--- YT Search results ---
  if ov.kind == okYtSearch:
    if ov.ytResults.len == 0 and ov.query.len > 0 and ctx.data.ytSearchLoading:
      ctx.tb.setBackgroundColor(theme.surface0)
      writeStr(ctx.tb, boxX + 2, curY, "Searching...", theme.subtext0)
    elif ov.ytResults.len == 0 and ov.query.len > 0:
      ctx.tb.setBackgroundColor(theme.surface0)
      writeStr(ctx.tb, boxX + 2, curY, "No results found", theme.subtext0)
    let availableLines = max(0, (boxY + boxH - 2) - curY)
    let displayCount = min(ov.ytResults.len, availableLines)
    for i in 0..<displayCount:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let r = ov.ytResults[i]
      let isSelected = (i == ov.cursor)
      let isMarked = i in ov.selected
      let kindIcon = if r.kind == srkPlaylist: "\xE2\x96\xB6" else: "\xE2\x80\xA2"
      let prefix = if isMarked: "\u25C9 " else: "  "
      let ttl = if r.title.runeLen > boxW - 22: r.title[0..<min(r.title.len, boxW - 25)] & "..." else: r.title
      let meta = r.channel & "  " & r.duration
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      writeStr(ctx.tb, boxX + 2, lineY, prefix & kindIcon & " " & ttl, if isSelected: theme.blue else: theme.text)
      writeStr(ctx.tb, boxX + boxW - 2 - meta.runeLen, lineY, meta, theme.subtext0)
    let footerW = boxW - 2
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.multiMode:
      let footerText = if footerW < 34: "Enter:Toggle(" & $ov.selected.len & ")  Esc:Cancel"
                       elif footerW < 44: "Tab:SubTab  Enter:Toggle  Ctrl+S:Done  Esc:Cancel"
                       else: "Tab:SubTab  Enter:Toggle  Ctrl+D:Batch(" & $ov.selected.len & ")  Ctrl+S:Done  Esc:Cancel"
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, footerText, theme.subtext0)
    else:
      let pageInfo = if ctx.data.ytSearchPage > 0: " [Page " & $(ctx.data.ytSearchPage + 1) & "]" else: ""
      let footerText = if footerW < 34: "Enter:Play  Esc:Cancel"
                       elif footerW < 44: "\u2191/\u2193:Nav  Enter:Play  Ctrl+D:Queue  Esc:Cancel"
                       else: "Tab:SubTab  \u2191/\u2193:Nav  Enter:Play  Ctrl+D:Queue  Ctrl+S:Multi" & pageInfo & "  Esc:Cancel"
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, footerText, theme.subtext0)
  #--- YT Batch picker ---
  elif ov.kind == okYtBatch:
    let options = ["Queue", "Playlist", "New Playlist"]
    for i, opt in options:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let isSelected = (i == ov.cursor)
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      if ov.batchShowPls and ov.cursor >= 0 and ov.cursor < ctx.data.libraryPlaylists.len:
        let pl = ctx.data.libraryPlaylists[ov.cursor]
        writeStr(ctx.tb, boxX + 2, lineY, truncateAt(pl.name & " (" & $pl.trackIds.len & " tracks)", boxW - 4), if isSelected: theme.blue else: theme.text)
      elif not ov.batchShowPls:
        writeStr(ctx.tb, boxX + 2, lineY, opt, if isSelected: theme.blue else: theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.batchShowPls:
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("j/k:Navigate  Enter:Add  Esc:Cancel", boxW - 2), theme.subtext0)
    else:
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("j/k:Navigate  Enter:Select  Esc:Cancel", boxW - 2), theme.subtext0)
  #--- Queue Picker / Playlist Search (track list with checkmarks) ---
  elif ov.kind in {okQueuePicker, okPlaylistSearch}:
    let displayCount = min(ov.results.len, boxH - 5)
    for i in 0..<displayCount:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let idx = ov.results[i]
      let isSelected = (i == ov.cursor)
      let track = if idx >= 0 and idx < ctx.data.libraryTracks.len: ctx.data.libraryTracks[idx] else: Track()
      let isChecked = idx in ov.selected
      let checkMark = if isChecked: "\u25C9 " else: "\u25CB "
      let prefix = checkMark & track.displayName()
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
    writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, footer, theme.subtext0)
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
        writeStr(ctx.tb, boxX + 2, lineY, seed, if isDarkMode(ctx.data.config.theme): theme.base else: theme.crust)
      else:
        writeStr(ctx.tb, boxX + 2, lineY, seed, theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.query.len > 0:
      writeStrBg(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("> " & ov.query, boxW - 2), theme.text, theme.surface1)
    else:
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, "> Type to search...", theme.subtext0)
  #--- Current Queue Overlay ---
  elif ov.kind == okQueueOverlay:
    let queue = ctx.data.playbackQueue
    let displayCount = min(queue.len, boxH - 4)
    for i in 0..<displayCount:
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let tIdx = queue[i]
      let isSelected = (i == ov.cursor)
      let t = if tIdx >= 0 and tIdx < ctx.data.libraryTracks.len: ctx.data.libraryTracks[tIdx] else: Track()
      let isNowPlaying = i == 0 and ctx.data.status in {psPlaying, psPaused}
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let bullet = if isNowPlaying: "\u25B6 " else: "  "
      let nameStr = bullet & truncateAt(t.displayName(), boxW - 6)
      writeStr(ctx.tb, boxX + 2, lineY, nameStr, if isSelected: theme.blue elif isNowPlaying: theme.green else: theme.text)
      if t.displayArtist().len > 0:
        let artist = truncateAt(t.displayArtist(), boxW - 4)
        writeStr(ctx.tb, boxX + boxW - 2 - artist.runeLen, lineY, artist, theme.subtext0)
    ctx.tb.setBackgroundColor(theme.surface0)
    if queue.len == 0:
      writeStr(ctx.tb, boxX + 2, curY, "Queue is empty", theme.subtext0)
    writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("j/k:Nav  d:Remove  Enter:Play  Esc:Close", boxW - 2), theme.subtext0)
  #--- Command Palette ---
  elif ov.kind == okCommandPalette:
    let displayResults = min(20, ov.results.len)
    for i in 0..<displayResults:
      let idx = ov.results[i]
      if idx < 0 or idx >= ctx.data.commands.len: continue
      let cmd = ctx.data.commands[idx]
      let isSelected = (i == ov.cursor)
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      writeStr(ctx.tb, boxX + 2, lineY, cmd.name, if isSelected: (theme.blue) else: theme.text)
      let keys = cmd.defaultKeys.join(", ")
      writeStr(ctx.tb, boxX + boxW - 2 - keys.runeLen, lineY, keys, theme.subtext0)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.query.len > 0:
      writeStrBg(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("> " & ov.query, boxW - 2), theme.text, theme.surface1)
    else:
      writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, "> Type to search...", theme.subtext0)
  #--- Fuzzy Finder ---
  elif ov.kind == okFuzzyFinder:
    let displayResults = min(20, ov.results.len)
    for i in 0..<displayResults:
      let idx = ov.results[i]
      let lineY = curY + i
      if lineY >= boxY + boxH - 1: break
      let isSelected = (i == ov.cursor)
      let ovRowBg = if isSelected: theme.surface2 else: theme.surface0
      if isSelected:
        fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, ovRowBg)
      ctx.tb.setBackgroundColor(ovRowBg)
      let labelRaw = if i < ov.strResults.len and ov.strResults[i].len > 0: ov.strResults[i]
                     else: "Track #" & $idx
      let maxW = max(1, boxW - 4)
      let label = if labelRaw.runeLen > maxW: labelRaw[0..<min(labelRaw.len, maxW - 2)] & "\u2026"
                  else: labelRaw
      writeStr(ctx.tb, boxX + 2, lineY, label, if isSelected: theme.blue else: theme.text)
    ctx.tb.setBackgroundColor(theme.surface0)
    if ov.results.len == 0 and ov.query.len > 0:
      writeStr(ctx.tb, boxX + 2, curY, "No matches", theme.subtext0)
    elif ov.results.len == 0:
      writeStr(ctx.tb, boxX + 2, curY, "Type to search for tracks...", theme.subtext0)
    writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, truncateAt("\u2191/\u2193:Nav  Enter:Play  Esc:Cancel", boxW - 2), theme.subtext0)

proc cmdKey(state: AppState, id: string): string =
  let idx = findCommandIdx(state, id)
  if idx >= 0 and state.commands[idx].keyCodes.len > 0:
    bindingDisplay(state.commands[idx].keyCodes[0])
  else: ""

type LeaderMenuOverlay = ref object of nw.Node
method render*(node: LeaderMenuOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let state = ctx.data
  let theme = state.theme
  let boxW = min(44, w - 8)
  let boxH = min(20, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  writeStr(ctx.tb, boxX + 1, boxY, "\u2316 Actions", theme.peach)
  writeStr(ctx.tb, boxX + 1, boxY + 1, "\u2500".repeat(boxW - 2), theme.surface2)
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
method render*(node: HelpOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 10: return
  let theme = ctx.data.theme
  let boxW = min(52, w - 4)
  let boxH = min(26, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  iw.drawRect(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1)
  writeStr(ctx.tb, boxX + 2, boxY + 1, " Help — Keybindings ", theme.mauve)
  var y = boxY + 3
  let col1x = boxX + 3
  let col2x = boxX + 17
  let maxDescW = boxX + boxW - col2x - 2
  for cmd in ctx.data.commands:
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
method render*(node: AboutOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 10 or h < 10: return
  let theme = ctx.data.theme
  let boxW = min(66, w - 4)
  let boxH = min(34, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  iw.drawRect(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1)
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
  if SYS_OS.len > 0:
    line("OS", SYS_OS)
  if SYS_KERNEL.len > 0:
    let kernelParts = SYS_KERNEL.split(' ')
    let kernelShort = if kernelParts.len >= 2: kernelParts[0] & " " & kernelParts[1] else: SYS_KERNEL
    line("Kernel", kernelShort)
  if SYS_CPU.len > 0:
    line("CPU", SYS_CPU & " (" & SYS_CPU_COUNT & " cores)")
  sep()

  # Dependencies
  if SYS_NIM_VER.len > 0:
    line("Nim", SYS_NIM_VER)
  if SYS_GCC_VER.len > 0:
    line("GCC", SYS_GCC_VER)
  if SYS_FFMPEG.len > 0:
    line("FFmpeg", SYS_FFMPEG)
  else:
    line("FFmpeg", "not found", theme.peach)
  if SYS_YTDLP.len > 0:
    line("yt-dlp", SYS_YTDLP)
  else:
    line("yt-dlp", "not found", theme.peach)
  var jsRuntimeStr = ""
  if SYS_NODE.len > 0: jsRuntimeStr.add("node " & SYS_NODE)
  if SYS_BUN.len > 0: jsRuntimeStr.add(", bun " & SYS_BUN)
  if SYS_DENO.len > 0: jsRuntimeStr.add(", deno " & SYS_DENO)
  if jsRuntimeStr.len == 0: jsRuntimeStr = "none"
  line("JS runtime", jsRuntimeStr)
  sep()

  # Paths
  let gtmPath = getAppFilename()
  let gtmdPath = gtmPath.parentDir() / "gtmd"
  let installPaths = gtmPath & "\n" & gtmdPath
  line("Installation path", installPaths)
  line("Download", ctx.data.ytDownloadDir)
  let storageSize = try:
    let (outp, _) = execCmdEx("du -sh " & stateDir() & " 2>/dev/null | cut -f1")
    let s = outp.strip
    if s.len > 0: s else: "(unknown)"
  except: "(unknown)"
  line("Storage", storageSize)
  sep()

  # Audio & playback
  let audioBackendName = case ctx.data.player.backendType
    of abtMixer: "MixerBackend"
    of abtFFmpeg: "FfmpegBackend"
    of abtProcess: "ProcessBackend"
    of abtDaemon: "DaemonClient"
    else: "none"
  line("Audio", audioBackendName)
  let playbackState = case ctx.data.status
    of psPlaying: "Playing"
    of psPaused: "Paused"
    of psStopped: "Stopped"
  line("State", playbackState,
    if ctx.data.status == psPlaying: theme.green
    elif ctx.data.status == psPaused: theme.peach
    else: theme.subtext0)

  if y < boxY + boxH - 2:
    y = boxY + boxH - 2
    writeStr(ctx.tb, labelX, y, "Press any key to close", theme.subtext0)

type VolumeCueOverlay* = ref object of nw.Node
method render*(node: VolumeCueOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 16 or ctx.data.volumeCueTimer <= 0: return
  let theme = ctx.data.theme
  let vol = ctx.data.volumeCueVolume
  let barWidth = 10
  let filled = (vol * barWidth + 50) div 100
  let bar = (repeat("█", filled) & repeat("░", barWidth - filled))
  let label = if ctx.data.volumeCueVolume == 0: "MUT" else: "VOL"
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
method render*(node: FeedbackCueOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 16 or ctx.data.notificationTimer <= 0 or ctx.data.notificationMsg.len == 0: return
  let theme = ctx.data.theme
  let kind = ctx.data.notificationKind
  let (_, fgCol, bgCol) = notificationColors(theme, kind)
  let icon = notificationIcon(kind)
  let title = ctx.data.notificationMsg
  let body = ctx.data.notificationBody
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
  iw.drawRect(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1)
  var curY = boxY + 1
  for idx, line in titleLines:
    let prefix = if idx == 0: icon else: " ".repeat(icon.runeLen)
    writeStr(ctx.tb, boxX + 1, curY, prefix & line, fgCol)
    curY.inc
  for line in bodyLines:
    writeStr(ctx.tb, boxX + 2, curY, line, theme.subtext0)
    curY.inc

type NowPlayingCueOverlay* = ref object of nw.Node
method render*(node: NowPlayingCueOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 20 or ctx.data.nowPlayingCueTimer <= 0 or ctx.data.nowPlayingCueMsg.len == 0: return
  let theme = ctx.data.theme
  let text = ctx.data.nowPlayingCueMsg
  let boxW = min(w div 3 * 2, 52)
  let innerW = max(1, boxW - 4)
  let lines = wordWrap(text, innerW)
  let boxH = 1 + lines.len
  let boxX = 2
  let boxY = 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  iw.drawRect(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1)
  var curY = boxY + 1
  for idx, line in lines:
    let prefix = if idx == 0: " \u25B6 " else: "    "
    writeStr(ctx.tb, boxX + 1, curY, prefix & line, theme.blue)
    curY.inc

type UpNextCueOverlay* = ref object of nw.Node
method render*(node: UpNextCueOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 20 or ctx.data.upNextTimer <= 0 or ctx.data.upNextMsg.len == 0: return
  let theme = ctx.data.theme
  let text = ctx.data.upNextMsg
  let boxW = min(w div 3 * 2, 52)
  let innerW = max(1, boxW - 4)
  let lines = wordWrap(text, innerW)
  let boxH = 1 + lines.len
  let boxX = 2
  let boxY = 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  iw.drawRect(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1)
  var curY = boxY + 1
  for idx, line in lines:
    let prefix = if idx == 0: " \u23ED " else: "     "
    writeStr(ctx.tb, boxX + 1, curY, prefix & line, theme.peach)
    curY.inc

type PlaylistInputOverlay* = ref object of nw.Node
method render*(node: PlaylistInputOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let theme = ctx.data.theme
  let boxW = min(50, w - 8)
  let boxH = 5
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  writeStr(ctx.tb, boxX + 1, boxY, ctx.data.playlistInputPrompt, theme.mauve)
  writeStrBg(ctx.tb, boxX + 1, boxY + 2, truncateAt("> " & ctx.data.playlistInputBuffer, boxW - 2), theme.text, theme.surface1)
  writeStr(ctx.tb, boxX + 1, boxY + 4, "Enter: confirm  Esc: cancel", theme.subtext0)

type EqualizerOverlay* = ref object of nw.Node
method render*(node: EqualizerOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 12: return
  let st = ctx.data
  let theme = st.theme
  let boxW = min(80, w - 4)
  let boxH = min(26, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  ctx.tb.setBackgroundColor(theme.surface0)
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  iw.drawRect(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1)
  ctx.tb.setBackgroundColor(theme.surface0)
  writeStr(ctx.tb, boxX + 2, boxY + 1, " Equalizer ", theme.mauve)

  const bandLabels = ["31Hz", "62Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]
  let sliderW = 16
  let sliderGap = 1
  let totalBandW = sliderW + sliderGap
  let maxVisibleBands = max(1, (boxW - 4) div totalBandW)
  let totalBands = 10

  # clamp scroll offset
  var scrollOff = st.eqScrollOffset.clamp(0, max(0, totalBands - maxVisibleBands))
  ctx.data.eqScrollOffset = scrollOff

  let sliderStartY = boxY + 3
  let sliderH = max(3, boxH - 8)

  # Draw scroll indicators
  ctx.tb.setBackgroundColor(theme.surface0)
  if scrollOff > 0:
    writeStr(ctx.tb, boxX + 1, boxY + boxH div 2, "\u25C0", theme.peach)
  if scrollOff + maxVisibleBands < totalBands:
    writeStr(ctx.tb, boxX + boxW - 2, boxY + boxH div 2, "\u25B6", theme.peach)

  for visIdx in 0..<min(maxVisibleBands, totalBands - scrollOff):
    let i = scrollOff + visIdx
    let sx = boxX + 2 + visIdx * totalBandW
    let gain = st.eqBands[i]
    let fillCount = ((gain + 12.0) / 24.0 * sliderH.float).int.clamp(0, sliderH)
    let botFill = if fillCount > sliderH div 2: fillCount - sliderH div 2 else: 0
    let topFill = if fillCount < sliderH div 2: sliderH div 2 - fillCount else: 0

    for row in 0..<sliderH:
      ctx.tb.setBackgroundColor(theme.surface0)
      let rowY = sliderStartY + row
      if row < topFill:
        writeStr(ctx.tb, sx + sliderW div 2, rowY, " ", theme.surface2)
      elif row > sliderH - 1 - botFill:
        writeStr(ctx.tb, sx + sliderW div 2, rowY, " ", theme.surface2)
      elif row == sliderH div 2:
        writeStr(ctx.tb, sx + sliderW div 2, rowY, "\u2502", theme.subtext0)
      else:
        let barCol = if i == st.eqBandSelect: theme.mauve else: theme.blue
        writeStr(ctx.tb, sx + sliderW div 2, rowY, "\u2588", barCol)

    # Center dot marker
    if i == st.eqBandSelect:
      let dotY = sliderStartY + (sliderH div 2) - ((gain / 24.0 * sliderH.float).int)
      ctx.tb.setBackgroundColor(theme.surface0)
      writeStr(ctx.tb, sx + sliderW div 2 - 1, dotY, ">", theme.peach)
      writeStr(ctx.tb, sx + sliderW div 2 + 1, dotY, "<", theme.peach)

    # Frequency label
    ctx.tb.setBackgroundColor(theme.surface0)
    writeStr(ctx.tb, sx, sliderStartY + sliderH + 1, bandLabels[i], theme.subtext0)

  # Gain value indicator
  let selBand = st.eqBandSelect.clamp(0, 9)
  let gainStr = (if st.eqBands[selBand] >= 0: "+" else: "") & formatFloat(st.eqBands[selBand], precision = 1) & "dB"
  ctx.tb.setBackgroundColor(theme.surface0)
  writeStr(ctx.tb, boxX + 2, boxY + boxH - 4, "Band: " & bandLabels[selBand] & "  Gain: " & gainStr, theme.text)

  # Preset name
  if st.eqPreset.len > 0:
    let presetText = "Preset: " & st.eqPreset
    writeStr(ctx.tb, boxX + boxW - presetText.runeLen - 3, boxY + boxH - 4, presetText, theme.green)

  # Footer instructions
  ctx.tb.setBackgroundColor(theme.surface0)
  writeStr(ctx.tb, boxX + 2, boxY + boxH - 2, " \u2190\u2192 gain  j/k band  h/l scroll  P preset  Esc close ", theme.subtext0)

proc renderApp*(ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < minGridW or h < minGridH: return
  let theme = ctx.data.theme
  var sliceCtx: Context[AppState]
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  var y = 0
  sliceCtx = nw.slice(ctx, 0, y, w, 1); render(TabBar(), sliceCtx)
  y += 3
  let mainH = h - y - statusBarHeight
  if mainH > 0:
    case ctx.data.tab
    of tabNowPlaying:
      if w >= 80 and ctx.data.vizVisible:
        let splitW = w * 3 div 4
        sliceCtx = nw.slice(ctx, 0, y, splitW, mainH); render(NowPlayingView(), sliceCtx)
        sliceCtx = nw.slice(ctx, splitW, y, w - splitW, mainH); render(VisualizerView(), sliceCtx)
      else:
        sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(NowPlayingView(), sliceCtx)
    of tabLibrary:
      let sidebarW = max(20, min(28, w div 5))
      let contentW = w - sidebarW
      sliceCtx = nw.slice(ctx, 0, y, sidebarW, mainH); render(LibrarySidebar(), sliceCtx)
      sliceCtx = nw.slice(ctx, sidebarW, y, contentW, mainH); render(LibraryContentView(), sliceCtx)
    of tabSettings:
      sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(SettingsView(), sliceCtx)
  let statY = h - statusBarHeight
  sliceCtx = nw.slice(ctx, 0, statY, w, 1); render(StatusBarComp(), sliceCtx)
  if ctx.data.helpVisible:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(HelpOverlay(), sliceCtx)
  if ctx.data.aboutVisible:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(AboutOverlay(), sliceCtx)
  if ctx.data.eqVisible:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(EqualizerOverlay(), sliceCtx)
  if ctx.data.volumeCueTimer > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(VolumeCueOverlay(), sliceCtx)
  if ctx.data.notificationTimer > 0 and ctx.data.notificationMsg.len > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(FeedbackCueOverlay(), sliceCtx)
  if ctx.data.nowPlayingCueTimer > 0 and ctx.data.nowPlayingCueMsg.len > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(NowPlayingCueOverlay(), sliceCtx)
  if ctx.data.upNextTimer > 0 and ctx.data.upNextMsg.len > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(UpNextCueOverlay(), sliceCtx)
  if ctx.data.mode == imLeaderMode:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(LeaderMenuOverlay(), sliceCtx)
  if ctx.data.playlistInputActive:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(PlaylistInputOverlay(), sliceCtx)
  if ctx.data.overlay.kind != okNone:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(GenericOverlay(), sliceCtx)

proc initApp*(state: var AppState) =
  state.theme = getTheme("mocha")
  state.status = psStopped
  state.volume = 80
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
  state.selectMode = false
  state.selectedIndices = initHashSet[int]()
  state.selectionAnchor = 0
  state.viz = newVisualizer()
  state.vizVisible = true
  state.overlay.clear()
  state.daemonConnected = false
  state.daemonPid = 0
  state.audioAvailable = false
  state.volumeCueTimer = 0
  state.volumeCueVolume = 80
  state.prevVolume = 80
  state.shuffleEnabled = false
  state.shuffleOrder = @[]
  state.shuffleIndex = 0
  state.repeatMode = 0
  state.sleepTimerRemaining = 0
  state.sleepTimerFrames = 0
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
  state.ytSearchProcessActive = false
  state.ytSearchOutputBuf = ""
  state.ytStreamActive = false
  state.ytStreamBuf = ""
  state.ytDownloadQueue = @[]
  state.ytDownloadTasks = @[]
  state.ytDownloaded = initTable[string, string]()
  state.downloadsTab = dtDownloading
  state.downloadProgress = initTable[string, int]()
  state.ytMaxConcurrentDownloads = 4
  state.ytBatchDownloadMode = false
  state.ytJsRuntime = "node"
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
  state.footerModules = {fmPlayStatus, fmVolume, fmBackend, fmNextTrack, fmSelectCount, fmTime, fmDate, fmRepeatShuffle, fmSleepTimer}
  state.rawKeybindingsJson = nil
  state.ytJsRuntime = "node"
  state.ytSearchHistory = @[]
  state.ytSearchHistoryLower = @[]
  state.ytSearchPage = 0
  state.ytSearchSeenUrls = initHashSet[string]()
  state.ytSearchFrameCounter = 0
  state.ytSearchPageSize = 10
  state.ytSearchLoading = false
  state.ytSearchResultsAll = @[]
  state.ytProgressCurrent = 0
  state.ytProgressTotal = 0
  state.crossfadeDuration = 5
  state.crossfadeCurve = cctQuadratic
  state.earlyPreloaded = false
  state.spinnerFrame = 0
  state.reconnecting = false
  state.reconnectAttempts = 0
  state.crossfading = false
  state.masterEnded = false
  state.feedbackMsg = ""
  state.feedbackTimer = 0
  state.notificationBody = ""
  state.notificationKind = nkInfo
  state.commands = @[]
  state.cmdRegistry = initTable[string, int]()
  state.keybindings = initTable[string, string]()
  state.keyDispatch = initTable[iw.Key, seq[int]]()
  state.multiKeyDispatch = initTable[seq[iw.Key], int]()
  state.pendingSeq = @[]
  state.pendingSeqTimer = 0
  state.configPath = configDir() & "/config.json"
  state.dataDir = dataDir()
  state.eqVisible = false
  state.eqBandSelect = 0
  state.eqPreset = "Flat"
  state.eqPresetSelect = 0
  state.eqScrollOffset = 0
  state.favouriteIds = initHashSet[int64]()
  state.ytStreamUrl = ""
  state.ytPlaybackStartTime = 0.0
  state.ytPauseDuration = 0.0
  state.ytPauseStartTime = 0.0
  state.ytDurationSec = 0.0
  state.ytSearchActive = false
  state.ytStreamResolving = false
  state.ytDownloadActive = false
  state.currentPlayingTitle = ""
  state.currentPlayingChannel = ""
  for i in 0..9: state.eqBands[i] = 0.0
  state.cursorVisible = false

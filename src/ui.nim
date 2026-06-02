import illwave as iw
import nimwave as nw
from unicode import runeLen, toRunes, Rune
import colors, sequtils, math, strutils, tables, sets
import state, theme, audio, visualizer, library, icons

type State* = AppState
include nimwave/prelude

const
  statusBarHeight = 1
  minGridW = 40
  minGridH = 10

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

proc writeStr(tb: var iw.TerminalBuffer, x, y: int, text: string, fg: colors.Color) =
  tb.setForegroundColor(fg)
  tb.write(x, y, text)

proc writeStrBg(tb: var iw.TerminalBuffer, x, y: int, text: string, fg, bg: colors.Color) =
  tb.setForegroundColor(fg)
  tb.setBackgroundColor(bg)
  tb.write(x, y, text)
  tb.setBackgroundColor(iw.bgNone)

type TabBar = ref object of nw.Node
method render*(node: TabBar, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 4: return
  let theme = ctx.data.theme
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  let tabs = [
    ("1", "Now Playing"), ("2", "Library"),
    ("3", "Playlists"), ("4", "Settings")
  ]
  var x = 1
  for i, (key, name) in tabs:
    let tab = AppTab(i)
    let isActive = ctx.data.tab == tab
    if isActive:
      fillBg(ctx.tb, x, 0, x + key.runeLen + name.runeLen + 3, 0, theme.blue)
      writeStr(ctx.tb, x, 0, "[" & key & "] " & name, theme.base)
    else:
      writeStr(ctx.tb, x, 0, "[" & key & "]", theme.overlay1)
      let keyEnd = x + key.runeLen + 2
      writeStr(ctx.tb, keyEnd, 0, name, theme.subtext0)
      x = keyEnd
    x += name.runeLen + 2
  writeStr(ctx.tb, w - 12, 0, " gtm " & GTM_VERSION & " ", theme.overlay2)

type NowPlayingView = ref object of nw.Node
method render*(node: NowPlayingView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  let state = ctx.data
  let theme = state.theme
  var line = 0
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  writeStr(ctx.tb, 1, 0, "Now Playing", theme.green)
  line = 2
  let track = if state.libraryTracks.len > 0 and
    state.selectIndex >= 0 and state.selectIndex < state.libraryTracks.len:
    state.libraryTracks[state.selectIndex]
  else:
    Track()
  if track.path.len > 0:
    template wl(label, value: string) =
      if value.len > 0:
        writeStr(ctx.tb, 1, line, label & " ", theme.subtext0)
        writeStr(ctx.tb, 1 + label.runeLen + 1, line, value, theme.text)
        line.inc
    template wlCond(label, value, condition: string) =
      if value.len > 0 and not value.startsWith(condition):
        writeStr(ctx.tb, 1, line, label & " ", theme.subtext0)
        writeStr(ctx.tb, 1 + label.runeLen + 1, line, value, theme.text)
        line.inc
    wl("Track", track.displayName())
    wlCond("Artist", track.displayArtist(), "Unknown")
    wlCond("Album", track.displayAlbum(), "Unknown")
    line.inc
    wl("Status", $(if state.status == psPlaying: "Playing" elif state.status == psPaused: "Paused" else: "Stopped"))
    let npIc = currentIcons()
    let volIcon =
      if state.volume == 0: npIc.volumeMuted
      elif state.volume <= 33: npIc.volumeLow
      elif state.volume <= 66: npIc.volumeMedium
      else: npIc.volumeHigh
    writeStr(ctx.tb, 1, line, "Volume ", theme.subtext0)
    writeStr(ctx.tb, 8, line, volIcon & " " & $state.volume & "%", theme.text)
    line.inc
    if state.duration > 0:
      writeStr(ctx.tb, 1, line, "Time   ", theme.subtext0)
      writeStr(ctx.tb, 8, line, formatTime(state.timePos) & " / -" & formatTime(max(0.0, state.duration - state.timePos)), theme.mauve)
      line.inc
    writeStr(ctx.tb, 1, line, "\u2500".repeat(min(w - 2, 40)), theme.surface2)
    line.inc
    if w >= 60 and state.libraryTracks.len > 0:
      writeStr(ctx.tb, 1, line, "Up Next:", theme.sky)
      line.inc
      let start = max(0, state.selectIndex)
      for i in start..<min(state.libraryTracks.len, start + h - line - 2):
        let t = state.libraryTracks[i]
        writeStr(ctx.tb, 2, line, t.displayName(), theme.text)
        line.inc
  else:
    writeStr(ctx.tb, 1, 2, "No track selected", theme.subtext0)
    if not state.audioAvailable:
      writeStr(ctx.tb, 1, 3, "Audio device unavailable — no sound output", theme.red)
    writeStr(ctx.tb, 1, 3, "Add music with: gtm <file|url>", theme.subtext0)

type LibraryView = ref object of nw.Node
method render*(node: LibraryView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  let state = ctx.data
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  let scopes = ["All", "Artists", "Albums", "Tracks"]
  var x = 1
  for i, s in scopes:
    let scope = FilterScope(i)
    let isActive = state.filterScope == scope
    if isActive:
      fillBg(ctx.tb, x, 0, x + s.runeLen + 1, 0, theme.surface0)
    writeStr(ctx.tb, x + 1, 0, s, if isActive: theme.blue else: theme.subtext0)
    x += s.runeLen + 2
  let items = state.displayItems
  let count = state.filteredCount()
  if count == 0:
    writeStr(ctx.tb, 1, 1, "No items found", theme.subtext0)
    return
  let startIdx = max(0, state.selectIndex - (h - 2) div 2)
  let endIdx = min(count, startIdx + h - 1)
  var line = 1
  for i in startIdx..<endIdx:
    let realIdx = state.filteredIndex(i)
    let isSelected = (i == state.selectIndex)
    let item = if realIdx >= 0 and realIdx < items.len: items[realIdx] else: LibraryItem()
    if isSelected:
      fillBg(ctx.tb, 0, line, w - 1, line, theme.surface2)
    elif realIdx in state.selectedIndices:
      fillBg(ctx.tb, 0, line, w - 1, line, theme.surface0)
    let ic = currentIcons()
    let indicator = if realIdx in state.selectedIndices: "\u25C9 " else: "  "
    let prefix = case item.kind
      of likArtist: ic.artist & " "
      of likAlbum: ic.album & " "
      of likPlaylist: ic.playlist & " "
      of likTrack: ic.music & " "
    let text = indicator & prefix & item.label
    let fg = if isSelected: theme.blue else: theme.text
    writeStr(ctx.tb, 1, line, text, fg)
    if item.sublabel.len > 0:
      writeStr(ctx.tb, 3 + text.runeLen, line, item.sublabel, theme.subtext0)
    line.inc
  if line < h:
    fillBg(ctx.tb, 0, line, w - 1, h - 1, theme.base)

type PlaylistsView = ref object of nw.Node
method render*(node: PlaylistsView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  let state = ctx.data
  let theme = state.theme
  let plIc = currentIcons()
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  if state.playlistContentsIdx >= 0:
    writeStr(ctx.tb, 1, 0, plIc.arrowLeft & " " & plIc.playlist & " Playlist Contents", theme.peach)
    let plIdx = state.playlistContentsIdx
    if plIdx >= 0 and plIdx < state.libraryPlaylists.len:
      let pl = state.libraryPlaylists[plIdx]
      writeStr(ctx.tb, 1, 1, pl.name, theme.blue)
      writeStr(ctx.tb, 3 + pl.name.runeLen, 1, $pl.trackIds.len & " tracks", theme.subtext0)
      if pl.trackIds.len == 0:
        writeStr(ctx.tb, 1, 3, "No tracks in this playlist.", theme.subtext0)
        return
      var line = 3
      let count = state.filteredCount()
      let startIdx = max(0, state.selectIndex - (h - 4) div 2)
      let endIdx = min(count, startIdx + h - 2)
      for i in startIdx..<endIdx:
        let realIdx = state.filteredIndex(i)
        let isSelected = (i == state.selectIndex)
        if isSelected:
          fillBg(ctx.tb, 0, line, w - 1, line, theme.surface2)
        if realIdx >= 0 and realIdx < pl.trackIds.len:
          let tid = pl.trackIds[realIdx]
          var trackLabel = $tid
          for t in state.libraryTracks:
            if t.id == tid:
              trackLabel = t.displayName()
              break
          writeStr(ctx.tb, 2, line, trackLabel, if isSelected: theme.blue else: theme.text)
        line.inc
    return
  writeStr(ctx.tb, 1, 0, "Playlists", theme.peach)
  let pls = state.libraryPlaylists
  if pls.len == 0:
    writeStr(ctx.tb, 1, 1, "No playlists yet. Use 'a' to create one.", theme.subtext0)
    return
  var line = 1
  for i, pl in pls:
    let isSelected = (i == state.selectIndex)
    if isSelected:
      fillBg(ctx.tb, 0, line, w - 1, line, theme.surface2)
    writeStr(ctx.tb, 1, line, plIc.playlist & " " & pl.name, if isSelected: theme.blue else: theme.text)
    writeStr(ctx.tb, 4 + pl.name.runeLen, line, $pl.trackIds.len & " tracks", theme.subtext0)
    line.inc

type SettingsView = ref object of nw.Node
method render*(node: SettingsView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 4 or h < 2: return
  let state = ctx.data
  let theme = state.theme
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  fillBg(ctx.tb, 0, 0, w - 1, 0, theme.mantle)
  writeStr(ctx.tb, 1, 0, "Settings", theme.mauve)
  writeStr(ctx.tb, 1, h - 1, "Tracks: " & $state.libraryTracks.len & "  |  gtm " & GTM_VERSION, theme.subtext0)
  let items = state.displayItems
  let count = state.filteredCount()
  if count == 0:
    writeStr(ctx.tb, 1, 1, "No settings", theme.subtext0)
    return
  let startIdx = max(0, state.selectIndex - (h - 2) div 2)
  let endIdx = min(count, startIdx + h - 1)
  var line = 1
  for i in startIdx..<endIdx:
    let realIdx = state.filteredIndex(i)
    let isSelected = (i == state.selectIndex)
    let item = if realIdx >= 0 and realIdx < items.len: items[realIdx] else: LibraryItem()
    if isSelected:
      fillBg(ctx.tb, 0, line, w - 1, line, theme.surface2)
    let text = item.label
    let fg = if isSelected: theme.blue else: theme.text
    writeStr(ctx.tb, 1, line, text, fg)
    if item.sublabel.len > 0:
      writeStr(ctx.tb, 3 + text.runeLen, line, item.sublabel, theme.subtext0)
    line.inc
  if line < h - 1:
    writeStr(ctx.tb, 1, line, "", theme.base)
  line = max(line + 1, h - 8)
  writeStr(ctx.tb, 1, line, "Keybindings", theme.mauve)
  line.inc
  for cmd in state.commands:
    if line >= h - 2: break
    let keys = cmd.defaultKeys.join(", ")
    writeStr(ctx.tb, 1, line, "  " & keys & "  " & cmd.name, theme.subtext0)
    line.inc

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
    cell.ch = "\u2500".toRunes[0]
    cell.fg = iw.fgNone
    cell.bg = iw.bgNone
    if frac < progress:
      let t = (progress - frac) / max(progress, 0.01)
      cell.fgTruecolor = if t > 0.5: theme.mauve else: theme.blue
    else:
      cell.fgTruecolor = theme.surface2
    ctx.tb[barStart + 1 + i, 0] = cell
  let ic = currentIcons()
  let statusIcon =
    case state.status
    of psPlaying: ic.play
    of psPaused: ic.pause
    of psStopped: ic.stop
  writeStr(ctx.tb, w - 2, 0, statusIcon,
    case state.status
    of psPlaying: theme.green
    of psPaused: theme.yellow
    of psStopped: theme.surface2)

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
  elif state.mode == imCommandPalette:
    hints = " Enter: Execute  ESC: Cancel "
  elif state.mode == imSelectMode:
    hints = " j/k:Extend  v:Exit select  Space: Actions"
  elif state.mode == imLeaderMode:
    hints = " Pick an action or ESC to cancel"
  else:
    hints = " :Commands Space:Menu j/k:Nav Enter:Play ?:Help /:Search"
  if state.selectMode:
    hints = " [SELECT] " & hints
  writeStr(ctx.tb, 1, 0, hints, theme.subtext0)
  if state.mode == imFilter:
    writeStrBg(ctx.tb, 1, 0, "Filter: " & state.filterText, theme.text, theme.surface0)
  let selCount = state.selectedIndices.len
  if selCount > 0:
    writeStr(ctx.tb, max(1, w - 14), 0, " [" & $selCount & " selected] ", theme.peach)

type VisualizerView = ref object of nw.Node
method render*(node: VisualizerView, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 8 or h < 3: return
  if not ctx.data.vizVisible or ctx.data.viz == nil: return
  let theme = ctx.data.theme
  let viz = ctx.data.viz
  let bars = max(MIN_VIS_BARS, min(MAX_VIS_BARS, w - 2))
  viz.barCount = bars
  let barW = max(1, (w - 2) div bars)
  for b in 0..<min(bars, w - 2):
    let val = viz.smoothBins[b]
    let barH = max(0, min(h - 1, int(val * float(h - 1))))
    let bx = 1 + b * barW
    for by in 0..barH:
      let idx = h - 1 - by
      if idx >= 0 and idx < h and bx < w:
        var cell = ctx.tb[bx, idx]
        let t = float(by) / float(max(h - 1, 1))
        if t < 0.33: cell.fgTruecolor = theme.green
        elif t < 0.66: cell.fgTruecolor = theme.yellow
        else: cell.fgTruecolor = theme.red
        cell.ch = "\u2588".toRunes[0]
        cell.fg = iw.fgNone
        cell.bg = iw.bgNone
        ctx.tb[bx, idx] = cell

type CommandPaletteOverlay = ref object of nw.Node
method render*(node: CommandPaletteOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let theme = ctx.data.theme
  let boxW = min(50, w - 8)
  let boxH = min(24, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  writeStr(ctx.tb, boxX + 1, boxY, "\u2328 Commands", theme.mauve)
  writeStr(ctx.tb, boxX + 1, boxY + 1, "\u2500".repeat(boxW - 2), theme.surface2)
  let displayResults = min(20, ctx.data.paletteResults.len)
  for i in 0..<displayResults:
    let idx = ctx.data.paletteResults[i]
    if idx < 0 or idx >= ctx.data.commands.len: continue
    let cmd = ctx.data.commands[idx]
    let isSelected = (i == ctx.data.paletteSelect)
    let lineY = boxY + 2 + i
    if lineY >= boxY + boxH - 1: break
    if isSelected:
      fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, theme.surface2)
    writeStr(ctx.tb, boxX + 2, lineY, cmd.name, if isSelected: theme.blue else: theme.text)
    let keys = cmd.defaultKeys.join(", ")
    writeStr(ctx.tb, boxX + boxW - 2 - keys.runeLen, lineY, keys, theme.subtext0)
  if ctx.data.paletteQuery.len > 0:
    writeStrBg(ctx.tb, boxX + 1, boxY + boxH - 1, "> " & ctx.data.paletteQuery, theme.text, theme.surface1)
  else:
    writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, "> Type to search...", theme.subtext0)

type LeaderMenuOverlay = ref object of nw.Node
method render*(node: LeaderMenuOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let theme = ctx.data.theme
  let boxW = min(40, w - 8)
  let boxH = min(16, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  writeStr(ctx.tb, boxX + 1, boxY, "\u2316 Actions", theme.peach)
  writeStr(ctx.tb, boxX + 1, boxY + 1, "\u2500".repeat(boxW - 2), theme.surface2)
  let selCount = ctx.data.selectedIndices.len
  let actions = if selCount > 0:
    @[("Remove " & $selCount & " items", "ShiftX"),
      ("Add to playlist...", "ShiftA"),
      ("Play selection", "Enter"),
      ("Deselect all", "Escape")]
  else:
    @[("Play/Pause", "Space"), ("Stop", "s"),
      ("Next Track", "n"), ("Prev Track", "p"),
      ("Volume +5", "ShiftJ"), ("Volume -5", "ShiftK"),
      ("Seek +5s", "l"), ("Seek -5s", "h"),
      ("Toggle mute", "m")]
  for i, (name, key) in actions:
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
  let bindings = [
    ("j/k", "Navigate"), ("Enter", "Play selected"),
    (":", "Command palette"), ("Space", "Leader menu"),
    ("Space,Space", "Toggle play/pause"), ("h/l", "Seek -5s / +5s"),
    ("J/K", "Volume -5% / +5%"), ("n/p", "Next / Previous"),
    ("s", "Stop"), ("m", "Mute"),
    ("v", "Toggle select mode"), ("/", "Filter"),
    ("1-4", "Switch tabs"), ("q", "Quit (bg playback)"),
    ("Q", "Quit & stop daemon"), ("?", "Toggle help"),
    ("Esc", "Close overlay")
  ]
  var y = boxY + 3
  let col1x = boxX + 3
  let col2x = boxX + 17
  for (key, desc) in bindings:
    if y >= boxY + boxH - 2: break
    writeStr(ctx.tb, col1x, y, key, theme.blue)
    writeStr(ctx.tb, col2x, y, desc, theme.text)
    y.inc

type VolumeCueOverlay* = ref object of nw.Node
method render*(node: VolumeCueOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  if w < 16 or ctx.data.volumeCueTimer <= 0: return
  let theme = ctx.data.theme
  let vol = ctx.data.volumeCueVolume
  let volIcon =
    if vol == 0: "\U0001F507"
    elif vol <= 33: "\U0001F508"
    elif vol <= 66: "\U0001F509"
    else: "\U0001F50A"
  let volColor =
    if vol == 0: theme.red
    elif vol <= 33: theme.yellow
    elif vol <= 66: theme.text
    else: theme.green
  let barWidth = 10
  let filled = (vol * barWidth + 50) div 100
  let bar = (repeat("█", filled) & repeat("░", barWidth - filled))
  let text = volIcon & " " & $vol & "% [" & bar & "]"
  let x = w - text.runeLen - 2
  let y = ctx.data.volumeCueTimer div 30
  writeStrBg(ctx.tb, x, y, text, volColor, theme.surface0)

type ThemePickerOverlay* = ref object of nw.Node
method render*(node: ThemePickerOverlay, ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < 20 or h < 8: return
  let theme = ctx.data.theme
  let boxW = min(44, w - 8)
  let boxH = min(22, h - 4)
  let boxX = (w - boxW) div 2
  let boxY = (h - boxH) div 2
  fillBg(ctx.tb, boxX, boxY, boxX + boxW - 1, boxY + boxH - 1, theme.surface0)
  writeStr(ctx.tb, boxX + 1, boxY, "Change Theme", theme.mauve)
  writeStr(ctx.tb, boxX + 1, boxY + 1, "\u2500".repeat(boxW - 2), theme.surface2)
  let displayResults = min(12, ctx.data.themePickerResults.len)
  for i in 0..<displayResults:
    let seed = ctx.data.themePickerResults[i]
    let lineY = boxY + 2 + i
    if lineY >= boxY + boxH - 2: break
    let isSelected = (i == ctx.data.themePickerSelect)
    if isSelected:
      fillBg(ctx.tb, boxX + 1, lineY, boxX + boxW - 2, lineY, theme.blue)
      writeStr(ctx.tb, boxX + 2, lineY, seed, theme.base)
    else:
      writeStr(ctx.tb, boxX + 2, lineY, seed, theme.text)
  if ctx.data.themePickerQuery.len > 0:
    writeStrBg(ctx.tb, boxX + 1, boxY + boxH - 1, "> " & ctx.data.themePickerQuery, theme.text, theme.surface1)
  else:
    writeStr(ctx.tb, boxX + 1, boxY + boxH - 1, "> Type to search...", theme.subtext0)

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
  writeStrBg(ctx.tb, boxX + 1, boxY + 2, "> " & ctx.data.playlistInputBuffer, theme.text, theme.surface1)
  writeStr(ctx.tb, boxX + 1, boxY + 4, "Enter: confirm  Esc: cancel", theme.subtext0)

proc renderApp*(ctx: var nw.Context[AppState]) =
  let w = iw.width(ctx.tb)
  let h = iw.height(ctx.tb)
  if w < minGridW or h < minGridH: return
  let theme = ctx.data.theme
  var sliceCtx: Context[AppState]
  fillBg(ctx.tb, 0, 0, w - 1, h - 1, theme.base)
  var y = 0
  sliceCtx = nw.slice(ctx, 0, y, w, 1); render(TabBar(), sliceCtx)
  y += 1
  let progY = y
  sliceCtx = nw.slice(ctx, 0, progY, w, 1); render(ProgressBarComp(), sliceCtx)
  y += 1
  let mainH = h - y - statusBarHeight
  if mainH > 0:
    case ctx.data.tab
    of tabNowPlaying:
      if w >= 120:
        let splitW = w * 2 div 3
        sliceCtx = nw.slice(ctx, 0, y, splitW, mainH); render(NowPlayingView(), sliceCtx)
        sliceCtx = nw.slice(ctx, splitW + 1, y, w - splitW - 1, mainH); render(VisualizerView(), sliceCtx)
      elif w >= 60:
        let splitW = w - 20
        sliceCtx = nw.slice(ctx, 0, y, splitW, mainH); render(NowPlayingView(), sliceCtx)
        sliceCtx = nw.slice(ctx, splitW, y, w - splitW, mainH); render(VisualizerView(), sliceCtx)
      else:
        sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(NowPlayingView(), sliceCtx)
    of tabLibrary:
      sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(LibraryView(), sliceCtx)
    of tabPlaylists:
      sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(PlaylistsView(), sliceCtx)
    of tabSettings:
      sliceCtx = nw.slice(ctx, 0, y, w, mainH); render(SettingsView(), sliceCtx)
  let statY = h - statusBarHeight
  sliceCtx = nw.slice(ctx, 0, statY, w, 1); render(StatusBarComp(), sliceCtx)
  if ctx.data.helpVisible:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(HelpOverlay(), sliceCtx)
  if ctx.data.volumeCueTimer > 0:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(VolumeCueOverlay(), sliceCtx)
  if ctx.data.mode == imCommandPalette:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(CommandPaletteOverlay(), sliceCtx)
  if ctx.data.mode == imLeaderMode:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(LeaderMenuOverlay(), sliceCtx)
  if ctx.data.showThemePicker:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(ThemePickerOverlay(), sliceCtx)
  if ctx.data.playlistInputActive:
    sliceCtx = nw.slice(ctx, 0, 0, w, h); render(PlaylistInputOverlay(), sliceCtx)

proc initApp*(state: var AppState) =
  state.theme = getTheme("mocha")
  state.status = psStopped
  state.volume = 80
  state.timePos = 0.0
  state.duration = 0.0
  state.helpVisible = false
  state.mode = imNormal
  state.filterText = ""
  state.filterScope = fsAll
  state.selectIndex = 0
  state.needsRedraw = true
  state.ggPressed = false
  state.ggTimer = 0
  state.leaderPressed = false
  state.leaderTimer = 0
  state.tab = tabNowPlaying
  state.selectMode = false
  state.selectedIndices = initHashSet[int]()
  state.selectionAnchor = 0
  state.viz = newVisualizer()
  state.vizVisible = true
  state.paletteQuery = ""
  state.paletteResults = @[]
  state.paletteSelect = 0
  state.showThemePicker = false
  state.themePickerQuery = ""
  state.themePickerResults = @[]
  state.themePickerSelect = 0
  state.daemonConnected = false
  state.daemonPid = 0
  state.audioAvailable = false
  state.volumeCueTimer = 0
  state.volumeCueVolume = 80
  state.prevVolume = 80
  state.playlistContentsIdx = -1
  state.playlistContentsTracks = @[]
  state.playlistInputActive = false
  state.playlistInputPrompt = ""
  state.playlistInputBuffer = ""
  state.commands = @[]
  state.cmdRegistry = initTable[string, int]()
  state.keybindings = initTable[string, string]()
  state.configPath = configDir() & "/config.json"
  state.dataDir = dataDir()

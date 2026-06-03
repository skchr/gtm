import os, terminal, strutils, unicode, json, sets, math, sequtils, algorithm, times, random
from illwave as iw import nil
from nimwave as nw import nil
import state, ui, audio, library, theme, commands, daemon_client, daemon, visualizer, cli

proc loadConfig(state: var AppState) =
  let path = state.configPath
  if fileExists(path):
    try:
      let json = parseJson(readFile(path))
      if json.hasKey("theme"):
        state.config.theme = json["theme"].getStr("mocha")
      if json.hasKey("volume"):
        state.volume = json["volume"].getInt(80)
      if json.hasKey("last_tab"):
        state.tab = AppTab(json["last_tab"].getInt(0))
      if json.hasKey("refresh_theme"):
        state.config.refreshTheme = json["refresh_theme"].getBool(false)
      if json.hasKey("viz_visible"):
        state.vizVisible = json["viz_visible"].getBool(true)
      if json.hasKey("idle_timeout"):
        state.config.idleTimeout = json["idle_timeout"].getInt(300)
      if json.hasKey("visualizer"):
        let vizNode = json["visualizer"]
        if vizNode.hasKey("bar_count"):
          state.viz.barCount = vizNode["bar_count"].getInt(32)
      let refreshSeed = state.config.refreshTheme or state.config.theme == "random"
      state.theme = getTheme(state.config.theme, refreshSeed)
    except:
      stderr.writeLine("[gtm] loadConfig error: " & getCurrentExceptionMsg())

proc saveConfig(state: AppState) =
  let dir = state.configPath.parentDir()
  if not dirExists(dir): createDir(dir)
  let json = %{
    "theme": %state.config.theme,
    "volume": %state.volume,
    "last_tab": %(state.tab.ord),
    "refresh_theme": %state.config.refreshTheme,
    "viz_visible": %state.vizVisible,
    "visualizer": %{"bar_count": %state.viz.barCount}
  }
  try:
    writeFile(state.configPath, $json)
  except:
    stderr.writeLine("[gtm] saveConfig error: " & getCurrentExceptionMsg())

proc loadLibrary(state: var AppState) =
  if state.libraryTracks.len > 0: return
  let dir = getEnv("HOME", "") & "/Music"
  if dirExists(dir):
    let paths = scanDirectoryRecursive(dir)
    for path in paths:
      let (_, name, _) = splitFile(path)
      let title = name.replace(".", " ")
      state.libraryTracks.add(Track(
        path: path, title: title, artist: "", album: "",
        duration: 0.0, id: int64(state.libraryTracks.len + 1)
      ))
  state.rebuildDisplayItems()

proc buildPlaylistFromArgs(state: var AppState, args: seq[string]) =
  var paths: seq[string] = @[]
  if args.len > 0: paths = loadFromArgs(args)
  if paths.len == 0:
    let home = getEnv("HOME", "")
    if home.len > 0:
      let musicDir = home & "/Music"
      if dirExists(musicDir): paths = scanDirectory(musicDir)
  if paths.len == 0: paths = scanDirectory(".")
  for p in paths:
    let (_, name, _) = splitFile(p)
    let title = name.replace(".", " ")
    state.libraryTracks.add(Track(
      path: p, title: title, artist: "", album: "",
      duration: 0.0, id: int64(state.libraryTracks.len + 1)
    ))

proc getCurrentTrack(state: AppState): Track =
  let items = state.displayItems
  if items.len > 0 and state.selectIndex >= 0 and state.selectIndex < items.len:
    let item = items[state.selectIndex]
    if item.kind == likTrack and item.trackIdx >= 0 and item.trackIdx < state.libraryTracks.len:
      return state.libraryTracks[item.trackIdx]
  if state.libraryTracks.len > 0:
    return state.libraryTracks[min(state.selectIndex, state.libraryTracks.len - 1)]
  Track()

proc generateShuffleOrder(count: int): seq[int] =
  result = toSeq(0..<count)
  for i in countup(0, count - 2):
    let j = rand(i..<count)
    swap(result[i], result[j])

proc performFilter(state: var AppState) =
  state.rebuildDisplayItems()
  state.filteredIndices = @[]
  if state.filterText.len > 0:
    let lowerFilter = state.filterText.toLowerAscii()
    for i, item in state.displayItems:
      if lowerFilter in item.label.toLowerAscii() or lowerFilter in item.sublabel.toLowerAscii():
        state.filteredIndices.add(i)
    state.selectIndex = if state.filteredIndices.len > 0: 0 else: -1
  else:
    state.selectIndex = min(state.selectIndex, state.displayItems.len - 1)
    if state.selectIndex < 0: state.selectIndex = 0

proc playSelected(state: var AppState) =
  let track = state.getCurrentTrack()
  if track.path.len > 0:
    state.player.loadFile(track.path)
    state.player.play()
    state.status = psPlaying

proc nextTrack(state: var AppState) =
  let items = state.displayItems
  if items.len == 0: return
  if state.shuffleEnabled:
    state.shuffleIndex = (state.shuffleIndex + 1) mod state.shuffleOrder.len
    state.selectIndex = state.shuffleOrder[state.shuffleIndex]
  elif state.repeatMode == 2:
    state.selectIndex = state.selectIndex
  else:
    var next = state.selectIndex + 1
    if next >= items.len:
      if state.repeatMode == 1:
        next = 0
      else:
        state.player.stop()
        state.status = psStopped
        return
    state.selectIndex = next
  state.playSelected()

proc prevTrack(state: var AppState) =
  let items = state.displayItems
  if items.len == 0: return
  if state.shuffleEnabled:
    state.shuffleIndex = (state.shuffleIndex - 1 + state.shuffleOrder.len) mod state.shuffleOrder.len
    state.selectIndex = state.shuffleOrder[state.shuffleIndex]
  else:
    var prev = state.selectIndex - 1
    if prev < 0:
      if state.repeatMode == 1:
        prev = items.len - 1
      else:
        prev = 0
    state.selectIndex = prev
  state.playSelected()

proc showVolumeCue(state: var AppState) =
  state.volumeCueTimer = 90
  state.volumeCueVolume = state.volume

proc adjustVolume(state: var AppState, delta: int) =
  state.volume = max(0, min(100, state.volume + delta))
  state.player.setVolume(state.volume)
  state.showVolumeCue()
  if state.tab == tabSettings: state.rebuildDisplayItems()

proc toggleShuffle(state: var AppState) =
  state.shuffleEnabled = not state.shuffleEnabled
  if state.shuffleEnabled:
    let count = state.displayItems.len
    if count > 0:
      state.shuffleOrder = generateShuffleOrder(count)
      state.shuffleIndex = 0

proc cycleRepeat(state: var AppState) =
  state.repeatMode = (state.repeatMode + 1) mod 3

proc toggleMute(state: var AppState) =
  if state.volume > 0:
    state.prevVolume = state.volume
    state.player.setVolume(0)
    state.volume = 0
  else:
    let restore = if state.prevVolume > 0: state.prevVolume else: 80
    state.player.setVolume(restore)
    state.volume = restore
  state.showVolumeCue()

proc moveSelection(state: var AppState, delta: int) =
  let count = state.filteredCount()
  if count == 0: return
  state.selectIndex = max(0, min(count - 1, state.selectIndex + delta))
  if state.selectMode:
    let realIdx = state.filteredIndex(state.selectIndex)
    if realIdx >= 0:
      state.selectedIndices.incl(realIdx)

proc toggleSelectMode(state: var AppState) =
  state.selectMode = not state.selectMode
  if state.selectMode:
    state.selectedIndices = initHashSet[int]()
    state.selectionAnchor = state.selectIndex

proc selectAll(state: var AppState) =
  let count = state.filteredCount()
  for i in 0..<count:
    let realIdx = state.filteredIndex(i)
    if realIdx >= 0:
      state.selectedIndices.incl(realIdx)

proc removeSelected(state: var AppState) =
  if state.selectedIndices.len == 0: return
  var sortedIdx = toSeq(state.selectedIndices.items)
  sortedIdx.sort(SortOrder.Descending)
  for idx in sortedIdx:
    if idx >= 0 and idx < state.libraryTracks.len:
      state.libraryTracks.delete(idx)
  state.selectedIndices = initHashSet[int]()
  state.rebuildDisplayItems()
  state.selectIndex = min(state.selectIndex, state.displayItems.len - 1)

proc cleanupAndQuit(state: var AppState, stopDaemon: bool) =
  state.saveConfig()
  if state.player of DaemonClient and stopDaemon:
    DaemonClient(state.player).sendQuitDaemon()
  elif not stopDaemon:
    state.player.shutdown()
  if state.viz != nil: state.viz.stopCapture()
  try: removeFile(sockPath()) except: stderr.writeLine("[gtm] removeFile sock: " & getCurrentExceptionMsg())
  try: removeFile(pidPath()) except: stderr.writeLine("[gtm] removeFile pid: " & getCurrentExceptionMsg())
  terminal.showCursor()
  eraseScreen()
  setCursorPos(0, 0)
  quit(0)

proc quitBackground(state: var AppState) =
  state.saveConfig()
  if state.viz != nil: state.viz.stopCapture()
  terminal.showCursor()
  eraseScreen()
  setCursorPos(0, 0)
  quit(0)

proc quitDaemon(state: var AppState) =
  cleanupAndQuit(state, true)

proc toggleVisualizer(state: var AppState) =
  state.vizVisible = not state.vizVisible

proc goToFirst(state: var AppState) =
  state.selectIndex = 0

proc goToLast(state: var AppState) =
  state.selectIndex = max(0, state.filteredCount() - 1)

proc saveCurrentQueue*(state: AppState) =
  if state.libraryTracks.len == 0: return
  let dir = state.dataDir
  if not dirExists(dir): createDir(dir)
  let name = "queue-" & getTime().format("yyyyMMdd-HHmmss") & ".m3u"
  let path = dir / name
  var f = open(path, fmWrite)
  f.writeLine("#EXTM3U")
  for track in state.libraryTracks:
    f.writeLine(track.path)
  f.close()

proc loadPlaylistsFromDaemon(state: var AppState) =
  if state.player of DaemonClient:
    let cli = DaemonClient(state.player)
    let resp = cli.listPlaylists()
    if resp.hasKey("playlists"):
      state.libraryPlaylists = @[]
      for plJson in resp["playlists"]:
        var trackIds: seq[int64] = @[]
        let tracksResp = cli.getPlaylistTracks(plJson["id"].getInt(0).int64)
        if tracksResp.hasKey("track_ids"):
          for tid in tracksResp["track_ids"]:
            trackIds.add(tid.getInt(0).int64)
        state.libraryPlaylists.add(UserPlaylist(
          id: plJson["id"].getInt(0).int64,
          name: plJson["name"].getStr(""),
          trackIds: trackIds
        ))
      state.rebuildDisplayItems()

proc addSelectionToPlaylist(state: var AppState) =
  if state.selectedIndices.len == 0: return
  if state.libraryPlaylists.len == 0:
    state.playlistInputActive = true
    state.playlistInputPrompt = "New Playlist Name:"
    state.playlistInputBuffer = ""
    return
  let idx = state.selectIndex mod state.libraryPlaylists.len
  for selIdx in state.selectedIndices:
    let realIdx = state.filteredIndex(selIdx)
    if realIdx >= 0 and realIdx < state.libraryTracks.len:
      let track = state.libraryTracks[realIdx]
      if track.id notin state.libraryPlaylists[idx].trackIds:
        state.libraryPlaylists[idx].trackIds.add(track.id)
        if state.player of DaemonClient:
          discard DaemonClient(state.player).addToPlaylist(state.libraryPlaylists[idx].id, track.id, state.libraryPlaylists[idx].trackIds.len - 1)
  state.selectedIndices = initHashSet[int]()
  state.rebuildDisplayItems()

proc addTracksToPlaylist(state: var AppState, playlistId: int64) =
  if state.selectedIndices.len == 0:
    state.addingToPlaylistId = -1
    state.addingToPlaylistName = ""
    state.tab = tabPlaylists
    state.rebuildDisplayItems()
    return
  var plIdx = -1
  for i, pl in state.libraryPlaylists:
    if pl.id == playlistId:
      plIdx = i
      break
  if plIdx < 0: return
  var added = 0
  for selIdx in state.selectedIndices:
    let realIdx = state.filteredIndex(selIdx)
    if realIdx >= 0 and realIdx < state.libraryTracks.len:
      let track = state.libraryTracks[realIdx]
      if track.id notin state.libraryPlaylists[plIdx].trackIds:
        state.libraryPlaylists[plIdx].trackIds.add(track.id)
        if state.player of DaemonClient:
          discard DaemonClient(state.player).addToPlaylist(playlistId, track.id, state.libraryPlaylists[plIdx].trackIds.len - 1)
        added += 1
  state.selectedIndices = initHashSet[int]()
  state.addingToPlaylistId = -1
  state.addingToPlaylistName = ""
  state.tab = tabPlaylists
  state.playlistContentsIdx = plIdx
  state.selectIndex = 0
  state.rebuildDisplayItems()

proc handleQuitSignal() {.noconv.} =
  iw.deinit()
  terminal.showCursor()
  eraseScreen()
  setCursorPos(0, 0)
  quit(0)

const themePickerPresets* = @[
  "mocha", "macchiato", "frappe", "latte",
  "gruvbox-dark", "gruvbox-light",
  "dracula", "tokyo-night", "tokyo-night-storm",
  "ayu-dark", "ayu-light", "random"
]

proc applyTheme(state: var AppState, seed: string) =
  let refresh = state.config.refreshTheme or seed == "random"
  state.theme = getTheme(seed, refresh)
  state.config.theme = seed

proc updateThemePickerResults(state: var AppState) =
  state.themePickerResults = @[]
  let q = state.themePickerQuery.toLowerAscii()
  for preset in themePickerPresets:
    if q.len == 0 or preset.contains(q):
      state.themePickerResults.add(preset)

proc dispatchCommand(state: var AppState, cmdId: string) =
  case cmdId
  of "toggle_play_pause": state.player.togglePause()
  of "stop_playback": state.player.stop(); state.status = psStopped
  of "seek_forward": state.player.seek(5.0)
  of "seek_backward": state.player.seek(-5.0)
  of "volume_up": state.adjustVolume(5)
  of "volume_down": state.adjustVolume(-5)
  of "toggle_mute": state.toggleMute()
  of "next_track": state.nextTrack()
  of "prev_track": state.prevTrack()
  of "nav_up": state.moveSelection(-1)
  of "nav_down": state.moveSelection(1)
  of "enter_filter": state.mode = imFilter; state.filterText = ""; state.filteredIndices = @[]
  of "play_selected": state.playSelected()
  of "go_to_first": state.goToFirst()
  of "go_to_last": state.goToLast()
  of "toggle_select_mode": state.toggleSelectMode()
  of "select_all": state.selectAll()
  of "remove_selected": state.removeSelected()
  of "add_to_playlist": state.addSelectionToPlaylist()
  of "tab_now_playing": state.tab = tabNowPlaying; state.rebuildDisplayItems()
  of "tab_library": state.tab = tabLibrary; state.rebuildDisplayItems()
  of "tab_playlists": state.tab = tabPlaylists; state.rebuildDisplayItems()
  of "tab_settings": state.tab = tabSettings; state.rebuildDisplayItems()
  of "show_help": state.helpVisible = true
  of "quit_background": state.quitBackground()
  of "quit_daemon": state.quitDaemon()
  of "toggle_visualizer": state.toggleVisualizer()
  of "command_palette":
    state.mode = imCommandPalette
    state.paletteQuery = ""
    state.paletteResults = @[]
    for i in 0..<state.commands.len: state.paletteResults.add(i)
    state.paletteSelect = 0
  of "change_theme":
    state.showThemePicker = true
    state.themePickerQuery = ""
    state.updateThemePickerResults()
    state.themePickerSelect = 0
  of "save_playlist":
    state.saveCurrentQueue()
  of "create_playlist":
    state.playlistInputActive = true
    state.playlistInputPrompt = "New Playlist Name:"
    state.playlistInputBuffer = ""
  of "delete_playlist":
    let item = state.selectedItem()
    if item.kind == likPlaylist and state.libraryPlaylists.len > 0:
      let idx = state.selectIndex
      if idx >= 0 and idx < state.libraryPlaylists.len:
        state.playlistInputActive = true
        state.playlistInputPrompt = "Delete playlist '" & state.libraryPlaylists[idx].name & "'? (y/N)"
        state.playlistInputBuffer = ""
  of "rename_playlist":
    let item = state.selectedItem()
    if item.kind == likPlaylist and state.libraryPlaylists.len > 0:
      let idx = state.selectIndex
      if idx >= 0 and idx < state.libraryPlaylists.len:
        state.playlistInputActive = true
        state.playlistInputPrompt = "Rename Playlist:"
        state.playlistInputBuffer = state.libraryPlaylists[idx].name
  of "import_m3u":
    state.playlistInputActive = true
    state.playlistInputPrompt = "Import M3U path:"
    state.playlistInputBuffer = ""
  of "export_m3u":
    state.saveCurrentQueue()
  of "rescan_library":
    state.libraryTracks = @[]
    state.loadLibrary()
    state.rebuildDisplayItems()
  of "show_now_playing":
    state.tab = tabNowPlaying
    state.rebuildDisplayItems()
  of "toggle_shuffle":
    state.toggleShuffle()
  of "toggle_repeat":
    state.cycleRepeat()
  of "sleep_timer":
    state.playlistInputActive = true
    state.playlistInputPrompt = "Sleep timer minutes (5, 10, 15, 30, 60, or 0 to cancel):"
    state.playlistInputBuffer = ""
  else: discard

proc handleKey(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  if state.helpVisible:
    if key in {iw.Key.QuestionMark, iw.Key.Escape, iw.Key.Q, iw.Key.ShiftQ}:
      state.helpVisible = false
    return
  if state.showThemePicker:
    case key
    of iw.Key.Escape:
      state.showThemePicker = false
      state.themePickerQuery = ""
    of iw.Key.Enter:
      if state.themePickerResults.len > 0 and state.themePickerSelect >= 0 and
         state.themePickerSelect < state.themePickerResults.len:
        let seed = state.themePickerResults[state.themePickerSelect]
        state.applyTheme(seed)
      state.showThemePicker = false
      state.themePickerQuery = ""
    of iw.Key.Backspace:
      if state.themePickerQuery.len > 0:
        state.themePickerQuery = state.themePickerQuery[0..^2]
        state.updateThemePickerResults()
    of iw.Key.J, iw.Key.Down:
      if state.themePickerSelect < state.themePickerResults.len - 1:
        state.themePickerSelect.inc
        let seed = state.themePickerResults[state.themePickerSelect]
        state.applyTheme(seed)
    of iw.Key.K, iw.Key.Up:
      if state.themePickerSelect > 0:
        state.themePickerSelect.dec
        let seed = state.themePickerResults[state.themePickerSelect]
        state.applyTheme(seed)
    else:
      for ch in chars:
        let code = ch.int
        if code >= 32 and code < 127:
          state.themePickerQuery &= $ch
          state.updateThemePickerResults()
      state.themePickerSelect = 0
    if state.themePickerResults.len > 0:
      state.themePickerSelect = min(state.themePickerSelect, state.themePickerResults.len - 1)
    return
  if state.playlistInputActive:
    case key
    of iw.Key.Escape:
      state.playlistInputActive = false
      state.playlistInputBuffer = ""
      state.playlistInputPrompt = ""
    of iw.Key.Enter:
      if state.playlistInputBuffer.len > 0:
        if state.playlistInputPrompt.contains("Delete playlist"):
          if state.playlistInputBuffer.toLowerAscii() == "y":
            let idx = state.selectIndex
            if idx >= 0 and idx < state.libraryPlaylists.len:
              let plId = state.libraryPlaylists[idx].id
              if state.player of DaemonClient:
                discard DaemonClient(state.player).deletePlaylist(plId)
              state.libraryPlaylists.delete(idx)
              state.rebuildDisplayItems()
        elif state.playlistInputPrompt.contains("Rename"):
          let idx = state.selectIndex
          if idx >= 0 and idx < state.libraryPlaylists.len:
            let plId = state.libraryPlaylists[idx].id
            if state.player of DaemonClient:
              discard DaemonClient(state.player).renamePlaylist(plId, state.playlistInputBuffer)
            state.libraryPlaylists[idx].name = state.playlistInputBuffer
            state.rebuildDisplayItems()
        elif state.playlistInputPrompt.contains("Import M3U"):
          let p = state.playlistInputBuffer
          if fileExists(p):
            let paths = parseM3u(p)
            for path in paths:
              let (_, name, _) = splitFile(path)
              let title = name.replace(".", " ")
              state.libraryTracks.add(Track(
                path: path, title: title, artist: "", album: "",
                duration: 0.0, id: int64(state.libraryTracks.len + 1)
              ))
            state.rebuildDisplayItems()
        elif state.playlistInputPrompt.contains("Sleep timer"):
          let minutes = state.playlistInputBuffer.parseInt()
          if minutes > 0:
            state.sleepTimerRemaining = minutes
          state.sleepTimerFrames = 0
        else:
          if state.player of DaemonClient:
            discard DaemonClient(state.player).createPlaylist(state.playlistInputBuffer)
            state.loadPlaylistsFromDaemon()
            if state.libraryPlaylists.len > 0:
              state.addingToPlaylistId = state.libraryPlaylists[^1].id
              state.addingToPlaylistName = state.libraryPlaylists[^1].name
              state.tab = tabLibrary
              state.selectMode = false
              state.selectedIndices = initHashSet[int]()
              state.rebuildDisplayItems()
      state.playlistInputActive = false
      state.playlistInputBuffer = ""
      state.playlistInputPrompt = ""
    of iw.Key.Backspace:
      if state.playlistInputBuffer.len > 0:
        state.playlistInputBuffer = state.playlistInputBuffer[0..^2]
    else:
      for ch in chars:
        let code = ch.int
        if code >= 32 and code < 127:
          state.playlistInputBuffer &= $ch
    return
  case state.mode
  of imCommandPalette:
    case key
    of iw.Key.Escape:
      state.mode = imNormal
      state.paletteQuery = ""
      state.paletteSearchMode = false
    of iw.Key.Enter:
      state.paletteSearchMode = false
      if state.paletteResults.len > 0 and state.paletteSelect >= 0 and
         state.paletteSelect < state.paletteResults.len:
        let cmdIdx = state.paletteResults[state.paletteSelect]
        if cmdIdx >= 0 and cmdIdx < state.commands.len:
          let cmdId = state.commands[cmdIdx].id
          state.mode = imNormal
          state.paletteQuery = ""
          dispatchCommand(state, cmdId)
          return
      state.mode = imNormal
      state.paletteQuery = ""
    of iw.Key.Slash:
      state.paletteSearchMode = true
      state.paletteQuery = ""
    of iw.Key.J, iw.Key.Down:
      if state.paletteSelect < state.paletteResults.len - 1:
        state.paletteSelect.inc
    of iw.Key.K, iw.Key.Up:
      if state.paletteSelect > 0:
        state.paletteSelect.dec
    of iw.Key.Backspace:
      if state.paletteSearchMode and state.paletteQuery.len > 0:
        state.paletteQuery = state.paletteQuery[0..^2]
    else:
      if state.paletteSearchMode:
        for ch in chars:
          let code = ch.int
          if code >= 32 and code < 127:
            state.paletteQuery &= $ch
    if state.paletteQuery.len > 0:
      state.paletteResults = @[]
      for i, cmd in state.commands:
        if fuzzyMatch(state.paletteQuery, cmd.name) or
           fuzzyMatch(state.paletteQuery, cmd.description):
          state.paletteResults.add(i)
      state.paletteSelect = 0
    elif not state.paletteSearchMode:
      state.paletteResults = @[]
      for i in 0..<state.commands.len:
        state.paletteResults.add(i)
    return
  of imLeaderMode:
    case key
    of iw.Key.Escape:
      state.mode = imNormal
    of iw.Key.Space:
      state.player.togglePause()
      state.mode = imNormal
    of iw.Key.S:
      state.player.stop()
      state.status = psStopped
      state.mode = imNormal
    of iw.Key.N:
      state.nextTrack()
      state.mode = imNormal
    of iw.Key.P:
      state.prevTrack()
      state.mode = imNormal
    of iw.Key.H:
      state.adjustVolume(-5)
      state.mode = imNormal
    of iw.Key.L:
      state.adjustVolume(5)
      state.mode = imNormal
    of iw.Key.Enter:
      if state.selectedIndices.len > 0:
        state.playSelected()
      state.mode = imNormal
    of iw.Key.ShiftX:
      state.removeSelected()
      state.mode = imNormal
    else:
      state.mode = imNormal
    return
  of imSelectMode:
    case key
    of iw.Key.Escape, iw.Key.V:
      state.selectMode = false
      state.selectedIndices = initHashSet[int]()
      state.mode = imNormal
    of iw.Key.J:
      state.moveSelection(1)
    of iw.Key.K:
      state.moveSelection(-1)
    of iw.Key.Space:
      state.mode = imLeaderMode
    else:
      if key >= iw.Key.A and key <= iw.Key.Z:
        discard
    return
  of imFilter:
    case key
    of iw.Key.Escape:
      state.mode = imNormal
      state.filterText = ""
      state.performFilter()
    of iw.Key.Enter:
      state.mode = imNormal
      if state.filteredCount() > 0 and state.selectIndex >= 0:
        state.playSelected()
    of iw.Key.Backspace:
      if state.filterText.len > 0:
        state.filterText = state.filterText[0..^2]
        state.performFilter()
    else:
      for ch in chars:
        let code = ch.int
        if code >= 32 and code < 127:
          state.filterText &= $ch
          state.performFilter()
    return
  of imNormal:
    discard

  case key
  of iw.Key.Colon:
    state.mode = imCommandPalette
    state.paletteQuery = ""
    state.paletteResults = @[]
    for i in 0..<state.commands.len: state.paletteResults.add(i)
    state.paletteSelect = 0
  of iw.Key.Space:
    if state.leaderPressed:
      state.player.togglePause()
      state.leaderPressed = false
    else:
      if state.selectMode:
        state.mode = imLeaderMode
      else:
        state.leaderPressed = true
        state.leaderTimer = 30
  of iw.Key.J: state.moveSelection(1)
  of iw.Key.K: state.moveSelection(-1)
  of iw.Key.Enter:
    if state.tab == tabPlaylists:
      if state.playlistContentsIdx >= 0:
        state.playSelected()
      else:
        let item = state.selectedItem()
        if item.kind == likPlaylist:
          state.playlistContentsIdx = state.selectIndex
          state.selectIndex = 0
          state.rebuildDisplayItems()
    elif state.tab == tabSettings:
      let idx = state.selectedItem().id
      case idx
      of 0:
        state.showThemePicker = true
        state.themePickerQuery = ""
        state.updateThemePickerResults()
        state.themePickerSelect = 0
      of 1:
        state.toggleMute()
        state.rebuildDisplayItems()
      of 2:
        state.config.refreshTheme = not state.config.refreshTheme
        state.rebuildDisplayItems()
      of 3:
        state.toggleVisualizer()
        state.rebuildDisplayItems()
      else: discard
    else:
      state.playSelected()
  of iw.Key.S: state.player.stop(); state.status = psStopped
  of iw.Key.H: state.player.seek(-5.0)
  of iw.Key.L: state.player.seek(5.0)
  of iw.Key.N: state.nextTrack()
  of iw.Key.P: state.prevTrack()
  of iw.Key.ShiftJ: state.adjustVolume(5)
  of iw.Key.ShiftK: state.adjustVolume(-5)
  of iw.Key.Plus, iw.Key.Equals: state.adjustVolume(5)
  of iw.Key.Minus, iw.Key.Underscore: state.adjustVolume(-5)
  of iw.Key.M: state.toggleMute()
  of iw.Key.G:
    if state.addingToPlaylistId >= 0:
      state.addTracksToPlaylist(state.addingToPlaylistId)
    elif state.ggPressed:
      state.goToFirst()
      state.ggPressed = false
    else:
      state.ggPressed = true
      state.ggTimer = 30
  of iw.Key.ShiftG:
    state.goToLast()
    state.ggPressed = false
    state.playSelected()
  of iw.Key.A:
    if state.tab == tabPlaylists and state.playlistContentsIdx < 0:
      dispatchCommand(state, "create_playlist")
  of iw.Key.D:
    if state.tab == tabPlaylists and state.playlistContentsIdx < 0:
      dispatchCommand(state, "delete_playlist")
  of iw.Key.R:
    if state.tab == tabPlaylists and state.playlistContentsIdx < 0:
      dispatchCommand(state, "rename_playlist")
  of iw.Key.ShiftS:
    state.toggleShuffle()
  of iw.Key.ShiftR:
    state.cycleRepeat()
  of iw.Key.Slash:
    state.mode = imFilter
    state.filterText = ""
    state.filteredIndices = @[]
  of iw.Key.V:
    if state.selectMode:
      state.selectMode = false
      state.selectedIndices = initHashSet[int]()
    else:
      state.selectMode = true
      state.selectedIndices = initHashSet[int]()
      state.selectionAnchor = state.selectIndex
  of iw.Key.QuestionMark: state.helpVisible = true
  of iw.Key.One: state.tab = tabNowPlaying; state.rebuildDisplayItems()
  of iw.Key.Two: state.tab = tabLibrary; state.rebuildDisplayItems()
  of iw.Key.Three: state.tab = tabPlaylists; state.rebuildDisplayItems()
  of iw.Key.Four: state.tab = tabSettings; state.rebuildDisplayItems()
  of iw.Key.ShiftQ: state.quitDaemon()
  of iw.Key.T:
    state.showThemePicker = true
    state.themePickerQuery = ""
    state.updateThemePickerResults()
    state.themePickerSelect = 0
  of iw.Key.Q:
    cleanupAndQuit(state, false)
  of iw.Key.Escape:
    if state.addingToPlaylistId >= 0:
      state.addingToPlaylistId = -1
      state.addingToPlaylistName = ""
      state.selectedIndices = initHashSet[int]()
      state.selectMode = false
      state.tab = tabPlaylists
      state.rebuildDisplayItems()
    elif state.playlistContentsIdx >= 0:
      state.playlistContentsIdx = -1
      state.selectIndex = 0
      state.rebuildDisplayItems()
  else: discard

proc processEvents(state: var AppState) =
  let events = state.player.pollEvents()
  if state.player of DaemonClient:
    state.audioAvailable = DaemonClient(state.player).working
  for ev in events:
    case ev.kind
    of aekPositionChanged: state.timePos = ev.floatVal
    of aekDurationChanged: state.duration = ev.floatVal
    of aekVolumeChanged: state.volume = ev.intVal
    of aekPlaybackStarted: state.status = psPlaying
    of aekPlaybackPaused: state.status = psPaused
    of aekPlaybackStopped: state.status = psStopped
    of aekTrackEnded:
      if state.sleepTimerRemaining > 0:
        state.player.stop()
        state.status = psStopped
        state.sleepTimerRemaining = 0
      elif state.repeatMode == 2:
        state.playSelected()
      else:
        state.player.stop()
        state.status = psStopped
        state.nextTrack()
    else: discard

proc runTui(args: seq[string]) =
  terminal.enableTrueColors()
  iw.init()
  setControlCHook(handleQuitSignal)
  terminal.hideCursor()
  var dClient = newDaemonClient()
  dClient.ensureDaemon()
  var ctx = nw.initContext[AppState]()
  ctx.data.player = dClient
  ctx.data.daemonConnected = dClient.connected
  ctx.data.loadPlaylistsFromDaemon()
  ctx.data.audioAvailable = dClient.working
  initApp(ctx.data)
  ctx.data.loadConfig()
  if ctx.data.tab != tabNowPlaying and ctx.data.tab != tabLibrary and
     ctx.data.tab != tabPlaylists and ctx.data.tab != tabSettings:
    ctx.data.tab = tabNowPlaying
  ctx.data.buildDefaultCommands()
  ctx.data.loadLibrary()
  ctx.data.buildPlaylistFromArgs(args)
  ctx.data.rebuildDisplayItems()
  if args.len > 0 and ctx.data.libraryTracks.len > 0:
    os.sleep(10)
    ctx.data.selectIndex = 0
    ctx.data.playSelected()
  if ctx.data.viz != nil and ctx.data.player of DaemonClient:
    ctx.data.viz.startCapture()
  var prevTb: iw.TerminalBuffer
  var mouseInfo: iw.MouseInfo
  while true:
    try:
      let key = iw.getKey(mouseInfo)
      if ctx.data.ggPressed:
        ctx.data.ggTimer -= 1
        if ctx.data.ggTimer <= 0: ctx.data.ggPressed = false
      if ctx.data.leaderPressed:
        ctx.data.leaderTimer -= 1
        if ctx.data.leaderTimer <= 0:
          ctx.data.mode = imLeaderMode
          ctx.data.leaderPressed = false
      var chars: seq[Rune] = @[]
      if key >= iw.Key.Space and key <= iw.Key.Tilde:
        chars.add(Rune(key.ord))
      if key == iw.Key.Mouse:
        discard
      elif key != iw.Key.None:
        handleKey(ctx.data, key, chars)
      processEvents(ctx.data)
      if ctx.data.volumeCueTimer > 0:
        ctx.data.volumeCueTimer.dec
      if ctx.data.sleepTimerRemaining > 0:
        ctx.data.sleepTimerFrames.inc
        if ctx.data.sleepTimerFrames >= 60:
          ctx.data.sleepTimerFrames = 0
          ctx.data.sleepTimerRemaining.dec
          if ctx.data.sleepTimerRemaining <= 0:
            ctx.data.player.pause()
            ctx.data.status = psPaused
      if ctx.data.viz != nil:
        ctx.data.viz.readPcm()
      ctx.tb = iw.initTerminalBuffer(
        terminal.terminalWidth(),
        terminal.terminalHeight()
      )
      renderApp(ctx)
      iw.display(ctx.tb, prevTb)
      prevTb = ctx.tb
      os.sleep(16)
    except Exception as ex:
      if ctx.data.viz != nil: ctx.data.viz.stopCapture()
      iw.deinit()
      echo "\nError: ", ex.msg
      echo ex.getStackTrace()
      quit(1)

when isMainModule:
  let args = os.commandLineParams()
  if args.len > 0 and args[0] == "daemon":
    runDaemon()
    quit(0)
  let parsed = parseArgs()
  if parsed.subcmd != scNone:
    if execSubcommand(parsed):
      quit(0)
  runTui(args)

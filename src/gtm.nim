import os, terminal, strutils, unicode, json, sets, math, sequtils, algorithm, times, random, posix, osproc, tables
from illwave as iw import nil
from nimwave as nw import nil
import state, ui, audio, library, theme, commands, client, visualizer, cli, ytdlp

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
        let savedTab = json["last_tab"].getInt(0)
        if savedTab == 2:
          state.tab = tabLibrary
          state.filterScope = fsPlaylists
        else:
          state.tab = AppTab(savedTab)
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
      if json.hasKey("yt_cookie_source"):
        state.ytCookieSource = json["yt_cookie_source"].getStr("")
      if json.hasKey("yt_js_runtime"):
        state.ytJsRuntime = json["yt_js_runtime"].getStr("node")
      if json.hasKey("yt_search_history"):
        state.ytSearchHistory = json["yt_search_history"].getElems().mapIt(it.getStr(""))
      if json.hasKey("yt_search_page_size"):
        state.ytSearchPageSize = json["yt_search_page_size"].getInt(10)
      if json.hasKey("crossfade_duration"):
        state.crossfadeDuration = json["crossfade_duration"].getInt(5)
      if json.hasKey("keybindings"):
        state.rawKeybindingsJson = json["keybindings"]
      let refreshSeed = state.config.refreshTheme or state.config.theme == "random"
      state.theme = getTheme(state.config.theme, refreshSeed)
    except:
      stderr.writeLine("[gtm] loadConfig error: " & getCurrentExceptionMsg())

proc applyKeybindings(state: var AppState) =
  if state.rawKeybindingsJson == nil: return
  try:
    for id, keys in state.rawKeybindingsJson.pairs:
      if keys.kind == JArray:
        var keyList: seq[string] = @[]
        for k in keys:
          if k.kind == JString:
            keyList.add(k.getStr(""))
        if keyList.len > 0:
          state.rebindCommand(id, keyList)
  except:
    stderr.writeLine("[gtm] applyKeybindings error: " & getCurrentExceptionMsg())
  state.rawKeybindingsJson = nil

proc saveConfig(state: AppState) =
  if state.configPath.len == 0: return
  let dir = state.configPath.parentDir()
  if not dirExists(dir): createDir(dir)
  let json = %{
    "theme": %state.config.theme,
    "volume": %state.volume,
    "last_tab": %(state.tab.ord),
    "refresh_theme": %state.config.refreshTheme,
    "viz_visible": %state.vizVisible,
    "visualizer": %{"bar_count": %state.viz.barCount},
    "yt_cookie_source": %state.ytCookieSource,
    "yt_js_runtime": %state.ytJsRuntime,
    "yt_search_history": %state.ytSearchHistory,
    "yt_search_page_size": %state.ytSearchPageSize,
    "crossfade_duration": %state.crossfadeDuration
  }
  var j = json
  if state.rawKeybindingsJson != nil:
    j["keybindings"] = state.rawKeybindingsJson
  try:
    writeFile(state.configPath, $j)
  except:
    stderr.writeLine("[gtm] saveConfig error: " & getCurrentExceptionMsg())

proc loadLibraryFromDaemon(state: var AppState, cli: DaemonClient, resp: JsonNode) =
  state.libraryTracks = @[]
  state.libraryArtists = @[]
  state.libraryAlbums = @[]
  for t in resp["tracks"]:
    state.libraryTracks.add(Track(
      path: t{"path"}.getStr(""),
      title: t{"title"}.getStr(""),
      artist: t{"artist"}.getStr(""),
      album: t{"album"}.getStr(""),
      duration: t{"duration"}.getFloat(0.0),
      id: t{"id"}.getInt(0).int64,
      trackNum: t{"track_num"}.getInt(0),
      year: t{"year"}.getInt(0),
      genre: t{"genre"}.getStr(""),
      playCount: t{"play_count"}.getInt(0),
      artistId: t{"artist_id"}.getInt(0).int64,
      albumId: t{"album_id"}.getInt(0).int64,
      isFavourite: t{"is_favourite"}.getBool(false),
      addedAt: t{"added_at"}.getStr(""),
      lastPlayed: t{"last_played"}.getStr("")
    ))
  for a in resp["artists"]:
    state.libraryArtists.add(ArtistEnt(
      id: a{"id"}.getInt(0).int64,
      name: a{"name"}.getStr("")
    ))
  for a in resp["albums"]:
    state.libraryAlbums.add(AlbumEnt(
      id: a{"id"}.getInt(0).int64,
      title: a{"title"}.getStr(""),
      artistId: a{"artist_id"}.getInt(0).int64,
      artistName: a{"artist_name"}.getStr(""),
      year: a{"year"}.getInt(0),
      genre: a{"genre"}.getStr("")
    ))
  state.rebuildItems()

proc scanLocalDir(state: var AppState, dir: string) =
  if not dirExists(dir): return
  let paths = scanDirectoryRecursive(dir)
  for path in paths:
    let (_, name, _) = splitFile(path)
    let title = name.replace(".", " ")
    state.libraryTracks.add(Track(
      path: path, title: title, artist: "", album: "",
      duration: 0.0, id: int64(state.libraryTracks.len + 1),
      isFavourite: false
    ))

proc loadLibrary(state: var AppState) =
  if state.libraryTracks.len > 0: return
  let musicDir = getEnv("HOME", "") & "/Music"
  if state.player of DaemonClient:
    let cli = DaemonClient(state.player)
    if cli.connected:
      let resp = cli.getLibrary()
      if resp.hasKey("tracks") and resp["tracks"].len > 0:
        state.loadLibraryFromDaemon(cli, resp)
        return
      # Daemon library empty: trigger server-side scan, then re-query
      if dirExists(musicDir):
        discard cli.scanDir(musicDir)
        let resp2 = cli.getLibrary()
        if resp2.hasKey("tracks") and resp2["tracks"].len > 0:
          state.loadLibraryFromDaemon(cli, resp2)
          return
  # Fallback: scan local files
  state.scanLocalDir(musicDir)
  state.rebuildItems()

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

proc shuffleOrder(count: int): seq[int] =
  result = toSeq(0..<count)
  for i in countup(0, count - 2):
    let j = rand(i..<count)
    swap(result[i], result[j])

proc applyFilter(state: var AppState) =
  state.rebuildItems()
  state.filteredIndices = @[]
  if state.filterText.len > 0:
    let lowerFilter = state.filterText.toLowerAscii()
    for i, item in state.displayItems:
      if lowerFilter in item.label.toLowerAscii() or lowerFilter in item.sublabel.toLowerAscii():
        state.filteredIndices.add(i)
    state.selectIndex = if state.filteredIndices.len > 0: 0 else: -1
  else:
    if state.displayItems.len > 0:
      state.selectIndex = min(state.selectIndex, state.displayItems.len - 1)
    else:
      state.selectIndex = -1

proc showVolumeCue(state: var AppState) =
  state.volumeCueTimer = 90
  state.volumeCueVolume = state.volume

proc showNotification*(state: var AppState, msg: string, kind: NotificationKind = nkInfo) =
  state.notificationMsg = msg
  state.notificationBody = ""
  state.notificationKind = kind
  state.notificationTimer = 90
  state.markDirty(ceFeedback)

proc setFeedback(state: var AppState, msg: string, kind: NotificationKind = nkInfo) =
  state.notificationMsg = msg
  state.notificationBody = ""
  state.notificationKind = kind
  state.feedbackTimer = 60
  state.markDirty(ceFeedback)

proc isYtPageUrl*(path: string): bool =
  path.contains("youtube.com") or path.contains("youtu.be")

proc playSelected(state: var AppState) =
  let track = state.getCurrentTrack()
  if track.path.len > 0:
    state.timePos = 0.0
    state.duration = 0.0
    # Check if this YT track has already been downloaded; use local file
    if isYtPageUrl(track.path) and state.ytDownloaded.hasKey(track.path):
      let localPath = state.ytDownloaded[track.path]
      if fileExists(localPath):
        state.ytStreamTitle = ""
        state.ytStreamChannel = ""
        state.ytStreamDuration = ""
        state.player.loadFile(localPath)
        state.player.play()
        state.status = psPlaying
        state.currentPlayingPath = localPath
        state.currentPlayingId = track.id
        state.markDirtyBatch(cePlayState, ceTrack)
        if state.duration == 0.0 and track.duration > 0:
          state.duration = track.duration
        return
    if isYtPageUrl(track.path) and not track.path.contains("googlevideo.com"):
      if state.ytStreamActive: return
      state.ytStreamPendingItem = YtSearchResult(
        title: track.title,
        url: track.path,
        duration: "",
        channel: track.displayArtist(),
        kind: srkVideo
      )
      state.ytStreamActive = startStreamUrlFetch(track.path, state.ytStreamProcess, state.ytCookieSource, state.ytJsRuntime)
      state.ytStreamBuf = ""
      if state.ytStreamActive:
        state.setFeedback("Resolving stream URL...")
      else:
        state.setFeedback("Failed to start stream resolution")
      state.markDirty(cePlayState)
      return
    state.ytStreamTitle = ""
    state.ytStreamChannel = ""
    state.ytStreamDuration = ""
    state.player.loadFile(track.path)
    state.player.play()
    state.status = psPlaying
    state.currentPlayingPath = track.path
    state.currentPlayingId = track.id
    state.markDirtyBatch(cePlayState, ceTrack)
    if state.duration == 0.0 and track.duration > 0:
      state.duration = track.duration

proc nextTrack(state: var AppState) =
  let items = state.displayItems
  if state.playbackQueue.len > 0:
    let tIdx = state.playbackQueue[0]
    state.playbackQueue.delete(0)
    if state.queueCursor > 0: state.queueCursor.dec
    state.markDirty(ceQueue)
    if tIdx >= 0 and tIdx < state.libraryTracks.len:
      state.selectIndex = tIdx
      state.playSelected()
    return
  if items.len == 0: return
  if state.shuffleEnabled and state.shuffleOrder.len > 0:
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
        state.markDirty(cePlayState)
        return
    state.selectIndex = next
  state.playSelected()

proc prevTrack(state: var AppState) =
  let items = state.displayItems
  if items.len == 0: return
  if state.shuffleEnabled and state.shuffleOrder.len > 0:
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

proc adjustVolume(state: var AppState, delta: int) =
  state.volume = max(0, min(100, state.volume + delta))
  state.player.setVolume(state.volume)
  state.showVolumeCue()
  if state.tab == tabSettings: state.rebuildItems()

proc toggleShuffle(state: var AppState) =
  state.shuffleEnabled = not state.shuffleEnabled
  if state.shuffleEnabled:
    let count = state.displayItems.len
    if count > 0:
      state.shuffleOrder = shuffleOrder(count)
      state.shuffleIndex = 0
  if state.player of DaemonClient:
    discard DaemonClient(state.player).setShuffle(state.shuffleEnabled)

proc cycleRepeat(state: var AppState) =
  state.repeatMode = (state.repeatMode + 1) mod 3
  if state.player of DaemonClient:
    discard DaemonClient(state.player).setRepeat(state.repeatMode)

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
  if state.tab == tabSettings:
    if state.settingsFocusPanel == lpSidebar:
      let cats = ord(high(SettingsCategory)) + 1
      state.settingsCategory = SettingsCategory((state.settingsCategory.ord + delta + cats) mod cats)
      state.selectIndex = 0
    else:
      let maxIdx = case state.settingsCategory
        of scAudio: 3
        of scYouTube: 6
        of scAppearance: 2
        of scSystem: 1
      state.selectIndex = max(0, min(maxIdx, state.selectIndex + delta))
    return
  let count = state.filteredCount()
  if count == 0:
    state.selectIndex = -1
    return
  state.selectIndex = max(0, min(count - 1, state.selectIndex + delta))
  if state.selectMode:
    let realIdx = state.filteredIndex(state.selectIndex)
    if realIdx >= 0:
      state.selectedIndices.incl(realIdx)

proc toggleSelect(state: var AppState) =
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
  state.rebuildItems()
  state.selectIndex = min(state.selectIndex, state.displayItems.len - 1)

proc cleanQuit(state: var AppState, stopDaemon: bool) =
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

proc checkAutocomplete(state: var AppState) =
  let query = state.overlay.query
  if query.len < 2:
    state.overlay.ytAutocompleteVisible = false
    state.overlay.ytAutocompleteSuggestions = @[]
    return
  # Local search history fuzzy match
  var matches: seq[string] = @[]
  let lowerQuery = query.toLowerAscii()
  for h in state.ytSearchHistory:
    if lowerQuery in h.toLowerAscii():
      matches.add(h)
  if matches.len > 0:
    state.overlay.ytAutocompleteSuggestions = matches[0..<min(matches.len, 5)]
    state.overlay.ytAutocompleteCursor = 0
    state.overlay.ytAutocompleteVisible = true
  else:
    state.overlay.ytAutocompleteVisible = false

proc quitBackground(state: var AppState) =
  state.saveConfig()
  if state.viz != nil: state.viz.stopCapture()
  terminal.showCursor()
  eraseScreen()
  setCursorPos(0, 0)
  quit(0)

proc quitDaemon(state: var AppState) =
  cleanQuit(state, true)

proc toggleVisualizer(state: var AppState) =
  state.vizVisible = not state.vizVisible

proc goToFirst(state: var AppState) =
  state.selectIndex = 0

proc goToLast(state: var AppState) =
  state.selectIndex = max(0, state.filteredCount() - 1)

proc queuePath*(state: AppState): string = state.dataDir / "queue.json"

proc saveQueue*(state: AppState) =
  let path = state.queuePath
  try:
    let dir = state.dataDir
    if not dirExists(dir): createDir(dir)
    var arr: seq[JsonNode] = @[]
    for idx in state.playbackQueue:
      if idx >= 0 and idx < state.libraryTracks.len:
        let t = state.libraryTracks[idx]
        arr.add(%*{"path": t.path, "title": t.title, "artist": t.artist})
    writeFile(path, $ %*{"queue": arr, "cursor": state.queueCursor})
  except:
    discard

proc loadQueue*(state: var AppState) =
  let path = state.queuePath
  if not fileExists(path): return
  try:
    let j = parseFile(path)
    state.playbackQueue = @[]
    if j.hasKey("cursor"):
      state.queueCursor = j["cursor"].getInt(0)
    if j.hasKey("queue"):
      for item in j["queue"]:
        let itemPath = item["path"].getStr("")
        # Find matching track in current library by path
        for i, t in state.libraryTracks:
          if t.path == itemPath:
            state.playbackQueue.add(i)
            break
  except:
    state.playbackQueue = @[]
    state.queueCursor = 0

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

proc parsePlaylists(state: var AppState, resp: JsonNode) =
  if resp.hasKey("playlists"):
    state.libraryPlaylists = @[]
    for plJson in resp["playlists"]:
      var trackIds: seq[int64] = @[]
      if state.player of DaemonClient:
        let cli = DaemonClient(state.player)
        let tracksResp = cli.getPlaylistTracks(plJson["id"].getInt(0).int64)
        if tracksResp.hasKey("track_ids"):
          for tid in tracksResp["track_ids"]:
            trackIds.add(tid.getInt(0).int64)
      state.libraryPlaylists.add(UserPlaylist(
        id: plJson["id"].getInt(0).int64,
        name: plJson["name"].getStr(""),
        trackIds: trackIds
      ))
    state.rebuildItems()

proc loadPlaylists(state: var AppState) =
  if state.player of DaemonClient:
    let cli = DaemonClient(state.player)
    let resp = cli.listPlaylists()
    state.parsePlaylists(resp)

proc addToPlaylist(state: var AppState) =
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
  state.rebuildItems()

proc addTracksToPl(state: var AppState, playlistId: int64) =
  if state.selectedIndices.len == 0:
    state.addingToPlaylistId = -1
    state.addingToPlaylistName = ""
    state.tab = tabLibrary
    state.filterScope = fsPlaylists
    state.rebuildItems()
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
  state.tab = tabLibrary
  state.filterScope = fsPlaylists
  state.playlistContentsIdx = plIdx
  state.selectIndex = 0
  state.rebuildItems()

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
  state.overlay.strResults = @[]
  let q = state.overlay.query.toLowerAscii()
  for preset in themePickerPresets:
    if q.len == 0 or preset.contains(q):
      state.overlay.strResults.add(preset)

proc initCommands(state: var AppState) =
  state.registerCommand("leader_menu", "Actions Menu",
    "Open the actions/leader menu", "\u2316", @["CtrlL"],
    proc(s: var AppState) = s.mode = imLeaderMode)
  state.registerCommand("toggle_play_pause", "Toggle Play/Pause",
    "Toggle between play and pause states", "\u25B6", @["Space"],
    proc(s: var AppState) = s.player.togglePause())
  state.registerCommand("stop_playback", "Stop",
    "Stop playback and reset position", "\u25A0", @["CtrlS", "s"],
    proc(s: var AppState) = s.player.stop(); s.status = psStopped)
  state.registerCommand("seek_forward", "Seek Forward",
    "Seek forward 5 seconds", "\u23E9", @[".", "Right"],
    proc(s: var AppState) = s.player.seek(5.0))
  state.registerCommand("seek_backward", "Seek Backward",
    "Seek backward 5 seconds", "\u23EA", @[",", "Left"],
    proc(s: var AppState) = s.player.seek(-5.0))
  state.registerCommand("volume_up", "Volume Up",
    "Increase volume by 5%", "\uF028", @["CtrlU", "ShiftJ", "Plus", "Equals"],
    proc(s: var AppState) = s.adjustVolume(5))
  state.registerCommand("volume_down", "Volume Down",
    "Decrease volume by 5%", "\uF027", @["CtrlD", "ShiftK", "Minus", "Underscore"],
    proc(s: var AppState) = s.adjustVolume(-5))
  state.registerCommand("toggle_mute", "Toggle Mute",
    "Mute or unmute audio", "\uF026", @["m"],
    proc(s: var AppState) = s.toggleMute())
  state.registerCommand("next_track", "Next Track",
    "Skip to next track in playlist", "\u23ED", @["CtrlN", "n"],
    proc(s: var AppState) = s.nextTrack())
  state.registerCommand("prev_track", "Previous Track",
    "Go to previous track", "\u23EE", @["CtrlP", "p"],
    proc(s: var AppState) = s.prevTrack())
  state.registerCommand("nav_up", "Move Up",
    "Move selection up in the list", "\u2B06", @["CtrlK", "k", "Up"],
    proc(s: var AppState) = s.moveSelection(-1))
  state.registerCommand("nav_down", "Move Down",
    "Move selection down in the list", "\u2B07", @["CtrlJ", "j", "Down"],
    proc(s: var AppState) = s.moveSelection(1))
  state.registerCommand("enter_filter", "Filter/Search",
    "Enter filter mode to search", "\U0001F50D", @["CtrlF", "Slash"],
    proc(s: var AppState) = s.mode = imFilter; s.filterText = ""; s.filteredIndices = @[])
  state.registerCommand("play_selected", "Play Selected",
    "Play the currently selected item", "\u25B6", @["Enter"],
    proc(s: var AppState) = s.playSelected())
  state.registerCommand("go_to_first", "Go to First",
    "Jump to first item in the list", "\u23EE", @["CtrlG", "g+g"],
    proc(s: var AppState) = s.goToFirst())
  state.registerCommand("go_to_last", "Go to Last",
    "Jump to last item in the list", "\u23ED", @["ShiftG"],
    proc(s: var AppState) = s.goToLast(); s.playSelected())
  state.registerCommand("toggle_select_mode", "Toggle Select Mode",
    "Enter or exit multi-select mode", "\U0001F7E8", @["v"],
    proc(s: var AppState) = s.toggleSelect())
  state.registerCommand("select_all", "Select All",
    "Select all visible items", "\U0001F7E9", @[],
    proc(s: var AppState) = s.selectAll())
  state.registerCommand("remove_selected", "Remove Selected",
    "Remove selected items", "\u274C", @["ShiftX"],
    proc(s: var AppState) = s.removeSelected())
  state.registerCommand("add_to_playlist", "Add to Playlist...",
    "Add selected items to playlist", "\U0001F4CB", @[],
    proc(s: var AppState) = s.addToPlaylist())
  state.registerCommand("tab_now_playing", "Now Playing",
    "Switch to Now Playing tab", "\U0001F3B5", @["1"],
    proc(s: var AppState) = s.tab = tabNowPlaying; s.rebuildItems())
  state.registerCommand("tab_library", "Library",
    "Switch to Library tab", "\U0001F4DA", @["2"],
    proc(s: var AppState) = s.tab = tabLibrary; s.filterScope = fsAll; s.rebuildItems())
  state.registerCommand("tab_settings", "Settings",
    "Switch to Settings tab", "\u2699", @["3"],
    proc(s: var AppState) = s.tab = tabSettings; s.rebuildItems())
  state.registerCommand("show_help", "Show Help",
    "Display help overlay with keybindings", "\u2753", @["QuestionMark"],
    proc(s: var AppState) = s.helpVisible = true)
  state.registerCommand("show_about", "About",
    "Show system information and build details", "\u24D8", @["ShiftA"],
    proc(s: var AppState) = s.aboutVisible = true)
  state.registerCommand("show_equalizer", "Equalizer",
    "Open graphic equalizer with 10-band EQ", "\U0001F3B5", @["AltE", "E"],
    proc(s: var AppState) = s.eqVisible = not s.eqVisible)
  state.registerCommand("quit_background", "Quit (Background)",
    "Exit TUI, keep playback running", "\u23F8", @["q"],
    proc(s: var AppState) = s.quitBackground())
  state.registerCommand("quit_daemon", "Quit & Stop Daemon",
    "Exit and terminate background daemon", "\u23F9", @["ShiftQ"],
    proc(s: var AppState) = s.quitDaemon())
  state.registerCommand("toggle_visualizer", "Toggle Visualizer",
    "Show or hide audio visualizer", "\U0001F4CA", @["CtrlV"],
    proc(s: var AppState) = s.toggleVisualizer())
  state.registerCommand("command_palette", "Command Palette",
    "Show command palette with fuzzy search", "\u2328", @["Colon"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okCommandPalette, query: "")
      for i in 0..<s.commands.len: s.overlay.results.add(i))
  state.registerCommand("change_theme", "Change Theme",
    "Open theme picker with live preview", "\U0001F3A8", @["AltC", "T"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okThemePicker, query: "")
      s.updateThemePickerResults())
  state.registerCommand("save_playlist", "Save Playlist",
    "Save current queue as a playlist file", "\U0001F4BE", @[],
    proc(s: var AppState) = s.saveCurrentQueue())
  state.registerCommand("create_playlist", "Create Playlist",
    "Create a new playlist", "\U0001F4CB", @["AltP", "a"],
    proc(s: var AppState) =
      s.playlistInputActive = true; s.playlistInputPrompt = "New Playlist Name:"; s.playlistInputBuffer = "")
  state.registerCommand("delete_playlist", "Delete Playlist",
    "Delete the selected playlist", "\u274C", @["AltD", "d"],
    proc(s: var AppState) =
      let item = s.selectedItem()
      if item.kind == likPlaylist and s.libraryPlaylists.len > 0:
        let idx = s.selectIndex
        if idx >= 0 and idx < s.libraryPlaylists.len:
          s.playlistInputActive = true
          s.playlistInputPrompt = "Delete playlist '" & s.libraryPlaylists[idx].name & "'? (y/N)"
          s.playlistInputBuffer = "")
  state.registerCommand("rename_playlist", "Rename Playlist",
    "Rename the selected playlist", "\U0001F4DD", @["AltR", "r"],
    proc(s: var AppState) =
      let item = s.selectedItem()
      if item.kind == likPlaylist and s.libraryPlaylists.len > 0:
        let idx = s.selectIndex
        if idx >= 0 and idx < s.libraryPlaylists.len:
          s.playlistInputActive = true
          s.playlistInputPrompt = "Rename Playlist:"
          s.playlistInputBuffer = s.libraryPlaylists[idx].name)
  state.registerCommand("toggle_favourite", "Toggle Favourite",
    "Mark or unmark the selected track as favourite", "\u2605", @["f"],
    proc(s: var AppState) =
      let idx = s.selectIndex
      let items = s.displayItems
      if idx >= 0 and idx < items.len and items[idx].trackIdx >= 0:
        let tid = items[idx].id
        if tid > 0:
          if tid in s.favouriteIds:
            s.favouriteIds.excl(tid)
            s.showNotification("Removed from favourites", nkInfo)
          else:
            s.favouriteIds.incl(tid)
            s.showNotification("Added to favourites", nkSuccess)
          s.markDirty(ceTrack))
  state.registerCommand("import_m3u", "Import M3U",
    "Import a playlist from .m3u file", "\U0001F4C2", @[],
    proc(s: var AppState) =
      s.playlistInputActive = true; s.playlistInputPrompt = "Import M3U path:"; s.playlistInputBuffer = "")
  state.registerCommand("rescan_library", "Rescan Library",
    "Rescan music directories for new files", "\U0001F504", @[],
    proc(s: var AppState) =
      s.libraryTracks = @[]; s.loadLibrary(); s.rebuildItems())
  state.registerCommand("toggle_shuffle", "Toggle Shuffle",
    "Toggle random playback order", "\U0001F500", @["ShiftS"],
    proc(s: var AppState) = s.toggleShuffle())
  state.registerCommand("toggle_repeat", "Toggle Repeat",
    "Cycle repeat modes: none / all / one", "\U0001F501", @["ShiftR"],
    proc(s: var AppState) = s.cycleRepeat())
  state.registerCommand("sleep_timer", "Sleep Timer",
    "Set a sleep timer to stop playback after N minutes", "\u23F0", @[],
    proc(s: var AppState) =
      s.playlistInputActive = true
      s.playlistInputPrompt = "Sleep timer minutes (5, 10, 15, 30, 60, or 0 to cancel):"
      s.playlistInputBuffer = "")
  state.registerCommand("yt_search", "YouTube Search",
    "Search YouTube for music to stream or download", "\U0001F50D", @["AltY", "y"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okYtSearch, query: "")
      s.ytDebounceAt = 0)
  state.registerCommand("yt_recommended", "Recommended Playlists",
    "Search YT for playlists related to current track", "\U0001F3B6", @["CtrlR"],
    proc(s: var AppState) =
      var q = s.ytStreamTitle
      if s.ytStreamChannel.len > 0:
        q &= " " & s.ytStreamChannel
      q &= " playlist"
      if q.len > 0:
        s.overlay = OverlayState(kind: okYtSearch, query: q)
        s.ytDebounceAt = 0)
  state.registerCommand("queue_picker", "Enqueue",
    "Add tracks to playback queue", "\U0001F3B6", @["i"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okQueuePicker, query: "")
      if s.displayItems.len > 0:
        for idx, item in s.displayItems:
          s.overlay.results.add(idx))

proc execCmd(state: var AppState, cmdId: string) =
  let idx = findCommandIdx(state, cmdId)
  if idx >= 0:
    state.commands[idx].handler(state)

const EQ_PRESETS = ["Flat", "Rock", "Pop", "Classical", "Jazz", "HipHop", "Vocal", "BassBoost", "Headphones", "Laptop"]

proc cycleEqPreset(state: var AppState) =
  var idx = EQ_PRESETS.find(state.eqPreset)
  idx = (idx + 1) mod EQ_PRESETS.len
  state.eqPreset = EQ_PRESETS[idx]
  # Apply preset gains (matching C preset values)
  const EQ_PRESET_VALS: array[10, array[10, float]] = [
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    [5.0, 4.0, 3.0, 2.0, 1.0, 0.0, 0.0, 1.0, 2.0, 3.0],
    [2.0, 3.0, 4.0, 3.0, 1.0, 0.0, 0.0, 1.0, 2.0, 2.0],
    [4.0, 3.0, 2.0, 1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
    [3.0, 2.0, 1.0, 2.0, 3.0, 4.0, 3.0, 2.0, 1.0, 0.0],
    [5.0, 4.0, 3.0, 2.0, 1.0, 0.0, 0.0, 0.0, 1.0, 2.0],
    [1.0, 2.0, 3.0, 4.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0],
    [7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 1.0, 1.0, 1.0],
    [2.0, 2.0, 1.0, 0.0, -1.0, -1.0, 0.0, 1.0, 2.0, 3.0],
    [1.0, 2.0, 2.0, 3.0, 3.0, 2.0, 1.0, 0.0, -1.0, -2.0],
  ]
  for i in 0..9:
    state.eqBands[i] = EQ_PRESET_VALS[idx][i]
  if state.player of DaemonClient:
    let cli = DaemonClient(state.player)
    cli.setEqPreset(state.eqPreset)

proc adjustSetting(state: var AppState, delta: int) =
  if state.tab != tabSettings: return
  case state.settingsCategory
  of scAudio:
    case state.selectIndex
    of 0: # Volume
      state.volume = max(0, min(100, state.volume + delta * 5))
      state.player.setVolume(state.volume)
      state.showVolumeCue()
      state.saveConfig()
    of 1: # Visualizer
      state.toggleVisualizer()
    of 2: # Crossfade Duration
      state.crossfadeDuration = max(0, min(10, state.crossfadeDuration + delta))
      state.saveConfig()
    else: discard
  of scYouTube:
    case state.selectIndex
    of 0: # Cookie Source — detect on Enter only
      discard
    of 1: # JS Runtime — cycle
      const runtimes = ["node", "bun", "deno"]
      var i = 0
      for idx, r in runtimes:
        if r == state.ytJsRuntime:
          i = (idx + delta + runtimes.len) mod runtimes.len
          break
      state.ytJsRuntime = runtimes[i]
      state.saveConfig()
    of 2: # Max Downloads
      state.ytMaxConcurrentDownloads = max(1, min(10, state.ytMaxConcurrentDownloads + delta))
    of 3: # Results Per Page
      state.ytSearchPageSize = max(5, min(50, state.ytSearchPageSize + delta * 5))
      state.saveConfig()
    of 4: # Search History — info on Enter only
      discard
    of 5: # Batch Mode
      state.ytBatchDownloadMode = not state.ytBatchDownloadMode
    of 6: # Clear Search History — action on Enter only
      discard
    else: discard
  of scAppearance:
    case state.selectIndex
    of 0: # Theme — open picker on Enter only
      discard
    of 1: # Refresh Theme
      state.config.refreshTheme = not state.config.refreshTheme
    else: discard
  of scSystem:
    case state.selectIndex
    of 0: # Idle Timeout
      state.config.idleTimeout = max(30, min(600, state.config.idleTimeout + delta * 30))
    of 1: # Reset All — action on Enter only
      discard
    else: discard
  state.rebuildItems()
  state.markDirty(ceSettings)

proc handleKey(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  if state.aboutVisible:
    if key notin {iw.Key.None}:
      state.aboutVisible = false
    return
  if state.eqVisible:
    case key
    of iw.Key.Escape:
      state.eqVisible = false
    of iw.Key.Left:
      let b = state.eqBandSelect.clamp(0, 9)
      state.eqBands[b] = max(-12.0, state.eqBands[b] - 0.5)
      state.eqPreset = ""
      if state.player of DaemonClient:
        DaemonClient(state.player).setEqBand(b, state.eqBands[b])
    of iw.Key.Right:
      let b = state.eqBandSelect.clamp(0, 9)
      state.eqBands[b] = min(12.0, state.eqBands[b] + 0.5)
      state.eqPreset = ""
      if state.player of DaemonClient:
        DaemonClient(state.player).setEqBand(b, state.eqBands[b])
    of iw.Key.J, iw.Key.Down:
      state.eqBandSelect = min(9, state.eqBandSelect + 1)
    of iw.Key.K, iw.Key.Up:
      state.eqBandSelect = max(0, state.eqBandSelect - 1)
    of iw.Key.P, iw.Key.ShiftP:
      cycleEqPreset(state)
    else:
      discard
    return
  if state.helpVisible:
    if key in {iw.Key.QuestionMark, iw.Key.Escape, iw.Key.Q, iw.Key.ShiftQ}:
      state.helpVisible = false
    return
  if state.playlistInputActive:
    case key
    of iw.Key.Escape:
      state.playlistInputActive = false
      state.playlistInputBuffer = ""
      state.playlistInputPrompt = ""
      state.overlay.batchItems = @[]
    of iw.Key.Enter:
      if state.playlistInputBuffer.len > 0:
        if state.playlistInputPrompt.contains("Delete playlist"):
          if state.playlistInputBuffer.toLowerAscii() == "y":
            let idx = state.selectIndex
            if idx >= 0 and idx < state.libraryPlaylists.len:
              let plId = state.libraryPlaylists[idx].id
              if state.player of DaemonClient:
                let resp = DaemonClient(state.player).deletePlaylist(plId)
                state.parsePlaylists(resp)
              else:
                state.libraryPlaylists.delete(idx)
                state.rebuildItems()
        elif state.playlistInputPrompt.contains("Rename"):
          let idx = state.selectIndex
          if idx >= 0 and idx < state.libraryPlaylists.len:
            let plId = state.libraryPlaylists[idx].id
            if state.player of DaemonClient:
              let resp = DaemonClient(state.player).renamePlaylist(plId, state.playlistInputBuffer)
              state.parsePlaylists(resp)
            else:
              state.libraryPlaylists[idx].name = state.playlistInputBuffer
              state.rebuildItems()
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
            state.rebuildItems()
        elif state.playlistInputPrompt.contains("Sleep timer"):
          let minutes = state.playlistInputBuffer.parseInt()
          if state.player of DaemonClient:
            discard DaemonClient(state.player).setSleepTimer(minutes)
          state.sleepTimerRemaining = if minutes > 0: minutes else: 0
        else:
          if state.player of DaemonClient:
            let resp = DaemonClient(state.player).createPlaylist(state.playlistInputBuffer)
            state.parsePlaylists(resp)
            if state.libraryPlaylists.len > 0:
              if state.overlay.batchItems.len > 0:
                let plIdx = state.libraryPlaylists.len - 1
                for item in state.overlay.batchItems:
                  let track = Track(
                    path: item.url, title: item.title, artist: item.channel,
                    album: "YouTube", duration: 0.0,
                    id: int64(state.libraryTracks.len + 1)
                  )
                  state.libraryTracks.add(track)
                  state.libraryPlaylists[plIdx].trackIds.add(track.id)
                state.overlay.batchItems = @[]
                state.rebuildItems()
                state.showNotification("Added items to new playlist")
              else:
                state.addingToPlaylistId = state.libraryPlaylists[^1].id
                state.addingToPlaylistName = state.libraryPlaylists[^1].name
                state.tab = tabLibrary
                state.selectMode = false
                state.selectedIndices = initHashSet[int]()
                state.rebuildItems()
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
  if state.overlay.kind != okNone:
    case state.overlay.kind
    of okThemePicker:
      case key
      of iw.Key.Escape:
        state.overlay.clear()
      of iw.Key.Enter:
        if state.overlay.strResults.len > 0 and state.overlay.cursor >= 0 and
           state.overlay.cursor < state.overlay.strResults.len:
          let seed = state.overlay.strResults[state.overlay.cursor]
          state.applyTheme(seed)
        state.overlay.clear()
      of iw.Key.Backspace:
        if state.overlay.query.len > 0:
          state.overlay.query = state.overlay.query[0..^2]
          state.updateThemePickerResults()
      of iw.Key.J, iw.Key.Down:
        if state.overlay.cursor < state.overlay.strResults.len - 1:
          state.overlay.cursor.inc
          let seed = state.overlay.strResults[state.overlay.cursor]
          state.applyTheme(seed)
      of iw.Key.K, iw.Key.Up:
        if state.overlay.cursor > 0:
          state.overlay.cursor.dec
          let seed = state.overlay.strResults[state.overlay.cursor]
          state.applyTheme(seed)
      else:
        for ch in chars:
          let code = ch.int
          if code >= 32 and code < 127:
            state.overlay.query &= $ch
            state.updateThemePickerResults()
        state.overlay.cursor = 0
      if state.overlay.strResults.len > 0:
        state.overlay.cursor = min(state.overlay.cursor, state.overlay.strResults.len - 1)
    of okYtSearch:
      case key
      of iw.Key.Escape:
        state.overlay.clear()
        state.ytDebounceAt = 0
        state.ytSearchQuery = ""
        if state.ytSearchProcessActive:
          close(state.ytSearchProcess)
          state.ytSearchProcessActive = false
        state.ytSearchOutputBuf = ""
        state.ytSearchLoading = false
      of iw.Key.Tab:
        # Cycle sub-tab: All ↔ Playlists
        if state.overlay.ytSubTab == ystAll:
          state.overlay.ytSubTab = ystPlaylists
        else:
          state.overlay.ytSubTab = ystAll
        state.overlay.cursor = 0
        state.overlay.ytResults = @[]
        state.ytSearchQuery = ""
        state.ytDebounceAt = epochTime() + 0.25
        state.markDirty(ceSearchResults)
      of iw.Key.CtrlS:
        if state.overlay.multiMode:
          state.overlay.multiMode = false
          state.overlay.selected = initHashSet[int]()
        else:
          state.overlay.multiMode = true
          if state.overlay.ytResults.len > 0:
            let idx = state.overlay.cursor
            state.overlay.selected.incl(idx)
      of iw.Key.Down, iw.Key.CtrlN:
        if state.overlay.ytAutocompleteVisible and state.overlay.ytAutocompleteSuggestions.len > 0:
          if state.overlay.ytAutocompleteCursor < state.overlay.ytAutocompleteSuggestions.len - 1:
            state.overlay.ytAutocompleteCursor.inc
        elif state.overlay.cursor < state.overlay.ytResults.len - 1:
          state.overlay.cursor.inc
        elif state.overlay.ytResults.len > 0:
          # Pagination: scroll past end → fetch next page
          state.ytSearchPage.inc
          state.ytDebounceAt = epochTime() + 0.25
          state.markDirty(ceSearchResults)
      of iw.Key.Up, iw.Key.CtrlP:
        if state.overlay.ytAutocompleteVisible and state.overlay.ytAutocompleteSuggestions.len > 0:
          if state.overlay.ytAutocompleteCursor > 0:
            state.overlay.ytAutocompleteCursor.dec
        elif state.overlay.cursor > 0:
          state.overlay.cursor.dec
      of iw.Key.Enter:
        if state.overlay.ytAutocompleteVisible and state.overlay.ytAutocompleteSuggestions.len > 0:
          state.overlay.query = state.overlay.ytAutocompleteSuggestions[state.overlay.ytAutocompleteCursor]
          state.overlay.ytAutocompleteVisible = false
          state.overlay.ytAutocompleteSuggestions = @[]
          state.ytDebounceAt = epochTime() + 0.25
        elif state.overlay.ytResults.len > 0:
          if state.overlay.multiMode:
            let idx = state.overlay.cursor
            if idx in state.overlay.selected:
              state.overlay.selected.excl(idx)
            else:
              state.overlay.selected.incl(idx)
          else:
            let r = state.overlay.ytResults[state.overlay.cursor]
            if r.kind == srkPlaylist:
              # Fetch playlist tracks
              let plDetail = fetchPlaylistTracks(r.url, state.ytCookieSource, state.ytJsRuntime)
              if plDetail.trackCount > 0:
                state.overlay.ytPlaylistDetail = plDetail
                state.overlay.ytResults = plDetail.tracks
                state.overlay.cursor = 0
                state.overlay.multiMode = false
                state.overlay.selected = initHashSet[int]()
                state.setFeedback("Playlist: " & plDetail.title & " (" & $plDetail.trackCount & " tracks)")
              else:
                state.setFeedback("Failed to fetch playlist tracks")
            else:
              # Add to search history
              if state.overlay.query.len > 0 and state.overlay.query notin state.ytSearchHistory:
                state.ytSearchHistory.insert(state.overlay.query, 0)
                if state.ytSearchHistory.len > 50:
                  state.ytSearchHistory.setLen(50)
              state.overlay.clear()
              state.ytStreamPendingItem = r
              state.ytStreamActive = startStreamUrlFetch(r.url, state.ytStreamProcess, state.ytCookieSource, state.ytJsRuntime)
              state.ytStreamBuf = ""
              if state.ytStreamActive:
                state.setFeedback("Resolving stream URL...")
      of iw.Key.CtrlD:
        proc addToBothQueues(state: var AppState, items: seq[YtSearchResult]) =
          for item in items:
            state.ytDownloadQueue.add(item)
            let track = Track(
              path: item.url, title: item.title, artist: item.channel,
              album: "YouTube", duration: 0.0,
              id: int64(state.libraryTracks.len + 1)
            )
            state.libraryTracks.add(track)
            state.playbackQueue.add(state.libraryTracks.len - 1)
          state.rebuildItems()
          state.markDirty(ceQueue)
          state.saveQueue()
        if state.overlay.multiMode:
          if state.overlay.selected.len > 0:
            var items: seq[YtSearchResult] = @[]
            for idx in state.overlay.selected:
              if idx >= 0 and idx < state.overlay.ytResults.len:
                items.add(state.overlay.ytResults[idx])
            state.addToBothQueues(items)
            state.showNotification("Queued " & $state.overlay.selected.len & " items")
        elif state.overlay.ytResults.len > 0 and
           state.overlay.cursor >= 0 and state.overlay.cursor < state.overlay.ytResults.len:
          let r = state.overlay.ytResults[state.overlay.cursor]
          state.addToBothQueues(@[r])
          state.showNotification("Queued: " & r.title)
      of iw.Key.Backspace:
        if state.overlay.query.len > 0:
          state.overlay.query = state.overlay.query[0..^2]
          state.ytDebounceAt = epochTime() + 0.25
          state.overlay.ytAutocompleteSuggestions = @[]
          state.overlay.ytAutocompleteVisible = false
      else:
        for ch in chars:
          let code = ch.int
          if code >= 32 and code < 127:
            state.overlay.query &= $ch
            state.ytDebounceAt = epochTime() + 0.25
            # Trigger autocomplete lookup
            checkAutocomplete(state)
    of okYtBatch:
      if state.overlay.batchShowPls:
        case key
        of iw.Key.Escape:
          state.overlay.batchShowPls = false
          state.overlay.cursor = 0
        of iw.Key.J, iw.Key.Down:
          if state.overlay.cursor < state.libraryPlaylists.len - 1:
            state.overlay.cursor.inc
        of iw.Key.K, iw.Key.Up:
          if state.overlay.cursor > 0:
            state.overlay.cursor.dec
        of iw.Key.Enter:
          let plIdx = state.overlay.cursor
          let items = state.overlay.batchItems
          state.overlay.clear()
          if plIdx >= 0 and plIdx < state.libraryPlaylists.len:
            for item in items:
              let track = Track(
                path: item.url, title: item.title, artist: item.channel,
                album: "YouTube", duration: 0.0,
                id: int64(state.libraryTracks.len + 1)
              )
              state.libraryTracks.add(track)
              state.libraryPlaylists[plIdx].trackIds.add(track.id)
            state.rebuildItems()
            state.showNotification("Added " & $items.len & " items to playlist")
        else: discard
      else:
        case key
        of iw.Key.Escape:
          state.overlay.clear()
        of iw.Key.J, iw.Key.Down:
          if state.overlay.cursor < 2: state.overlay.cursor.inc
        of iw.Key.K, iw.Key.Up:
          if state.overlay.cursor > 0: state.overlay.cursor.dec
        of iw.Key.Enter:
          let sel = state.overlay.cursor
          let items = state.overlay.batchItems
          state.overlay.clear()
          case sel
          of 0:
            for item in items:
              if state.ytBatchDownloadMode:
                state.ytDownloadQueue.add(item)
              else:
                let track = Track(
                  path: item.url, title: item.title, artist: item.channel,
                  album: "YouTube", duration: 0.0,
                  id: int64(state.libraryTracks.len + 1)
                )
                state.libraryTracks.add(track)
                state.playbackQueue.add(state.libraryTracks.len - 1)
            state.rebuildItems()
            let mode = if state.ytBatchDownloadMode: "download" else: "queue"
            state.markDirty(ceQueue)
            state.saveQueue()
            state.showNotification("Added " & $items.len & " items to " & mode)
          of 1:
            state.overlay = OverlayState(kind: okYtBatch, batchItems: items, batchShowPls: true)
            if state.libraryPlaylists.len > 0:
              state.overlay.batchShowPls = true
              state.overlay.cursor = 0
            else:
              state.setFeedback("No playlists exist. Create one first.")
          of 2:
            state.overlay = OverlayState(kind: okYtBatch, batchItems: items)
            state.playlistInputActive = true
            state.playlistInputPrompt = "New Playlist Name:"
            state.playlistInputBuffer = ""
          else: discard
        else: discard
    of okQueuePicker:
      case key
      of iw.Key.Escape:
        state.overlay.clear()
      of iw.Key.J, iw.Key.Down:
        if state.overlay.cursor < state.overlay.results.len - 1:
          state.overlay.cursor.inc
      of iw.Key.K, iw.Key.Up:
        if state.overlay.cursor > 0:
          state.overlay.cursor.dec
      of iw.Key.Enter:
        for idx in state.overlay.selected:
          if idx >= 0 and idx < state.libraryTracks.len:
            state.playbackQueue.add(idx)
        state.markDirty(ceQueue)
        state.saveQueue()
        if state.status == psStopped and state.playbackQueue.len > 0:
          state.overlay.clear()
          state.nextTrack()
          return
        state.showNotification("Added " & $state.overlay.selected.len & " tracks to queue")
        state.overlay.clear()
      of iw.Key.Space:
        if state.overlay.results.len > 0 and state.overlay.cursor >= 0 and
           state.overlay.cursor < state.overlay.results.len:
          let idx = state.overlay.results[state.overlay.cursor]
          if idx in state.overlay.selected:
            state.overlay.selected.excl(idx)
          else:
            state.overlay.selected.incl(idx)
      of iw.Key.Backspace:
        if state.overlay.query.len > 0:
          state.overlay.query = state.overlay.query[0..^2]
      else:
        for ch in chars:
          let code = ch.int
          if code >= 32 and code < 127:
            state.overlay.query &= $ch
      state.overlay.results = @[]
      if state.overlay.query.len > 0:
        let q = state.overlay.query.toLowerAscii()
        for i, t in state.libraryTracks:
          if fuzzyMatch(q, t.displayName().toLowerAscii()) or
             fuzzyMatch(q, t.displayArtist().toLowerAscii()):
            state.overlay.results.add(i)
      else:
        for i in 0..<state.libraryTracks.len:
          state.overlay.results.add(i)
      if state.overlay.results.len > 0:
        state.overlay.cursor = min(state.overlay.cursor, state.overlay.results.len - 1)
      else:
        state.overlay.cursor = 0
    of okQueueOverlay:
      case key
      of iw.Key.Escape:
        state.overlay.clear()
      of iw.Key.J, iw.Key.Down:
        if state.overlay.cursor < state.playbackQueue.len - 1:
          state.overlay.cursor.inc
          state.overlay = OverlayState(kind: okQueueOverlay, cursor: state.overlay.cursor)
      of iw.Key.K, iw.Key.Up:
        if state.overlay.cursor > 0:
          state.overlay.cursor.dec
          state.overlay = OverlayState(kind: okQueueOverlay, cursor: state.overlay.cursor)
      of iw.Key.Enter:
        if state.playbackQueue.len > 0 and state.overlay.cursor >= 0 and
           state.overlay.cursor < state.playbackQueue.len:
          let qIdx = state.overlay.cursor
          let tIdx = state.playbackQueue[qIdx]
          state.overlay.clear()
          if tIdx >= 0 and tIdx < state.libraryTracks.len:
            let track = state.libraryTracks[tIdx]
            state.playbackQueue.delete(qIdx)
            if state.queueCursor >= qIdx and state.queueCursor > 0:
              state.queueCursor.dec
            state.ytStreamTitle = ""
            state.ytStreamChannel = ""
            state.ytStreamDuration = ""
            state.player.loadFile(track.path)
            state.player.play()
            state.status = psPlaying
            state.currentPlayingPath = track.path
            state.currentPlayingId = track.id
            state.markDirtyBatch(cePlayState, ceTrack, ceQueue)
            if state.duration == 0.0 and track.duration > 0:
              state.duration = track.duration
      of iw.Key.D:
        if state.playbackQueue.len > 0 and state.overlay.cursor >= 0 and
           state.overlay.cursor < state.playbackQueue.len:
          let qIdx = state.overlay.cursor
          let t = state.libraryTracks[state.playbackQueue[qIdx]]
          state.showNotification("Removed '" & t.displayName() & "' from queue")
          state.playbackQueue.delete(qIdx)
          state.queueCursor = min(state.queueCursor, state.playbackQueue.len - 1)
          if state.playbackQueue.len == 0:
            state.overlay.clear()
          else:
            state.overlay = OverlayState(kind: okQueueOverlay, cursor: min(state.overlay.cursor, state.playbackQueue.len - 1))
      else: discard
    of okPlaylistSearch:
      case key
      of iw.Key.Escape:
        state.overlay.clear()
      of iw.Key.J, iw.Key.Down:
        if state.overlay.cursor < state.overlay.results.len - 1:
          state.overlay.cursor.inc
      of iw.Key.K, iw.Key.Up:
        if state.overlay.cursor > 0:
          state.overlay.cursor.dec
      of iw.Key.Enter:
        if state.overlay.results.len > 0 and state.overlay.cursor >= 0 and
           state.overlay.cursor < state.overlay.results.len:
          let idx = state.overlay.results[state.overlay.cursor]
          if idx in state.overlay.selected:
            state.overlay.selected.excl(idx)
          else:
            state.overlay.selected.incl(idx)
      of iw.Key.Backspace:
        if state.overlay.query.len > 0:
          state.overlay.query = state.overlay.query[0..^2]
      of iw.Key.A:
        if state.overlay.plMode == 1 and state.overlay.selected.len > 0:
          let plIdx = state.playlistContentsIdx
          if plIdx >= 0 and plIdx < state.libraryPlaylists.len:
            for idx in state.overlay.selected:
              if idx >= 0 and idx < state.libraryTracks.len:
                let track = state.libraryTracks[idx]
                if track.id notin state.libraryPlaylists[plIdx].trackIds:
                  state.libraryPlaylists[plIdx].trackIds.add(track.id)
                  if state.player of DaemonClient:
                    discard DaemonClient(state.player).addToPlaylist(state.libraryPlaylists[plIdx].id, track.id, state.libraryPlaylists[plIdx].trackIds.len - 1)
            state.rebuildItems()
          state.overlay.clear()
      of iw.Key.X:
        if state.overlay.plMode == 2 and state.overlay.selected.len > 0:
          let plIdx = state.playlistContentsIdx
          if plIdx >= 0 and plIdx < state.libraryPlaylists.len:
            for idx in state.overlay.selected:
              if idx >= 0 and idx < state.libraryTracks.len:
                let trackId = state.libraryTracks[idx].id
                let removeIdx = state.libraryPlaylists[plIdx].trackIds.find(trackId)
                if removeIdx >= 0:
                  state.libraryPlaylists[plIdx].trackIds.delete(removeIdx)
                  if state.player of DaemonClient:
                    discard DaemonClient(state.player).removeFromPlaylist(state.libraryPlaylists[plIdx].id, trackId)
            state.rebuildItems()
          state.overlay.clear()
      else:
        for ch in chars:
          let code = ch.int
          if code >= 32 and code < 127:
            state.overlay.query &= $ch
      state.overlay.results = @[]
      if state.overlay.query.len > 0:
        let q = state.overlay.query.toLowerAscii()
        for i, t in state.libraryTracks:
          if fuzzyMatch(q, t.displayName().toLowerAscii()) or
             fuzzyMatch(q, t.displayArtist().toLowerAscii()):
            state.overlay.results.add(i)
      else:
        for i in 0..<state.libraryTracks.len:
          state.overlay.results.add(i)
      if state.overlay.results.len > 0:
        state.overlay.cursor = min(state.overlay.cursor, state.overlay.results.len - 1)
      else:
        state.overlay.cursor = 0
    of okCommandPalette:
      case key
      of iw.Key.Escape:
        state.overlay.clear()
      of iw.Key.Enter:
        if state.overlay.results.len > 0 and state.overlay.cursor >= 0 and
           state.overlay.cursor < state.overlay.results.len:
          let cmdIdx = state.overlay.results[state.overlay.cursor]
          if cmdIdx >= 0 and cmdIdx < state.commands.len:
            let cmdId = state.commands[cmdIdx].id
            state.overlay.clear()
            execCmd(state, cmdId)
            return
        state.overlay.clear()
      of iw.Key.Slash:
        state.overlay.query = ""
      of iw.Key.J, iw.Key.Down:
        state.overlay.cursor = (state.overlay.cursor + 1) mod max(state.overlay.results.len, 1)
      of iw.Key.K, iw.Key.Up:
        state.overlay.cursor = (state.overlay.cursor - 1 + state.overlay.results.len) mod max(state.overlay.results.len, 1)
      of iw.Key.Backspace:
        if state.overlay.query.len > 0:
          state.overlay.query = state.overlay.query[0..^2]
      else:
        for ch in chars:
          let code = ch.int
          if code >= 32 and code < 127:
            state.overlay.query &= $ch
      if state.overlay.query.len > 0:
        state.overlay.results = @[]
        for i, cmd in state.commands:
          if fuzzyMatch(state.overlay.query, cmd.name) or
             fuzzyMatch(state.overlay.query, cmd.description):
            state.overlay.results.add(i)
        state.overlay.cursor = 0
      elif true:
        state.overlay.results = @[]
        for i in 0..<state.commands.len:
          state.overlay.results.add(i)
    of okNone:
      discard
    return
  const sidebarScopes = [fsAll, fsArtists, fsAlbums, fsPlaylists, fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed]
  if state.tab == tabLibrary and state.libraryFocusPanel == lpSidebar and state.mode == imNormal:
    case key
    of iw.Key.J, iw.Key.Down:
      state.librarySidebarSelect = min(sidebarScopes.high, state.librarySidebarSelect + 1)
      state.filterScope = sidebarScopes[state.librarySidebarSelect]
      state.selectIndex = 0
      state.rebuildItems()
      state.markDirty(ceSearchResults)
      state.needsRedraw = true; return
    of iw.Key.K, iw.Key.Up:
      state.librarySidebarSelect = max(0, state.librarySidebarSelect - 1)
      state.filterScope = sidebarScopes[state.librarySidebarSelect]
      state.selectIndex = 0
      state.rebuildItems()
      state.markDirty(ceSearchResults)
      state.needsRedraw = true; return
    of iw.Key.Enter, iw.Key.L, iw.Key.Right:
      state.filterScope = sidebarScopes[state.librarySidebarSelect]
      state.selectIndex = 0
      state.libraryFocusPanel = lpContent
      state.playlistContentsIdx = -1
      state.rebuildItems()
      state.needsRedraw = true; return
    of iw.Key.H, iw.Key.Left, iw.Key.Escape, iw.Key.Tab:
      state.libraryFocusPanel = lpContent
      state.needsRedraw = true; return
    else: discard
  case state.mode
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
      if state.tab == tabLibrary:
        const scopes = ord(high(FilterScope)) + 1
        state.filterScope = FilterScope((state.filterScope.ord - 1 + scopes) mod scopes)
        state.selectIndex = 0; state.rebuildItems()
      elif state.isPlaylistView():
        if state.playlistContentsIdx >= 0:
          state.playlistContentsIdx = -1
          state.selectIndex = 0
          state.rebuildItems()
          state.setFeedback("[Playlist Up]")
      else:
        state.adjustVolume(-5)
      state.mode = imNormal
    of iw.Key.L:
      if state.tab == tabLibrary:
        const scopes = ord(high(FilterScope)) + 1
        state.filterScope = FilterScope((state.filterScope.ord + 1) mod scopes)
        state.selectIndex = 0; state.rebuildItems()
      elif state.isPlaylistView():
        if state.playlistContentsIdx < 0:
          let item = state.selectedItem()
          if item.kind == likPlaylist:
            let plIdx = state.selectIndex
            if plIdx >= 0 and plIdx < state.libraryPlaylists.len and state.libraryPlaylists[plIdx].trackIds.len == 0:
              state.mode = imNormal
              return
            state.playlistContentsIdx = state.selectIndex
            state.selectIndex = 0
            state.rebuildItems()
            state.setFeedback("[Playlist Down]")
      else:
        state.adjustVolume(5)
      state.mode = imNormal
    of iw.Key.Enter:
      if state.selectedIndices.len > 0:
        state.playSelected()
      state.mode = imNormal
    of iw.Key.ShiftX:
      state.removeSelected()
      state.mode = imNormal
    of iw.Key.V:
      state.toggleSelect()
      state.mode = imNormal
    of iw.Key.ShiftV:
      state.selectAll()
      state.mode = imNormal
    of iw.Key.ShiftA:
      execCmd(state, "add_to_playlist")
      state.mode = imNormal
    of iw.Key.Slash:
      state.mode = imFilter
      state.filterText = ""
      state.filteredIndices = @[]
    of iw.Key.A:
      if state.isPlaylistView() and state.playlistContentsIdx < 0:
        execCmd(state, "create_playlist")
      state.mode = imNormal
    of iw.Key.D:
      if state.isPlaylistView() and state.playlistContentsIdx < 0:
        execCmd(state, "delete_playlist")
      state.mode = imNormal
    of iw.Key.R:
      if state.isPlaylistView() and state.playlistContentsIdx < 0:
        execCmd(state, "rename_playlist")
      state.mode = imNormal
    of iw.Key.J, iw.Key.Down:
      state.moveSelection(1)
      state.mode = imNormal
    of iw.Key.K, iw.Key.Up:
      state.moveSelection(-1)
      state.mode = imNormal
    of iw.Key.One: state.tab = tabNowPlaying; state.rebuildItems(); state.mode = imNormal
    of iw.Key.Two: state.tab = tabLibrary; state.rebuildItems(); state.mode = imNormal
    of iw.Key.Three: state.tab = tabSettings; state.rebuildItems(); state.mode = imNormal
    of iw.Key.Comma: state.player.seek(-5.0); state.setFeedback("[Seeking -5s]"); state.mode = imNormal
    of iw.Key.Dot: state.player.seek(5.0); state.setFeedback("[Seeking +5s]"); state.mode = imNormal
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
      state.applyFilter()
    of iw.Key.Enter:
      state.mode = imNormal
      if state.filteredCount() > 0 and state.selectIndex >= 0:
        state.playSelected()
    of iw.Key.Backspace:
      if state.filterText.len > 0:
        state.filterText = state.filterText[0..^2]
        state.applyFilter()
    else:
      for ch in chars:
        let code = ch.int
        if code >= 32 and code < 127:
          state.filterText &= $ch
          state.applyFilter()
    return
  of imNormal:
    discard

  if state.queuePendingConfirm != 0:
    if key == iw.Key.Y:
      if state.queuePendingConfirm == 1:
        if state.queueCursor < state.playbackQueue.len:
          state.playbackQueue.delete(state.queueCursor)
          if state.queueCursor >= state.playbackQueue.len and state.queueCursor > 0:
            state.queueCursor.dec
      elif state.queuePendingConfirm == 2:
        state.playbackQueue = @[]
        state.queueCursor = 0
    state.queuePendingConfirm = 0
    state.markDirty(ceQueue)
    state.setFeedback("")
    return

  case key
  of iw.Key.Colon:
    state.overlay = OverlayState(kind: okCommandPalette, query: "")
    for i in 0..<state.commands.len: state.overlay.results.add(i)
  of iw.Key.Space:
    if state.selectMode:
      state.toggleSelect()
    elif state.status == psPlaying or state.status == psPaused:
      state.player.togglePause()
    else:
      state.playSelected()
  of iw.Key.CtrlL:
    state.mode = imLeaderMode
  of iw.Key.Tab:
    if state.tab == tabLibrary:
      if state.libraryFocusPanel == lpContent: state.libraryFocusPanel = lpSidebar
      else: state.libraryFocusPanel = lpContent
      state.needsRedraw = true
    elif state.tab == tabSettings:
      if state.settingsFocusPanel == lpContent: state.settingsFocusPanel = lpSidebar
      else: state.settingsFocusPanel = lpContent
      state.selectIndex = 0
      state.needsRedraw = true
  of iw.Key.CtrlS:
    state.player.stop(); state.status = psStopped
    state.markDirty(cePlayState)
  of iw.Key.CtrlN: state.nextTrack()
  of iw.Key.CtrlP: state.prevTrack()
  of iw.Key.CtrlU: state.adjustVolume(5); state.showVolumeCue()
  of iw.Key.CtrlD: state.adjustVolume(-5); state.showVolumeCue()

  of iw.Key.CtrlJ: state.moveSelection(1)
  of iw.Key.CtrlK: state.moveSelection(-1)
  of iw.Key.CtrlG: state.goToFirst()
  of iw.Key.CtrlF:
    state.mode = imFilter; state.filterText = ""; state.filteredIndices = @[]
  of iw.Key.CtrlR:
    execCmd(state, "yt_recommended")
  of iw.Key.CtrlV:
    state.toggleVisualizer()
    state.markDirty(ceSettings)
  of iw.Key.AltY:
    state.overlay = OverlayState(kind: okYtSearch, query: "")
    state.ytDebounceAt = 0
  of iw.Key.AltC:
    state.overlay = OverlayState(kind: okThemePicker, query: "")
    state.updateThemePickerResults()
  of iw.Key.AltE:
    state.eqVisible = not state.eqVisible
    state.markDirty(ceSettings)
  of iw.Key.AltQ:
    state.overlay = OverlayState(kind: okQueueOverlay, query: "", cursor: state.queueCursor)
  of iw.Key.AltP:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "create_playlist")
  of iw.Key.AltD:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "delete_playlist")
    elif state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      let t = state.libraryTracks[state.playbackQueue[state.queueCursor]]
      state.setFeedback("Remove '" & t.displayName() & "' from queue? (y/N)")
      state.queuePendingConfirm = 1
  of iw.Key.AltR:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "rename_playlist")
  of iw.Key.J, iw.Key.Down:
    if state.tab == tabNowPlaying and state.overlay.kind == okNone:
      if state.playbackQueue.len > 0:
        if state.queueCursor < state.playbackQueue.len - 1: state.queueCursor.inc
      else:
        state.setFeedback("Queue is empty — press i to add tracks")
    else: state.moveSelection(1)
  of iw.Key.K, iw.Key.Up:
    if state.tab == tabNowPlaying and state.overlay.kind == okNone:
      if state.playbackQueue.len > 0:
        if state.queueCursor > 0: state.queueCursor.dec
      else:
        state.setFeedback("Queue is empty — press i to add tracks")
    else: state.moveSelection(-1)
  of iw.Key.Enter:
    if state.isPlaylistView():
      if state.playlistContentsIdx >= 0:
        state.playSelected()
      else:
        let plIdx = state.selectIndex
        if plIdx >= 0 and plIdx < state.libraryPlaylists.len:
          if state.libraryPlaylists[plIdx].trackIds.len == 0: return
          state.playlistContentsIdx = plIdx
          state.selectIndex = 0
          state.rebuildItems()
    elif state.tab == tabSettings:
      # Enter: open/activate actions only
      case state.settingsCategory
      of scAudio:
        case state.selectIndex
        of 3: # Daemon status (refresh)
          state.daemonConnected = state.player of DaemonClient and DaemonClient(state.player).connected
        else: discard
      of scYouTube:
        case state.selectIndex
        of 0: # Cookie Source
          state.ytCookieSource = detectBrowserCookieSource()
          if state.ytCookieSource.len == 0:
            state.setFeedback("No browser cookie database found — install Firefox and sign in to YouTube")
          else:
            state.showNotification("Detected cookies: " & state.ytCookieSource)
          state.saveConfig()
        of 1: # JS Runtime
          const runtimes2 = ["node", "bun", "deno"]
          var i = 0
          for idx, r in runtimes2:
            if r == state.ytJsRuntime:
              i = (idx + 1) mod runtimes2.len
              break
          state.ytJsRuntime = runtimes2[i]
          state.saveConfig()
        of 4: # Search History (view)
          state.setFeedback("Search history: " & $state.ytSearchHistory.len & " entries")
        of 6: # Clear Search History
          state.ytSearchHistory = @[]
          state.saveConfig()
          state.showNotification("Search history cleared")
        else: discard
      of scAppearance:
        case state.selectIndex
        of 0: # Theme
          state.overlay = OverlayState(kind: okThemePicker, query: "")
          state.updateThemePickerResults()
        else: discard
      of scSystem:
        case state.selectIndex
        of 1: # Reset All
          state.config.theme = "mocha"
          state.theme = getTheme("mocha")
          state.volume = 80
          state.vizVisible = true
          state.config.refreshTheme = false
          state.player.setVolume(80)
          state.shuffleEnabled = false
          state.repeatMode = 0
          state.sleepTimerRemaining = 0
          state.sleepTimerFrames = 0
          state.ytMaxConcurrentDownloads = 4
          state.ytBatchDownloadMode = false
          state.ytJsRuntime = "node"
          state.mode = imNormal
          state.selectIndex = 0
          state.playlistContentsIdx = -1
          state.filterText = ""
          state.filterScope = fsAll
          state.saveConfig()
          state.showVolumeCue()
        else: discard
      state.rebuildItems()
      state.markDirty(ceSettings)
    else:
      state.playSelected()
  of iw.Key.S: state.player.stop(); state.status = psStopped
  of iw.Key.Y:
    state.overlay = OverlayState(kind: okYtSearch, query: "")
    state.ytDebounceAt = 0
  of iw.Key.I:
    state.overlay = OverlayState(kind: okQueuePicker, query: "")
    for i in 0..<state.libraryTracks.len: state.overlay.results.add(i)
  of iw.Key.H:
    if state.tab == tabLibrary:
      const sbar = [fsAll, fsArtists, fsAlbums, fsPlaylists, fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed]
      state.filterScope = sbar[(state.librarySidebarSelect - 1 + sbar.len) mod sbar.len]
      state.librarySidebarSelect = (state.librarySidebarSelect - 1 + sbar.len) mod sbar.len
      state.selectIndex = 0; state.rebuildItems()
    elif state.isPlaylistView():
      if state.playlistContentsIdx >= 0:
        state.playlistContentsIdx = -1
        state.selectIndex = 0
        state.rebuildItems()
        state.setFeedback("[Playlist Up]")
  of iw.Key.L:
    if state.tab == tabLibrary:
      const sbar = [fsAll, fsArtists, fsAlbums, fsPlaylists, fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed]
      state.filterScope = sbar[(state.librarySidebarSelect + 1) mod sbar.len]
      state.librarySidebarSelect = (state.librarySidebarSelect + 1) mod sbar.len
      state.selectIndex = 0; state.rebuildItems()
    elif state.isPlaylistView():
      if state.playlistContentsIdx < 0:
        let item = state.selectedItem()
        if item.kind == likPlaylist:
          let plIdx = state.selectIndex
          if plIdx >= 0 and plIdx < state.libraryPlaylists.len and state.libraryPlaylists[plIdx].trackIds.len == 0:
            return
          state.playlistContentsIdx = state.selectIndex
          state.selectIndex = 0
          state.rebuildItems()
          state.setFeedback("[Playlist Down]")
  of iw.Key.Comma: state.player.seek(-5.0); state.setFeedback("[Seeking -5s]")
  of iw.Key.Dot: state.player.seek(5.0); state.setFeedback("[Seeking +5s]")
  of iw.Key.Left:
    if state.tab == tabSettings:
      if state.settingsFocusPanel == lpContent:
        state.adjustSetting(-1)
      elif state.settingsFocusPanel == lpSidebar:
        state.settingsFocusPanel = lpContent
        state.selectIndex = 0
        state.needsRedraw = true
    elif state.tab == tabLibrary:
      if state.libraryFocusPanel == lpContent:
        state.libraryFocusPanel = lpSidebar
    elif state.isPlaylistView():
      if state.playlistContentsIdx >= 0:
        state.playlistContentsIdx = -1
        state.selectIndex = 0
        state.rebuildItems()
  of iw.Key.Right:
    if state.tab == tabSettings:
      if state.settingsFocusPanel == lpContent:
        state.adjustSetting(1)
      elif state.settingsFocusPanel == lpSidebar:
        state.settingsFocusPanel = lpContent
        state.selectIndex = 0
        state.needsRedraw = true
    elif state.tab == tabLibrary:
      if state.libraryFocusPanel == lpSidebar:
        const scopeMap2 = [fsAll, fsArtists, fsAlbums, fsPlaylists, fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed]
        state.filterScope = scopeMap2[state.librarySidebarSelect]
        state.libraryFocusPanel = lpContent
        state.selectIndex = 0
        state.rebuildItems()
    elif state.isPlaylistView():
      if state.playlistContentsIdx < 0:
        let item = state.selectedItem()
        if item.kind == likPlaylist:
          let plIdx = state.selectIndex
          if plIdx >= 0 and plIdx < state.libraryPlaylists.len and state.libraryPlaylists[plIdx].trackIds.len == 0:
            return
          state.playlistContentsIdx = state.selectIndex
          state.selectIndex = 0
          state.rebuildItems()
  of iw.Key.N: state.nextTrack()
  of iw.Key.P: state.prevTrack()
  of iw.Key.ShiftJ: state.adjustVolume(5)
  of iw.Key.ShiftK: state.adjustVolume(-5)
  of iw.Key.Plus, iw.Key.Equals: state.adjustVolume(5)
  of iw.Key.Minus, iw.Key.Underscore: state.adjustVolume(-5)
  of iw.Key.M: state.toggleMute()
  of iw.Key.G:
    if state.addingToPlaylistId >= 0:
      state.addTracksToPl(state.addingToPlaylistId)
    elif state.pendingSeq.len == 0:
      state.pendingSeq = @[key]
      state.pendingSeqTimer = 30
    elif state.pendingSeq == @[iw.Key.G] and key == iw.Key.G:
      state.pendingSeq = @[]
      state.pendingSeqTimer = 0
      state.goToFirst()
    else:
      state.pendingSeq = @[]
      state.pendingSeqTimer = 0
  of iw.Key.ShiftG:
    state.goToLast()
    state.pendingSeq = @[]
    state.pendingSeqTimer = 0
    state.playSelected()
  of iw.Key.A:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "create_playlist")
  of iw.Key.ShiftA:
    if state.isPlaylistView() and state.playlistContentsIdx >= 0:
      state.overlay = OverlayState(kind: okPlaylistSearch, query: "", plMode: 1)
      for i in 0..<state.libraryTracks.len:
        state.overlay.results.add(i)
    else:
      state.aboutVisible = true
  of iw.Key.D:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "delete_playlist")
    elif state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      let t = state.libraryTracks[state.playbackQueue[state.queueCursor]]
      state.setFeedback("Remove '" & t.displayName() & "' from queue? (y/N)")
      state.queuePendingConfirm = 1
  of iw.Key.ShiftD:
    if state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      state.setFeedback("Clear entire queue? (y/N)")
      state.queuePendingConfirm = 2
  of iw.Key.R:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "rename_playlist")
  of iw.Key.ShiftS:
    state.toggleShuffle()
  of iw.Key.ShiftR:
    state.cycleRepeat()
  of iw.Key.Slash:
    state.mode = imFilter
    if state.tab == tabLibrary:
      state.libraryFocusPanel = lpContent
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
  of iw.Key.One: state.tab = tabNowPlaying; state.rebuildItems()
  of iw.Key.Two: state.tab = tabLibrary; state.rebuildItems()
  of iw.Key.Three: state.tab = tabSettings; state.rebuildItems()
  of iw.Key.ShiftQ: state.quitDaemon()
  of iw.Key.ShiftX:
    if state.isPlaylistView() and state.playlistContentsIdx >= 0:
      state.overlay = OverlayState(kind: okPlaylistSearch, query: "", plMode: 2)
      for i in 0..<state.libraryTracks.len:
        state.overlay.results.add(i)
  of iw.Key.F:
    execCmd(state, "toggle_favourite")
  of iw.Key.T:
    state.overlay = OverlayState(kind: okThemePicker, query: "")
    state.updateThemePickerResults()
  of iw.Key.Q:
    quitBackground(state)
  of iw.Key.Escape:
    if state.addingToPlaylistId >= 0:
      state.addingToPlaylistId = -1
      state.addingToPlaylistName = ""
      state.selectedIndices = initHashSet[int]()
      state.selectMode = false
      state.tab = tabLibrary
      state.filterScope = fsPlaylists
      state.rebuildItems()
    elif state.playlistContentsIdx >= 0:
      state.playlistContentsIdx = -1
      state.selectIndex = 0
      state.rebuildItems()
  else: discard

proc getNextTrackInfo(state: var AppState): tuple[path: string, id: int64] =
  let items = state.displayItems
  if state.playbackQueue.len > 0:
    let tIdx = state.playbackQueue[0]
    if tIdx >= 0 and tIdx < state.libraryTracks.len:
      return (state.libraryTracks[tIdx].path, state.libraryTracks[tIdx].id)
    return ("", 0)
  if items.len == 0: return ("", 0)
  var idx: int
  if state.shuffleEnabled and state.shuffleOrder.len > 0:
    let si = (state.shuffleIndex + 1) mod state.shuffleOrder.len
    idx = state.shuffleOrder[si]
  elif state.repeatMode == 2:
    idx = state.selectIndex
  else:
    idx = state.selectIndex + 1
    if idx >= items.len:
      if state.repeatMode != 1:
        return ("", 0)
      idx = 0
  if idx >= 0 and idx < items.len:
    let track = state.libraryTracks[items[idx].trackIdx]
    return (track.path, track.id)
  return ("", 0)

proc parseDurationToSec*(dur: string): float =
  let parts = dur.split(':')
  if parts.len == 2:
    try: result = parts[0].parseInt.float * 60 + parts[1].parseInt.float except: result = 0.0
  elif parts.len == 3:
    try: result = parts[0].parseInt.float * 3600 + parts[1].parseInt.float * 60 + parts[2].parseInt.float except: result = 0.0

proc processEvents(state: var AppState) =
  let events = state.player.pollEvents()
  if state.player of DaemonClient:
    state.audioAvailable = DaemonClient(state.player).working
  var gotPosition = false
  var crossfadeEnded = false
  for ev in events:
    case ev.kind
    of aekPositionChanged:
      state.timePos = ev.floatVal
      gotPosition = true
      state.markDirty(cePosition)
    of aekDurationChanged:
      state.duration = ev.floatVal
      state.markDirty(ceTrack)
    of aekVolumeChanged:
      state.volume = ev.intVal
      state.markDirty(ceVolume)
    of aekPlaybackStarted:
      state.status = psPlaying
      state.crossfadePrepared = false
      state.crossfadeStarted = false
      state.earlyPreloaded = false
      state.crossfadeNextPath = ""
      # Resume software timer for YouTube streams
      if state.ytPlaybackStartTime > 0 and state.ytPauseStartTime > 0:
        state.ytPauseDuration += epochTime() - state.ytPauseStartTime
        state.ytPauseStartTime = 0.0
      elif state.ytPlaybackStartTime == 0 and state.ytStreamTitle.len > 0:
        state.ytPlaybackStartTime = epochTime()
      # Increment play count for the in-memory track
      if state.currentPlayingId > 0:
        for i in 0..<state.libraryTracks.len:
          if state.libraryTracks[i].id == state.currentPlayingId:
            state.libraryTracks[i].playCount.inc
            state.libraryTracks[i].lastPlayed = now().format("yyyy-MM-dd HH:mm:ss")
            break
      # Song change notification when not on Now Playing tab
      if state.tab != tabNowPlaying:
        if state.currentPlayingId > 0:
          for i in 0..<state.libraryTracks.len:
            if state.libraryTracks[i].id == state.currentPlayingId:
              let t = state.libraryTracks[i]
              let msg = "Now Playing: " & t.title & (if t.artist.len > 0: " — " & t.artist else: "")
              state.nowPlayingCueMsg = msg
              state.nowPlayingCueTimer = 150
              break
        elif state.ytStreamTitle.len > 0:
          state.nowPlayingCueMsg = "Now Playing: " & state.ytStreamTitle
          state.nowPlayingCueTimer = 150
      state.markDirtyBatch(cePlayState, ceTrack)
    of aekPlaybackPaused:
      state.status = psPaused
      state.markDirty(cePlayState)
      if state.viz != nil: state.viz.clear()
      if state.ytPlaybackStartTime > 0 and state.ytPauseStartTime == 0:
        state.ytPauseStartTime = epochTime()
    of aekPlaybackStopped:
      state.status = psStopped
      state.ytStreamUrl = ""
      state.ytPlaybackStartTime = 0.0
      state.ytPauseDuration = 0.0
      state.ytPauseStartTime = 0.0
      state.markDirty(cePlayState)
    of aekTrackEnded:
      if state.crossfadeStarted:
        crossfadeEnded = true
      else:
        # Auto-download YouTube stream on completion
        if state.ytStreamTitle.len > 0 and state.ytStreamUrl.len > 0:
          var alreadyQueued = false
          if state.ytDownloaded.hasKey(state.ytStreamUrl):
            alreadyQueued = true
          for q in state.ytDownloadQueue:
            if q.url == state.ytStreamUrl:
              alreadyQueued = true
              break
          for t in state.ytDownloadTasks:
            if t.url == state.ytStreamUrl:
              alreadyQueued = true
              break
          if not alreadyQueued:
            state.ytDownloadQueue.add(YtSearchResult(
              title: state.ytStreamTitle,
              url: state.ytStreamUrl,
              duration: state.ytStreamDuration,
              channel: state.ytStreamChannel
            ))
            state.showNotification("Auto-downloading: " & state.ytStreamTitle)
        if state.sleepTimerRemaining > 0:
          state.player.stop()
          state.status = psStopped
          state.sleepTimerRemaining = 0
        elif state.playbackQueue.len > 0:
          state.nextTrack()
        else:
          state.player.stop()
          state.status = psStopped
          state.nextTrack()
        state.ytPlaybackStartTime = 0.0
        state.ytPauseDuration = 0.0
        state.ytPauseStartTime = 0.0
        state.markDirtyBatch(cePlayState, ceQueue)
    else: discard
  if crossfadeEnded:
    state.ytStreamTitle = ""
    state.ytStreamChannel = ""
    state.ytStreamDuration = ""
    state.crossfadeStarted = false
    state.crossfadePrepared = false
    state.earlyPreloaded = false
    # Advance queue/selection to match daemon's auto-advanced playback
    if state.playbackQueue.len > 0:
      let tIdx = state.playbackQueue[0]
      state.playbackQueue.delete(0)
      if state.queueCursor > 0: state.queueCursor.dec
      state.markDirty(ceQueue)
      if tIdx >= 0 and tIdx < state.libraryTracks.len:
        state.currentPlayingPath = state.libraryTracks[tIdx].path
        state.currentPlayingId = state.libraryTracks[tIdx].id
        state.selectIndex = tIdx
        if state.duration > 0:
          state.timePos = 0.0
        state.markDirty(ceTrack)
    else:
      let items = state.displayItems
      if items.len > 0:
        var nextIdx = state.selectIndex + 1
        if nextIdx >= items.len:
          if state.repeatMode == 1:
            nextIdx = 0
          else:
            nextIdx = state.selectIndex
        if state.shuffleEnabled and state.shuffleOrder.len > 0:
          state.shuffleIndex = (state.shuffleIndex + 1) mod state.shuffleOrder.len
          nextIdx = state.shuffleOrder[state.shuffleIndex]
        state.selectIndex = nextIdx
        if nextIdx >= 0 and nextIdx < items.len:
          let track = state.libraryTracks[items[nextIdx].trackIdx]
          state.currentPlayingPath = track.path
          state.currentPlayingId = track.id
        state.markDirty(ceTrack)
  if not gotPosition and state.status == psPlaying:
    # Software timer fallback for YouTube streams (FFmpeg can't track HTTP stream position)
    if state.ytPlaybackStartTime > 0 and state.ytDurationSec > 0:
      let elapsed = epochTime() - state.ytPlaybackStartTime - state.ytPauseDuration
      let newTime = max(0.0, min(elapsed, state.ytDurationSec))
      if abs(newTime - state.timePos) > 0.5:
        state.timePos = newTime
        state.markDirty(cePosition)
    elif state.player.timePos != state.timePos:
      state.timePos = state.player.timePos
      state.markDirty(cePosition)
  if state.duration == 0.0 and state.player.duration > 0.0:
    state.duration = state.player.duration
  # Crossfade scheduling
  if state.status == psPlaying and state.duration > 0 and state.player.backendType == abtDaemon:
    let remaining = state.duration - state.timePos
    if remaining <= 0:
      state.earlyPreloaded = false
    # Phase 0: Early preload (90s before end)
    if not state.earlyPreloaded and remaining <= 90.0 and remaining > state.crossfadeDuration.float + 2.0:
      let nextInfo = state.getNextTrackInfo()
      if nextInfo.path.len > 0:
        state.player.prepareNext(nextInfo.path)
        state.earlyPreloaded = true
        state.crossfadeNextPath = nextInfo.path
        state.crossfadeNextId = nextInfo.id
    # Phase 1: Crossfade prepare (when close enough)
    if state.crossfadeDuration > 0 and not state.crossfadePrepared and remaining <= state.crossfadeDuration.float + 2.0 and remaining > 0:
      if not state.earlyPreloaded:
        let nextInfo = state.getNextTrackInfo()
        if nextInfo.path.len > 0:
          state.player.prepareNext(nextInfo.path)
          state.crossfadeNextPath = nextInfo.path
          state.crossfadeNextId = nextInfo.id
      state.crossfadePrepared = true
    # Phase 2: Start crossfade
    if state.crossfadeDuration > 0 and state.crossfadePrepared and not state.crossfadeStarted and remaining <= state.crossfadeDuration.float and remaining > 0:
      state.player.startCrossfade(state.crossfadeDuration.float)
      state.crossfadeStarted = true

proc fullStateSync(state: var AppState, daemonState: JsonNode) =
  if daemonState.hasKey("state"):
    let s = daemonState["state"].getStr()
    state.status = if s == "playing": psPlaying elif s == "paused": psPaused else: psStopped
  if daemonState.hasKey("track_path"):
    state.currentPlayingPath = daemonState["track_path"].getStr("")
  state.ytStreamTitle = ""
  state.ytStreamChannel = ""
  state.ytStreamDuration = ""
  state.ytStreamUrl = ""
  if daemonState.hasKey("track_title"):
    state.ytStreamTitle = daemonState["track_title"].getStr("")
  if daemonState.hasKey("track_channel"):
    state.ytStreamChannel = daemonState["track_channel"].getStr("")
  if daemonState.hasKey("track_album"):
    if state.ytStreamChannel.len == 0:
      state.ytStreamChannel = daemonState["track_album"].getStr("")
  if daemonState.hasKey("time_pos"):
    state.timePos = max(0.0, daemonState["time_pos"].getFloat(0.0))
  if state.ytStreamTitle.len > 0:
    if daemonState.hasKey("duration"):
      state.ytDurationSec = max(0.0, daemonState["duration"].getFloat(0.0))
    state.ytPlaybackStartTime = epochTime()
    state.ytPauseDuration = state.timePos
    state.ytPauseStartTime = 0.0
  else:
    state.ytPlaybackStartTime = 0.0
    state.ytPauseDuration = 0.0
    state.ytPauseStartTime = 0.0
  if daemonState.hasKey("duration"):
    state.duration = max(0.0, daemonState["duration"].getFloat(0.0))
  if daemonState.hasKey("volume"):
    state.volume = daemonState["volume"].getInt(80)
  if daemonState.hasKey("shuffle"):
    state.shuffleEnabled = daemonState["shuffle"].getBool(false)
  if daemonState.hasKey("repeat"):
    state.repeatMode = daemonState["repeat"].getInt(0)
  if daemonState.hasKey("sleep_timer"):
    state.sleepTimerRemaining = daemonState["sleep_timer"].getInt(0)
  if daemonState.hasKey("crossfading"):
    state.crossfading = daemonState["crossfading"].getBool(false)
  if daemonState.hasKey("master_ended"):
    state.masterEnded = daemonState["master_ended"].getBool(false)
  state.crossfadeStarted = false
  state.crossfadePrepared = false
  state.earlyPreloaded = false

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
  ctx.data.loadPlaylists()
  ctx.data.audioAvailable = dClient.working
  initApp(ctx.data)
  ctx.data.loadConfig()
  if ctx.data.ytCookieSource.len == 0:
    ctx.data.ytCookieSource = detectBrowserCookieSource()
  if dClient.connected:
    let daemonState = dClient.getDaemonState()
    fullStateSync(ctx.data, daemonState)
  ctx.data.loadQueue()
  ctx.data.player.setVolume(ctx.data.volume)
  ctx.data.initCommands()
  ctx.data.applyKeybindings()
  ctx.data.loadLibrary()
  ctx.data.buildPlaylistFromArgs(args)
  ctx.data.rebuildItems()
  if dClient.connected and ctx.data.currentPlayingPath.len > 0:
    for i, t in ctx.data.libraryTracks:
      if t.path == ctx.data.currentPlayingPath:
        ctx.data.selectIndex = i
        break
    if ctx.data.status == psPlaying or ctx.data.status == psPaused:
      ctx.data.setFeedback("[Resumed playback]")
  if args.len > 0:
    ctx.data.selectIndex = 0
    ctx.data.playSelected()
  if ctx.data.viz != nil and ctx.data.player of DaemonClient:
    ctx.data.viz.startCapture()
  var prevTb: iw.TerminalBuffer
  var tbReady: bool
  var mouseInfo: iw.MouseInfo
  var oldStatus = ctx.data.status
  var oldTimePos = ctx.data.timePos
  var oldTimeDisplay = formatTime(ctx.data.timePos)
  var lastW = terminal.terminalWidth()
  var lastH = terminal.terminalHeight()
  var resized = false
  var frameNo = 0
  var vizFrameSkip = 0
  while true:
    try:
      var rfds: TFdSet
      FD_ZERO(rfds)
      FD_SET(0.cint, rfds)
      var tv: Timeval
      tv.tv_sec = posix.Time(0)
      tv.tv_usec = posix.Suseconds(16000)
      let hasInput = select(1.cint, addr(rfds), nil, nil, addr(tv))
      let key = if hasInput > 0: iw.getKey(mouseInfo) else: iw.Key.None
      if ctx.data.pendingSeqTimer > 0:
        ctx.data.pendingSeqTimer -= 1
        if ctx.data.pendingSeqTimer <= 0:
          ctx.data.pendingSeq = @[]
      var chars: seq[Rune] = @[]
      if key >= iw.Key.Space and key <= iw.Key.Tilde:
        chars.add(Rune(key.ord))
      if key == iw.Key.Mouse:
        discard
      elif key != iw.Key.None:
        handleKey(ctx.data, key, chars)
        ctx.data.needsRedraw = true
      processEvents(ctx.data)
      # Daemon reconnection watchdog
      if ctx.data.player of DaemonClient:
        let cli = DaemonClient(ctx.data.player)
        if not cli.connected:
          ctx.data.reconnectAttempts.inc
          if not ctx.data.reconnecting:
            ctx.data.reconnecting = true
            ctx.data.setFeedback("[Daemon disconnected — reconnecting...]", nkWarning)
            ctx.data.markDirty(ceReconnecting)
          if ctx.data.reconnectAttempts mod 30 == 0:
            cli.ensureDaemon()
            if cli.connected:
              ctx.data.setFeedback("[Daemon reconnected]")
              let daemonState = cli.getDaemonState()
              fullStateSync(ctx.data, daemonState)
              # Re-fetch library from daemon to pick up any metadata changes
              let libResp = cli.getLibrary()
              if libResp.hasKey("tracks") and libResp["tracks"].len > 0:
                ctx.data.loadLibraryFromDaemon(cli, libResp)
              ctx.data.loadQueue()
              if ctx.data.currentPlayingPath.len > 0:
                for i, t in ctx.data.libraryTracks:
                  if t.path == ctx.data.currentPlayingPath:
                    ctx.data.selectIndex = i
                    break
              ctx.data.reconnecting = false
              ctx.data.reconnectAttempts = 0
              ctx.data.markDirtyBatch(cePlayState, ceTrack, ceVolume, cePosition)
        elif ctx.data.reconnecting:
          ctx.data.reconnecting = false
          ctx.data.reconnectAttempts = 0
          ctx.data.setFeedback("[Daemon connected]")
      if ctx.data.overlay.kind == okYtSearch:
        if ctx.data.ytDebounceAt > 0 and epochTime() >= ctx.data.ytDebounceAt:
          ctx.data.ytDebounceAt = 0
          if ctx.data.overlay.query.len > 0:
            # If query changed while a search was active, kill the old process
            if ctx.data.ytSearchQuery != ctx.data.overlay.query:
              if ctx.data.ytSearchProcessActive:
                try:
                  ctx.data.ytSearchProcess.terminate()
                except: discard
                close(ctx.data.ytSearchProcess)
                ctx.data.ytSearchProcessActive = false
                ctx.data.ytSearchOutputBuf = ""
              ctx.data.overlay.ytResults = @[]
              ctx.data.overlay.cursor = 0
              ctx.data.ytSearchQuery = ctx.data.overlay.query
              ctx.data.ytSearchPage = 0
            if not ctx.data.ytSearchProcessActive:
              ctx.data.ytSearchProcessActive = startYoutubeSearch(ctx.data.overlay.query, ctx.data.ytSearchProcess, ctx.data.ytCookieSource, ctx.data.ytSearchPageSize * max(1, ctx.data.ytSearchPage + 1))
              ctx.data.ytSearchLoading = true
              ctx.data.markDirty(ceSearchLoading)
        if ctx.data.ytSearchProcessActive:
          let results = pollYoutubeSearch(ctx.data.ytSearchProcess, ctx.data.ytSearchOutputBuf)
          if results.len > 0:
            if ctx.data.overlay.ytResults.len == 0:
              ctx.data.overlay.ytResults = results
              ctx.data.overlay.cursor = 0
            else:
              var seen: HashSet[string]
              for r in ctx.data.overlay.ytResults: seen.incl(r.url)
              for r in results:
                if r.url notin seen:
                  ctx.data.overlay.ytResults.add(r)
                  seen.incl(r.url)
            ctx.data.markDirty(ceSearchResults)
          if not ctx.data.ytSearchProcess.running():
            let finalResults = finishYoutubeSearch(ctx.data.ytSearchProcess, ctx.data.ytSearchOutputBuf)
            if finalResults.len > 0:
              var seen: HashSet[string]
              for r in ctx.data.overlay.ytResults: seen.incl(r.url)
              for r in finalResults:
                if r.url notin seen:
                  ctx.data.overlay.ytResults.add(r)
                  seen.incl(r.url)
              ctx.data.markDirty(ceSearchResults)
            ctx.data.ytSearchProcessActive = false
            ctx.data.ytSearchLoading = false
            ctx.data.ytSearchOutputBuf = ""
            ctx.data.markDirty(ceSearchResults)
      if ctx.data.ytStreamActive:
        if not ctx.data.ytStreamProcess.running():
          let url = pollStreamUrlFetch(ctx.data.ytStreamProcess, ctx.data.ytStreamBuf)
          ctx.data.ytStreamActive = false
          ctx.data.ytStreamBuf = ""
          if url.len > 0 and ctx.data.ytStreamPendingItem.title.len > 0:
            ctx.data.ytStreamTitle = ctx.data.ytStreamPendingItem.title
            ctx.data.ytStreamChannel = ctx.data.ytStreamPendingItem.channel
            ctx.data.ytStreamDuration = ctx.data.ytStreamPendingItem.duration
            ctx.data.ytStreamUrl = ctx.data.ytStreamPendingItem.url
            # Parse duration string (e.g. "3:45") into seconds for progress tracking
            ctx.data.ytDurationSec = parseDurationToSec(ctx.data.ytStreamPendingItem.duration)
            if ctx.data.ytDurationSec > 0:
              ctx.data.duration = ctx.data.ytDurationSec
            # Start software timer for elapsed time tracking
            ctx.data.ytPlaybackStartTime = epochTime()
            ctx.data.ytPauseDuration = 0.0
            ctx.data.ytPauseStartTime = 0.0
            if ctx.data.player of DaemonClient:
              let cli = DaemonClient(ctx.data.player)
              cli.pendingStreamTitle = ctx.data.ytStreamPendingItem.title
              cli.pendingStreamChannel = ctx.data.ytStreamPendingItem.channel
            ctx.data.player.loadFile(url)
            ctx.data.player.play()
            ctx.data.status = psPlaying
            ctx.data.currentPlayingPath = url
            if ctx.data.player of DaemonClient:
              ctx.data.currentPlayingId = DaemonClient(ctx.data.player).lastTrackId
            else:
              ctx.data.currentPlayingId = 0
            ctx.data.markDirtyBatch(cePlayState, ceTrack)
            ctx.data.showNotification("Streaming: " & ctx.data.ytStreamPendingItem.title, nkInfo)
            # Add stream track to library so it appears in Recent / Last Played
            block:
              var existsInLib = false
              for t in ctx.data.libraryTracks:
                if t.path == ctx.data.ytStreamPendingItem.url:
                  existsInLib = true
                  break
              if not existsInLib:
                ctx.data.libraryTracks.add(Track(
                  path: ctx.data.ytStreamPendingItem.url,
                  title: ctx.data.ytStreamPendingItem.title,
                  artist: ctx.data.ytStreamPendingItem.channel,
                  album: "", duration: ctx.data.ytDurationSec.float,
                  id: int64(ctx.data.libraryTracks.len + 1),
                  isFavourite: false
                ))
                ctx.data.rebuildItems()
          else:
            ctx.data.setFeedback("Failed to resolve stream URL")
      if ctx.data.ytDownloadQueue.len > 0 or ctx.data.ytDownloadTasks.len > 0:
        var done: seq[int] = @[]
        for i in 0..<ctx.data.ytDownloadTasks.len:
          if not ctx.data.ytDownloadTasks[i].completed:
            let p = ctx.data.ytDownloadTasks[i].process
            if not p.running():
              var path = ""
              try:
                path = pollDownload(ctx.data.ytDownloadTasks[i].process, ctx.data.ytDownloadTasks[i].buf)
              except:
                discard
              ctx.data.ytDownloadTasks[i].completed = true
              done.add(i)
              if path.len > 0:
                let (_, name, _) = splitFile(path)
                let origUrl = ctx.data.ytDownloadTasks[i].url
                ctx.data.ytDownloaded[origUrl] = path
                # Update any existing library track that still points to the YouTube URL
                for j in 0..<ctx.data.libraryTracks.len:
                  if ctx.data.libraryTracks[j].path == origUrl:
                    ctx.data.libraryTracks[j].path = path
                    ctx.data.libraryTracks[j].title = name
                    # If this is the currently playing track, update the path
                    if ctx.data.currentPlayingPath == origUrl:
                      ctx.data.currentPlayingPath = path
                    break
                ctx.data.showNotification("Downloaded: " & name, nkSuccess)
                ctx.data.rebuildItems()
          else:
            done.add(i)
        for i in countdown(done.len - 1, 0):
          ctx.data.ytDownloadTasks.delete(done[i])
        while ctx.data.ytDownloadTasks.len < ctx.data.ytMaxConcurrentDownloads and ctx.data.ytDownloadQueue.len > 0:
          let item = ctx.data.ytDownloadQueue[0]
          ctx.data.ytDownloadQueue.delete(0)
          var task: DownloadTask
          if startDownload(item, ctx.data.ytDownloadDir, task.process, ctx.data.ytCookieSource, ctx.data.ytJsRuntime):
            task.title = item.title
            task.url = item.url
            task.outputDir = ctx.data.ytDownloadDir
            task.completed = false
            ctx.data.ytDownloadTasks.add(task)
      if ctx.data.feedbackTimer > 0:
        ctx.data.feedbackTimer.dec
      if ctx.data.ytSearchLoading and ctx.data.overlay.kind == okYtSearch and ctx.data.overlay.ytResults.len == 0:
        ctx.data.markDirty(ceSearchLoading)
      if ctx.data.volumeCueTimer > 0:
        ctx.data.volumeCueTimer.dec
      if ctx.data.notificationTimer > 0:
        ctx.data.notificationTimer.dec
      if ctx.data.nowPlayingCueTimer > 0:
        ctx.data.nowPlayingCueTimer.dec
      if ctx.data.sleepTimerRemaining > 0 and ctx.data.player of DaemonClient:
        ctx.data.sleepTimerRemaining = DaemonClient(ctx.data.player).sleepTimerRemaining
      let curW = terminal.terminalWidth()
      let curH = terminal.terminalHeight()
      resized = false
      if curW != lastW or curH != lastH:
        lastW = curW
        lastH = curH
        resized = true
      vizFrameSkip = (vizFrameSkip + 1) mod 3
      if ctx.data.viz != nil and vizFrameSkip == 0:
        ctx.data.viz.readPcm()
      if ctx.data.status != oldStatus:
        ctx.data.needsRedraw = true
      oldStatus = ctx.data.status
      if ctx.data.timePos != oldTimePos:
        let newDisplay = formatTime(ctx.data.timePos)
        if newDisplay != oldTimeDisplay:
          oldTimeDisplay = newDisplay
          ctx.data.markDirty(cePosition)
        oldTimePos = ctx.data.timePos
      if ctx.data.vizVisible and ctx.data.viz != nil and frameNo mod 6 == 0:
        ctx.data.markDirty(cePosition)
      if ceQueue in ctx.data.dirtyFlags:
        ctx.data.saveQueue()
      let shouldDraw = resized or ctx.data.needsRedraw or ctx.data.dirtyFlags.card > 0
      if shouldDraw:
        ctx.tb = iw.initTerminalBuffer(curW, curH)
        renderApp(ctx)
        if resized:
          prevTb = iw.initTerminalBuffer(0, 0)
        ctx.data.needsRedraw = false
        tbReady = true
      if shouldDraw and tbReady:
        iw.display(ctx.tb, prevTb)
        prevTb = ctx.tb
      if key != iw.Key.None:
        showInputCursor(ctx.data, curW, curH)
      ctx.data.clearDirty()
      frameNo += 1
    except Exception as ex:
      if ctx.data.viz != nil: ctx.data.viz.stopCapture()
      iw.deinit()
      echo "\nError: ", ex.msg
      echo ex.getStackTrace()
      quit(1)

when isMainModule:
  let rawArgs = os.commandLineParams()
  var args: seq[string] = @[]
  for a in rawArgs:
    if a == "--debug":
      debugMode = true
    else:
      args.add(a)
  if args.len > 0 and args[0] == "daemon":
    stderr.writeLine("[gtm] use 'gtmd' instead of 'gtm daemon'")
    quit(1)
  let parsed = parseArgs(args)
  if parsed.subcmd != scNone:
    if execSubcommand(parsed):
      quit(0)
  runTui(args)

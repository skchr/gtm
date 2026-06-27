## gtm — Terminal Music Player (TUI entry point)
##
## Implements the application lifecycle: config loading, daemon
## spawning, connection retry, event processing, keyboard dispatch,
## and the ~60fps render loop.
##
## ┌────────────────────────────────────────────────────────┐
## │  gtm main proc                                         │
## │                                                        │
## │  ┌──────────────┐                                      │
## │  │ loadConfig()  │  read ~/.config/gtm/config.json     │
## │  └──────┬───────┘                                      │
## │         ▼                                              │
## │  ┌──────────────┐                                      │
## │  │ setupUI()     │  init illwave terminal, set theme   │
## │  └──────┬───────┘                                      │
## │         ▼                                              │
## │  ┌──────────────┐     ┌──────────────────────┐        │
## │  │ spawnDaemon()│────►│ wait for connection   │        │
## │  │ (if needed)  │     │ (retry loop with      │        │
## │  └──────────────┘     │  exponential backoff) │        │
## │                       └──────────┬───────────┘        │
## │  ┌──────────────┐               │                      │
## │  │ main loop     │◄──────────────┘                      │
## │  │ 16ms frame    │                                      │
## │  │ cap (60fps)   │                                      │
## │  │               │                                      │
## │  │ 1. pollEvents() ──► processEvents()                  │
## │  │ 2. handleInput() ──► dispatch TUI commands           │
## │  │ 3. render()        ──► draw tab content              │
## │  └──────────────┘                                      │
## └────────────────────────────────────────────────────────┘

import os, terminal, strutils, unicode, json, sets, math, sequtils, algorithm, times, posix, tables, osproc, hashes, base64
from illwave as iw import nil
from ../vendor/nimwave/nimwave as nw import nil
import state, ui, audio, library, theme, commands, cli, ytdlp, graphics, daemonservice, store, icons
from lyrics import currentLrcLine

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
      if json.hasKey("idle_timeout"):
        state.config.idleTimeout = json["idle_timeout"].getInt(300)
      if json.hasKey("ipc_timeout"):
        state.config.ipcTimeout = json["ipc_timeout"].getInt(3)
      if json.hasKey("yt_search_page_size"):
        state.ytSearchPageSize = json["yt_search_page_size"].getInt(10)
      if json.hasKey("keybindings"):
        state.rawKeybindingsJson = json["keybindings"]
      if json.hasKey("footer_preset"):
        let fp = json["footer_preset"].getStr("full")
        state.footerPreset = parseEnum[FooterPresetName]("fpn" & fp.capitalizeAscii(), fpnFull)
      if json.hasKey("highlight_overrides"):
        state.userHighlightOverrides = json["highlight_overrides"]
      if json.hasKey("crossfade_duration"):
        state.crossfadeDuration = json["crossfade_duration"].getInt(state.crossfadeDuration)
      if json.hasKey("crossfade_curve"):
        state.crossfadeCurve = CrossfadeCurveType(json["crossfade_curve"].getInt(state.crossfadeCurve.ord))
      if json.hasKey("eq_preset"):
        state.eqPreset = json["eq_preset"].getStr("Flat")
      if json.hasKey("yt_js_runtime"):
        state.ytJsRuntime = json["yt_js_runtime"].getStr("node")
      if json.hasKey("yt_cookie_source"):
        state.ytCookieSource = json["yt_cookie_source"].getStr("")
      if json.hasKey("yt_cookie_file_path"):
        state.ytCookieFilePath = json["yt_cookie_file_path"].getStr("")
      if json.hasKey("yt_max_concurrent"):
        state.ytMaxConcurrentDownloads = json["yt_max_concurrent"].getInt(4)
      if json.hasKey("yt_batch_mode"):
        state.ytAutoDownload = json["yt_batch_mode"].getBool(false)
      if json.hasKey("yt_auto_download"):
        state.ytAutoDownload = json["yt_auto_download"].getBool(state.ytAutoDownload)
      if json.hasKey("hover_delay"):
        state.hoverDelay = json["hover_delay"].getFloat(3.0)
      if json.hasKey("sp_cookie_source"):
        state.spCookieSource = json["sp_cookie_source"].getStr("")
      if json.hasKey("sp_cookie_file_path"):
        state.spCookieFilePath = json["sp_cookie_file_path"].getStr("")
      if json.hasKey("sp_audio_format"):
        state.spAudioFormat = json["sp_audio_format"].getStr("opus")
      if json.hasKey("icon_preference"):
        let p = json["icon_preference"].getStr("auto")
        state.iconPreference = if p == "nerd": ipNerdFont elif p == "emoji": ipEmoji else: ipAuto
      if json.hasKey("transparent_bg"):
        state.transparentBg = json["transparent_bg"].getBool()
      if json.hasKey("overlay_opacity"):
        state.overlayOpacity = json["overlay_opacity"].getFloat()
      if json.hasKey("border_style"):
        state.borderStyle = BorderStyle(json["border_style"].getInt(0))
      if json.hasKey("progress_style"):
        state.progressStyle = json["progress_style"].getInt(0)
      if json.hasKey("on_config_apply"):
        let arr = json["on_config_apply"]
        if arr.kind == JArray:
          state.config.onConfigApply = @[]
          for v in arr:
            state.config.onConfigApply.add((v{"cmd"}.getStr(""), v{"arg"}.getStr("")))
      if json.hasKey("footer_left_modules"):
        let arr = json["footer_left_modules"]
        if arr.kind == JArray:
          for v in arr:
            try:
              state.footerLeftModules.incl(parseEnum[FooterModule]("fm" & v.getStr("").capitalizeAscii()))
            except: discard
      if json.hasKey("footer_right_modules"):
        let arr = json["footer_right_modules"]
        if arr.kind == JArray:
          for v in arr:
            try:
              state.footerRightModules.incl(parseEnum[FooterModule]("fm" & v.getStr("").capitalizeAscii()))
            except: discard
      let refreshSeed = state.config.refreshTheme or state.config.theme == "random"
      state.theme = getTheme(state.config.theme, refreshSeed)
      state.highlightGroups = initHighlightGroups(state.theme)
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
  var j = %{
    "theme": %state.config.theme,
    "volume": %state.volume,
    "last_tab": %(state.tab.ord),
    "refresh_theme": %state.config.refreshTheme,
    "footer_preset": %($state.footerPreset).substr(3).toLowerAscii(),
    "crossfade_duration": %state.crossfadeDuration,
    "crossfade_curve": %state.crossfadeCurve.ord,
    "yt_search_page_size": %state.ytSearchPageSize,
    "ipc_timeout": %state.config.ipcTimeout,
    "idle_timeout": %state.config.idleTimeout,
    "eq_preset": %state.eqPreset,
    "yt_js_runtime": %state.ytJsRuntime,
    "yt_cookie_source": %state.ytCookieSource,
    "yt_cookie_file_path": %state.ytCookieFilePath,
    "yt_max_concurrent": %state.ytMaxConcurrentDownloads,
    "yt_auto_download": %state.ytAutoDownload,
    "hover_delay": %state.hoverDelay,
    "sp_cookie_source": %state.spCookieSource,
    "sp_cookie_file_path": %state.spCookieFilePath,
    "sp_audio_format": %state.spAudioFormat
  }
  var onApply = newJArray()
  for (cmd, arg) in state.config.onConfigApply:
    onApply.add(%*{"cmd": cmd, "arg": arg})
  j["on_config_apply"] = onApply
  let iconPrefStr =
    case state.iconPreference
    of ipAuto: "auto"
    of ipNerdFont: "nerd"
    of ipEmoji: "emoji"
  j["icon_preference"] = %iconPrefStr
  j["transparent_bg"] = %state.transparentBg
  j["overlay_opacity"] = %state.overlayOpacity
  j["border_style"] = %state.borderStyle.ord
  j["progress_style"] = %state.progressStyle
  # Save footer left/right module sets
  var leftMods = newJArray()
  for m in state.footerLeftModules:
    leftMods.add(%($m).substr(2).toLowerAscii())
  j["footer_left_modules"] = leftMods
  var rightMods = newJArray()
  for m in state.footerRightModules:
    rightMods.add(%($m).substr(2).toLowerAscii())
  j["footer_right_modules"] = rightMods
  if state.rawKeybindingsJson != nil:
    j["keybindings"] = state.rawKeybindingsJson
  try:
    writeFile(state.configPath, $j)
  except:
    stderr.writeLine("[gtm] saveConfig error: " & getCurrentExceptionMsg())

proc applyOnConfig(state: var AppState) =
  if state.player.backendType != abtDaemon: return
  let cli = DaemonService(state.svc)
  for (cmd, arg) in state.config.onConfigApply:
    if cmd.len > 0:
      try:
        let payload = if arg.len > 0: %*{"cmd": cmd, "arg": arg} else: %*{"cmd": cmd}
        cli.sendOnly(payload)
      except: discard

proc loadLibraryFromDaemon(state: var AppState, resp: JsonNode) =
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
  if state.libraryTracks.len > 0:
    state.libraryLoading = false
    return
  state.libraryLoading = true
  let musicDir = if existsEnv("TERMUX_VERSION"):
    let shared = getEnv("HOME", "") & "/storage/shared/Music"
    if dirExists(shared): shared else: getEnv("HOME", "") & "/Music"
  else:
    getEnv("HOME", "") & "/Music"
  if state.player.backendType == abtDaemon:
    let cli = DaemonService(state.svc)
    if cli.isConnected:
      let resp = cli.getLibrary()
      if resp.hasKey("tracks") and resp["tracks"].len > 0:
        state.loadLibraryFromDaemon(resp)
        state.libraryLoading = false
        return
      # Daemon library empty: trigger server-side scan, then wait for scan_done event
      if dirExists(musicDir):
        discard cli.scanDir(musicDir)
        state.libraryNeedsScan = true
        return
  # Fallback: scan local files
  state.scanLocalDir(musicDir)
  state.rebuildItems()
  state.libraryLoading = false

proc retryLoadLibrary(state: var AppState) =
  if not state.libraryLoading or not state.libraryNeedsScan:
    return
  if state.libraryTracks.len > 0:
    state.libraryLoading = false
    state.libraryNeedsScan = false
    return
  let now = epochTime()
  if now - state.libraryLastRetryAt < 0.5:
    return
  state.libraryLastRetryAt = now
  state.libraryRetryCount.inc
  # Wait for scan_done event instead of polling — don't clear needsScan on timeout
  if state.player.backendType == abtDaemon:
    let cli = DaemonService(state.svc)
    if cli.isConnected:
      let resp = cli.getLibrary()
      if resp.hasKey("tracks") and resp["tracks"].len > 0:
        state.loadLibraryFromDaemon(resp)
        state.libraryLoading = false
        state.libraryNeedsScan = false
        state.libraryRetryCount = 0

proc buildPlaylistFromArgs(state: var AppState, args: seq[string]) =
  var paths: seq[string] = @[]
  if args.len > 0: paths = loadFromArgs(args)
  if paths.len == 0:
    let home = getEnv("HOME", "")
    if home.len > 0:
      let musicDir = home & "/Music"
      if dirExists(musicDir): paths = scanDirectory(musicDir)
  if paths.len == 0: paths = scanDirectory(".")
  let startIdx = state.libraryTracks.len
  for p in paths:
    let (_, name, _) = splitFile(p)
    let title = name.replace(".", " ")
    state.libraryTracks.add(Track(
      path: p, title: title, artist: "", album: "",
      duration: 0.0, id: int64(state.libraryTracks.len + 1)
    ))
  # Populate playback queue from CLI args (not for default ~/Music or . scan)
  if args.len > 0:
    let addedCount = state.libraryTracks.len - startIdx
    if addedCount > 0:
      state.playbackQueue = @[]
      for i in startIdx..<state.libraryTracks.len:
        state.playbackQueue.add(i)
      # Sync queue to daemon (clear first, then add)
      if state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        if cli.isConnected:
          discard daemonSimpleCmd(cli, "queue_clear")
          var items: seq[(string, string, string)] = @[]
          for idx in state.playbackQueue:
            let t = state.libraryTracks[idx]
            items.add((t.path, t.title, t.artist))
          discard cli.queueAdd(items)

proc getCurrentTrack(state: AppState): Track =
  let item = state.selectedItem()
  if item.kind == likTrack and item.trackIdx >= 0 and item.trackIdx < state.libraryTracks.len:
    return state.libraryTracks[item.trackIdx]
  if state.libraryTracks.len > 0 and state.selectIndex >= 0 and state.selectIndex < state.libraryTracks.len:
    return state.libraryTracks[state.selectIndex]
  Track()

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

proc getPlaybackDeviceName(): string =
  try:
    let (sink, _) = execCmdEx("pactl get-default-sink")
    let sinkName = sink.strip()
    if sinkName.len > 0:
      let (jsonStr, _) = execCmdEx("pactl -f json list-sinks")
      let sinks = parseJson(jsonStr)
      for s in sinks:
        if s{"name"}.getStr("") == sinkName:
          result = s{"description"}.getStr("")
          break
    if result.len == 0: result = "ALSA"
  except:
    result = "ALSA"

proc showNotification*(state: var AppState, msg: string, kind: NotificationKind = nkInfo) =
  state.notificationTimer = 0
  state.notificationMsg = msg
  state.notificationBody = ""
  state.notificationKind = kind
  state.notificationTimer = 120
  state.markDirty(ceFeedback)

proc setFeedback(state: var AppState, msg: string, kind: NotificationKind = nkInfo) =
  state.feedbackMsg = msg
  state.feedbackTimer = 60
  state.markDirty(ceFeedback)

proc queueLog(msg: string) =
  let cacheDir = getEnv("XDG_CACHE_HOME", getEnv("HOME", "") & "/.cache") & "/gtm"
  if not dirExists(cacheDir): createDir(cacheDir)
  let logPath = cacheDir / "gtm.log"
  var f: File
  if f.open(logPath, fmAppend):
    f.writeLine("[" & getTime().format("yyyy-MM-dd HH:mm:ss") & "] " & msg)
    f.close()

proc sendPlayRequest(state: var AppState, path, title, channel: string, queuePaths: seq[string] = @[]) =
  queueLog("sendPlayRequest: track=" & path & " title=" & title)
  if state.player.backendType == abtDaemon:
    let cli = DaemonService(state.svc)
    if not state.startupQueueFlushed:
      cli.sendOnly(%*{"cmd": "queue_clear"})
      state.startupQueueFlushed = true
      state.playbackQueue = @[]
      state.queuePaths = @[]
    cli.sendOnly(%*{"cmd": "load_file", "path": path, "title": title, "channel": channel})
    if queuePaths.len > 0:
      cli.sendOnly(%*{"cmd": "queue_clear"})
      cli.sendOnly(%*{"cmd": "queue_add", "data": %queuePaths})
    cli.sendOnly(%*{"cmd": "play"})
  else:
    discard state.player.loadFile(path, title, channel)
    state.playbackQueue = @[]
    state.queuePaths = @[]
    for p in queuePaths:
      var tIdx = -1
      for i, t in state.libraryTracks:
        if t.path == p:
          tIdx = i; break
      state.playbackQueue.add(tIdx)
      state.queuePaths.add(p)
    state.player.play()
  state.markDirtyBatch(cePlayState, ceTrack)

proc playTrackFromLibrary(state: var AppState, path, title, channel: string, libIdx: int) =
  if path.len == 0: return
  queueLog("playTrackFromLibrary: track=" & path & " title=" & title & " id=" & $libIdx)
  state.sendPlayRequest(path, title, channel)

proc playSelected(state: var AppState) =
  let track = state.getCurrentTrack()
  if track.path.len > 0:
    queueLog("playSelected: track=" & track.path & " title=" & track.title & " id=" & $track.id)
    # Populate queue with remaining displayItems after selected track
    var queuedPaths: seq[string] = @[]
    if state.selectIndex >= 0 and state.selectIndex < state.displayItems.len:
      for i in state.selectIndex + 1 ..< state.displayItems.len:
        let item = state.displayItems[i]
        if item.kind == likTrack and item.trackIdx >= 0 and item.trackIdx < state.libraryTracks.len:
          let tp = state.libraryTracks[item.trackIdx].path
          if tp.len > 0 and (isUrl(tp) or fileExists(tp)):
            queuedPaths.add(tp)
    else:
      for i in state.selectIndex + 1 ..< state.libraryTracks.len:
        if i >= 0 and i < state.libraryTracks.len:
          let tp = state.libraryTracks[i].path
          if tp.len > 0 and (isUrl(tp) or fileExists(tp)):
            queuedPaths.add(tp)
            if queuedPaths.len >= 200:
              break
    state.sendPlayRequest(track.path, track.title, track.artist, queuedPaths)

proc nextTrack(state: var AppState) =
  state.upNextTimer = 0
  state.upNextMsg = ""
  if state.player.backendType == abtDaemon:
    DaemonService(state.svc).sendOnly(%*{"cmd": "next"})
  state.markDirty(cePlayState)

proc prevTrack(state: var AppState) =
  state.upNextTimer = 0
  state.upNextMsg = ""
  if state.player.backendType == abtDaemon:
    DaemonService(state.svc).sendOnly(%*{"cmd": "prev"})
  state.markDirty(cePlayState)

proc adjustVolume(state: var AppState, delta: int) =
  let newVol = max(0, min(100, state.volume + delta))
  if newVol > state.volumeSafetyThreshold and not state.volumeSafetyConfirmed and delta > 0:
    state.setFeedback("High volume may damage hearing. Press Y to confirm, N to cancel.", nkWarning)
    state.queuePendingConfirm = 3
    return
  state.player.setVolume(newVol)
  state.volume = newVol
  state.showVolumeCue()
  if state.tab == tabSettings: state.rebuildItems()

proc adjustSettingValue(state: var AppState, delta: int) =
  if state.tab != tabSettings or state.settingsFocusPanel != lpContent:
    return
  case state.settingsCategory
  of scAudio:
    case state.selectIndex
    of 0:
      state.adjustVolume(delta * 5)
      return
    of 1:
      state.crossfadeDuration = max(0, min(10, state.crossfadeDuration + delta))
      if state.player.backendType == abtDaemon:
        DaemonService(state.svc).sendOnly(%*{"cmd": "set_crossfade_duration", "duration": state.crossfadeDuration})
      state.configDirty = true
    of 2:
      let cats = ord(high(CrossfadeCurveType))
      state.crossfadeCurve = CrossfadeCurveType((state.crossfadeCurve.ord + delta + cats + 1) mod (cats + 1))
      if state.player.backendType == abtDaemon:
        DaemonService(state.svc).sendOnly(%*{"cmd": "set_crossfade_curve", "curve_type": state.crossfadeCurve.ord})
      state.configDirty = true
    else: discard
  of scYouTube:
    case state.selectIndex
    of 3:
      state.ytMaxConcurrentDownloads = max(1, min(10, state.ytMaxConcurrentDownloads + delta))
      state.configDirty = true
    of 4:
      state.ytSearchPageSize = max(10, min(50, state.ytSearchPageSize + delta * 5))
      state.configDirty = true
    of 6:
      if delta != 0:
        state.ytAutoDownload = not state.ytAutoDownload
        state.configDirty = true
    else: discard
  of scAppearance:
    case state.selectIndex
    of 1:
      if delta != 0:
        state.config.refreshTheme = not state.config.refreshTheme
        state.configDirty = true
    of 2:
      let cats = ord(high(FooterPresetName))
      state.footerPreset = FooterPresetName((state.footerPreset.ord + delta + cats + 1) mod (cats + 1))
      state.configDirty = true
    of 4:
      if delta != 0:
        state.transparentBg = not state.transparentBg
        state.configDirty = true
    of 5:
      let curPct = int(state.overlayOpacity * 100)
      let newPct = max(0, min(100, curPct + delta * 5))
      state.overlayOpacity = newPct.float / 100.0
      state.configDirty = true
    of 6:
      let cats = ord(high(IconPreference))
      state.iconPreference = IconPreference((state.iconPreference.ord + delta + cats + 1) mod (cats + 1))
      state.configDirty = true
    of 7:
      let cats = ord(high(BorderStyle))
      state.borderStyle = BorderStyle((state.borderStyle.ord + delta + cats + 1) mod (cats + 1))
      state.configDirty = true
    of 8:
      state.progressStyle = max(0, min(1, state.progressStyle + delta))
      state.configDirty = true
    of 9:
      state.hoverDelay = max(0.0, min(6.0, state.hoverDelay + delta.float * 0.5))
      state.configDirty = true
    else: discard
  of scSystem:
    case state.selectIndex
    of 0:
      state.config.idleTimeout = max(0, min(600, state.config.idleTimeout + delta * 30))
      state.configDirty = true
    of 1:
      state.config.ipcTimeout = max(1, min(30, state.config.ipcTimeout + delta))
      state.configDirty = true
    else: discard
  of scSpotify:
    case state.selectIndex
    of 3:
      state.ytMaxConcurrentDownloads = max(1, min(10, state.ytMaxConcurrentDownloads + delta))
      state.configDirty = true
    else: discard
  state.rebuildItems()
  state.needsRedraw = true

proc toggleShuffle(state: var AppState) =
  if state.player.backendType == abtDaemon:
    DaemonService(state.svc).sendOnly(%*{"cmd": "set_shuffle", "enabled": (not state.shuffleEnabled).int})

proc cycleRepeat(state: var AppState) =
  if state.player.backendType == abtDaemon:
    let newMode = (state.repeatMode + 1) mod 3
    DaemonService(state.svc).sendOnly(%*{"cmd": "set_repeat", "mode": newMode})

proc toggleMute(state: var AppState) =
  if state.volume > 0:
    state.prevVolume = state.volume
    state.player.setVolume(0)
    state.volume = 0
  else:
    let restore = if state.prevVolume > 0: state.prevVolume else: 80
    state.player.setVolume(restore)
    state.volume = restore
    state.prevVolume = 0
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
        of scYouTube: 7
        of scAppearance: 9
        of scSystem: 3
        of scSpotify: 6
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
  else:
    state.selectedIndices = initHashSet[int]()

proc selectAll(state: var AppState) =
  let count = state.filteredCount()
  for i in 0..<count:
    let realIdx = state.filteredIndex(i)
    if realIdx >= 0:
      state.selectedIndices.incl(realIdx)

proc deleteSelected(state: var AppState, permanent: bool) =
  if state.selectedIndices.len == 0: return
  if state.player.backendType == abtDaemon:
    let cli = DaemonService(state.svc)
    for selIdx in state.selectedIndices:
      if selIdx >= 0 and selIdx < state.libraryTracks.len:
        let track = state.libraryTracks[selIdx]
        if track.id > 0:
          discard cli.deleteTrack(track.id, permanent)
    state.selectedIndices = initHashSet[int]()
    state.loadLibrary()
  else:
    var sortedIdx = toSeq(state.selectedIndices.items)
    sortedIdx.sort(SortOrder.Descending)
    for idx in sortedIdx:
      if idx >= 0 and idx < state.libraryTracks.len:
        state.libraryTracks.delete(idx)
    state.selectedIndices = initHashSet[int]()
    state.rebuildItems()
    state.selectIndex = min(state.selectIndex, state.displayItems.len - 1)

proc deleteConfirm(state: var AppState) =
  if state.selectedIndices.len == 0:
    state.setFeedback("No tracks selected")
    return
  let n = state.selectedIndices.len
  state.deleteConfirmPending = 1
  state.setFeedback("Delete " & $n & " track(s)? (t=trash, P=perm, n=cancel)")

proc restoreTerminal() =
  iw.deinit()
  terminal.showCursor()
  stdout.write("\e[0m\e[39m\e[49m\e[?25h")
  eraseScreen()
  setCursorPos(0, 0)
  stdout.flushFile()

proc cleanQuit(state: var AppState, stopDaemon: bool) =
  state.saveConfig()
  if state.player.backendType == abtDaemon and stopDaemon:
    DaemonService(state.svc).sendQuit
  elif not stopDaemon:
    state.player.shutdown()
  restoreTerminal()
  quit(0)

proc checkAutocomplete(state: var AppState) =
  let query = state.overlay.query
  if query.len < 2:
    state.overlay.ytAutocompleteVisible = false
    state.overlay.ytAutocompleteSuggestions = @[]
    return
  var matches: seq[string] = @[]
  let lowerQuery = query.toLowerAscii()
  for i, hLower in state.ytSearchHistoryLower:
    if lowerQuery in hLower:
      matches.add(state.ytSearchHistory[i])
      if matches.len >= 5: break
  if matches.len > 0:
    state.overlay.ytAutocompleteSuggestions = matches
    state.overlay.ytAutocompleteCursor = 0
    state.overlay.ytAutocompleteVisible = true
  else:
    state.overlay.ytAutocompleteVisible = false

proc quitBackground(state: var AppState) =
  state.saveConfig()
  restoreTerminal()
  quit(0)

proc quitDaemon(state: var AppState) =
  cleanQuit(state, true)

proc goToFirst(state: var AppState) =
  state.selectIndex = 0
  state.needsRedraw = true

proc goToLast(state: var AppState) =
  state.selectIndex = max(0, state.filteredCount() - 1)
  state.needsRedraw = true

proc queuePath*(state: AppState): string = state.dataDir / "queue.json"

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
      if state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
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
  if state.player.backendType == abtDaemon:
    let cli = DaemonService(state.svc)
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
        if state.player.backendType == abtDaemon:
          let resp = DaemonService(state.svc).addToPlaylist(state.libraryPlaylists[idx].id, track.id, state.libraryPlaylists[idx].trackIds.len - 1)
          if resp{"ok"}.getBool(false):
            state.libraryPlaylists[idx].trackIds.add(track.id)
        else:
          state.libraryPlaylists[idx].trackIds.add(track.id)
  state.selectedIndices = initHashSet[int]()
  state.rebuildItems()

proc handleQuitSignal() {.noconv.} =
  restoreTerminal()
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

proc updateEqPresetPickerResults(state: var AppState) =
  state.overlay.strResults = @[]
  let q = state.overlay.query.toLowerAscii()
  for preset in state.eqPresetList:
    if q.len == 0 or preset.toLowerAscii().contains(q):
      state.overlay.strResults.add(preset)

proc updateTrashResults(state: var AppState) =
  state.overlay.strResults = @[]
  state.overlay.results = @[]
  let q = state.overlay.query.toLowerAscii()
  for i, item in state.trashItems:
    let label = item.originalPath.splitPath().tail & " (" & item.trashedAt.fromUnix().format("yyyy-MM-dd") & ")"
    if q.len == 0 or label.toLowerAscii().contains(q):
      state.overlay.results.add(i)
      state.overlay.strResults.add(label)

proc applyEqPreset(state: var AppState, name: string) =
  state.eqPreset = name
  if state.player.backendType == abtDaemon:
    DaemonService(state.svc).setEqPreset(name)

proc switchTab(state: var AppState, tab: AppTab) =
  if state.tab == tab: return
  state.saveTabState()
  state.tab = tab
  state.restoreTabState()
  state.rebuildItems()
  state.needsRedraw = true

proc initCommands(state: var AppState) =
  state.registerCommand("toggle_play_pause", "Toggle Play/Pause",
    "Toggle between play and pause states", "\u25B6", @["Space"],
    proc(s: var AppState) =
      if s.selectedIndices.len > 0:
        s.selectMode = false
        s.playSelected()
      elif s.status == psPlaying:
        s.player.pause()
      else:
        s.player.play())
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
    "Increase volume by 5%", "\uF028", @["Plus", "Equals"],
    proc(s: var AppState) = s.adjustVolume(5))
  state.registerCommand("volume_down", "Volume Down",
    "Decrease volume by 5%", "\uF027", @["Minus", "Underscore"],
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
    "Move selection up in the list", "\u2B06", @["Up"],
    proc(s: var AppState) = s.moveSelection(-1))
  state.registerCommand("nav_down", "Move Down",
    "Move selection down in the list", "\u2B07", @["Down"],
    proc(s: var AppState) = s.moveSelection(1))
  state.registerCommand("enter_filter", "Filter/Search",
    "Enter filter mode to search", "\U0001F50D", @["CtrlF", "Slash"],
    proc(s: var AppState) = s.mode = imFilter; s.filterText = ""; s.filteredIndices = @[])
  state.registerCommand("play_selected", "Play Selected",
    "Play the currently selected item", "\u25B6", @["Enter"],
    proc(s: var AppState) =
      if s.filterScope in {fsSpLiked, fsSpPlaylists}:
        if s.filterScope == fsSpLiked and s.selectIndex >= 0 and s.selectIndex < s.spLikedSongs.len:
          let r = s.spLikedSongs[s.selectIndex]
          s.overlay = OverlayState(kind: okYtSearch, query: r.name & " " & r.artist, cursor: 0)
          if s.player.backendType == abtDaemon:
            let cli = DaemonService(s.svc)
            cli.sendOnly(%*{"cmd": "yt_search", "query": s.overlay.query})
        elif s.filterScope == fsSpPlaylists and s.selectIndex >= 0 and s.selectIndex < s.spUserPlaylists.len:
          let plName = s.spUserPlaylists[s.selectIndex].name
          s.overlay = OverlayState(kind: okYtSearch, query: plName, cursor: 0)
          if s.player.backendType == abtDaemon:
            let cli = DaemonService(s.svc)
            cli.sendOnly(%*{"cmd": "yt_search", "query": s.overlay.query})
      else:
        s.playSelected())
  state.registerCommand("go_to_first", "Go to First",
    "Jump to first item in the list", "\u23EE", @["CtrlG", "g+g"],
    proc(s: var AppState) = s.goToFirst())
  state.registerCommand("go_to_last", "Go to Last",
    "Jump to last item in the list", "\u23ED", @["ShiftG"],
    proc(s: var AppState) = s.goToLast(); s.playSelected())
  state.registerCommand("toggle_select_mode", "Toggle Select Mode",
    "Enter or exit multi-select mode", "\U0001F7E8", @["CtrlV"],
    proc(s: var AppState) = s.toggleSelect())
  state.registerCommand("select_all", "Select All",
    "Select all visible items", "\U0001F7E9", @["CtrlZ"],
    proc(s: var AppState) = s.selectAll())
  state.registerCommand("remove_selected", "Delete Selected",
    "Move selected tracks to trash", "\u274C", @["AltX"],
    proc(s: var AppState) = s.deleteConfirm())
  state.registerCommand("add_to_playlist", "Add to Playlist...",
    "Add selected items to playlist", "\U0001F4CB", @["AltP"],
    proc(s: var AppState) = s.addToPlaylist())
  state.registerCommand("tab_now_playing", "Now Playing",
    "Switch to Now Playing tab", "\U0001F3B5", @["1"],
    proc(s: var AppState) = s.switchTab(tabNowPlaying))
  state.registerCommand("tab_library", "Library",
    "Switch to Library tab", "\U0001F4DA", @["2"],
    proc(s: var AppState) = s.switchTab(tabLibrary))
  state.registerCommand("tab_settings", "Settings",
    "Switch to Settings tab", "\u2699", @["3"],
    proc(s: var AppState) = s.switchTab(tabSettings))
  state.registerCommand("show_help", "Show Help",
    "Display help overlay with keybindings", "\u2753", @["AltH"],
    proc(s: var AppState) = s.helpVisible = true)
  state.registerCommand("show_about", "About",
    "Show system information and build details", "\u24D8", @["AltA"],
    proc(s: var AppState) = s.aboutVisible = true)
  state.registerCommand("show_trash", "Trash",
    "Browse trashed files and restore or delete them", "\U0001F5D1", @["AltT"],
    proc(s: var AppState) =
      if s.player.backendType == abtDaemon:
        let cli = DaemonService(s.svc)
        let resp = cli.listTrash()
        if resp.hasKey("trash"):
          s.overlay = OverlayState(kind: okTrashView, query: "")
          s.trashItems = @[]
          for item in resp["trash"]:
            s.trashItems.add(TrashItem(
              id: item["id"].getInt(0),
              trackId: item["track_id"].getInt(0).int64,
              originalPath: item["original_path"].getStr(""),
              trashPath: item["trash_path"].getStr(""),
              trashedAt: item["trashed_at"].getInt(0),
              expiresAt: item["expires_at"].getInt(0)
            ))
          s.updateTrashResults())
  state.registerCommand("show_equalizer", "EQ Presets",
    "Browse and preview equalizer presets", "\U0001F3B5", @["AltE"],
    proc(s: var AppState) =
      if s.player.backendType == abtDaemon:
        let cli = DaemonService(s.svc)
        let resp = cli.getEqPresets()
        if resp.hasKey("presets"):
          s.eqPresetList = @[]
          for p in resp["presets"]:
            s.eqPresetList.add(p.getStr(""))
      s.overlay = OverlayState(kind: okEqPresetPicker, query: "")
      s.updateEqPresetPickerResults())
  state.registerCommand("quit_background", "Quit (Background)",
    "Exit TUI, keep playback running", "\u23F8", @["q"],
    proc(s: var AppState) = s.quitBackground())
  state.registerCommand("quit_daemon", "Quit & Stop Daemon",
    "Exit and terminate background daemon", "\u23F9", @["ShiftQ"],
    proc(s: var AppState) = s.quitDaemon())
  state.registerCommand("command_palette", "Command Palette",
    "Show command palette with fuzzy search", "\u2328", @["Colon"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okCommandPalette, query: "")
      for i in 0..<s.commands.len: s.overlay.results.add(i))
  state.registerCommand("change_theme", "Change Theme",
    "Open theme picker with live preview", "\U0001F3A8", @["AltC"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okThemePicker, query: "")
      s.updateThemePickerResults())
  state.registerCommand("save_playlist", "Save Playlist",
    "Save current queue as a playlist file", "\U0001F4BE", @[],
    proc(s: var AppState) = s.saveCurrentQueue())
  state.registerCommand("create_playlist", "Create Playlist",
    "Create a new playlist", "\U0001F4CB", @["a"],
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
    "Mark or unmark the selected track as favourite", "\u2605", @["F"],
    proc(s: var AppState) =
      let idx = s.selectIndex
      let items = s.displayItems
      if idx >= 0 and idx < items.len and items[idx].trackIdx >= 0:
        let tid = items[idx].id
        if tid > 0:
          if tid in s.favouriteIds:
            s.favouriteIds.excl(tid)
            if s.player.backendType == abtDaemon:
              discard DaemonService(s.svc).removeFavourite(tid)
            s.showNotification("Removed from favourites", nkInfo)
          else:
            s.favouriteIds.incl(tid)
            if s.player.backendType == abtDaemon:
              discard DaemonService(s.svc).addFavourite(tid)
            s.showNotification("Added to favourites", nkSuccess)
          s.markDirty(ceTrack))
  state.registerCommand("import_m3u", "Import M3U",
    "Import a playlist from .m3u file", "\U0001F4C2", @[],
    proc(s: var AppState) =
      s.playlistInputActive = true; s.playlistInputPrompt = "Import M3U path:"; s.playlistInputBuffer = "")
  state.registerCommand("rescan_library", "Rescan Library",
    "Rescan music directories for new files", "\U0001F504", @[],
    proc(s: var AppState) =
      s.libraryTracks = @[]; s.libraryLoading = true; s.loadLibrary(); s.rebuildItems())
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
    "Search YouTube for music to stream or download", "\U0001F50D", @["AltY"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okYtSearch, query: "")
      s.ytDebounceAt = 0)
  state.registerCommand("spotify_url", "Import Spotify URL",
    "Import a Spotify playlist or track from URL", "\U0001F4CB", @["AltS"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okSpotifyUrlInput, query: "")
      s.setFeedback("Paste a Spotify playlist URL (e.g. https://open.spotify.com/playlist/...)"))
  state.registerCommand("spotify_search", "Spotify Search",
    "Search Spotify for tracks", "\U0001F3B5", @["CtrlE"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okSpotifySearch, query: "")
      s.spSearchResults = @[]
      s.spSearchLoading = false)
  state.registerCommand("toggle_lyrics", "Toggle Lyrics",
    "Show or hide synced lyrics in Now Playing tab", "\U0001F3B5", @["AltL"],
    proc(s: var AppState) =
      s.lyricsVisible = not s.lyricsVisible
      s.markDirty(ceTrack))
  state.registerCommand("search_lyrics", "Search Lyrics",
    "Search for song lyrics by artist and title", "\U0001F50D", @["ShiftL"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okLyricsSearch, query: "")
      if s.currentPlayingTitle.len > 0:
        s.overlay.query = s.currentPlayingTitle & " " & s.currentPlayingChannel
      s.overlay.lyricsSearchResults = @[])
  state.registerCommand("yt_recommended", "Recommended Playlists",
    "Search YT for playlists related to current track", "\U0001F3B6", @["CtrlR"],
    proc(s: var AppState) =
      var q = s.ytStreamTitle
      if s.ytStreamChannel.len > 0:
        q &= " " & s.ytStreamChannel
      q &= " playlist"
      s.switchTab(tabNowPlaying)
      if q.len > 0:
        s.overlay = OverlayState(kind: okYtSearch, query: q)
        s.ytDebounceAt = 0)
  state.registerCommand("fuzzy_finder", "Fuzzy Finder",
    "Search all library tracks by name", "\U0001F50D", @["AltF"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okFuzzyFinder, query: "")
      for i in 0..<s.libraryTracks.len:
        s.overlay.results.add(i)
        let t = s.libraryTracks[i]
        s.overlay.strResults.add(t.displayName() & "  \u2014  " & t.displayArtist()))
  state.registerCommand("download_track", "Download Track",
    "Download the currently selected YouTube or Spotify track", "\u2B07", @["CtrlD"],
    proc(s: var AppState) =
      if s.overlay.kind == okYtSearch and s.overlay.ytResults.len > 0 and
         s.overlay.cursor >= 0 and s.overlay.cursor < s.overlay.ytResults.len:
        let r = s.overlay.ytResults[s.overlay.cursor]
        if r.kind == srkVideo:
          if s.player.backendType == abtDaemon:
            let cli = DaemonService(s.svc)
            discard cli.ytDownload(r.url, r.title, r.channel)
            s.ytDownloadActive = true
            s.showNotification("Downloading: " & r.title, nkInfo)
        else:
          s.showNotification("Cannot download a playlist directly", nkWarning)
      else:
        s.showNotification("Select a YouTube result first", nkInfo))
  state.registerCommand("queue_picker", "Enqueue",
    "Add tracks to playback queue", "\U0001F3B6", @["CtrlA", "AltI"],
    proc(s: var AppState) =
      s.overlay = OverlayState(kind: okQueuePicker, query: "")
      if s.displayItems.len > 0:
        for idx, item in s.displayItems:
          s.overlay.results.add(idx))

proc execCmd(state: var AppState, cmdId: string) =
  let idx = findCommandIdx(state, cmdId)
  if idx >= 0:
    if state.overlay.kind == okNone and not state.helpVisible and not state.aboutVisible:
      state.lastCommandName = state.commands[idx].name
    state.commands[idx].handler(state)

proc handleEqPresetPickerOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape:
    state.overlay.clear()
  of iw.Key.Enter:
    if state.overlay.strResults.len > 0 and state.overlay.cursor >= 0 and
       state.overlay.cursor < state.overlay.strResults.len:
      state.applyEqPreset(state.overlay.strResults[state.overlay.cursor])
    state.overlay.clear()
  of iw.Key.Backspace:
    if state.overlay.query.len > 0:
      state.overlay.query = state.overlay.query[0..^2]
      state.updateEqPresetPickerResults()
  of iw.Key.Down:
    if state.overlay.cursor < state.overlay.strResults.len - 1:
      state.overlay.cursor.inc
      if state.overlay.cursor < state.overlay.strResults.len:
        state.applyEqPreset(state.overlay.strResults[state.overlay.cursor])
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
      if state.overlay.cursor < state.overlay.strResults.len:
        state.applyEqPreset(state.overlay.strResults[state.overlay.cursor])
  else:
    for ch in chars:
      let code = ch.int
      if code >= 32 and code < 127:
        state.overlay.query &= $ch
        state.updateEqPresetPickerResults()
    state.overlay.cursor = 0
  if state.overlay.strResults.len > 0:
    state.overlay.cursor = min(state.overlay.cursor, state.overlay.strResults.len - 1)

proc persistConfigIfDirty(state: var AppState) =
  if state.configDirty:
    state.configDirty = false
    state.saveConfig()
    state.applyOnConfig()

proc overlayScrollCfg(state: var AppState, visible: int) =
  let total = if state.overlay.ytResults.len > 0: state.overlay.ytResults.len else: state.overlay.results.len
  if total == 0: return
  let c = state.overlay.cursor
  let so = state.overlay.scrollOffset
  if c < so:
    state.overlay.scrollOffset = c
  elif c >= so + visible and visible > 0:
    state.overlay.scrollOffset = c - visible + 1
  let maxOff = max(0, total - visible)
  state.overlay.scrollOffset = max(0, min(state.overlay.scrollOffset, maxOff))

proc handleThemePickerOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
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
  of iw.Key.Down:
    if state.overlay.cursor < state.overlay.strResults.len - 1:
      state.overlay.cursor.inc
      let seed = state.overlay.strResults[state.overlay.cursor]
      state.applyTheme(seed)
  of iw.Key.Up:
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

proc handleYtSearchOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape:
    state.overlay.clear()
    state.ytDebounceAt = 0
    state.ytSearchQuery = ""
    state.ytSearchLoading = false
  of iw.Key.Tab:
    if state.overlay.ytSubTab == ystAll:
      state.overlay.ytSubTab = ystPlaylists
    else:
      state.overlay.ytSubTab = ystAll
    state.overlay.cursor = 0
    state.overlay.ytResults = @[]
    state.ytSearchQuery = ""
    state.ytDebounceAt = epochTime() + 0.3
    state.markDirty(ceSearchResults)
  of iw.Key.CtrlS:
    if state.overlay.multiMode:
      state.overlay.multiMode = false
      state.overlay.selected = initHashSet[int]()
    else:
      state.overlay.multiMode = true
      if state.overlay.ytResults.len > 0:
        state.overlay.selected.incl(state.overlay.cursor)
  of iw.Key.Down, iw.Key.CtrlN:
    if state.overlay.ytAutocompleteVisible and state.overlay.ytAutocompleteSuggestions.len > 0:
      if state.overlay.ytAutocompleteCursor < state.overlay.ytAutocompleteSuggestions.len - 1:
        state.overlay.ytAutocompleteCursor.inc
    elif state.overlay.cursor < state.overlay.ytResults.len - 1:
      state.overlay.cursor.inc
      state.overlayScrollCfg(15)
    elif state.overlay.ytResults.len > 0:
      state.ytSearchPage.inc
      state.ytDebounceAt = epochTime() + 0.3
      state.markDirty(ceSearchResults)
  of iw.Key.Up, iw.Key.CtrlP:
    if state.overlay.ytAutocompleteVisible and state.overlay.ytAutocompleteSuggestions.len > 0:
      if state.overlay.ytAutocompleteCursor > 0:
        state.overlay.ytAutocompleteCursor.dec
    elif state.overlay.cursor > 0:
      state.overlay.cursor.dec
      state.overlayScrollCfg(15)
  of iw.Key.Enter:
    if state.overlay.ytAutocompleteVisible and state.overlay.ytAutocompleteSuggestions.len > 0:
      state.overlay.query = state.overlay.ytAutocompleteSuggestions[state.overlay.ytAutocompleteCursor]
      state.overlay.ytAutocompleteVisible = false
      state.overlay.ytAutocompleteSuggestions = @[]
      state.ytDebounceAt = epochTime() + 0.3
    elif state.overlay.ytResults.len > 0:
      if state.overlay.multiMode:
        let idx = state.overlay.cursor
        if idx in state.overlay.selected: state.overlay.selected.excl(idx)
        else: state.overlay.selected.incl(idx)
      else:
        let r = state.overlay.ytResults[state.overlay.cursor]
        if r.kind == srkPlaylist and state.player.backendType == abtDaemon:
          let cli = DaemonService(state.svc)
          if state.ytPlaylistFetching:
            state.setFeedback("Playlist fetch already in progress")
          else:
            let plResp = cli.ytFetchPlaylist(r.url)
            if plResp.hasKey("pending") and plResp["pending"].getBool():
              state.ytPlaylistFetching = true
              state.ytSearchLoading = true
              state.setFeedback("Fetching playlist tracks...")
            else:
              state.setFeedback("Failed to start playlist fetch")
        else:
          state.overlay.clear()
          state.ytStreamPendingItem = r
          if state.player.backendType == abtDaemon:
            let cli = DaemonService(state.svc)
            if state.ytAutoDownload:
              discard cli.ytDownload(r.url, r.title, r.channel)
              state.ytDownloadActive = true
              state.setFeedback("Downloading: " & r.title)
            else:
              discard cli.ytResolveStream(r.url)
              state.ytStreamResolving = true
              state.setFeedback("Resolving stream URL...")
  of iw.Key.CtrlA:
    proc addToBothQueues(state: var AppState, items: seq[YtSearchResult]) =
      var daemonItems: seq[tuple[path, title, channel: string]] = @[]
      for item in items:
        let track = Track(
          path: item.url, title: item.title, artist: item.channel,
          album: "YouTube", duration: 0.0,
          id: int64(state.libraryTracks.len + 1)
        )
        state.libraryTracks.add(track)
        state.playbackQueue.add(state.libraryTracks.len - 1)
        daemonItems.add((item.url, item.title, item.channel))
      state.rebuildItems()
      state.markDirty(ceQueue)
      if daemonItems.len > 0 and state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        if cli.isConnected:
          discard cli.queueAdd(daemonItems)
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
  of iw.Key.CtrlD:
    if state.player.backendType == abtDaemon:
      let cli = DaemonService(state.svc)
      if state.overlay.multiMode:
        if state.overlay.selected.len > 0:
          for idx in state.overlay.selected:
            if idx >= 0 and idx < state.overlay.ytResults.len:
              let r = state.overlay.ytResults[idx]
              discard cli.ytDownload(r.url, r.title, r.channel)
          state.ytDownloadActive = true
          state.showNotification("Downloading " & $state.overlay.selected.len & " items")
      elif state.overlay.ytResults.len > 0 and
         state.overlay.cursor >= 0 and state.overlay.cursor < state.overlay.ytResults.len:
        let r = state.overlay.ytResults[state.overlay.cursor]
        discard cli.ytDownload(r.url, r.title, r.channel)
        state.ytDownloadActive = true
        state.ytStreamPendingItem = r
        state.setFeedback("Downloading: " & r.title)
  of iw.Key.Backspace:
    if state.overlay.query.len > 0:
      state.overlay.query = state.overlay.query[0..^2]
      state.ytDebounceAt = epochTime() + 0.3
      state.overlay.ytAutocompleteSuggestions = @[]
      state.overlay.ytAutocompleteVisible = false
  else:
    for ch in chars:
      let code = ch.int
      if code >= 32 and code < 127:
        state.overlay.query &= $ch
        state.ytDebounceAt = epochTime() + 0.3
        checkAutocomplete(state)

proc handleSpotifySearchOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape:
    state.overlay.clear()
  of iw.Key.Down:
    if state.overlay.cursor < state.spSearchResults.len - 1:
      state.overlay.cursor.inc
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
  of iw.Key.Enter:
    if state.overlay.cursor >= 0 and state.overlay.cursor < state.spSearchResults.len:
      let r = state.spSearchResults[state.overlay.cursor]
      state.overlay.clear()
      state.overlay = OverlayState(kind: okYtSearch, query: r.name & " " & r.artist, cursor: 0)
      if state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        cli.sendOnly(%*{"cmd": "yt_search", "query": state.overlay.query})
  of iw.Key.Backspace:
    if state.overlay.query.len > 0:
      state.overlay.query = state.overlay.query[0..^2]
      state.spSearchLoading = true
      if state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let resp = cli.spSearch(state.overlay.query)
        if resp.hasKey("results"):
          state.spSearchResults = @[]
          for item in resp["results"]:
            state.spSearchResults.add((id: item{"id"}.getStr(""), name: item{"name"}.getStr(""),
              artist: item{"artist"}.getStr(""), album: item{"album"}.getStr(""),
              url: item{"url"}.getStr(""), durationMs: item{"duration_ms"}.getInt(0)))
        state.spSearchLoading = false
  else:
    for ch in chars:
      let code = ch.int
      if code >= 32 and code < 127:
        state.overlay.query &= $ch
        state.spSearchLoading = true
        if state.player.backendType == abtDaemon:
          let cli = DaemonService(state.svc)
          let resp = cli.spSearch(state.overlay.query)
          if resp.hasKey("results"):
            state.spSearchResults = @[]
            for item in resp["results"]:
              state.spSearchResults.add((id: item{"id"}.getStr(""), name: item{"name"}.getStr(""),
                artist: item{"artist"}.getStr(""), album: item{"album"}.getStr(""),
                url: item{"url"}.getStr(""), durationMs: item{"duration_ms"}.getInt(0)))
          state.spSearchLoading = false

proc handleLyricsSearchOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape:
    state.overlay.clear()
  of iw.Key.Down:
    if state.overlay.cursor < state.overlay.lyricsSearchResults.len - 1:
      state.overlay.cursor.inc
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
  of iw.Key.Enter:
    if state.overlay.cursor >= 0 and state.overlay.cursor < state.overlay.lyricsSearchResults.len:
      let r = state.overlay.lyricsSearchResults[state.overlay.cursor]
      state.overlay.clear()
      if state.player.backendType == abtDaemon:
        DaemonService(state.svc).sendOnly(%*{"cmd": "request_lyrics",
          "path": state.currentPlayingPath, "title": r.title,
          "artist": r.artist, "duration": r.duration})
  of iw.Key.Backspace:
    if state.overlay.query.len > 0:
      state.overlay.query = state.overlay.query[0..^2]
      state.overlay.lyricsSearchResults = @[]
      state.overlay.cursor = 0
      if state.player.backendType == abtDaemon and state.overlay.query.len > 0:
        let parts = state.overlay.query.split(' ', 1)
        let artist = if parts.len > 1: parts[1] else: ""
        DaemonService(state.svc).sendOnly(%*{"cmd": "search_lyrics", "title": parts[0], "artist": artist})
  else:
    for ch in chars:
      let code = ch.int
      if code >= 32 and code < 127:
        state.overlay.query &= $ch
        state.overlay.lyricsSearchResults = @[]
        state.overlay.cursor = 0
        if state.player.backendType == abtDaemon and state.overlay.query.len > 0:
          let parts = state.overlay.query.split(' ', 1)
          let artist = if parts.len > 1: parts[1] else: ""
          DaemonService(state.svc).sendOnly(%*{"cmd": "search_lyrics", "title": parts[0], "artist": artist})

proc handleYtBatchOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  if state.overlay.batchShowPls:
    case key
    of iw.Key.Escape:
      state.overlay.batchShowPls = false
      state.overlay.cursor = 0
    of iw.Key.Down:
      if state.overlay.cursor < state.libraryPlaylists.len - 1:
        state.overlay.cursor.inc
    of iw.Key.Up:
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
    of iw.Key.Escape: state.overlay.clear()
    of iw.Key.Down:
      if state.overlay.cursor < 2: state.overlay.cursor.inc
    of iw.Key.Up:
      if state.overlay.cursor > 0: state.overlay.cursor.dec
    of iw.Key.Enter:
      let sel = state.overlay.cursor
      let items = state.overlay.batchItems
      state.overlay.clear()
      case sel
      of 0:
        var daemonItems: seq[tuple[path, title, channel: string]] = @[]
        for item in items:
          let track = Track(
            path: item.url, title: item.title, artist: item.channel,
            album: "YouTube", duration: 0.0,
            id: int64(state.libraryTracks.len + 1)
          )
          state.libraryTracks.add(track)
          state.playbackQueue.add(state.libraryTracks.len - 1)
          daemonItems.add((item.url, item.title, item.channel))
        state.rebuildItems()
        state.markDirty(ceQueue)
        if daemonItems.len > 0 and state.player.backendType == abtDaemon:
          let cli = DaemonService(state.svc)
          if cli.isConnected:
            discard cli.queueAdd(daemonItems)
        state.showNotification("Added " & $items.len & " items to queue")
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

proc handleSpotifyUrlOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
  of iw.Key.Enter:
    let input = state.overlay.query.strip()
    if input.len > 0:
      if input.startsWith("https://"):
        state.overlay = OverlayState(kind: okYtSearch, query: input, cursor: 0)
        state.overlay.ytSubTab = ystAll
        state.overlay.ytAutocompleteVisible = false
        state.overlay.ytResults = @[]
        state.ytSearchLoading = true
        if state.player.backendType == abtDaemon:
          let cli = DaemonService(state.svc)
          let resp = cli.ytFetchPlaylist(input)
          if resp.hasKey("ok") and resp["ok"].getBool(false):
            state.showNotification("Fetching Spotify playlist...")
          else:
            let err = if resp.hasKey("error"): resp["error"].getStr("") else: "unknown error"
            state.setFeedback("Failed: " & err)
            state.overlay.clear()
        else:
          state.setFeedback("Daemon not connected")
          state.overlay.clear()
      else:
        state.setFeedback("Please enter a valid Spotify playlist URL (starting with https://)")
    else:
      state.overlay.clear()
  of iw.Key.Backspace:
    if state.overlay.query.len > 0:
      state.overlay.query = state.overlay.query[0..^2]
  else:
    for ch in chars:
      let code = ch.int
      if code >= 32 and code < 127:
        state.overlay.query &= $ch

proc handleQueuePickerOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
  of iw.Key.Down:
    if state.overlay.cursor < state.overlay.results.len - 1:
      state.overlay.cursor.inc
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
  of iw.Key.Enter:
    var items: seq[(string, string, string)] = @[]
    for idx in state.overlay.selected:
      if idx >= 0 and idx < state.libraryTracks.len:
        state.playbackQueue.add(idx)
        let t = state.libraryTracks[idx]
        items.add((t.path, t.title, t.artist))
    if items.len > 0 and state.player.backendType == abtDaemon:
      discard DaemonService(state.svc).queueAdd(items)
    state.markDirty(ceQueue)
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
      if idx in state.overlay.selected: state.overlay.selected.excl(idx)
      else: state.overlay.selected.incl(idx)
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

proc handleQueueOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
  of iw.Key.Down:
    if state.overlay.cursor < state.playbackQueue.len - 1:
      state.overlay.cursor.inc
      state.overlayScrollCfg(15)
      state.overlay = OverlayState(kind: okQueueOverlay, cursor: state.overlay.cursor, scrollOffset: state.overlay.scrollOffset)
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
      state.overlayScrollCfg(15)
      state.overlay = OverlayState(kind: okQueueOverlay, cursor: state.overlay.cursor, scrollOffset: state.overlay.scrollOffset)
  of iw.Key.Enter:
    if state.playbackQueue.len > 0 and state.overlay.cursor >= 0 and
       state.overlay.cursor < state.playbackQueue.len:
      let qIdx = state.overlay.cursor
      let tIdx = state.playbackQueue[qIdx]
      state.overlay.clear()
      let trackPath =
        if tIdx >= 0 and tIdx < state.libraryTracks.len:
          state.libraryTracks[tIdx].path
        elif qIdx < state.queuePaths.len:
          state.queuePaths[qIdx]
        else: ""
      if trackPath.len > 0:
        if state.player.backendType == abtDaemon:
          discard DaemonService(state.svc).queueRemovePath(trackPath)
        state.playbackQueue.delete(qIdx)
        if state.queuePaths.len > qIdx:
          state.queuePaths.delete(qIdx)
        if state.queueCursor >= qIdx and state.queueCursor > 0:
          state.queueCursor.dec
        discard state.player.loadFile(trackPath)
        state.player.play()
        state.status = psPlaying
        state.currentPlayingPath = trackPath
        if tIdx >= 0 and tIdx < state.libraryTracks.len:
          let track = state.libraryTracks[tIdx]
          state.currentPlayingTitle = track.title
          state.currentPlayingChannel = track.artist
          state.currentPlayingId = track.id
        state.ytStreamTitle = state.currentPlayingTitle
        state.ytStreamChannel = state.currentPlayingChannel
        state.markDirtyBatch(cePlayState, ceTrack, ceQueue)
  of iw.Key.D:
    if state.playbackQueue.len > 0 and state.overlay.cursor >= 0 and
       state.overlay.cursor < state.playbackQueue.len:
      let qIdx = state.overlay.cursor
      let tIdx = state.playbackQueue[qIdx]
      let dName =
        if tIdx >= 0 and tIdx < state.libraryTracks.len:
          state.libraryTracks[tIdx].displayName()
        elif qIdx < state.queuePaths.len:
          state.queuePaths[qIdx].splitFile().name.replace(".", " ")
        else: "Unknown"
      let removePath =
        if tIdx >= 0 and tIdx < state.libraryTracks.len:
          state.libraryTracks[tIdx].path
        elif qIdx < state.queuePaths.len:
          state.queuePaths[qIdx]
        else: ""
      state.showNotification("Removed '" & dName & "' from queue")
      if state.player.backendType == abtDaemon and removePath.len > 0:
        discard DaemonService(state.svc).queueRemovePath(removePath)
      state.playbackQueue.delete(qIdx)
      if state.queuePaths.len > qIdx:
        state.queuePaths.delete(qIdx)
      state.queueCursor = min(state.queueCursor, state.playbackQueue.len - 1)
      if state.playbackQueue.len == 0:
        state.overlay.clear()
      else:
        state.overlay = OverlayState(kind: okQueueOverlay, cursor: min(state.overlay.cursor, state.playbackQueue.len - 1))
  of iw.Key.A:
    state.overlay = OverlayState(kind: okQueuePicker, query: "")
    for i in 0..<state.libraryTracks.len: state.overlay.results.add(i)
  else: discard

proc handlePlaylistSearchOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
  of iw.Key.Down:
    if state.overlay.cursor < state.overlay.results.len - 1:
      state.overlay.cursor.inc
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
  of iw.Key.Enter:
    if state.overlay.results.len > 0 and state.overlay.cursor >= 0 and
       state.overlay.cursor < state.overlay.results.len:
      let idx = state.overlay.results[state.overlay.cursor]
      if idx in state.overlay.selected: state.overlay.selected.excl(idx)
      else: state.overlay.selected.incl(idx)
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
              if state.player.backendType == abtDaemon:
                discard DaemonService(state.svc).addToPlaylist(state.libraryPlaylists[plIdx].id, track.id, state.libraryPlaylists[plIdx].trackIds.len - 1)
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
              if state.player.backendType == abtDaemon:
                discard DaemonService(state.svc).removeFromPlaylist(state.libraryPlaylists[plIdx].id, trackId)
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

proc handleCommandPaletteOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
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
  of iw.Key.Slash: state.overlay.query = ""
  of iw.Key.Down:
    state.overlay.cursor = (state.overlay.cursor + 1) mod max(state.overlay.results.len, 1)
    state.overlayScrollCfg(20)
  of iw.Key.Up:
    state.overlay.cursor = (state.overlay.cursor - 1 + state.overlay.results.len) mod max(state.overlay.results.len, 1)
    state.overlayScrollCfg(20)
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

proc handleFuzzyFinderOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
  of iw.Key.Enter:
    if state.overlay.results.len > 0 and state.overlay.cursor >= 0 and
       state.overlay.cursor < state.overlay.results.len:
      let idx = state.overlay.results[state.overlay.cursor]
      state.overlay.clear()
      if idx >= 0 and idx < state.libraryTracks.len:
        let track = state.libraryTracks[idx]
        state.playTrackFromLibrary(track.path, track.title, track.artist, idx)
  of iw.Key.Down:
    if state.overlay.cursor < state.overlay.results.len - 1:
      state.overlay.cursor.inc
      state.overlayScrollCfg(20)
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
      state.overlayScrollCfg(20)
  of iw.Key.Backspace:
    if state.overlay.query.len > 0:
      state.overlay.query = state.overlay.query[0..^2]
  else:
    for ch in chars:
      let code = ch.int
      if code >= 32 and code < 127:
        state.overlay.query &= $ch
  state.overlay.results = @[]
  state.overlay.strResults = @[]
  if state.overlay.query.len > 0:
    let q = state.overlay.query.toLowerAscii()
    for i, t in state.libraryTracks:
      if fuzzyMatch(q, t.displayName().toLowerAscii()) or
         fuzzyMatch(q, t.displayArtist().toLowerAscii()):
        state.overlay.results.add(i)
        state.overlay.strResults.add(t.displayName() & "  \u2014  " & t.displayArtist())
  else:
    for i, t in state.libraryTracks:
      state.overlay.results.add(i)
      state.overlay.strResults.add(t.displayName() & "  \u2014  " & t.displayArtist())
  if state.overlay.results.len > 0:
    state.overlay.cursor = min(state.overlay.cursor, state.overlay.results.len - 1)
  else:
    state.overlay.cursor = 0

proc handleTrashOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape: state.overlay.clear()
  of iw.Key.Down:
    if state.overlay.cursor < state.overlay.results.len - 1:
      state.overlay.cursor.inc
      state.overlayScrollCfg(15)
  of iw.Key.Up:
    if state.overlay.cursor > 0:
      state.overlay.cursor.dec
      state.overlayScrollCfg(15)
  of iw.Key.Enter:
    if state.overlay.results.len > 0 and state.overlay.cursor >= 0 and
       state.overlay.cursor < state.overlay.results.len:
      let idx = state.overlay.results[state.overlay.cursor]
      let item = state.trashItems[idx]
      if state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let resp = cli.restoreTrack(item.id)
        if resp{"ok"}.getBool(false):
          state.showNotification("Restored: " & item.originalPath.splitPath().tail, nkSuccess)
          let resp2 = cli.listTrash()
          if resp2.hasKey("trash"):
            state.trashItems = @[]
            for ti in resp2["trash"]:
              state.trashItems.add(TrashItem(
                id: ti["id"].getInt(0),
                trackId: ti["track_id"].getInt(0).int64,
                originalPath: ti["original_path"].getStr(""),
                trashPath: ti["trash_path"].getStr(""),
                trashedAt: ti["trashed_at"].getInt(0),
                expiresAt: ti["expires_at"].getInt(0)
              ))
          state.updateTrashResults()
        else:
          state.showNotification("Failed to restore", nkError)
    state.overlay.clear()
  of iw.Key.Delete, iw.Key.ShiftX:
    if state.overlay.results.len > 0 and state.overlay.cursor >= 0 and
       state.overlay.cursor < state.overlay.results.len:
      let idx = state.overlay.results[state.overlay.cursor]
      let item = state.trashItems[idx]
      if state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        discard cli.permanentDeleteTrash(item.id)
        let resp2 = cli.listTrash()
        if resp2.hasKey("trash"):
          state.trashItems = @[]
          for ti in resp2["trash"]:
            state.trashItems.add(TrashItem(
              id: ti["id"].getInt(0),
              trackId: ti["track_id"].getInt(0).int64,
              originalPath: ti["original_path"].getStr(""),
              trashPath: ti["trash_path"].getStr(""),
              trashedAt: ti["trashed_at"].getInt(0),
              expiresAt: ti["expires_at"].getInt(0)
            ))
        state.trashItems.delete(idx)
        state.updateTrashResults()
        state.showNotification("Permanently deleted", nkWarning)
  of iw.Key.P:
    if state.player.backendType == abtDaemon:
      let cli = DaemonService(state.svc)
      let resp = cli.purgeTrash()
      let n = resp{"purged"}.getInt(0)
      let resp2 = cli.listTrash()
      if resp2.hasKey("trash"):
        state.trashItems = @[]
        for ti in resp2["trash"]:
          state.trashItems.add(TrashItem(
            id: ti["id"].getInt(0),
            trackId: ti["track_id"].getInt(0).int64,
            originalPath: ti["original_path"].getStr(""),
            trashPath: ti["trash_path"].getStr(""),
            trashedAt: ti["trashed_at"].getInt(0),
            expiresAt: ti["expires_at"].getInt(0)
          ))
      state.updateTrashResults()
      if n > 0:
        state.showNotification("Purged " & $n & " expired item(s)", nkInfo)
      else:
        state.showNotification("No expired items to purge", nkInfo)
  of iw.Key.Backspace:
    if state.overlay.query.len > 0:
      state.overlay.query = state.overlay.query[0..^2]
      state.updateTrashResults()
  else:
    for ch in chars:
      let code = ch.int
      if code >= 32 and code < 127:
        state.overlay.query &= $ch
        state.updateTrashResults()
    state.overlay.cursor = 0
  if state.overlay.results.len > 0:
    state.overlay.cursor = min(state.overlay.cursor, state.overlay.results.len - 1)

proc handleFooterModulePickerOverlay(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  let allModules = [fmPlayStatus, fmVolume, fmBackend, fmDeviceName, fmSelectCount, fmTime, fmDate, fmRepeatShuffle, fmSleepTimer, fmKeyPressed, fmQueueCount, fmEqPreset, fmCurrentPlaylist]
  case key
  of iw.Key.Escape:
    state.footerPreset = fpnCustom
    state.saveConfig()
    state.overlay.clear()
  of iw.Key.Down:
    state.overlay.cursor = min(allModules.high, state.overlay.cursor + 1)
  of iw.Key.Up:
    state.overlay.cursor = max(0, state.overlay.cursor - 1)
  of iw.Key.Left, iw.Key.R:
    if state.overlay.cursor >= 0 and state.overlay.cursor < allModules.len:
      let m = allModules[state.overlay.cursor]
      state.footerLeftModules.incl(m)
      state.footerRightModules.excl(m)
  of iw.Key.Right, iw.Key.L:
    if state.overlay.cursor >= 0 and state.overlay.cursor < allModules.len:
      let m = allModules[state.overlay.cursor]
      state.footerRightModules.incl(m)
      state.footerLeftModules.excl(m)
  of iw.Key.Space:
    if state.overlay.cursor >= 0 and state.overlay.cursor < allModules.len:
      let m = allModules[state.overlay.cursor]
      state.footerLeftModules.excl(m)
      state.footerRightModules.excl(m)
  else: discard

proc handlePlaylistInput(state: var AppState, key: iw.Key, chars: seq[Rune]) =
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
            if state.player.backendType == abtDaemon:
              let resp = DaemonService(state.svc).deletePlaylist(plId)
              state.parsePlaylists(resp)
            else:
              state.libraryPlaylists.delete(idx)
              state.rebuildItems()
      elif state.playlistInputPrompt.contains("Rename"):
        let idx = state.selectIndex
        if idx >= 0 and idx < state.libraryPlaylists.len:
          let plId = state.libraryPlaylists[idx].id
          if state.player.backendType == abtDaemon:
            let resp = DaemonService(state.svc).renamePlaylist(plId, state.playlistInputBuffer)
            state.parsePlaylists(resp)
          else:
            state.libraryPlaylists[idx].name = state.playlistInputBuffer
            state.rebuildItems()
      elif state.playlistInputPrompt.contains("Import M3U"):
        let p = state.playlistInputBuffer
        if fileExists(p):
          let paths = parseM3u(p)
          let startIdx = state.libraryTracks.len
          for path in paths:
            let (title, artist, album) = parseFilenameMetadata(path)
            state.libraryTracks.add(Track(
              path: path, title: title, artist: artist, album: album,
              duration: 0.0, id: int64(state.libraryTracks.len + 1)
            ))
          state.rebuildItems()
          let addedCount = state.libraryTracks.len - startIdx
          if addedCount > 0:
            state.playbackQueue = @[]
            for i in startIdx..<state.libraryTracks.len:
              state.playbackQueue.add(i)
            if state.player.backendType == abtDaemon:
              let cli = DaemonService(state.svc)
              if cli.isConnected:
                discard daemonSimpleCmd(cli, "queue_clear")
                var items: seq[(string, string, string)] = @[]
                for idx in state.playbackQueue:
                  let t = state.libraryTracks[idx]
                  items.add((t.path, t.title, t.artist))
                discard cli.queueAdd(items)
          state.nextTrack()
          state.setFeedback("Imported " & $addedCount & " tracks from M3U")
      elif state.playlistInputPrompt.contains("Sleep timer"):
        let minutes = state.playlistInputBuffer.parseInt()
        if state.player.backendType == abtDaemon:
          discard DaemonService(state.svc).setSleepTimer(minutes)
        state.sleepTimerRemaining = if minutes > 0: minutes else: 0
      else:
        if state.player.backendType == abtDaemon:
          let resp = DaemonService(state.svc).createPlaylist(state.playlistInputBuffer)
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

proc handleFilterMode(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Escape:
    state.mode = imNormal
    state.filterText = ""
    state.applyFilter()
  of iw.Key.Enter:
    state.mode = imNormal
    if state.tab == tabSettings and state.settingsCategory == scYouTube and state.selectIndex == 1:
      state.ytCookieFilePath = state.filterText
      state.saveConfig()
      state.setFeedback("Cookie file set: " & state.ytCookieFilePath)
      state.filterText = ""
    elif state.tab == tabSettings and state.settingsCategory == scSpotify and state.selectIndex == 1:
      state.spCookieFilePath = state.filterText
      if state.player.backendType == abtDaemon:
        discard DaemonService(state.svc).spSetConfig(state.spCookieSource, state.spCookieFilePath, state.spAudioFormat)
      state.saveConfig()
      state.setFeedback("Cookie file set: " & state.spCookieFilePath)
      state.filterText = ""
    elif state.filteredCount() > 0 and state.selectIndex >= 0:
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

proc handleMainKey(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  case key
  of iw.Key.Colon:
    execCmd(state, "command_palette")
  of iw.Key.Space:
    if guardDebounce(state): return
    execCmd(state, "toggle_play_pause")
  of iw.Key.Tab:
    if state.tab == tabSettings:
      if state.settingsFocusPanel == lpSidebar:
        state.settingsFocusPanel = lpContent
      else:
        state.settingsFocusPanel = lpSidebar
    elif state.libraryFocusPanel == lpSidebar:
      state.libraryFocusPanel = lpContent
    else:
      state.libraryFocusPanel = lpSidebar
    state.needsRedraw = true
  of iw.Key.CtrlS:
    if guardDebounce(state): return
    execCmd(state, "stop_playback")
  of iw.Key.CtrlN:
    if guardDebounce(state): return
    execCmd(state, "next_track")
  of iw.Key.CtrlP:
    if guardDebounce(state): return
    execCmd(state, "prev_track")
  of iw.Key.CtrlA: execCmd(state, "queue_picker")
  of iw.Key.CtrlD: execCmd(state, "download_track")
  of iw.Key.CtrlJ: execCmd(state, "nav_down")
  of iw.Key.CtrlK: execCmd(state, "nav_up")
  of iw.Key.CtrlG: execCmd(state, "go_to_first")
  of iw.Key.CtrlF: execCmd(state, "enter_filter")
  of iw.Key.CtrlR: execCmd(state, "yt_recommended")
  of iw.Key.AltY: execCmd(state, "yt_search")
  of iw.Key.AltC: execCmd(state, "change_theme")
  of iw.Key.AltE: execCmd(state, "show_equalizer")
  of iw.Key.AltS: execCmd(state, "spotify_url")
  of iw.Key.AltA: execCmd(state, "show_about")
  of iw.Key.AltQ:
    state.overlay = OverlayState(kind: okQueueOverlay, query: "", cursor: state.queueCursor)
  of iw.Key.AltP:
    execCmd(state, "create_playlist")
  of iw.Key.AltD:
    if state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      let tIdx = state.playbackQueue[state.queueCursor]
      var removePath = ""
      if tIdx >= 0 and tIdx < state.libraryTracks.len:
        removePath = state.libraryTracks[tIdx].path
      elif state.queueCursor < state.queuePaths.len and state.queuePaths[state.queueCursor].len > 0:
        removePath = state.queuePaths[state.queueCursor]
      else:
        let qLabel = if state.queueCursor < state.queuePaths.len: state.queuePaths[state.queueCursor].splitFile().name.replace(".", " ") else: "track"
        removePath = qLabel
      if removePath.len > 0:
        state.queuePendingConfirm = 1
        state.setFeedback("Remove item from queue? (Y/N)")
    elif state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "delete_playlist")
  of iw.Key.AltR:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "rename_playlist")
  of iw.Key.Down:
    if state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      if state.queueCursor < state.playbackQueue.len - 1:
        state.queueCursor.inc
        if state.queueCursor >= state.upNextScrollOffset + 5:
          state.upNextScrollOffset.inc
      state.markDirty(ceQueue)
    else:
      state.moveSelection(1)
  of iw.Key.Up:
    if state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      if state.queueCursor > 0:
        state.queueCursor.dec
        if state.queueCursor < state.upNextScrollOffset:
          state.upNextScrollOffset = max(0, state.upNextScrollOffset - 1)
      state.markDirty(ceQueue)
    else:
      state.moveSelection(-1)
  of iw.Key.Enter:
    if state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      let qIdx = state.queueCursor
      if qIdx >= 0 and qIdx < state.playbackQueue.len:
        let tIdx = state.playbackQueue[qIdx]
        let trackPath = if tIdx >= 0 and tIdx < state.libraryTracks.len:
          state.libraryTracks[tIdx].path
        elif qIdx < state.queuePaths.len:
          state.queuePaths[qIdx]
        else:
          ""
        if trackPath.len > 0:
          for i in 0..<qIdx:
            if state.playbackQueue.len > 0:
              state.playbackQueue.delete(0)
          if state.queuePaths.len >= qIdx:
            for i in 0..<qIdx:
              if state.queuePaths.len > 0:
                state.queuePaths.delete(0)
          state.queueCursor = 0
          discard daemonSimpleCmd(DaemonService(state.svc), "next")
          state.markDirty(cePlayState)
    elif state.tab != tabSettings and state.selectedIndices.len > 0:
      state.playSelected()
    elif state.tab != tabSettings and state.filteredCount() > 0 and state.selectIndex >= 0:
      state.playSelected()
  of iw.Key.S:
    if guardDebounce(state): return
    execCmd(state, "stop_playback")
  of iw.Key.H:
    if state.isPlaylistView():
      if state.playlistContentsIdx >= 0:
        state.playlistContentsIdx = -1
        state.selectIndex = 0
        state.rebuildItems()
        state.setFeedback("[Playlist Up]")
      elif state.libraryFocusPanel == lpContent:
        state.libraryFocusPanel = lpSidebar
        state.needsRedraw = true
    elif state.libraryFocusPanel == lpContent:
      state.libraryFocusPanel = lpSidebar
      state.needsRedraw = true
  of iw.Key.L:
    if state.isPlaylistView():
      if state.playlistContentsIdx < 0:
        let item = state.selectedItem()
        if item.kind == likPlaylist:
          let plIdx = state.selectIndex
          if plIdx >= 0 and plIdx < state.libraryPlaylists.len and state.libraryPlaylists[plIdx].trackIds.len == 0:
            discard
          else:
            state.playlistContentsIdx = state.selectIndex
            state.selectIndex = 0
            state.rebuildItems()
            state.setFeedback("[Playlist Down]")
    elif state.libraryFocusPanel == lpSidebar:
      state.libraryFocusPanel = lpContent
      state.needsRedraw = true
  of iw.Key.Comma: execCmd(state, "seek_backward")
  of iw.Key.Dot: execCmd(state, "seek_forward")
  of iw.Key.Left:
    if state.tab == tabSettings and state.settingsFocusPanel == lpContent:
      state.adjustSettingValue(-1)
    elif state.isPlaylistView():
      if state.playlistContentsIdx >= 0:
        state.playlistContentsIdx = -1; state.selectIndex = 0; state.rebuildItems(); state.setFeedback("[Playlist Up]")
  of iw.Key.Right:
    if state.tab == tabSettings and state.settingsFocusPanel == lpContent:
      state.adjustSettingValue(1)
    elif state.isPlaylistView():
      if state.playlistContentsIdx < 0:
        let item = state.selectedItem()
        if item.kind == likPlaylist:
          let plIdx = state.selectIndex
          if plIdx >= 0 and plIdx < state.libraryPlaylists.len and state.libraryPlaylists[plIdx].trackIds.len == 0:
            discard
          else:
            state.playlistContentsIdx = state.selectIndex; state.selectIndex = 0; state.rebuildItems(); state.setFeedback("[Playlist Down]")
  of iw.Key.N:
    if guardDebounce(state): return
    execCmd(state, "next_track")
  of iw.Key.P:
    if guardDebounce(state): return
    execCmd(state, "prev_track")
  of iw.Key.J: execCmd(state, "nav_down")
  of iw.Key.Plus, iw.Key.Equals: execCmd(state, "volume_up")
  of iw.Key.Minus, iw.Key.Underscore: execCmd(state, "volume_down")
  of iw.Key.M:
    if guardDebounce(state): return
    execCmd(state, "toggle_mute")
  of iw.Key.G:
    if state.pendingSeq.len == 0 or state.pendingSeq[state.pendingSeq.len - 1] != iw.Key.G:
      state.pendingSeq = @[iw.Key.G]
      state.pendingSeqTimer = 60
    else:
      state.pendingSeq = @[]
      state.selectIndex = 0
      state.needsRedraw = true
  of iw.Key.ShiftG: execCmd(state, "go_to_last")
  of iw.Key.A:
    if state.libraryFocusPanel == lpContent and state.filterScope == fsPlaylists:
      if state.isPlaylistView() and state.playlistContentsIdx >= 0:
        if state.selectIndex >= 0:
          state.addingToPlaylistId = state.libraryPlaylists[state.playlistContentsIdx].id
          state.addingToPlaylistName = state.libraryPlaylists[state.playlistContentsIdx].name
          state.switchTab(tabLibrary)
          state.selectMode = false
          state.selectedIndices = initHashSet[int]()
          state.setFeedback("Select tracks to add to \"" & state.addingToPlaylistName & "\"")
      else:
        execCmd(state, "create_playlist")
  of iw.Key.D:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "delete_playlist")
    elif state.tab == tabNowPlaying and state.playbackQueue.len > 0:
      let tIdx = state.playbackQueue[state.queueCursor]
      var removePath = ""
      if tIdx >= 0 and tIdx < state.libraryTracks.len:
        removePath = state.libraryTracks[tIdx].path
      elif state.queueCursor < state.queuePaths.len:
        removePath = state.queuePaths[state.queueCursor]
      if removePath.len > 0:
        state.queuePendingConfirm = 1
        state.setFeedback("Remove item from queue? (Y/N)")
    elif state.libraryFocusPanel == lpContent:
      state.deleteConfirm()
  of iw.Key.ShiftD:
    if state.playbackQueue.len > 0:
      state.queuePendingConfirm = 2
      state.setFeedback("Clear entire queue? (Y/N)")
  of iw.Key.R:
    if state.isPlaylistView() and state.playlistContentsIdx < 0:
      execCmd(state, "rename_playlist")
  of iw.Key.ShiftS:
    if guardDebounce(state): return
    execCmd(state, "toggle_shuffle")
  of iw.Key.ShiftR:
    if guardDebounce(state): return
    execCmd(state, "toggle_repeat")
  of iw.Key.Slash: execCmd(state, "enter_filter")
  of iw.Key.CtrlV: execCmd(state, "toggle_select_mode")
  of iw.Key.One: execCmd(state, "tab_now_playing")
  of iw.Key.Two: execCmd(state, "tab_library")
  of iw.Key.Three: execCmd(state, "tab_settings")
  of iw.Key.ShiftQ: execCmd(state, "quit_daemon")
  of iw.Key.ShiftF: execCmd(state, "toggle_favourite")
  of iw.Key.Q: execCmd(state, "quit_background")
  of iw.Key.Escape:
    if state.addingToPlaylistId > 0:
      state.addingToPlaylistId = 0
      state.addingToPlaylistName = ""
      state.selectMode = false
      state.selectedIndices = initHashSet[int]()
      state.rebuildItems()
    elif state.isPlaylistView() and state.playlistContentsIdx >= 0:
      state.playlistContentsIdx = -1
      state.selectIndex = 0
      state.rebuildItems()
      state.setFeedback("[Playlist Up]")
  else:
    if state.keyDispatch.hasKey(key):
      for idx in state.keyDispatch[key]:
        if idx >= 0 and idx < state.commands.len:
          execCmd(state, state.commands[idx].id)

proc handleKey(state: var AppState, key: iw.Key, chars: seq[Rune]) =
  if key != iw.Key.None:
    state.lastKeyDisplay = keyDisplayName(key)
    state.lastKeyTimer = 120
    if state.overlay.kind == okNone and not state.helpVisible and not state.aboutVisible:
      state.lastCommandName = ""
  if state.aboutVisible:
    if key notin {iw.Key.None}:
      state.aboutVisible = false
    return
  if state.helpVisible:
    if key in {iw.Key.QuestionMark, iw.Key.Escape, iw.Key.Q, iw.Key.ShiftQ}:
      state.helpVisible = false
    return
  if state.playlistInputActive:
    handlePlaylistInput(state, key, chars)
    return
  if state.overlay.kind != okNone:
    case state.overlay.kind
    of okThemePicker: state.handleThemePickerOverlay(key, chars)
    of okEqPresetPicker: state.handleEqPresetPickerOverlay(key, chars)
    of okYtSearch: state.handleYtSearchOverlay(key, chars)
    of okYtBatch: state.handleYtBatchOverlay(key, chars)
    of okQueuePicker: state.handleQueuePickerOverlay(key, chars)
    of okQueueOverlay: state.handleQueueOverlay(key, chars)
    of okPlaylistSearch: state.handlePlaylistSearchOverlay(key, chars)
    of okCommandPalette: state.handleCommandPaletteOverlay(key, chars)
    of okFuzzyFinder: state.handleFuzzyFinderOverlay(key, chars)
    of okTrashView: state.handleTrashOverlay(key, chars)
    of okFooterModulePicker: state.handleFooterModulePickerOverlay(key, chars)
    of okSpotifyUrlInput: state.handleSpotifyUrlOverlay(key, chars)
    of okSpotifySearch: state.handleSpotifySearchOverlay(key, chars)
    of okLyricsSearch: state.handleLyricsSearchOverlay(key, chars)
    of okNone: discard
    return
  let sidebarScopes = if state.sidebarSpExpanded:
    @[fsAll, fsArtists, fsAlbums, fsPlaylists, fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed, fsDownloads, fsSpotify, fsSpLiked, fsSpPlaylists]
  else:
    @[fsAll, fsArtists, fsAlbums, fsPlaylists, fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed, fsDownloads, fsSpotify]
  if state.tab == tabLibrary and state.libraryFocusPanel == lpSidebar and state.mode == imNormal:
    case key
    of iw.Key.Down:
      state.librarySidebarSelect = min(sidebarScopes.high, state.librarySidebarSelect + 1)
      let ds = sidebarScopes[state.librarySidebarSelect]
      if ds == fsSpLiked and state.spLikedSongs.len == 0 and state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let resp = cli.spLikedSongs(50)
        if resp.hasKey("results"):
          state.spLikedSongs = @[]
          for item in resp["results"]:
            state.spLikedSongs.add((id: item{"id"}.getStr(""), name: item{"name"}.getStr(""),
              artist: item{"artist"}.getStr(""), album: item{"album"}.getStr(""),
              url: item{"url"}.getStr(""), durationMs: item{"duration_ms"}.getInt(0)))
      elif ds == fsSpPlaylists and state.spUserPlaylists.len == 0 and state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let feed = cli.spFeed()
        if feed.hasKey("playlists"):
          state.spUserPlaylists = @[]
          for p in feed["playlists"]:
            state.spUserPlaylists.add((id: p{"id"}.getStr(""), name: p{"name"}.getStr("")))
      state.filterScope = ds
      state.selectIndex = 0
      state.rebuildItems()
      state.markDirty(ceSearchResults)
      state.needsRedraw = true; return
    of iw.Key.Up:
      state.librarySidebarSelect = max(0, state.librarySidebarSelect - 1)
      let us = sidebarScopes[state.librarySidebarSelect]
      if us == fsSpLiked and state.spLikedSongs.len == 0 and state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let resp = cli.spLikedSongs(50)
        if resp.hasKey("results"):
          state.spLikedSongs = @[]
          for item in resp["results"]:
            state.spLikedSongs.add((id: item{"id"}.getStr(""), name: item{"name"}.getStr(""),
              artist: item{"artist"}.getStr(""), album: item{"album"}.getStr(""),
              url: item{"url"}.getStr(""), durationMs: item{"duration_ms"}.getInt(0)))
      elif us == fsSpPlaylists and state.spUserPlaylists.len == 0 and state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let feed = cli.spFeed()
        if feed.hasKey("playlists"):
          state.spUserPlaylists = @[]
          for p in feed["playlists"]:
            state.spUserPlaylists.add((id: p{"id"}.getStr(""), name: p{"name"}.getStr("")))
      state.filterScope = us
      state.selectIndex = 0
      state.rebuildItems()
      state.markDirty(ceSearchResults)
      state.needsRedraw = true; return
    of iw.Key.Enter, iw.Key.L:
      if state.librarySidebarSelect < sidebarScopes.len and sidebarScopes[state.librarySidebarSelect] == fsSpotify:
        state.sidebarSpExpanded = not state.sidebarSpExpanded
        state.needsRedraw = true; return
      let selScope = sidebarScopes[state.librarySidebarSelect]
      if selScope == fsSpLiked and state.spLikedSongs.len == 0 and state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let resp = cli.spLikedSongs(50)
        if resp.hasKey("results"):
          state.spLikedSongs = @[]
          for item in resp["results"]:
            state.spLikedSongs.add((id: item{"id"}.getStr(""), name: item{"name"}.getStr(""),
              artist: item{"artist"}.getStr(""), album: item{"album"}.getStr(""),
              url: item{"url"}.getStr(""), durationMs: item{"duration_ms"}.getInt(0)))
      elif selScope == fsSpPlaylists and state.spUserPlaylists.len == 0 and state.player.backendType == abtDaemon:
        let cli = DaemonService(state.svc)
        let feed = cli.spFeed()
        if feed.hasKey("playlists"):
          state.spUserPlaylists = @[]
          for p in feed["playlists"]:
            state.spUserPlaylists.add((id: p{"id"}.getStr(""), name: p{"name"}.getStr("")))
      state.filterScope = selScope
      state.selectIndex = 0
      state.libraryFocusPanel = lpContent
      state.playlistContentsIdx = -1
      state.rebuildItems()
      state.needsRedraw = true; return
    of iw.Key.H, iw.Key.Escape, iw.Key.Tab:
      state.libraryFocusPanel = lpContent
      state.needsRedraw = true; return
    else: discard
  if state.mode == imFilter:
    handleFilterMode(state, key, chars)
    return
  if state.queuePendingConfirm != 0:
    if key == iw.Key.Y:
      if state.queuePendingConfirm == 1:
        if state.queueCursor < state.playbackQueue.len:
          let tIdx = state.playbackQueue[state.queueCursor]
          var removePath = ""
          if tIdx >= 0 and tIdx < state.libraryTracks.len:
            removePath = state.libraryTracks[tIdx].path
          elif state.queueCursor < state.queuePaths.len:
            removePath = state.queuePaths[state.queueCursor]
          state.playbackQueue.delete(state.queueCursor)
          if state.queuePaths.len > state.queueCursor:
            state.queuePaths.delete(state.queueCursor)
          if state.queueCursor >= state.playbackQueue.len and state.queueCursor > 0:
            state.queueCursor.dec
          if state.player.backendType == abtDaemon and removePath.len > 0:
            discard DaemonService(state.svc).queueRemovePath(removePath)
      elif state.queuePendingConfirm == 2:
        state.playbackQueue = @[]
        state.queuePaths = @[]
        state.queueCursor = 0
        if state.player.backendType == abtDaemon:
          discard daemonSimpleCmd(DaemonService(state.svc), "queue_clear")
      elif state.queuePendingConfirm == 3:
        state.volumeSafetyConfirmed = true
        let newVol = state.volume
        state.player.setVolume(newVol)
        state.showVolumeCue()
    state.queuePendingConfirm = 0
    state.markDirty(ceQueue)
    state.setFeedback("")
    return
  if state.deleteConfirmPending != 0:
    if key == iw.Key.T:
      state.deleteSelected(false)
      state.showNotification("Moved to trash", nkInfo)
    elif key == iw.Key.ShiftP:
      state.deleteSelected(true)
      state.showNotification("Permanently deleted", nkInfo)
    else:
      if key != iw.Key.None:
        let idx = state.selectIndex
        if idx >= 0 and idx < state.filteredIndices.len:
          state.selectIndex = idx
        state.setFeedback("")
    state.deleteConfirmPending = 0
    return
  if state.pendingSeq.len > 0:
    state.pendingSeq.add(key)
    let boundCmd = state.multiKeyDispatch.getOrDefault(state.pendingSeq)
    if boundCmd > 0:
      state.pendingSeq = @[]
      if boundCmd < state.commands.len:
        state.commands[boundCmd].handler(state)
    else:
      state.pendingSeqTimer = 60
    return
  handleMainKey(state, key, chars)


proc parseDurationToSec*(dur: string): float =
  let parts = dur.split(':')
  if parts.len == 2:
    try: result = parts[0].parseInt.float * 60 + parts[1].parseInt.float except: result = 0.0
  elif parts.len == 3:
    try: result = parts[0].parseInt.float * 3600 + parts[1].parseInt.float * 60 + parts[2].parseInt.float except: result = 0.0

proc fullStateSync(state: var AppState, daemonState: JsonNode)

proc processEvents(state: var AppState) =
  let events = state.player.pollEvents()
  if state.player.backendType == abtDaemon:
    state.audioAvailable = DaemonService(state.svc).isWorking
  for ev in events:
    if ev.version > state.daemonStateVersion:
      state.daemonStateVersion = ev.version
    case ev.kind
    of evPositionChanged:
      state.timePos = ev.floatVal
      state.markDirty(cePosition)
      if state.currentLyrics.lines.len > 0:
        let newIdx = currentLrcLine(state.currentLyrics, state.timePos)
        if newIdx != state.lyricsLineIdx:
          state.lyricsLineIdx = newIdx
          state.markDirty(ceTrack)
    of evDurationChanged:
      state.duration = ev.floatVal
      state.markDirty(ceTrack)
    of evVolumeChanged:
      state.volume = ev.intVal
      state.markDirty(ceVolume)
    of evPlaybackStarted:
      let newPath = ev.metadata.getOrDefault("track_path", "")
      let isSameTrack = newPath.len > 0 and newPath == state.currentPlayingPath
      state.status = psPlaying
      state.notificationTimer = 0
      state.notificationMsg = ""
      state.nowPlayingCueTimer = 0
      state.nowPlayingCueMsg = ""
      if state.player.duration > 0.0:
        state.duration = state.player.duration
      if state.player.timePos >= 0.0:
        state.timePos = state.player.timePos
      let autoAdvanced = ev.metadata.getOrDefault("auto_advanced", "false") == "true"
      # Sync track info from event metadata (daemon always includes it)
      if ev.metadata.hasKey("track_path"):
        state.currentPlayingPath = ev.metadata["track_path"]
        state.currentPlayingTitle = ev.metadata.getOrDefault("track_title", "")
        state.currentPlayingChannel = ev.metadata.getOrDefault("track_channel", "")
        state.ytStreamTitle = state.currentPlayingTitle
        state.ytStreamChannel = state.currentPlayingChannel
        if state.tab == tabLibrary:
          state.rebuildItems()
          state.markDirty(ceSearchResults)
      # Fallback: derive from player state if metadata not available
      elif state.player.timePos >= 0 and state.player.duration > 0:
        state.setFeedback("[Track changed]", nkInfo)
      # Resolve currentPlayingId from path and sync title/artist into library
      if state.currentPlayingPath.len > 0:
        state.cachedPlayingPath = ""
        for i in 0..<state.libraryTracks.len:
          if state.libraryTracks[i].path == state.currentPlayingPath:
            state.currentPlayingId = state.libraryTracks[i].id
            if state.currentPlayingTitle.len > 0 and state.libraryTracks[i].title != state.currentPlayingTitle:
              state.libraryTracks[i].title = state.currentPlayingTitle
            if state.currentPlayingChannel.len > 0 and state.libraryTracks[i].artist != state.currentPlayingChannel:
              state.libraryTracks[i].artist = state.currentPlayingChannel
            state.cachedPlayingTrack = state.libraryTracks[i]
            state.cachedPlayingPath = state.currentPlayingPath
            break
      state.markDirtyBatch(cePlayState, ceTrack)
      # Request cover art from daemon — non-blocking, response via cover_art_sync event
      if state.hasKittyGraphics and state.currentPlayingPath.len > 0 and state.coverPendingPath != state.currentPlayingPath:
        state.coverPendingPath = state.currentPlayingPath
        let cacheKey = hash(state.currentPlayingPath).toHex
        if cacheKey in state.coverCache:
          state.coverImageId = -1
        elif state.player.backendType == abtDaemon:
          DaemonService(state.svc).sendOnly(%*{"cmd": "request_cover_art", "path": state.currentPlayingPath})
      # Request lyrics from daemon — non-blocking, response via lyrics_sync event
      if not isSameTrack and state.currentPlayingPath.len > 0:
        state.currentLyrics = LrcData(lines: @[])
        state.lyricsLineIdx = -1
        if state.player.backendType == abtDaemon:
          DaemonService(state.svc).sendOnly(%*{"cmd": "request_lyrics",
            "path": state.currentPlayingPath, "title": state.currentPlayingTitle,
            "artist": state.currentPlayingChannel, "duration": state.duration})
      # Show Now Playing notification — skip if same track (play/pause resume) or auto-advanced
      if not isSameTrack and not autoAdvanced:
        if state.currentPlayingTitle.len > 0:
          state.showNotification("Now Playing: " & state.currentPlayingTitle &
            (if state.currentPlayingChannel.len > 0: " — " & state.currentPlayingChannel else: ""))
        elif state.currentPlayingPath.len > 0:
          state.showNotification("Now Playing: " & state.currentPlayingPath.splitFile().name.replace(".", " "))
      state.upNextTimer = 0
      state.upNextMsg = ""
      # Suppress NowPlayingCue on Library tab (inline header already shows it)
      if state.tab != tabNowPlaying and state.tab != tabLibrary and state.currentPlayingId > 0 and not isSameTrack:
        for i in 0..<state.libraryTracks.len:
          if state.libraryTracks[i].id == state.currentPlayingId:
            let t = state.libraryTracks[i]
            state.nowPlayingCueMsg = "Now Playing: " & t.title & (if t.artist.len > 0: " — " & t.artist else: "")
            state.nowPlayingCueTimer = 150
            break
    of evPlaybackPaused:
      state.status = psPaused
      state.markDirty(cePlayState)
    of evPlaybackStopped:
      state.status = psStopped
      state.markDirty(cePlayState)
    of evTrackEnded:
      state.notificationTimer = 0
      state.notificationMsg = ""
      state.nowPlayingCueTimer = 0
      state.nowPlayingCueMsg = ""
      state.upNextTimer = 0
      state.upNextMsg = ""
      # Daemon advances queue — trust queue_changed event to update state
    of evMetadataChanged:
      if ev.strVal == "crossfade_started":
        state.crossfadeStarted = true
        state.crossfading = true
      elif ev.strVal == "crossfade_ended":
        state.crossfadeStarted = false
        state.crossfading = false
        state.crossfadePrepared = false
    of evCustomEvent:
      if ev.strVal == "up_next":
        let nextTitle = ev.metadata.getOrDefault("next_title", "")
        let nextChannel = ev.metadata.getOrDefault("next_channel", "")
        if nextTitle.len > 0:
          state.upNextMsg = "Up Next: " & nextTitle &
            (if nextChannel.len > 0: " — " & nextChannel else: "")
        else:
          let nextPath = ev.metadata.getOrDefault("next_path", "")
          if nextPath.len > 0:
            state.upNextMsg = "Up Next: " & nextPath.splitFile().name.replace(".", " ")
        state.upNextTimer = 150
        state.markDirty(ceFeedback)
      elif ev.strVal == "full_state_sync":
        if ev.version > 0 and ev.version < state.daemonStateVersion:
          discard  # stale state
        else:
          var fs = %*{}
          if ev.metadata.hasKey("state"): fs["state"] = %ev.metadata["state"]
          if ev.metadata.hasKey("track_path"): fs["track_path"] = %ev.metadata["track_path"]
          if ev.metadata.hasKey("track_title"): fs["track_title"] = %ev.metadata["track_title"]
          if ev.metadata.hasKey("track_channel"): fs["track_channel"] = %ev.metadata["track_channel"]
          if ev.metadata.hasKey("time_pos"):
            try: fs["time_pos"] = %parseFloat(ev.metadata["time_pos"]) except: discard
          if ev.metadata.hasKey("duration"):
            try: fs["duration"] = %parseFloat(ev.metadata["duration"]) except: discard
          if ev.metadata.hasKey("volume"):
            try: fs["volume"] = %parseInt(ev.metadata["volume"]) except: discard
          if ev.metadata.hasKey("full_shuffle"):
            fs["shuffle"] = %(ev.metadata["full_shuffle"] == "true")
          if ev.metadata.hasKey("full_repeat"):
            try: fs["repeat"] = %parseInt(ev.metadata["full_repeat"]) except: discard
          if ev.metadata.hasKey("sleep_timer"):
            try: fs["sleep_timer"] = %parseInt(ev.metadata["sleep_timer"]) except: discard
          if ev.metadata.hasKey("full_shuffle_index"):
            try: fs["shuffleIndex"] = %parseInt(ev.metadata["full_shuffle_index"]) except: discard
          if ev.metadata.hasKey("full_crossfade_duration"):
            try: fs["crossfadeDuration"] = %parseInt(ev.metadata["full_crossfade_duration"]) except: discard
          if ev.metadata.hasKey("full_crossfade_curve"):
            try: fs["crossfadeCurve"] = %parseInt(ev.metadata["full_crossfade_curve"]) except: discard
          if fs.len > 0:
            fullStateSync(state, fs)
            state.markDirtyBatch(cePlayState, ceTrack, cePosition, ceVolume)
          # Rebuild queue from full_state_sync
          if ev.metadata.hasKey("queue"):
            try:
              let daemonQueue = parseJson(ev.metadata["queue"])
              var newQueue: seq[int] = @[]
              var newPaths: seq[string] = @[]
              for qItem in daemonQueue.items:
                let qPath = qItem.getStr("")
                var found = false
                for i, t in state.libraryTracks:
                  if t.path == qPath:
                    newQueue.add(i)
                    newPaths.add("")
                    found = true
                    break
                if not found:
                  newQueue.add(-1)
                  newPaths.add(qPath)
              state.playbackQueue = newQueue
              state.queuePaths = newPaths
              if state.queueCursor >= newQueue.len:
                state.queueCursor = max(0, newQueue.len - 1)
              state.rebuildItems()
              state.markDirty(ceQueue)
            except: discard
      elif ev.strVal == "crossfade_duration_changed":
        if ev.metadata.hasKey("duration"):
          try:
            state.crossfadeDuration = parseInt(ev.metadata["duration"])
            state.markDirty(ceSettings)
          except: discard
      elif ev.strVal == "crossfade_curve_changed":
        if ev.metadata.hasKey("curve"):
          try:
            state.crossfadeCurve = CrossfadeCurveType(parseInt(ev.metadata["curve"]))
            state.markDirty(ceSettings)
          except: discard
      elif ev.strVal == "queue_changed" and state.player.backendType == abtDaemon:
        state.shuffleIndex = ev.intVal
        state.markDirty(ceQueue)
        # Rebuild TUI playbackQueue from daemon queue paths
        if ev.metadata.hasKey("queue"):
          try:
            let daemonQueue = parseJson(ev.metadata["queue"])
            var newQueue: seq[int] = @[]
            var newPaths: seq[string] = @[]
            for qItem in daemonQueue.items:
              let qPath = qItem.getStr("")
              var found = false
              for i, t in state.libraryTracks:
                if t.path == qPath:
                  newQueue.add(i)
                  newPaths.add("")
                  found = true
                  break
              if not found:
                newQueue.add(-1)
                newPaths.add(qPath)
            state.playbackQueue = newQueue
            state.queuePaths = newPaths
            if state.queueCursor >= newQueue.len:
              state.queueCursor = max(0, newQueue.len - 1)
            state.rebuildItems()
            state.markDirty(ceQueue)
          except: discard
      elif ev.strVal == "shuffle_changed":
        if ev.metadata.hasKey("shuffle"):
          state.shuffleEnabled = ev.metadata["shuffle"] == "true"
          state.markDirty(ceQueue)
      elif ev.strVal == "repeat_changed":
        if ev.metadata.hasKey("repeat"):
          state.repeatMode = parseInt(ev.metadata["repeat"])
          state.markDirty(ceQueue)
      elif ev.strVal == "yt_download_done":
        state.ytDownloadActive = false
        let dlUrl = ev.metadata.getOrDefault("url", "")
        let dlPath = ev.metadata.getOrDefault("path", "")
        let dlTitle = ev.metadata.getOrDefault("title", "")
        if dlUrl.len == 0 or dlPath.len == 0:
          discard
        else:
          state.ytDownloaded[dlUrl] = dlPath
          state.downloadCount = state.ytDownloaded.len
          for i in 0..<state.libraryTracks.len:
            if state.libraryTracks[i].path == dlUrl:
              state.libraryTracks[i].path = dlPath
              if dlTitle.len > 0: state.libraryTracks[i].title = dlTitle
              if state.currentPlayingPath == dlUrl:
                state.currentPlayingPath = dlPath
              break
            state.rebuildItems()
            if state.player.backendType == abtDaemon and dlPath.len > 0:
              DaemonService(state.svc).sendOnly(%*{"cmd": "request_cover_art", "path": dlPath})
            state.showNotification("Downloaded: " & (if dlTitle.len > 0: dlTitle else: splitFile(dlPath).name), nkSuccess)
          if "spotify.com" in dlUrl:
            state.spDownloaded[dlUrl] = dlPath
            state.spDownloadCount = state.spDownloaded.len
            state.rebuildItems()
      elif ev.strVal == "yt_search_partial" or ev.strVal == "yt_search_done":
        if ev.metadata.hasKey("results"):
          try:
            let resultsArr = parseJson(ev.metadata["results"])
            var results: seq[YtSearchResult] = @[]
            for jr in resultsArr.items:
              results.add(YtSearchResult(
                title: jr{"title"}.getStr(""),
                url: jr{"url"}.getStr(""),
                duration: jr{"duration"}.getStr(""),
                channel: jr{"channel"}.getStr(""),
                kind: YtSearchResultKind(jr{"kind"}.getInt(0))
              ))
            if results.len > 0:
              state.overlay.ytResults = results
              if state.overlay.cursor >= results.len:
                state.overlay.cursor = 0
              state.markDirty(ceSearchResults)
            if ev.strVal == "yt_search_done":
              # Cache results
              let cacheKey = state.ytSearchQuery & ":" & $(state.ytSearchPageSize * max(1, state.ytSearchPage + 1))
              state.ytSearchCache[cacheKey] = results
              state.ytSearchCacheKeys.add(cacheKey)
              # Evict oldest entries when cache exceeds 32
              while state.ytSearchCacheKeys.len > 32:
                let oldKey = state.ytSearchCacheKeys[0]
                state.ytSearchCacheKeys.delete(0)
                state.ytSearchCache.del(oldKey)
              state.ytSearchActive = false
              state.ytSearchLoading = false
              state.markDirty(ceSearchResults)
          except: discard
      elif ev.strVal == "yt_stream_resolved":
        let url = ev.metadata.getOrDefault("url", "")
        let title = ev.metadata.getOrDefault("title", "")
        let channel = ev.metadata.getOrDefault("channel", "")
        if url.len > 0:
          state.ytStreamResolving = false
          discard state.player.loadFile(url, title, channel)
          state.player.play()
          state.status = psPlaying
          state.currentPlayingPath = url
          state.currentPlayingTitle = title
          state.currentPlayingChannel = channel
          state.markDirtyBatch(cePlayState, ceTrack)
          state.showNotification("Streaming: " & title)
        else:
          state.setFeedback("Failed to resolve stream URL")
          state.ytStreamResolving = false
      elif ev.strVal == "yt_playlist_fetched":
        state.ytPlaylistFetching = false
        state.ytSearchLoading = false
        if ev.metadata.hasKey("tracks"):
          try:
            let tracksArr = parseJson(ev.metadata["tracks"])
            var tracks: seq[YtSearchResult] = @[]
            for jt in tracksArr.items:
              tracks.add(YtSearchResult(
                kind: srkVideo,
                title: jt{"title"}.getStr(""),
                url: jt{"url"}.getStr(""),
                duration: jt{"duration"}.getStr(""),
                channel: jt{"channel"}.getStr("")
              ))
            let plTitle = ev.metadata.getOrDefault("title", "Playlist")
            state.overlay.ytPlaylistDetail = YtPlaylistDetail(
              title: plTitle,
              trackCount: tracks.len,
              tracks: tracks
            )
            state.overlay.ytResults = tracks
            state.overlay.cursor = 0
            state.overlay.multiMode = false
            state.overlay.selected = initHashSet[int]()
            state.setFeedback("Playlist: " & plTitle & " (" & $tracks.len & " tracks)")
            state.markDirty(ceSearchResults)
          except: discard
      elif ev.strVal == "cover_art_sync":
        let reqPath = ev.metadata.getOrDefault("req_path", "")
        if reqPath.len > 0:
          let cacheKey = hash(reqPath).toHex
          if ev.metadata.hasKey("cover_data") and ev.metadata["cover_data"].len > 0:
            let mime = ev.metadata.getOrDefault("cover_mime", "image/jpeg")
            try:
              state.coverCache[cacheKey] = (cast[seq[byte]](decode(ev.metadata["cover_data"])), mime)
              state.touchCoverCache(cacheKey)
              state.ensureCoverCacheFit()
              if reqPath == state.coverPendingPath:
                state.coverImageId = -1
            except: discard
            state.markDirty(ceTrack)
          elif cacheKey notin state.coverCache:
            state.coverCache[cacheKey] = (@[], "")
        state.coverFetching = false
        state.hoverState.coverFetching = false
      elif ev.strVal == "lyrics_sync":
        if ev.metadata.hasKey("ok") and ev.metadata["ok"] == "true":
          var lrcData = LrcData(title: ev.metadata.getOrDefault("title", ""),
            artist: ev.metadata.getOrDefault("artist", ""),
            album: ev.metadata.getOrDefault("album", ""), lines: @[])
          if ev.metadata.hasKey("lines"):
            try:
              let linesArr = parseJson(ev.metadata["lines"])
              for ln in linesArr.items:
                lrcData.lines.add(LrcLine(timestamp: ln{"ts"}.getFloat(), text: ln{"text"}.getStr("")))
              state.currentLyrics = lrcData
            except: discard
      elif ev.strVal == "lyrics_search_sync":
        if ev.metadata.hasKey("results") and state.overlay.kind == okLyricsSearch:
          try:
            let resultsArr = parseJson(ev.metadata["results"])
            state.overlay.lyricsSearchResults = @[]
            for jr in resultsArr.items:
              state.overlay.lyricsSearchResults.add((
                id: jr{"id"}.getInt(0),
                title: jr{"title"}.getStr(""),
                artist: jr{"artist"}.getStr(""),
                album: jr{"album"}.getStr(""),
                duration: jr{"duration"}.getFloat(0.0)
              ))
            if state.overlay.cursor >= state.overlay.lyricsSearchResults.len:
              state.overlay.cursor = 0
            state.markDirty(ceSearchResults)
          except: discard
      elif ev.strVal == "scan_done" and state.player.backendType == abtDaemon:
        state.libraryNeedsScan = false
        let cli = DaemonService(state.svc)
        if cli.isConnected:
          let resp = cli.getLibrary()
          if resp.hasKey("tracks") and resp["tracks"].len > 0:
            state.loadLibraryFromDaemon(resp)
        state.libraryLoading = false
        state.libraryRetryCount = 0
        state.rebuildItems()
        state.markDirty(ceSearchResults)
    else: discard
  if state.player.timePos != state.timePos and state.status == psPlaying:
    state.timePos = state.player.timePos
    state.markDirty(cePosition)
  if state.duration == 0.0 and state.player.duration > 0.0:
    state.duration = state.player.duration

proc fullStateSync(state: var AppState, daemonState: JsonNode) =
  let s = daemonState{"state"}.getStr("stopped")
  state.status = if s == "playing": psPlaying elif s == "paused": psPaused else: psStopped
  # Only sync track info if daemon reports actively playing or paused
  if s == "playing" or s == "paused":
    if daemonState.hasKey("track_path"):
      state.currentPlayingPath = daemonState["track_path"].getStr("")
    if daemonState.hasKey("track_title"):
      state.currentPlayingTitle = daemonState["track_title"].getStr("")
    if daemonState.hasKey("track_channel"):
      state.currentPlayingChannel = daemonState["track_channel"].getStr("")
  elif daemonState.hasKey("track_path") and daemonState["track_path"].getStr("").len > 0:
    state.currentPlayingPath = daemonState["track_path"].getStr("")
    if daemonState.hasKey("track_title"):
      state.currentPlayingTitle = daemonState["track_title"].getStr("")
    if daemonState.hasKey("track_channel"):
      state.currentPlayingChannel = daemonState["track_channel"].getStr("")
  if daemonState.hasKey("time_pos"):
    state.timePos = max(0.0, daemonState["time_pos"].getFloat(0.0))
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
  if daemonState.hasKey("spatialWidth"):
    state.spatialWidth = daemonState["spatialWidth"].getFloat(1.0)
  if daemonState.hasKey("crossfadeDuration"):
    state.crossfadeDuration = daemonState["crossfadeDuration"].getInt(0)
  if daemonState.hasKey("crossfadeCurve"):
    state.crossfadeCurve = CrossfadeCurveType(daemonState["crossfadeCurve"].getInt(1))
  if daemonState.hasKey("shuffleIndex"):
    state.shuffleIndex = daemonState["shuffleIndex"].getInt(0)
  if daemonState.hasKey("backend_name"):
    state.audioBackendName = daemonState["backend_name"].getStr("unknown")

proc runTui(args: seq[string]) =
  terminal.enableTrueColors()
  iw.init()
  setControlCHook(handleQuitSignal)
  terminal.hideCursor()
  let hasKittyGraphics = supportsKittyGraphics()
  ensureSysInfo()
  var store = newStore()
  var ctx = nw.initContext[Store]()
  ctx.data = store
  initApp(ctx.state)
  ctx.state.hasKittyGraphics = hasKittyGraphics
  ctx.state.loadConfig()
  ctx.state.highlightGroups = initHighlightGroups(ctx.state.theme, ctx.state.transparentBg)
  setIconPreference(ctx.state.iconPreference)
  ctx.state.daemonConnected = false
  ctx.state.audioAvailable = false
  ctx.state.startupPhase = spInit
  ctx.state.startupQueueFlushed = false
  ctx.state.initCommands()
  ctx.state.applyKeybindings()
  ctx.state.needsRedraw = true
  var prevTb: iw.TerminalBuffer
  var tbReady: bool
  var mouseInfo: iw.MouseInfo
  var oldStatus = ctx.state.status
  var oldTimePos = ctx.state.timePos
  var oldTimeDisplay = formatTime(ctx.state.timePos)
  var lastW = terminal.terminalWidth()
  var lastH = terminal.terminalHeight()
  var resized = false
  var frameNo = 0
  var lastRenderTime = 0.0
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
      if ctx.state.pendingSeqTimer > 0:
        ctx.state.pendingSeqTimer -= 1
        if ctx.state.pendingSeqTimer <= 0:
          ctx.state.pendingSeq = @[]
      var chars: seq[Rune] = @[]
      if key >= iw.Key.Space and key <= iw.Key.Tilde:
        chars.add(Rune(key.ord))
      if key == iw.Key.Mouse:
        discard
      elif key != iw.Key.None:
        handleKey(ctx.state, key, chars)
        if ctx.state.overlay.kind != okNone:
          ctx.state.markDirty(ceSearchResults)
        else:
          ctx.state.needsRedraw = true
      # Deferred initialization — runs across multiple frames for fast first render
      if ctx.state.startupPhase != spReady:
        case ctx.state.startupPhase
        of spInit:
          # First frame — connect to daemon
          ctx.data.service.ensureConnected()
          ctx.state.daemonConnected = ctx.data.service.isConnected
          ctx.state.audioAvailable = ctx.data.service.isWorking
          ctx.state.loadPlaylists()
          ctx.state.startupPhase = spConfigLoading
          ctx.state.needsRedraw = true
        of spConfigLoading:
          ctx.state.deviceName = getPlaybackDeviceName()
          if ctx.state.ytCookieSource.len == 0:
            ctx.state.ytCookieSource = detectBrowserCookieSource()
          if ctx.state.spCookieSource.len == 0:
            ctx.state.spCookieSource = detectBrowserCookieSource()
          ctx.data.service.setIpcTimeout(float(ctx.state.config.ipcTimeout))
          if ctx.data.service.isConnected:
            discard ctx.data.service.spSetConfig(ctx.state.spCookieSource, ctx.state.spCookieFilePath, ctx.state.spAudioFormat)
          ctx.state.player.setVolume(ctx.state.volume)
          ctx.state.startupPhase = spLibraryLoading
        of spLibraryLoading:
          ctx.state.loadLibrary()
          ctx.state.buildPlaylistFromArgs(args)
          if ctx.data.service.isConnected and args.len == 0:
            try:
              let daemonState = ctx.data.service.getFullState()
              fullStateSync(ctx.state, daemonState)
              if daemonState.hasKey("queue"):
                try:
                  let qArr = daemonState["queue"]
                  var queue: seq[int] = @[]
                  var queuePaths: seq[string] = @[]
                  for qItem in qArr.items:
                    let qPath = qItem.getStr("")
                    var found = false
                    for i, t in ctx.state.libraryTracks:
                      if t.path == qPath:
                        queue.add(i)
                        queuePaths.add("")
                        found = true
                        break
                    if not found:
                      queue.add(-1)
                      queuePaths.add(qPath)
                  ctx.state.playbackQueue = queue
                  ctx.state.queuePaths = queuePaths
                  ctx.state.markDirty(ceQueue)
                except: discard
            except: discard
          ctx.state.startupPhase = spSpotifySync
        of spSpotifySync:
          if ctx.data.service.isConnected:
            try:
              let spResp = ctx.data.service.spListDownloads()
              if spResp.hasKey("downloads"):
                let arr = spResp["downloads"]
                ctx.state.spDownloadCount = arr.len
                for item in arr:
                  ctx.state.spDownloaded[item{"url"}.getStr("")] = item{"path"}.getStr("")
            except: discard
          ctx.state.rebuildItems()
          if ctx.data.service.isConnected and ctx.state.currentPlayingPath.len > 0:
            for i, t in ctx.state.libraryTracks:
              if t.path == ctx.state.currentPlayingPath:
                ctx.state.selectIndex = i
                ctx.state.currentPlayingId = t.id
                break
            if ctx.state.status == psPlaying:
              ctx.state.setFeedback("[Resumed playback]")
          if args.len > 0:
            ctx.state.selectIndex = 0
          ctx.state.applyOnConfig()
          ctx.state.startupPhase = spReady
          ctx.state.needsRedraw = true
        else: discard
      retryLoadLibrary(ctx.state)
      processEvents(ctx.state)
      ctx.state.spinnerFrame.inc
      persistConfigIfDirty(ctx.state)
      # Daemon reconnection watchdog — non-blocking async state sync
      if ctx.state.player.backendType == abtDaemon:
        let cli = DaemonService(ctx.state.svc)
        if not cli.isConnected:
          ctx.state.reconnectAttempts.inc
          if not ctx.state.reconnecting:
            ctx.state.reconnecting = true
            ctx.state.reattachSyncPending = 0
            ctx.state.markDirty(ceReconnecting)
          if ctx.state.reattachSyncPending == 0 and ctx.state.reconnectAttempts mod 30 == 0:
            cli.ensureConnected()
            if cli.isConnected:
              ctx.state.reattachSyncPending = 3
              try:
                let resp = cli.sendDaemonCmd(%*{"cmd": "get_full_state"})
                fullStateSync(ctx.state, resp)
                if resp.hasKey("queue"):
                  try:
                    let qArr = resp["queue"]
                    var queue: seq[int] = @[]
                    var queuePaths: seq[string] = @[]
                    for qItem in qArr.items:
                      let qPath = qItem.getStr("")
                      var found = false
                      for i, t in ctx.state.libraryTracks:
                        if t.path == qPath:
                          queue.add(i)
                          queuePaths.add("")
                          found = true
                          break
                      if not found:
                        queue.add(-1)
                        queuePaths.add(qPath)
                    ctx.state.playbackQueue = queue
                    ctx.state.queuePaths = queuePaths
                    ctx.state.markDirtyBatch(ceQueue, cePlayState)
                  except: discard
                if ctx.state.currentPlayingPath.len > 0:
                  for i, t in ctx.state.libraryTracks:
                    if t.path == ctx.state.currentPlayingPath:
                      ctx.state.selectIndex = i
                      ctx.state.currentPlayingId = t.id
                      break
                ctx.state.reattachSyncPending.dec
                if ctx.state.libraryTracks.len == 0:
                  let respLib = cli.sendDaemonCmd(%*{"cmd": "get_library"})
                  if respLib.hasKey("tracks") and respLib["tracks"].len > 0:
                    ctx.state.loadLibraryFromDaemon(respLib)
                    ctx.state.ytDownloaded.clear()
                    let dlDir = ctx.state.ytDownloadDir
                    for t in ctx.state.libraryTracks:
                      if t.path.startsWith(dlDir):
                        ctx.state.ytDownloaded[t.path] = t.path
                    ctx.state.downloadCount = ctx.state.ytDownloaded.len
                ctx.state.reattachSyncPending.dec
                let respFav = cli.sendDaemonCmd(%*{"cmd": "get_favourites"})
                if respFav.hasKey("favourites"):
                  ctx.state.favouriteIds = initHashSet[int64]()
                  for fid in respFav["favourites"]:
                    ctx.state.favouriteIds.incl(fid.getInt(0).int64)
                ctx.state.reattachSyncPending.dec
                if ctx.state.reattachSyncPending == 0:
                  ctx.state.reconnecting = false
                  ctx.state.reconnectAttempts = 0
                  ctx.state.markDirtyBatch(cePlayState, ceTrack, ceVolume, cePosition)
              except:
                ctx.state.reconnecting = false
                ctx.state.reconnectAttempts = 0
        elif ctx.state.reconnecting and ctx.state.reattachSyncPending == 0:
          ctx.state.reconnecting = false
          ctx.state.reconnectAttempts = 0
          ctx.state.markDirtyBatch(cePlayState, ceTrack, ceVolume, cePosition)

      if ctx.state.overlay.kind == okYtSearch and ctx.state.player.backendType == abtDaemon:
        let cli = DaemonService(ctx.state.svc)
        if ctx.state.ytDebounceAt > 0 and epochTime() >= ctx.state.ytDebounceAt:
          ctx.state.ytDebounceAt = 0
          if ctx.state.overlay.query.len > 0:
            if ctx.state.ytSearchQuery != ctx.state.overlay.query:
              if ctx.state.ytSearchActive:
                cli.ytSearchCancel()
                ctx.state.ytSearchActive = false
              ctx.state.overlay.ytResults = @[]
              ctx.state.overlay.cursor = 0
              ctx.state.ytSearchQuery = ctx.state.overlay.query
              ctx.state.ytSearchPage = 0
            if not ctx.state.ytSearchActive:
              # Check cache first
              let cacheKey = ctx.state.overlay.query & ":" & $(ctx.state.ytSearchPageSize * max(1, ctx.state.ytSearchPage + 1))
              if ctx.state.ytSearchCache.hasKey(cacheKey) and ctx.state.ytSearchCache[cacheKey].len > 0:
                ctx.state.overlay.ytResults = ctx.state.ytSearchCache[cacheKey]
                if ctx.state.overlay.cursor >= ctx.state.overlay.ytResults.len:
                  ctx.state.overlay.cursor = 0
                ctx.state.ytSearchLoading = false
                ctx.state.ytSearchActive = false
                ctx.state.markDirty(ceSearchResults)
              else:
                cli.ytSearch(ctx.state.overlay.query, ctx.state.ytSearchPageSize * max(1, ctx.state.ytSearchPage + 1))
                ctx.state.ytSearchActive = true
                ctx.state.ytSearchLoading = true
                ctx.state.markDirty(ceSearchLoading)
      if ctx.state.ytStreamResolving and ctx.state.player.backendType == abtDaemon:
        # Stream resolution handled via yt_stream_resolved event in processEvents
        discard
      if ctx.state.feedbackTimer > 0:
        ctx.state.feedbackTimer.dec
      if ctx.state.ytSearchLoading and ctx.state.overlay.kind == okYtSearch and ctx.state.overlay.ytResults.len == 0:
        ctx.state.markDirty(ceSearchLoading)
      if ctx.state.volumeCueTimer > 0:
        ctx.state.volumeCueTimer.dec
      if ctx.state.notificationTimer > 0:
        ctx.state.notificationTimer.dec
      if ctx.state.nowPlayingCueTimer > 0:
        ctx.state.nowPlayingCueTimer.dec
      if ctx.state.lastKeyTimer > 0:
        ctx.state.lastKeyTimer.dec
      if ctx.state.upNextTimer > 0:
        ctx.state.upNextTimer.dec
      if ctx.state.status == psPlaying and ctx.state.volume >= 80:
        ctx.state.highVolAccumFrames.inc
        if ctx.state.highVolAccumFrames >= 30 * 60 * 60:
          ctx.state.highVolAccumFrames = 0
          ctx.state.showNotification("High volume for 30 min — lower to protect hearing", nkWarning)
      elif ctx.state.highVolAccumFrames > 0:
        ctx.state.highVolAccumFrames = 0
      if ctx.state.sleepTimerRemaining > 0 and ctx.state.player.backendType == abtDaemon:
        ctx.state.sleepTimerRemaining = DaemonService(ctx.state.svc).getSleepTimerRemaining
      # Reconnection cooldown (frame-based, no os.sleep)
      if ctx.state.player.backendType == abtDaemon:
        let cli = DaemonService(ctx.state.svc)
        if cli.getReconnectCooldown > 0:
          cli.decReconnectCooldown
      let curW = terminal.terminalWidth()
      let curH = terminal.terminalHeight()
      resized = false
      if curW != lastW or curH != lastH:
        lastW = curW
        lastH = curH
        resized = true
      if ctx.state.status != oldStatus:
        ctx.state.needsRedraw = true
      oldStatus = ctx.state.status
      if ctx.state.timePos != oldTimePos:
        let newDisplay = formatTime(ctx.state.timePos)
        if newDisplay != oldTimeDisplay:
          oldTimeDisplay = newDisplay
          ctx.state.markDirty(cePosition)
        oldTimePos = ctx.state.timePos
      # Hover preview: track selection changes and show preview after 3s idle
      if key != iw.Key.None:
        if ctx.state.hoverState.active:
          deleteImage(HoverImageId)
          ctx.state.markDirty(ceSearchResults)
        ctx.state.hoverState.active = false
        ctx.state.hoverState.coverData = @[]
        ctx.state.hoverState.coverFetching = false
        ctx.state.hoverState.coverTransmitted = false
      if ctx.state.tab == tabLibrary and ctx.state.overlay.kind == okNone and not ctx.state.helpVisible and not ctx.state.aboutVisible:
        if ctx.state.selectIndex != ctx.state.lastHoverSelectIdx:
          ctx.state.lastHoverSelectIdx = ctx.state.selectIndex
          ctx.state.hoverState.hoverStart = epochTime()
          ctx.state.hoverState.active = false
          ctx.state.hoverState.trackIdx = -1
          ctx.state.hoverState.coverData = @[]
          ctx.state.hoverState.coverFetching = false
          ctx.state.hoverState.coverTransmitted = false
          deleteImage(HoverImageId)
          if ctx.state.selectIndex >= 0 and ctx.state.selectIndex < ctx.state.displayItems.len:
            let item = ctx.state.displayItems[ctx.state.selectIndex]
            if item.kind == likTrack and item.trackIdx >= 0 and item.trackIdx < ctx.state.libraryTracks.len:
              let t = ctx.state.libraryTracks[item.trackIdx]
              ctx.state.hoverState.trackIdx = item.trackIdx
              ctx.state.hoverState.path = t.path
              ctx.state.hoverState.title = t.displayName()
              ctx.state.hoverState.album = t.album
              ctx.state.hoverState.channel = t.artist
              ctx.state.hoverState.duration = t.duration
              ctx.state.hoverState.rowX = 0
              ctx.state.hoverState.rowY = 3
        let justActivated = not ctx.state.hoverState.active and ctx.state.hoverState.trackIdx >= 0 and epochTime() - ctx.state.hoverState.hoverStart > ctx.state.hoverDelay
        if justActivated:
          ctx.state.hoverState.active = true
          ctx.state.needsRedraw = true
        # Fetch cover art for hover — async, checks cache every frame
        if ctx.state.hoverState.active and ctx.state.hasKittyGraphics and ctx.state.hoverState.path.len > 0 and ctx.state.hoverState.coverData.len == 0:
          let cacheKey = hash(ctx.state.hoverState.path).toHex
          if ctx.state.coverCache.hasKey(cacheKey):
            let (cd, cm) = ctx.state.coverCache[cacheKey]
            if cd.len > 0:
              ctx.state.hoverState.coverData = cd
              ctx.state.hoverState.coverMime = cm
              ctx.state.hoverState.coverTransmitted = false
              ctx.state.touchCoverCache(cacheKey)
              ctx.state.needsRedraw = true
            else:
              ctx.state.hoverState.coverRequestedPath = ctx.state.hoverState.path
          elif not ctx.state.hoverState.coverFetching and ctx.state.hoverState.coverRequestedPath != ctx.state.hoverState.path and ctx.state.player.backendType == abtDaemon:
            ctx.state.hoverState.coverFetching = true
            ctx.state.hoverState.coverRequestedPath = ctx.state.hoverState.path
            DaemonService(ctx.state.svc).sendOnly(%*{"cmd": "request_cover_art", "path": ctx.state.hoverState.path})
      else:
        if ctx.state.hoverState.active:
          deleteImage(HoverImageId)
        ctx.state.hoverState.active = false
        ctx.state.hoverState.coverData = @[]
        ctx.state.hoverState.coverFetching = false
      let now = epochTime()
      let shouldDraw = resized or ctx.state.needsRedraw or ctx.state.dirtyFlags.card > 0
      if shouldDraw and (resized or now - lastRenderTime > 0.016):
        lastRenderTime = now
        ctx.tb = iw.initTerminalBuffer(curW, curH)
        renderApp(ctx)
        if resized:
          prevTb = iw.initTerminalBuffer(0, 0)
        ctx.state.needsRedraw = false
        tbReady = true
      if shouldDraw and tbReady:
        iw.display(ctx.tb, prevTb)
        prevTb = ctx.tb

      if key != iw.Key.None:
        showInputCursor(ctx.state, curW, curH)
      ctx.state.clearDirty()
      frameNo += 1
    except Exception as ex:
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
      let cacheDir = getEnv("XDG_CACHE_HOME", getEnv("HOME", "") & "/.cache") & "/gtm"
      if not dirExists(cacheDir): createDir(cacheDir)
      let debugPath = cacheDir / "debug.log"
      var debugFile: File
      if debugFile.open(debugPath, fmAppend):
        discard dup2(cint(debugFile.getFileHandle), cint(2))
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

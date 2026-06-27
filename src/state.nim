## Core state types and global state for the TUI application
##
## AppState holds all mutable UI state: tabs, play queue, settings,
## library view, theme cache, cover art cache, and the daemon IPC
## connection. It is passed by `var` through the entire TUI codebase.
##
## ┌───────────────────────────────────────────────────────┐
## │  AppState                                              │
## │                                                       │
## │  ┌─────────────────┐  ┌──────────────────────────┐    │
## │  │  Config fields   │  │  DaemonClient (Audio     │    │
## │  │  (theme, volume,│  │  Backend subclass)       │    │
## │  │   keybindings…)  │  │  - sock, buf, pending    │    │
## │  └─────────────────┘  │  - drainedEvents[]        │    │
## │                        └──────────────────────────┘    │
## │  ┌─────────────────┐  ┌──────────────────────────┐    │
## │  │  Playback        │  │  Library view            │    │
## │  │  - queue[]       │  │  - tracks[], playlists[] │    │
## │  │  - cursor, status │  │  - filter, search          │    │
## │  │  - volume, repeat,│  │  - selection            │    │
## │  │    shuffle, mute  │  └──────────────────────────┘    │
## │  └─────────────────┘                                    │
## │  ┌─────────────────┐  ┌──────────────────────────┐    │
## │  │  UI state        │  │  Cover cache + lyrics    │    │
## │  │  - tab, editor   │  │  (LrcData, LrcLine[])   │    │
## │  │  - notifications │  └──────────────────────────┘    │
## │  └─────────────────┘                                    │
## │  daemonStateVersion — monotonic counter for state sync  │
## └───────────────────────────────────────────────────────┘

import illwave as iw
import os, tables, sets, osproc, audio, theme, math, json, options, colors, strutils, icons

const
  DefaultVolume* = 80
  CrossfadeCurveLabels* = ["EqualPower", "Quadratic", "Cubic", "Asymmetric"]
  JsRuntimes* = ["node", "bun", "deno"]
  SpotifyFormats* = ["opus", "m4a", "best"]

var debugMode*: bool

const ActionDebounceMs* = 150

type
  PlaybackStatus* = enum
    psStopped, psPlaying, psPaused

  ChangeEvent* = enum
    ceTrack, cePlayState, cePosition, ceVolume, ceQueue,
    ceSearchResults, ceSearchLoading, ceSettings,
    cePlaylists, ceQueueCursor, ceFeedback, ceDownloadProgress,
    ceReconnecting

  StartupPhase* = enum
    spInit, spDaemonConnecting, spConfigLoading, spLibraryLoading,
    spSpotifySync, spReady

  HighlightAttr* = object
    fg*, bg*: Option[colors.Color]
    bold*, italic*, underline*: bool

  HighlightGroups* = object
    Normal*: HighlightAttr
    TabBar*: HighlightAttr
    TabBarActive*: HighlightAttr
    TabBarInactive*: HighlightAttr
    NowPlayingTitle*: HighlightAttr
    NowPlayingArtist*: HighlightAttr
    NowPlayingProgress*: HighlightAttr
    NowPlayingProgressFill*: HighlightAttr
    NowPlayingStatus*: HighlightAttr
    NowPlayingUpNext*: HighlightAttr
    NowPlayingUpNextCursor*: HighlightAttr
    NowPlayingUpNextHeader*: HighlightAttr
    LibrarySidebar*: HighlightAttr
    LibrarySidebarActive*: HighlightAttr
    LibrarySidebarSelected*: HighlightAttr
    LibraryContentHeader*: HighlightAttr
    LibraryContentRow*: HighlightAttr
    LibraryContentRowSelected*: HighlightAttr
    SettingsSidebar*: HighlightAttr
    SettingsContentRow*: HighlightAttr
    SettingsContentRowSelected*: HighlightAttr
    SettingsSectionHeader*: HighlightAttr
    StatusBar*: HighlightAttr
    StatusBarHints*: HighlightAttr
    StatusBarModule*: HighlightAttr
    FilterBar*: HighlightAttr
    ProgressBar*: HighlightAttr
    ProgressBarTime*: HighlightAttr
    VisualizerBar*: HighlightAttr
    OverlayBorder*: HighlightAttr
    OverlayTitle*: HighlightAttr
    OverlayInput*: HighlightAttr
    OverlayRow*: HighlightAttr
    OverlayRowSelected*: HighlightAttr
    OverlayFooter*: HighlightAttr
    Scrollbar*: HighlightAttr
    ErrorMsg*: HighlightAttr
    WarningMsg*: HighlightAttr
    InfoMsg*: HighlightAttr
    SuccessMsg*: HighlightAttr
    VolumeCue*: HighlightAttr
    FeedbackCue*: HighlightAttr
    NowPlayingCue*: HighlightAttr
    UpNextCue*: HighlightAttr
    EqualizerBar*: HighlightAttr

  FooterPresetName* = enum
    fpnMinimal, fpnCompact, fpnFull, fpnInfo, fpnNavigator, fpnDebug, fpnMusic, fpnClock, fpnCustom

  CrossfadeCurveType* = enum
    cctEqualPower, cctQuadratic, cctCubic, cctAsymmetric

  InputMode* = enum
    imNormal, imFilter

  LibraryPanel* = enum
    lpSidebar, lpContent

  AppTab* = enum
    tabNowPlaying = 0, tabLibrary, tabSettings

  TabSavedState* = object
    selectIndex*: int
    filterText*: string
    filterScope*: FilterScope
    librarySidebarSelect*: int
    playlistContentsIdx*: int
    settingsCategory*: SettingsCategory
    settingsFocusPanel*: LibraryPanel

  QueueItem* = object
    id*: int64
    path*: string

  Track* = object
    path*: string
    title*: string
    artist*: string
    album*: string
    duration*: float
    id*: int64
    trackNum*: int
    year*: int
    genre*: string
    playCount*: int
    artistId*: int64
    albumId*: int64
    isFavourite*: bool
    addedAt*: string
    lastPlayed*: string

  ArtistEnt* = object
    id*: int64
    name*: string

  AlbumEnt* = object
    id*: int64
    title*: string
    artistId*: int64
    artistName*: string
    year*: int
    genre*: string

  UserPlaylist* = object
    id*: int64
    name*: string
    trackIds*: seq[int64]

  ConfigData* = object
    theme*: string
    volume*: int
    lastTab*: AppTab
    refreshTheme*: bool
    idleTimeout*: int
    ipcTimeout*: int
    onConfigApply*: seq[tuple[cmd, arg: string]]

  LibraryItemKind* = enum
    likTrack, likArtist, likAlbum, likPlaylist

  FilterScope* = enum
    fsAll, fsArtists, fsAlbums, fsPlaylists, fsTracks,
    fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed,
    fsDownloads, fsSpotify, fsSpLiked, fsSpPlaylists

  DownloadsTab* = enum
    dtDownloading, dtDownloaded

  YtSearchResultKind* = enum srkVideo, srkPlaylist

  YtSearchResult* = object
    title*: string
    url*: string
    duration*: string
    channel*: string
    playlistTitle*: string
    kind*: YtSearchResultKind

  YtPlaylistDetail* = object
    title*: string
    url*: string
    channel*: string
    trackCount*: int
    tracks*: seq[YtSearchResult]

  TrashItem* = object
    id*: int
    trackId*: int64
    originalPath*: string
    trashPath*: string
    trashedAt*: int
    expiresAt*: int

  LrcLine* = object
    timestamp*: float
    text*: string

  LrcData* = object
    title*, artist*, album*: string
    lines*: seq[LrcLine]

  OverlayKind* = enum
    okNone
    okYtSearch
    okYtBatch
    okQueuePicker
    okPlaylistSearch
    okThemePicker
    okCommandPalette
    okQueueOverlay
    okFuzzyFinder
    okEqPresetPicker
    okTrashView
    okFooterModulePicker
    okSpotifyUrlInput
    okSpotifySearch
    okLyricsSearch
    okDeleteConfirm

  YtSubTab* = enum ystAll, ystPlaylists

  NotificationKind* = enum nkInfo, nkSuccess, nkWarning, nkError

  OverlayState* = object
    kind*: OverlayKind
    query*: string
    cursor*: int
    scrollOffset*: int
    results*: seq[int]
    strResults*: seq[string]
    ytResults*: seq[YtSearchResult]
    selected*: HashSet[int]
    multiMode*: bool
    batchItems*: seq[YtSearchResult]
    batchShowPls*: bool
    plMode*: int
    lyricsSearchResults*: seq[tuple[id: int, title, artist, album: string, duration: float]]
    ytSubTab*: YtSubTab
    ytPlaylistDetail*: YtPlaylistDetail
    ytAutocompleteSuggestions*: seq[string]
    ytAutocompleteCursor*: int
    ytAutocompleteVisible*: bool

  DownloadTask* = object
    process*: Process
    title*: string
    url*: string
    channel*: string
    outputDir*: string
    buf*: string
    completed*: bool
    resultPath*: string
    startedAt*: float

  LibraryItem* = object
    kind*: LibraryItemKind
    trackIdx*: int
    label*: string
    sublabel*: string
    id*: int64

  CommandEntry* = object
    id*: string
    name*: string
    description*: string
    icon*: string
    defaultKeys*: seq[string]
    keyCodes*: seq[seq[iw.Key]]
    handler*: proc(state: var AppState) {.closure.}

  FooterModule* = enum
    fmPlayStatus
    fmVolume
    fmBackend
    fmDeviceName
    fmSelectCount
    fmTime
    fmDate
    fmRepeatShuffle
    fmSleepTimer
    fmElapsedTime
    fmQueueCount
    fmEqPreset
    fmCurrentPlaylist
    fmKeyPressed

  SettingsCategory* = enum
    scAudio, scYouTube, scAppearance, scSystem, scSpotify

  BorderStyle* = enum
    bsRounded, bsSharp, bsDouble, bsBold, bsDotted, bsCurved, bsNone

  HoverPreviewState* = object
    active*: bool
    hoverStart*: float
    trackIdx*: int
    rowX*, rowY*: int
    path*: string
    title*: string
    album*: string
    channel*: string
    duration*: float
    coverData*: seq[byte]
    coverMime*: string
    coverFetching*: bool
    coverRequestedPath*: string
    coverTransmitted*: bool
  AppState* = object
    theme*: Theme
    highlightGroups*: HighlightGroups
    userHighlightOverrides*: JsonNode
    footerPreset*: FooterPresetName
    player*: AudioBackend
    svc*: ref RootObj
    status*: PlaybackStatus
    timePos*: float
    duration*: float
    volume*: int
    dirtyFlags*: set[ChangeEvent]
    helpVisible*: bool
    mode*: InputMode
    filterText*: string
    filterScope*: FilterScope
    libraryFocusPanel*: LibraryPanel
    librarySidebarSelect*: int
    settingsCategory*: SettingsCategory
    settingsFocusPanel*: LibraryPanel
    filteredIndices*: seq[int]
    selectIndex*: int
    needsRedraw*: bool
    tab*: AppTab
    tabSaved*: array[AppTab, TabSavedState]
    selectMode*: bool
    selectedIndices*: HashSet[int]
    selectionAnchor*: int
    config*: ConfigData
    libraryTracks*: seq[Track]
    libraryArtists*: seq[ArtistEnt]
    libraryAlbums*: seq[AlbumEnt]
    libraryPlaylists*: seq[UserPlaylist]
    favouriteIds*: HashSet[int64]
    displayItems*: seq[LibraryItem]
    commands*: seq[CommandEntry]
    cmdRegistry*: Table[string, int]
    keybindings*: Table[string, string]
    keyDispatch*: Table[iw.Key, seq[int]]
    multiKeyDispatch*: Table[seq[iw.Key], int]
    pendingSeq*: seq[iw.Key]
    pendingSeqTimer*: int
    overlay*: OverlayState
    daemonConnected*: bool
    daemonPid*: int
    configPath*: string
    dataDir*: string
    audioAvailable*: bool
    currentPlayingPath*: string
    currentPlayingId*: int64
    cachedPlayingTrack*: Track
    cachedPlayingPath*: string
    volumeCueTimer*: int
    volumeCueVolume*: int
    highVolAccumFrames*: int
    notificationMsg*: string
    notificationBody*: string
    notificationKind*: NotificationKind
    notificationTimer*: int
    nowPlayingCueMsg*: string
    nowPlayingCueTimer*: int
    lastKeyDisplay*: string
    lastKeyTimer*: int
    lastCommandName*: string
    prevVolume*: int
    shuffleEnabled*: bool
    shuffleOrder*: seq[int]
    shuffleIndex*: int
    repeatMode*: int
    sleepTimerRemaining*: int
    playlistContentsIdx*: int
    playlistInputActive*: bool
    playlistInputPrompt*: string
    playlistInputBuffer*: string
    addingToPlaylistId*: int64
    addingToPlaylistName*: string
    footerModules*: set[FooterModule]
    footerLeftModules*: set[FooterModule]
    footerRightModules*: set[FooterModule]
    rawKeybindingsJson*: JsonNode
    feedbackMsg*: string
    feedbackTimer*: int
    playbackQueue*: seq[int]
    queuePaths*: seq[string]
    queueItemIds*: seq[int64]
    trackIdToIdx*: Table[int64, int]
    ytDebounceAt*: float
    ytStreamPendingItem*: YtSearchResult
    ytStreamTitle*: string
    ytStreamChannel*: string
    ytDownloadDir*: string
    ytDownloadQueue*: seq[YtSearchResult]
    ytDownloadTasks*: seq[DownloadTask]
    ytDownloaded*: Table[string, string]
    downloadCount*: int
    spCookieSource*: string
    spCookieFilePath*: string
    spAudioFormat*: string
    spDownloaded*: Table[string, string]
    spDownloadCount*: int
    spSearchResults*: seq[tuple[id, name, artist, album, url: string, durationMs: int]]
    spSearchLoading*: bool
    spUserPlaylists*: seq[tuple[id, name: string]]
    spLikedSongs*: seq[tuple[id, name, artist, album, url: string, durationMs: int]]
    sidebarSpExpanded*: bool
    downloadsTab*: DownloadsTab
    downloadProgress*: Table[string, int]
    ytMaxConcurrentDownloads*: int
    ytAutoDownload*: bool
    ytCookieSource*: string
    ytCookieFilePath*: string
    ytJsRuntime*: string
    ytSearchHistory*: seq[string]
    ytSearchHistoryLower*: seq[string]
    ytSearchCache*: TableRef[string, seq[YtSearchResult]]
    ytSearchCacheKeys*: seq[string]
    ytSearchQuery*: string
    ytSearchPage*: int
    ytSearchPageSize*: int
    ytSearchLoading*: bool
    actionDebounceAt*: float
    iconPreference*: IconPreference
    transparentBg*: bool
    overlayOpacity*: float
    borderStyle*: BorderStyle
    progressStyle*: int
    ytProgressCurrent*: int
    ytProgressTotal*: int
    crossfadeDuration*: int
    crossfadeCurve*: CrossfadeCurveType
    crossfadePrepared*: bool
    crossfadeStarted*: bool
    crossfading*: bool
    crossfadeNextPath*: string
    aboutVisible*: bool
    reconnecting*: bool
    reconnectAttempts*: int
    reattachSyncPending*: int
    pingMissed*: int
    spinnerFrame*: int
    queueCursor*: int
    queuePendingConfirm*: int
    eqPreset*: string
    spatialWidth*: float
    eqPresetList*: seq[string]
    eqPresetSelect*: int
    ytPlaybackStartTime*: float
    ytPauseDuration*: float
    ytPauseStartTime*: float
    ytDurationSec*: float
    ytSearchActive*: bool
    ytStreamResolving*: bool
    ytDownloadActive*: bool
    ytPlaylistFetching*: bool
    currentPlayingTitle*: string
    currentPlayingChannel*: string
    upNextMsg*: string
    upNextTimer*: int
    upNextScrollOffset*: int
    cursorVisible*: bool
    deviceName*: string
    audioBackendName*: string
    hasKittyGraphics*: bool
    hoverState*: HoverPreviewState
    coverCache*: Table[string, tuple[data: seq[byte], mime: string]]
    coverCacheOrder*: seq[string]
    coverPendingPath*: string
    trashItems*: seq[TrashItem]
    coverFetching*: bool
    coverImageId*: int
    hoverDelay*: float
    daemonStateVersion*: int
    startupPhase*: StartupPhase
    startupQueueFlushed*: bool
    configDirty*: bool
    currentLyrics*: LrcData
    lyricsLineIdx*: int
    lyricsVisible*: bool
    libraryLoading*: bool
    libraryNeedsScan*: bool
    libraryRetryCount*: int
    libraryLastRetryAt*: float
    showItemCounts*: bool
    volumeSafetyThreshold*: int
    volumeSafetyConfirmed*: bool
    libraryLastVersion*: int
    lastHoverSelectIdx*: int
    hoverDismissAt*: float

const
  CoverCacheMaxSize* = 100

const
  GTM_VERSION* {.strdefine.} = staticExec("git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'").strip
  GTM_BUILD_TIME* {.strdefine.} = staticExec("date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null").strip

  FooterPresets*: Table[FooterPresetName, set[FooterModule]] = {
    fpnMinimal:   {fmPlayStatus},
    fpnCompact:   {fmPlayStatus, fmTime, fmBackend, fmQueueCount, fmEqPreset},
    fpnFull:      {fmPlayStatus, fmVolume, fmBackend, fmDeviceName, fmSelectCount, fmTime, fmDate, fmRepeatShuffle, fmSleepTimer, fmQueueCount, fmEqPreset, fmCurrentPlaylist},
    fpnInfo:      {fmPlayStatus, fmVolume, fmBackend, fmQueueCount},
    fpnNavigator: {fmPlayStatus, fmRepeatShuffle, fmSelectCount, fmTime, fmDate},
    fpnDebug:     {fmPlayStatus, fmTime, fmDate, fmSleepTimer, fmBackend, fmVolume, fmQueueCount, fmEqPreset},
    fpnMusic:     {fmPlayStatus, fmRepeatShuffle, fmVolume, fmQueueCount, fmEqPreset},
    fpnClock:     {fmPlayStatus, fmTime, fmDate}
  }.toTable()


const
  SettingCategoryDescs*: array[SettingsCategory, string] = [
    "Configure audio playback: volume, crossfade between tracks, and audio backend.",
    "YouTube integration: JS runtime, download limits, search preferences, cookies.",
    "Customize the UI appearance: theme colors, footer layout, and refresh behavior.",
    "System settings: idle timeout, daemon IPC, and factory reset options.",
    "Spotify integration: cookies, audio format, download management, and playlist import."
  ]

  SettingDescs*: array[SettingsCategory, seq[string]] = [
    scAudio: @[
      "Master output volume (0\u2013100). Adjust with Left/Right arrows.",
      "Crossfade transition length (0\u201310 sec). 0 = disabled.",
      "Crossfade curve type for smooth transitions between tracks.",
      "Connection status to the background gtm daemon process."
    ],
    scYouTube: @[
      "Path to browser cookie file for YouTube authentication.",
      "JavaScript runtime for YouTube extraction and processing.",
      "Maximum concurrent YouTube downloads (1\u201310).",
      "YouTube search results per page (10\u201350).",
      "View and manage saved YouTube search history.",
      "When enabled, pressing Enter on a YouTube result starts downloading immediately instead of resolving a stream URL.",
      "Remove all saved YouTube search queries permanently."
    ],
    scAppearance: @[
      "Color theme seed. Type a name or use a preset (mocha/latte).",
      "Randomize the theme seed on each application launch.",
      "Choose a preset layout for the status bar footer modules.",
      "Individually enable/disable footer modules and assign them to left or right side.",
      "Transparent background mode. Uses terminal's native background color.",
      "Overlay background opacity (0\u2013100%). Only applies in transparent mode.",
      "Icon style: Auto-detect, Nerd Font, or Emoji fallback.",
      "Border style for overlay windows and popups.",
      "Progress bar style: Block or Thumb+Track."
    ],
    scSystem: @[
      "Seconds of inactivity before auto-shutdown (0 = never).",
      "Timeout in seconds for daemon IPC communication (1\u201330).",
      "Restore all settings to factory defaults (cannot be undone).",
      "Keyboard mode: Desktop or Termux. Auto-detected on startup."
    ],
    scSpotify: @[
      "Browser cookie source for Spotify authentication.",
      "Path to a custom Netscape-format cookie file for Spotify.",
      "Preferred audio format for Spotify-sourced downloads.",
      "Maximum concurrent Spotify downloads (1\u201310).",
      "View download history for all Spotify-sourced tracks.",
      "Remove all Spotify download history permanently.",
      "Import a Spotify playlist URL to fetch and download tracks."
    ]
  ]

  ToggleOptionDescs*: Table[string, string] = {
    "node": "Node.js runtime. Recommended for best yt-dlp compatibility.",
    "bun": "Bun runtime. Fast startup, good yt-dlp compatibility.",
    "deno": "Deno runtime. Experimental \u2014 may have compatibility issues.",
    "EqualPower": "Equal-power cos/sin curve. Constant perceived loudness.",
    "Quadratic": "Quadratic ease-in-out. Faster fade-in, slower fade-out.",
    "Cubic": "Cubic ease-in-out. More pronounced fade effect.",
    "Asymmetric": "Asymmetric curve. Fast fade-out, slow fade-in."
  }.toTable()

proc stateDir*(): string =
  let xdg = getEnv("XDG_RUNTIME_DIR", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = getTempDir() / "gtm-" & getEnv("USER", "unknown")

proc configDir*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = getEnv("HOME", "") & "/.config/gtm"

proc dataDir*(): string =
  let xdg = getEnv("XDG_DATA_HOME", "")
  if xdg.len > 0:
    result = xdg & "/gtm"
  else:
    result = getEnv("HOME", "") & "/.local/share/gtm"

proc pidPath*(): string = stateDir() & "/gtmd.pid"
proc sockPath*(): string = stateDir() & "/gtmd.sock"

proc clear*(o: var OverlayState) =
  o = OverlayState(kind: okNone)

proc isPlaylistView*(state: AppState): bool =
  state.tab == tabLibrary and state.filterScope == fsPlaylists

proc getPlayingTrack*(state: var AppState): Track =
  if state.currentPlayingPath.len > 0:
    if state.cachedPlayingPath == state.currentPlayingPath:
      return state.cachedPlayingTrack
    for t in state.libraryTracks:
      if t.path == state.currentPlayingPath:
        state.cachedPlayingPath = state.currentPlayingPath
        state.cachedPlayingTrack = t
        return t
  Track()

proc saveTabState*(state: var AppState) =
  let t = state.tab
  state.tabSaved[t].selectIndex = state.selectIndex
  state.tabSaved[t].filterText = state.filterText
  state.tabSaved[t].filterScope = state.filterScope
  state.tabSaved[t].librarySidebarSelect = state.librarySidebarSelect
  state.tabSaved[t].playlistContentsIdx = state.playlistContentsIdx
  state.tabSaved[t].settingsCategory = state.settingsCategory
  state.tabSaved[t].settingsFocusPanel = state.settingsFocusPanel

proc restoreTabState*(state: var AppState) =
  let t = state.tab
  let saved = state.tabSaved[t]
  state.selectIndex = saved.selectIndex
  state.filterText = saved.filterText
  state.filterScope = saved.filterScope
  state.librarySidebarSelect = saved.librarySidebarSelect
  state.playlistContentsIdx = saved.playlistContentsIdx
  state.settingsCategory = saved.settingsCategory
  state.settingsFocusPanel = saved.settingsFocusPanel

template markDirty*(state: var AppState, event: ChangeEvent) =
  state.dirtyFlags.incl(event)

template markDirtyBatch*(state: var AppState, events: varargs[ChangeEvent]) =
  for e in events: state.dirtyFlags.incl(e)

template clearDirty*(state: var AppState) =
  state.dirtyFlags = {}

template isDirty*(state: AppState, event: ChangeEvent): bool =
  event in state.dirtyFlags

proc ensureCoverCacheFit*(state: var AppState) =
  while state.coverCache.len > CoverCacheMaxSize and state.coverCacheOrder.len > 0:
    let oldest = state.coverCacheOrder[0]
    state.coverCacheOrder.delete(0)
    state.coverCache.del(oldest)

proc touchCoverCache*(state: var AppState, key: string) =
  let idx = state.coverCacheOrder.find(key)
  if idx >= 0:
    state.coverCacheOrder.delete(idx)
  state.coverCacheOrder.add(key)

template guardDebounce*(state: var AppState): bool =
  ## Returns true if action should be skipped (debounced). Seek exempt.
  let now = epochTime()
  if state.actionDebounceAt > 0 and now < state.actionDebounceAt:
    true
  else:
    state.actionDebounceAt = now + (ActionDebounceMs / 1000.0)
    false



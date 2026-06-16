import illwave as iw
import os, tables, sets, osproc, audio, theme, math, json, options, colors

var debugMode*: bool

type
  PlaybackStatus* = enum
    psStopped, psPlaying, psPaused

  ChangeEvent* = enum
    ceTrack, cePlayState, cePosition, ceVolume, ceQueue,
    ceSearchResults, ceSearchLoading, ceSettings,
    cePlaylists, ceQueueCursor, ceFeedback, ceDownloadProgress,
    ceReconnecting

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
    fpnMinimal, fpnCompact, fpnFull, fpnInfo, fpnNavigator, fpnDebug, fpnMusic, fpnClock

  CrossfadeCurveType* = enum
    cctEqualPower, cctQuadratic, cctCubic, cctAsymmetric

  InputMode* = enum
    imNormal, imFilter, imLeaderMode

  LibraryPanel* = enum
    lpSidebar, lpContent

  AppTab* = enum
    tabNowPlaying = 0, tabLibrary, tabSettings

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

  LibraryItemKind* = enum
    likTrack, likArtist, likAlbum, likPlaylist

  FilterScope* = enum
    fsAll, fsArtists, fsAlbums, fsPlaylists, fsTracks,
    fsRecent, fsFavourites, fsLastPlayed, fsMostPlayed, fsLeastPlayed,
    fsDownloads

  DownloadsTab* = enum
    dtDownloading, dtDownloaded

  YtSearchResultKind* = enum srkVideo, srkPlaylist

  YtSearchResult* = object
    title*: string
    url*: string
    duration*: string
    channel*: string
    thumbnail*: string
    playlistTitle*: string
    kind*: YtSearchResultKind

  YtPlaylistDetail* = object
    title*: string
    url*: string
    channel*: string
    thumbnail*: string
    trackCount*: int
    tracks*: seq[YtSearchResult]

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

  YtSubTab* = enum ystAll, ystPlaylists

  NotificationKind* = enum nkInfo, nkSuccess, nkWarning, nkError

  OverlayState* = object
    kind*: OverlayKind
    query*: string
    cursor*: int
    results*: seq[int]
    strResults*: seq[string]
    ytResults*: seq[YtSearchResult]
    selected*: HashSet[int]
    multiMode*: bool
    batchItems*: seq[YtSearchResult]
    batchShowPls*: bool
    plMode*: int
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
    fmSelectCount
    fmTime
    fmDate
    fmRepeatShuffle
    fmSleepTimer
    fmElapsedTime
    fmQueueCount
    fmEqPreset
    fmCurrentPlaylist

  SettingsCategory* = enum
    scAudio, scYouTube, scAppearance, scSystem

  AppState* = object
    theme*: Theme
    highlightGroups*: HighlightGroups
    userHighlightOverrides*: JsonNode
    footerPreset*: FooterPresetName
    player*: AudioBackend
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
    volumeCueTimer*: int
    volumeCueVolume*: int
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
    rawKeybindingsJson*: JsonNode
    feedbackMsg*: string
    feedbackTimer*: int
    playbackQueue*: seq[int]
    ytDebounceAt*: float
    ytStreamPendingItem*: YtSearchResult
    ytStreamTitle*: string
    ytStreamChannel*: string
    ytDownloadDir*: string
    ytDownloadQueue*: seq[YtSearchResult]
    ytDownloadTasks*: seq[DownloadTask]
    ytDownloaded*: Table[string, string]
    downloadCount*: int
    downloadsTab*: DownloadsTab
    downloadProgress*: Table[string, int]
    ytMaxConcurrentDownloads*: int
    ytBatchDownloadMode*: bool
    ytCookieSource*: string
    ytJsRuntime*: string
    ytSearchHistory*: seq[string]
    ytSearchHistoryLower*: seq[string]
    ytSearchQuery*: string
    ytSearchPage*: int
    ytSearchPageSize*: int
    ytSearchLoading*: bool
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
    pingMissed*: int
    spinnerFrame*: int
    queueCursor*: int
    queuePendingConfirm*: int
    eqVisible*: bool
    eqBands*: array[10, float]
    eqPreset*: string
    eqPresetList*: seq[string]
    eqBandSelect*: int
    eqPresetSelect*: int
    eqScrollOffset*: int
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
    currentThumbnail*: string
    upNextMsg*: string
    upNextTimer*: int
    upNextScrollOffset*: int
    cursorVisible*: bool
    artAnsi*: string
    artAnsiLines*: int
    artAnsiKey*: string
    artAnsiWritten*: bool
    artBoxX*, artBoxY*, artBoxW*, artBoxH*: int
    artLoading*: bool

const
  GTM_VERSION* {.strdefine.} = "0.4.7"
  GTM_BUILD_TIME* {.strdefine.} = ""

  FooterPresets*: Table[FooterPresetName, set[FooterModule]] = {
    fpnMinimal:   {fmPlayStatus},
    fpnCompact:   {fmPlayStatus, fmTime, fmBackend, fmQueueCount, fmEqPreset},
    fpnFull:      {fmPlayStatus, fmVolume, fmBackend, fmSelectCount, fmTime, fmDate, fmRepeatShuffle, fmSleepTimer, fmQueueCount, fmEqPreset, fmCurrentPlaylist},
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
    "System settings: idle timeout, daemon IPC, and factory reset options."
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
      "When enabled, all YouTube results are queued as batch downloads.",
      "Remove all saved YouTube search queries permanently."
    ],
    scAppearance: @[
      "Color theme seed. Type a name or use a preset (mocha/latte).",
      "Randomize the theme seed on each application launch.",
      "Choose a preset layout for the status bar footer modules."
    ],
    scSystem: @[
      "Seconds of inactivity before auto-shutdown (0 = never).",
      "Timeout in seconds for daemon IPC communication (1\u201330).",
      "Restore all settings to factory defaults (cannot be undone)."
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
    result = "/tmp/gtm-" & getEnv("USER", "unknown")

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

proc getPlayingTrack*(state: AppState): Track =
  if state.currentPlayingPath.len > 0:
    for t in state.libraryTracks:
      if t.path == state.currentPlayingPath:
        return t
  Track()

template markDirty*(state: var AppState, event: ChangeEvent) =
  state.dirtyFlags.incl(event)

template markDirtyBatch*(state: var AppState, events: varargs[ChangeEvent]) =
  for e in events: state.dirtyFlags.incl(e)

template clearDirty*(state: var AppState) =
  state.dirtyFlags = {}

template isDirty*(state: AppState, event: ChangeEvent): bool =
  event in state.dirtyFlags



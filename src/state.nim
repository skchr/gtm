import illwave as iw
import os, tables, sets, osproc, audio, theme, visualizer, math, json

var debugMode*: bool

type
  PlaybackStatus* = enum
    psStopped, psPlaying, psPaused

  ChangeEvent* = enum
    ceTrack, cePlayState, cePosition, ceVolume, ceQueue,
    ceSearchResults, ceSearchLoading, ceSettings,
    cePlaylists, ceQueueCursor, ceFeedback, ceDownloadProgress,
    ceReconnecting

  InputMode* = enum
    imNormal, imFilter, imSelectMode, imLeaderMode

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
    kind*: YtSearchResultKind

  YtPlaylistDetail* = object
    title*: string
    url*: string
    channel*: string
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
    fmNextTrack
    fmSelectCount
    fmTime
    fmDate
    fmRepeatShuffle
    fmSleepTimer

  SettingsCategory* = enum
    scAudio, scYouTube, scAppearance, scSystem

  AppState* = object
    theme*: Theme
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
    viz*: Visualizer
    vizVisible*: bool
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
    prevVolume*: int
    shuffleEnabled*: bool
    shuffleOrder*: seq[int]
    shuffleIndex*: int
    repeatMode*: int
    sleepTimerRemaining*: int
    sleepTimerFrames*: int
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
    ytSearchProcess*: Process
    ytSearchProcessActive*: bool
    ytSearchOutputBuf*: string
    ytStreamProcess*: Process
    ytStreamActive*: bool
    ytStreamBuf*: string
    ytStreamPendingItem*: YtSearchResult
    ytStreamTitle*: string
    ytStreamChannel*: string
    ytStreamDuration*: string
    ytStreamUrl*: string
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
    ytSearchQuery*: string
    ytSearchPage*: int
    ytSearchPageSize*: int
    ytSearchLoading*: bool
    ytSearchResultsAll*: seq[YtSearchResult]
    ytProgressCurrent*: int
    ytProgressTotal*: int
    crossfadeDuration*: int
    crossfadePrepared*: bool
    crossfadeStarted*: bool
    crossfading*: bool
    masterEnded*: bool
    earlyPreloaded*: bool
    crossfadeNextPath*: string
    crossfadeNextId*: int64
    aboutVisible*: bool
    reconnecting*: bool
    reconnectAttempts*: int
    spinnerFrame*: int
    queueCursor*: int
    queuePendingConfirm*: int
    eqVisible*: bool
    eqBands*: array[10, float]
    eqPreset*: string
    eqBandSelect*: int
    eqPresetSelect*: int
    ytPlaybackStartTime*: float
    ytPauseDuration*: float
    ytPauseStartTime*: float
    ytDurationSec*: float
    ytSearchActive*: bool
    ytStreamResolving*: bool
    ytDownloadActive*: bool
    currentPlayingTitle*: string
    currentPlayingChannel*: string
    cursorVisible*: bool

const
  GTM_VERSION* {.strdefine.} = "0.3.0"
  GTM_BUILD_TIME* {.strdefine.} = ""


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



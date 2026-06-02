import os, tables, sets, audio, theme, visualizer

type
  PlaybackStatus* = enum
    psStopped, psPlaying, psPaused

  InputMode* = enum
    imNormal, imFilter, imCommandPalette, imSelectMode, imLeaderMode

  AppTab* = enum
    tabNowPlaying = 0, tabLibrary, tabPlaylists, tabSettings

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

  LibraryItemKind* = enum
    likTrack, likArtist, likAlbum, likPlaylist

  FilterScope* = enum
    fsAll, fsArtists, fsAlbums, fsPlaylists, fsTracks

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

  AppState* = object
    theme*: Theme
    player*: AudioBackend
    status*: PlaybackStatus
    timePos*: float
    duration*: float
    volume*: int
    helpVisible*: bool
    mode*: InputMode
    filterText*: string
    filterScope*: FilterScope
    filteredIndices*: seq[int]
    selectIndex*: int
    needsRedraw*: bool
    ggPressed*: bool
    ggTimer*: int
    leaderPressed*: bool
    leaderTimer*: int
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
    displayItems*: seq[LibraryItem]
    commands*: seq[CommandEntry]
    cmdRegistry*: Table[string, int]
    keybindings*: Table[string, string]
    paletteQuery*: string
    paletteResults*: seq[int]
    paletteSelect*: int
    showThemePicker*: bool
    themePickerQuery*: string
    themePickerResults*: seq[string]
    themePickerSelect*: int
    daemonConnected*: bool
    daemonPid*: int
    configPath*: string
    dataDir*: string
    audioAvailable*: bool
    currentPlayingPath*: string
    currentPlayingId*: int64
    volumeCueTimer*: int
    volumeCueVolume*: int
    prevVolume*: int
    playlistContentsIdx*: int
    playlistContentsTracks*: seq[int64]
    playlistInputActive*: bool
    playlistInputPrompt*: string
    playlistInputBuffer*: string

const
  GTM_VERSION* = "0.2.0"

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



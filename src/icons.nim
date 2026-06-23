import os, strutils, tables

type
  IconPreference* = enum ipAuto, ipNerdFont, ipEmoji

  IconPack* = object
    play*, pause*, stop*, nextTrack*, prevTrack*: string
    volumeHigh*, volumeMedium*, volumeLow*, volumeMuted*: string
    music*, artist*, album*, playlist*: string
    search*, heart*, shuffle*, repeatOne*, repeatAll*: string
    queue*, library*, settings*, help*: string
    checkmark*, cross*, arrowUp*, arrowDown*, arrowLeft*, arrowRight*: string
    musicNote*, disk*, headphone*, speaker*: string
    commandPalette*, filter*, selectMode*: string
    track*, time*, folder*, file*: string
    # Command palette icons (added for terminal fallback support)
    leaderMenu*, showAbout*, trash*, eqPresets*: string
    quitBg*, quitDaemon*, changeTheme*, savePlaylist*: string
    createPlaylist*, deletePlaylist*, renamePlaylist*: string
    toggleFav*, importM3u*, rescanLib*, sleepTimer*: string
    ytSearch*, spUrl*, spSearch*, dashboard*, spFeed*: string
    ytRecommended*, fuzzyFinder*, enqueue*, stopPlayback*: string
    seekForward*, seekBackward*, navUp*, navDown*: string
    enterFilter*, selectAll*, removeSelected*, addToPlaylist*: string

proc nerdFontIcons*(): IconPack =
  IconPack(
    play: " \uF04B ", pause: " \uF04C ", stop: " \uF04D ",
    nextTrack: "\uF050", prevTrack: "\uF049",
    volumeHigh: "\uF028", volumeMedium: "\uF027", volumeLow: "\uF026", volumeMuted: "\uF6A9",
    music: "\uF001", artist: "\uF007", album: "\uF0A0", playlist: "\uF0CA",
    search: "\uF002", heart: "\uF004", shuffle: " \uF049D ", repeatOne: " \uF0B6 ", repeatAll: " \uF01E ",
    queue: "\uF0C9", library: "\uF02D", settings: "\uF013", help: "\uF059",
    checkmark: "\uF00C", cross: "\uF00D", arrowUp: "\uF062", arrowDown: "\uF063", arrowLeft: "\uF060", arrowRight: "\uF061",
    musicNote: "\uF3B5", disk: "\uF0A0", headphone: "\uF025", speaker: "\uF028",
    commandPalette: "\uF120", filter: "\uF0B0", selectMode: "\uF204",
    track: "\uF001", time: "\uF017", folder: "\uF07B", file: "\uF15B",
    leaderMenu: "\uF0C9", showAbout: "\uF059", trash: "\uF1F8", eqPresets: "\uF025",
    quitBg: "\uF04C", quitDaemon: "\uF04D", changeTheme: "\uF1FC", savePlaylist: "\uF019",
    createPlaylist: "\uF067", deletePlaylist: "\uF1F8", renamePlaylist: "\uF044",
    toggleFav: "\uF004", importM3u: "\uF07C", rescanLib: "\uF021", sleepTimer: "\uF017",
    ytSearch: "\uF002", spUrl: "\uF0C1", spSearch: "\uF002", dashboard: "\uF0E4", spFeed: "\uF021",
    ytRecommended: "\uF144", fuzzyFinder: "\uF002", enqueue: "\uF0C9", stopPlayback: "\uF04D",
    seekForward: "\uF051", seekBackward: "\uF048", navUp: "\uF062", navDown: "\uF063",
    enterFilter: "\uF0B0", selectAll: "\uF00C", removeSelected: "\uF00D", addToPlaylist: "\uF0CA"
  )

proc emojiIcons*(): IconPack =
  IconPack(
    play: " \u25B6 ", pause: " \u23F8 ", stop: " \u23F9 ",
    nextTrack: "\u23ED", prevTrack: "\u23EE",
    volumeHigh: "\U0001F50A", volumeMedium: "\U0001F509", volumeLow: "\U0001F508", volumeMuted: "\U0001F507",
    music: "\U0001F3B5", artist: "\U0001F464", album: "\U0001F4BF", playlist: "\U0001F4CB",
    search: "\U0001F50D", heart: "\u2764", shuffle: " \U0001F500 ", repeatOne: " \U0001F502 ", repeatAll: " \U0001F501 ",
    queue: "\U0001F4DC", library: "\U0001F4DA", settings: "\u2699", help: "\u2753",
    checkmark: "\u2714", cross: "\u274C", arrowUp: "\u2B06", arrowDown: "\u2B07", arrowLeft: "\u2B05", arrowRight: "\u27A1",
    musicNote: "\u266B", disk: "\U0001F4BF", headphone: "\U0001F3A7", speaker: "\U0001F509",
    commandPalette: "\u2328", filter: "\U0001F50D", selectMode: "\U0001F7E8",
    track: "\U0001F3B5", time: "\u23F1", folder: "\U0001F4C1", file: "\U0001F4C4",
    leaderMenu: "\u2630", showAbout: "\u2139", trash: "\U0001F5D1", eqPresets: "\U0001F3B5",
    quitBg: "\u23F8", quitDaemon: "\u23F9", changeTheme: "\U0001F3A8", savePlaylist: "\U0001F4BE",
    createPlaylist: "\u2795", deletePlaylist: "\u274C", renamePlaylist: "\U0001F4DD",
    toggleFav: "\u2B50", importM3u: "\U0001F4C2", rescanLib: "\U0001F504", sleepTimer: "\u23F0",
    ytSearch: "\U0001F50D", spUrl: "\U0001F517", spSearch: "\U0001F50D", dashboard: "\U0001F4CA", spFeed: "\U0001F504",
    ytRecommended: "\U0001F3B6", fuzzyFinder: "\U0001F50D", enqueue: "\U0001F3B6", stopPlayback: "\u25A0",
    seekForward: "\u23E9", seekBackward: "\u23EA", navUp: "\u2B06", navDown: "\u2B07",
    enterFilter: "\U0001F50D", selectAll: "\u2714", removeSelected: "\u274C", addToPlaylist: "\U0001F4CB"
  )

var
  gNerdFontDetected*: bool = false
  gNerdDetectionDone: bool = false
  gIconPreference*: IconPreference = ipAuto
  gIconOverrides*: TableRef[string, string] = nil

proc detectNerdFonts*(): bool =
  if gNerdDetectionDone:
    return gNerdFontDetected
  gNerdDetectionDone = true

  let nfEnv = getEnv("NERD_FONTS", "")
  if nfEnv.len > 0:
    gNerdFontDetected = nfEnv == "1" or nfEnv.toLowerAscii() == "true"
    return gNerdFontDetected

  let termProg = getEnv("TERM_PROGRAM", "")
  if termProg.len > 0:
    let knownNerdTerms = ["alacritty", "kitty", "wezterm", "tabby", "warp",
                          "ghostty", "foot", "konsole", "hyper", "terminator",
                          "terminology", "tilix", "urxvt", "st"]
    if termProg.toLowerAscii() in knownNerdTerms:
      gNerdFontDetected = true
      return true

  let term = getEnv("TERM", "")
  if term.contains("kitty") or term.contains("alacritty") or
     term.contains("wezterm") or term.contains("foot") or
     term.contains("ghostty"):
    gNerdFontDetected = true
    return true

  gNerdFontDetected = false
  return false

proc setIconPreference*(pref: IconPreference) =
  gIconPreference = pref
  gNerdDetectionDone = false

proc setIconOverrides*(overrides: TableRef[string, string]) =
  gIconOverrides = overrides

proc applyOverrides(pack: IconPack): IconPack =
  result = pack
  if gIconOverrides == nil: return
  if gIconOverrides.hasKey("play"): result.play = gIconOverrides["play"]
  if gIconOverrides.hasKey("pause"): result.pause = gIconOverrides["pause"]
  if gIconOverrides.hasKey("stop"): result.stop = gIconOverrides["stop"]
  if gIconOverrides.hasKey("nextTrack"): result.nextTrack = gIconOverrides["nextTrack"]
  if gIconOverrides.hasKey("prevTrack"): result.prevTrack = gIconOverrides["prevTrack"]
  if gIconOverrides.hasKey("volumeHigh"): result.volumeHigh = gIconOverrides["volumeHigh"]
  if gIconOverrides.hasKey("volumeMedium"): result.volumeMedium = gIconOverrides["volumeMedium"]
  if gIconOverrides.hasKey("volumeLow"): result.volumeLow = gIconOverrides["volumeLow"]
  if gIconOverrides.hasKey("volumeMuted"): result.volumeMuted = gIconOverrides["volumeMuted"]
  if gIconOverrides.hasKey("music"): result.music = gIconOverrides["music"]
  if gIconOverrides.hasKey("artist"): result.artist = gIconOverrides["artist"]
  if gIconOverrides.hasKey("album"): result.album = gIconOverrides["album"]
  if gIconOverrides.hasKey("playlist"): result.playlist = gIconOverrides["playlist"]
  if gIconOverrides.hasKey("search"): result.search = gIconOverrides["search"]
  if gIconOverrides.hasKey("heart"): result.heart = gIconOverrides["heart"]
  if gIconOverrides.hasKey("shuffle"): result.shuffle = gIconOverrides["shuffle"]
  if gIconOverrides.hasKey("repeatOne"): result.repeatOne = gIconOverrides["repeatOne"]
  if gIconOverrides.hasKey("repeatAll"): result.repeatAll = gIconOverrides["repeatAll"]
  if gIconOverrides.hasKey("queue"): result.queue = gIconOverrides["queue"]
  if gIconOverrides.hasKey("library"): result.library = gIconOverrides["library"]
  if gIconOverrides.hasKey("settings"): result.settings = gIconOverrides["settings"]
  if gIconOverrides.hasKey("help"): result.help = gIconOverrides["help"]
  if gIconOverrides.hasKey("checkmark"): result.checkmark = gIconOverrides["checkmark"]
  if gIconOverrides.hasKey("cross"): result.cross = gIconOverrides["cross"]
  if gIconOverrides.hasKey("arrowUp"): result.arrowUp = gIconOverrides["arrowUp"]
  if gIconOverrides.hasKey("arrowDown"): result.arrowDown = gIconOverrides["arrowDown"]
  if gIconOverrides.hasKey("arrowLeft"): result.arrowLeft = gIconOverrides["arrowLeft"]
  if gIconOverrides.hasKey("arrowRight"): result.arrowRight = gIconOverrides["arrowRight"]
  if gIconOverrides.hasKey("musicNote"): result.musicNote = gIconOverrides["musicNote"]
  if gIconOverrides.hasKey("disk"): result.disk = gIconOverrides["disk"]
  if gIconOverrides.hasKey("headphone"): result.headphone = gIconOverrides["headphone"]
  if gIconOverrides.hasKey("speaker"): result.speaker = gIconOverrides["speaker"]
  if gIconOverrides.hasKey("commandPalette"): result.commandPalette = gIconOverrides["commandPalette"]
  if gIconOverrides.hasKey("filter"): result.filter = gIconOverrides["filter"]
  if gIconOverrides.hasKey("selectMode"): result.selectMode = gIconOverrides["selectMode"]
  if gIconOverrides.hasKey("track"): result.track = gIconOverrides["track"]
  if gIconOverrides.hasKey("time"): result.time = gIconOverrides["time"]
  if gIconOverrides.hasKey("folder"): result.folder = gIconOverrides["folder"]
  if gIconOverrides.hasKey("file"): result.file = gIconOverrides["file"]

proc commandIcon*(cmdId: string, ic: IconPack): string =
  case cmdId
  of "leader_menu": ic.leaderMenu
  of "toggle_play_pause": ic.play
  of "stop_playback": ic.stopPlayback
  of "seek_forward": ic.seekForward
  of "seek_backward": ic.seekBackward
  of "volume_up": ic.volumeHigh
  of "volume_down": ic.volumeLow
  of "toggle_mute": ic.volumeMuted
  of "next_track": ic.nextTrack
  of "prev_track": ic.prevTrack
  of "nav_up": ic.navUp
  of "nav_down": ic.navDown
  of "enter_filter": ic.enterFilter
  of "play_selected": ic.play
  of "go_to_first": ic.prevTrack
  of "go_to_last": ic.nextTrack
  of "toggle_select_mode": ic.selectMode
  of "select_all": ic.selectAll
  of "remove_selected": ic.removeSelected
  of "add_to_playlist": ic.addToPlaylist
  of "tab_now_playing": ic.headphone
  of "tab_library": ic.library
  of "tab_settings": ic.settings
  of "show_help": ic.help
  of "show_about": ic.showAbout
  of "show_trash": ic.trash
  of "show_equalizer": ic.eqPresets
  of "quit_background": ic.quitBg
  of "quit_daemon": ic.quitDaemon
  of "command_palette": ic.commandPalette
  of "change_theme": ic.changeTheme
  of "save_playlist": ic.savePlaylist
  of "create_playlist": ic.createPlaylist
  of "delete_playlist": ic.deletePlaylist
  of "rename_playlist": ic.renamePlaylist
  of "toggle_favourite": ic.toggleFav
  of "import_m3u": ic.importM3u
  of "rescan_library": ic.rescanLib
  of "toggle_shuffle": ic.shuffle
  of "toggle_repeat": ic.repeatOne
  of "sleep_timer": ic.sleepTimer
  of "yt_search": ic.ytSearch
  of "spotify_url": ic.spUrl
  of "spotify_search": ic.spSearch
  of "dashboard": ic.dashboard
  of "sp_fetch_feed": ic.spFeed
  of "yt_recommended": ic.ytRecommended
  of "fuzzy_finder": ic.fuzzyFinder
  of "queue_picker": ic.enqueue
  else: ""

proc currentIcons*(): IconPack =
  result =
    if gIconPreference == ipEmoji:
      emojiIcons()
    elif gIconPreference == ipNerdFont:
      nerdFontIcons()
    elif detectNerdFonts():
      nerdFontIcons()
    else:
      emojiIcons()
  if gIconOverrides != nil:
    result = applyOverrides(result)

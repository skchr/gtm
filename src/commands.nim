import state, strutils, algorithm, tables

type
  CommandCategory* = enum
    ccPlayback, ccNavigation, ccSelection, ccPlaylist,
    ccLibrary, ccSystem, ccView, ccGeneral

proc fuzzyMatch*(query, target: string): bool =
  if query.len == 0: return true
  var qi = 0
  for tc in target:
    if qi < query.len and tc.toLowerAscii() == query[qi].toLowerAscii():
      qi.inc
    if qi == query.len: return true
  return false

proc filterCommandsByContext*(state: AppState): seq[int] =
  result = @[]
  for i, cmd in state.commands:
    result.add(i)

proc fuzzySearchCommands*(state: AppState, query: string): seq[tuple[idx: int, score: int]] =
  let candidates = filterCommandsByContext(state)
  result = @[]
  for idx in candidates:
    let cmd = state.commands[idx]
    if fuzzyMatch(query, cmd.name) or fuzzyMatch(query, cmd.description) or fuzzyMatch(query, cmd.id):
      let nameScore = if fuzzyMatch(query, cmd.name): 3 else: 0
      let descScore = if fuzzyMatch(query, cmd.description): 1 else: 0
      let idScore = if fuzzyMatch(query, cmd.id): 2 else: 0
      result.add((idx, nameScore + descScore + idScore))
  result.sort do (a, b: tuple[idx: int, score: int]) -> int:
    -cmp(a.score, b.score)

proc registerCommand*(state: var AppState, id, name, description, icon: string,
                      defaultKeys: seq[string]) =
  let entry = CommandEntry(id: id, name: name, description: description,
                           icon: icon, defaultKeys: defaultKeys)
  state.commands.add(entry)
  let idx = state.commands.len - 1
  state.cmdRegistry[id] = idx
  for key in defaultKeys:
    state.keybindings[key] = id

proc findCommandIdx*(state: AppState, id: string): int =
  if state.cmdRegistry.hasKey(id):
    return state.cmdRegistry[id]
  -1

proc buildDefaultCommands*(state: var AppState) =
  state.registerCommand("toggle_play_pause", "Toggle Play/Pause",
    "Toggle between play and pause states", "\u25B6", @["Space", "Space"])
  state.registerCommand("stop_playback", "Stop",
    "Stop playback and reset position", "\u25A0", @["s"])
  state.registerCommand("seek_forward", "Seek Forward",
    "Seek forward 5 seconds", "\u23E9", @["l"])
  state.registerCommand("seek_backward", "Seek Backward",
    "Seek backward 5 seconds", "\u23EA", @["h"])
  state.registerCommand("volume_up", "Volume Up",
    "Increase volume by 5%", "\uF028", @["ShiftJ", "Plus", "Equals"])
  state.registerCommand("volume_down", "Volume Down",
    "Decrease volume by 5%", "\uF027", @["ShiftK", "Minus", "Underscore"])
  state.registerCommand("toggle_mute", "Toggle Mute",
    "Mute or unmute audio", "\uF026", @["m"])
  state.registerCommand("next_track", "Next Track",
    "Skip to next track in playlist", "\u23ED", @["n"])
  state.registerCommand("prev_track", "Previous Track",
    "Go to previous track", "\u23EE", @["p"])
  state.registerCommand("nav_up", "Move Up",
    "Move selection up in the list", "\u2B06", @["k"])
  state.registerCommand("nav_down", "Move Down",
    "Move selection down in the list", "\u2B07", @["j"])
  state.registerCommand("enter_filter", "Filter/Search",
    "Enter filter mode to search", "\U0001F50D", @["Slash"])
  state.registerCommand("play_selected", "Play Selected",
    "Play the currently selected item", "\u25B6", @["Enter"])
  state.registerCommand("go_to_first", "Go to First",
    "Jump to first item in the list", "\u23EE", @["g", "g"])
  state.registerCommand("go_to_last", "Go to Last",
    "Jump to last item in the list", "\u23ED", @["ShiftG"])
  state.registerCommand("toggle_select_mode", "Toggle Select Mode",
    "Enter or exit multi-select mode", "\U0001F7E8", @["v"])
  state.registerCommand("select_all", "Select All",
    "Select all visible items", "\U0001F7E9", @["CtrlA"])
  state.registerCommand("invert_selection", "Invert Selection",
    "Invert current selection", "\U0001F7E8", @["CtrlI"])
  state.registerCommand("remove_selected", "Remove Selected",
    "Remove selected items", "\u274C", @["ShiftX"])
  state.registerCommand("add_to_playlist", "Add to Playlist...",
    "Add selected items to playlist", "\U0001F4CB", @["ShiftA"])
  state.registerCommand("tab_now_playing", "Now Playing",
    "Switch to Now Playing tab", "\U0001F3B5", @["1"])
  state.registerCommand("tab_library", "Library",
    "Switch to Library tab", "\U0001F4DA", @["2"])
  state.registerCommand("tab_playlists", "Playlists",
    "Switch to Playlists tab", "\U0001F4CB", @["3"])
  state.registerCommand("tab_settings", "Settings",
    "Switch to Settings tab", "\u2699", @["4"])
  state.registerCommand("show_help", "Show Help",
    "Display help overlay with keybindings", "\u2753", @["QuestionMark"])
  state.registerCommand("quit_background", "Quit (Background)",
    "Exit TUI, keep playback running", "\u23F8", @["q"])
  state.registerCommand("quit_daemon", "Quit & Stop Daemon",
    "Exit and terminate background daemon", "\u23F9", @["ShiftQ"])
  state.registerCommand("toggle_visualizer", "Toggle Visualizer",
    "Show or hide audio visualizer", "\U0001F4CA", @["ShiftV"])
  state.registerCommand("command_palette", "Command Palette",
    "Show command palette with fuzzy search", "\u2328", @[":"])
  state.registerCommand("change_theme", "Change Theme",
    "Open theme picker with live preview", "\U0001F3A8", @["T"])
  state.registerCommand("save_playlist", "Save Playlist",
    "Save current queue as a playlist file", "\U0001F4BE", @["CtrlS"])
  state.registerCommand("create_playlist", "Create Playlist",
    "Create a new playlist", "\U0001F4CB", @["a"])
  state.registerCommand("delete_playlist", "Delete Playlist",
    "Delete the selected playlist", "\u274C", @["d"])
  state.registerCommand("rename_playlist", "Rename Playlist",
    "Rename the selected playlist", "\U0001F4DD", @["r"])
  state.registerCommand("import_m3u", "Import M3U",
    "Import a playlist from .m3u file", "\U0001F4C2", @["CtrlO"])
  state.registerCommand("export_m3u", "Export M3U",
    "Export playlist to .m3u file", "\U0001F4E4", @["CtrlS"])
  state.registerCommand("rescan_library", "Rescan Library",
    "Rescan music directories for new files", "\U0001F504", @[""])
  state.registerCommand("show_now_playing", "Show Now Playing",
    "Jump to Now Playing view", "\U0001F3B5", @[""])

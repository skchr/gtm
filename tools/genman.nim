import os, strutils, tables, json, osproc, algorithm
import ../tools/docs

const
  SrcDir = "src"
  DocsDir = "docs"

proc readFileStr(path: string): string =
  try: result = readFile(path)
  except: result = ""

# ── CLI subcommand extraction ────────────────────────────────────────

type CliSubcmd = object
  name: string
  args: string
  desc: string

proc extractCliSubcmds(): seq[CliSubcmd] =
  # Hardcoded from src/cli.nim: Subcommand enum + execSubcommand
  # These match the parseSubcmd wire names and must be kept in sync
  result = @[
    CliSubcmd(name: "play",    args: "<path|url>", desc: "Play a file or URL via daemon"),
    CliSubcmd(name: "pause",   args: "",            desc: "Toggle play/pause"),
    CliSubcmd(name: "stop",    args: "",            desc: "Stop playback"),
    CliSubcmd(name: "next",    args: "",            desc: "Skip to next track"),
    CliSubcmd(name: "prev",    args: "",            desc: "Go to previous track"),
    CliSubcmd(name: "volume",  args: "[level]",     desc: "Get/set volume (0\u2013100)"),
    CliSubcmd(name: "shuffle", args: "[on/off]",    desc: "Toggle shuffle mode"),
    CliSubcmd(name: "repeat",  args: "[mode]",      desc: "Set repeat mode (0=none, 1=all, 2=one)"),
    CliSubcmd(name: "sleep",   args: "[minutes]",   desc: "Set sleep timer in minutes"),
    CliSubcmd(name: "status",  args: "",            desc: "Show current playback status"),
    CliSubcmd(name: "now",     args: "",            desc: "Show current track info"),
    CliSubcmd(name: "kill",    args: "",            desc: "Stop the daemon process"),
    CliSubcmd(name: "daemon",  args: "",            desc: "Start the background daemon process (auto-started by the TUI)"),
    CliSubcmd(name: "help",    args: "",            desc: "Show help and usage information"),
    CliSubcmd(name: "version", args: "",            desc: "Show version information"),
  ]

# ── TUI command extraction (registerCommand) ─────────────────────────

type TuiCmd = object
  id: string
  name: string
  desc: string
  keys: seq[string]

proc extractTuiCommands(): seq[TuiCmd] =
  let src = readFileStr(SrcDir / "gtm.nim")
  let lines = src.splitLines()
  var inRegister = false
  var parenDepth = 0
  var buf = ""
  for line in lines:
    if "registerCommand(" in line:
      inRegister = true
      parenDepth = 0
      buf = ""
    if inRegister:
      for ch in line:
        if ch == '(': parenDepth.inc
        elif ch == ')': parenDepth.dec
        buf.add(ch)
      if parenDepth == 0 and buf.len > 0:
        # Parse args from buf
        inRegister = false
        # Find first ( and last )
        let p1 = buf.find('(')
        if p1 < 0: continue
        let p2 = buf.rfind(')')
        if p2 <= p1: continue
        let args = buf[p1+1..<p2]
        # Split by top-level commas
        var parts: seq[string]
        var depth = 0
        var cur = ""
        for ch in args:
          if ch in {'(', '[', '{'}: depth.inc
          elif ch in {')', ']', '}'}: depth.dec
          if ch == ',' and depth == 0:
            parts.add(cur.strip())
            cur = ""
          else:
            cur.add(ch)
        if cur.strip().len > 0:
          parts.add(cur.strip())
        if parts.len >= 5:
          let idStr = parts[0].strip().strip(leading=false, trailing=false, chars={'"'})
          let nameStr = parts[1].strip().strip(leading=false, trailing=false, chars={'"'})
          let descStr = parts[2].strip().strip(leading=false, trailing=false, chars={'"'})
          var keys: seq[string]
          let keysPart = parts[4].strip()
          if keysPart.startsWith("@["):
            let inner = keysPart[2..^1]
            let ki = inner.rfind(']')
            let keyStr = if ki >= 0: inner[0..<ki] else: inner
            for k in keyStr.split(','):
              let kt = k.strip().strip(leading=false, trailing=false, chars={'"'})
              if kt.len > 0: keys.add(kt)
          result.add(TuiCmd(id: idStr, name: nameStr, desc: descStr, keys: keys))

# ── Daemon command extraction ────────────────────────────────────────

type DaemonCmd = object
  wire: string
  enumName: string
  args: seq[string]
  desc: string

proc extractDaemonCommands(): seq[DaemonCmd] =
  let src = readFileStr(SrcDir / "daemon.nim")
  let lines = src.splitLines()

  # First pass: collect full arg info from parseDaemonCommand
  # Build a mapping of wire → args
  var wireArgs: Table[string, seq[string]]
  var wireEnum: Table[string, string]
  var inParser = false
  for i, line in lines:
    let t = line.strip()
    if t.startsWith("proc parseDaemonCommand"):
      inParser = true; continue
    if not inParser: continue
    if t.startsWith("of ") and not t.startsWith("of dck") and not t.startsWith("of sc"):
      let q1 = t.find('"')
      if q1 >= 0:
        let q2 = t.find('"', q1+1)
        if q2 > q1:
          let wireName = t[q1+1..<q2]
          let rest = t[q2+1..^1]
          let dck = rest.find("dck")
          var enumName = ""
          if dck >= 0:
            enumName = rest[dck..^1].strip()
            let colon = enumName.find(':')
            if colon >= 0: enumName = enumName[0..<colon]
            enumName = enumName.strip()
          # Collect args from this line and the next line
          var argsBlock = t
          if i + 1 < lines.len:
            var next = lines[i+1].strip()
            # Skip blank lines looking for continuation
            if next.len == 0 and i + 2 < lines.len:
              next = lines[i+2].strip()
            if next.len > 0 and next[0] notin {'o', 'e', '}'} and not next.startsWith("of "):
              argsBlock &= " " & next
              # Also search for dck on continuation line
              let dck2 = next.find("dck")
              if dck2 >= 0 and enumName.len == 0:
                var en = next[dck2..^1].strip()
                let semi = en.find(';')
                if semi >= 0: en = en[0..<semi]
                let dot = en.find('.')
                if dot >= 0: en = en[0..<dot]
                let eq2 = en.find('=')
                if eq2 >= 0: en = en[eq2+1..^1].strip()
                enumName = en.strip()
          wireEnum[wireName] = enumName
          var cmdArgs: seq[string]
          # Extract JSON arg keys from j{"key"} patterns
          var jpos = argsBlock.find("j{\"")
          if jpos < 0: jpos = argsBlock.find("j{")
          if jpos < 0: jpos = argsBlock.find("j[\"")
          if jpos >= 0:
            let argBlock = argsBlock[jpos..^1]
            var depth = 0
            var cur = ""
            for ch in argBlock:
              if ch == '{': depth.inc
              elif ch == '}': depth.dec
              if depth > 0 or ch == '{':
                cur.add(ch)
                if depth == 0 and cur.len > 1:
                  for part in cur.split(','):
                    let kv = part.split(':')
                    if kv.len >= 2:
                      let kn = kv[0].strip().strip(leading=false, trailing=false, chars={'"', '{'})
                      if kn.len > 0 and kn != "cmd":
                        cmdArgs.add(kn)
                  break
          wireArgs[wireName] = cmdArgs
    if t.contains("else:") and t.contains("dckStatus"):
      break

  # Second pass: collect all wire names from the enum
  for wire, enumName in wireEnum:
    let args = if wire in wireArgs: wireArgs[wire] else: @[]
    result.add(DaemonCmd(wire: wire, enumName: enumName, args: args, desc: ""))

  # Sort by wire name for predictable output
  sort(result, proc(a, b: DaemonCmd): int = cmp(a.wire, b.wire))

  # Extract descriptions from executeCommand case branches
  var inExec = false
  var execCase = ""
  var execLines: seq[string]
  for i, line in lines:
    let t = line.strip()
    if t.startsWith("proc executeCommand"):
      inExec = true; continue
    if not inExec: continue
    if t.startsWith("of dck"):
      if execCase.len > 0: execLines.add(execCase)
      execCase = t
    elif t.startsWith("of "):
      if execCase.len > 0: execLines.add(execCase)
      execCase = ""
    elif t.startsWith("else:"):
      if execCase.len > 0: execLines.add(execCase)
      break
    elif execCase.len > 0:
      # Check for echo-like description hints
      if t.contains("result[") or t.contains("d.") or t.contains("player."):
        if execCase.len > 0:
          execLines.add(execCase)
          execCase = ""
  if execCase.len > 0: execLines.add(execCase)

  # Descriptions could be extracted from executeCommand handlers
  # but for now they are generated from context in the manpage template

# ── Audio event extraction ───────────────────────────────────────────

type AudioEvent = object
  kind: int
  name: string
  fields: string
  desc: string

proc extractAudioEvents(): seq[AudioEvent] =
  let src = readFileStr(SrcDir / "audio.nim")
  let lines = src.splitLines()
  var inEnum = false
  var idx = 0
  for line in lines:
    let t = line.strip()
    if "AudioEventKind*" in line:
      inEnum = true; continue
    if not inEnum: continue
    # Check raw line for 4-space indentation (enum values)
    if line.len >= 4 and line[0..3] == "    " and not line.strip().startsWith("#"):
      var v = line.strip()
      # Handle multi-value lines: split by comma
      for part in v.split(','):
        var p = part.strip()
        if p.len == 0: continue
        let eq = p.find('=')
        if eq >= 0:
          try: idx = parseInt(p[eq+1..^1].strip())
          except: discard
          p = p[0..<eq].strip()
        if p.len > 0 and p[0] in {'a'..'z','e','E'}:
          result.add(AudioEvent(kind: idx, name: p, fields: "", desc: ""))
          idx.inc
    elif line.len >= 2 and line[0..1] == "  " and (line.len < 4 or line[0..3] != "    ") and (t.startsWith("AudioEvent*") or t.startsWith("type") or t.len == 0):
      # 2-space indent = back to struct level
      if result.len > 0: break
    elif t.len == 0:
      continue
    else:
      if result.len > 0: break

  # Build event descriptions from the IPC doc or hardcoded
  let descriptions = {
    "evNone": "No event (placeholder)",
    "evPlaybackStarted": "Playback has started. Extra: state, track_path, track_title, track_channel, time_pos, duration",
    "evPlaybackPaused": "Playback was paused. Extra: state",
    "evPlaybackStopped": "Playback was stopped. Extra: state",
    "evTrackEnded": "Current track reached end-of-file. Extra: reason",
    "evPositionChanged": "Playback position changed. Extra: time_pos",
    "evDurationChanged": "Track duration changed. Extra: duration",
    "evVolumeChanged": "Volume changed. Extra: volume",
    "evMetadataChanged": "Track metadata changed. Extra: event",
    "evError": "Audio backend error occurred",
    "evCustomEvent": "Custom event. Extra: event, plus type-specific fields"
  }.toTable()

  for i in 0..<result.len:
    if result[i].name in descriptions:
      result[i].desc = descriptions[result[i].name]
    # Determine extra fields
    case result[i].name
    of "evPositionChanged": result[i].fields = "time_pos"
    of "evDurationChanged": result[i].fields = "duration"
    of "evVolumeChanged": result[i].fields = "volume"
    of "evPlaybackStarted": result[i].fields = "state, track_path, track_title, track_channel, time_pos, duration"
    of "evPlaybackPaused": result[i].fields = "state"
    of "evPlaybackStopped": result[i].fields = "state"
    of "evTrackEnded": result[i].fields = "reason"
    of "evMetadataChanged": result[i].fields = "event"
    of "evCustomEvent": result[i].fields = "event, (type-specific)"
    else: discard

# ── Manpage generation ───────────────────────────────────────────────

proc versionStr(): string =
  try:
    let tag = osproc.execCmdEx("git describe --tags --abbrev=0 2>/dev/null").output.strip
    if tag.len > 0: tag.strip(chars={'v'}) else: "0.0.0-dev"
  except: "0.0.0-dev"

proc generateGtmManpage(cli: seq[CliSubcmd]; tui: seq[TuiCmd]; examples: seq[DocExample]): string =
  result = "% GTM(1) User Manuals\n"
  result &= "% prjctimg\n"
  result &= "% v" & versionStr() & "\n"
  result &= "\n"
  result &= "# NAME\n\n"
  result &= "gtm - terminal music player with YouTube integration, crossfade, and equalizer\n\n"
  result &= "# SYNOPSIS\n\n"
  result &= "| `gtm` [*options*] [*file*|*url*...]\n"
  result &= "| `gtm` *command* [*args*...]\n"
  result &= "| `gtm daemon`\n\n"
  result &= "# DESCRIPTION\n\n"
  result &= "**gtm** is a terminal-based music player. It supports local audio files,\n"
  result &= "YouTube streaming, playlist management, album art display, gapless crossfade\n"
  result &= "playback, and a 10-band graphic equalizer.\n\n"
  result &= "The player is split into two binaries:\n\n"
  result &= "`gtm`\n"
  result &= ":   Terminal UI client \\- renders the player interface, accepts keyboard\n"
  result &= "    input and CLI subcommands.\n\n"
  result &= "`gtmd`\n"
  result &= ":   Background daemon \\- owns audio playback (FFmpeg + ALSA), manages the\n"
  result &= "    music library (SQLite), and communicates with the TUI over a Unix\n"
  result &= "    domain socket.\n\n"
  result &= "```\n"
  result &= "┌─────────────────────────────────────────────────────┐\n"
  result &= "│                     gtm (TUI)                      │\n"
  result &= "│  ┌─────────┐  ┌──────────┐  ┌───────────┐         │\n"
  result &= "│  │ Now     │  │ Library  │  │ Settings  │  CLI    │\n"
  result &= "│  │ Playing │  │ Tab      │  │ Tab       │  cmds   │\n"
  result &= "│  └────┬────┘  └────┬─────┘  └─────┬─────┘         │\n"
  result &= "│       │            │              │               │\n"
  result &= "│       └──────┬─────┴──────┬───────┘               │\n"
  result &= "│              │ AppState   │                        │\n"
  result &= "│       ┌──────┴────────────┴──────┐                 │\n"
  result &= "│       │  DaemonClient (IPC)      │                 │\n"
  result &= "│       └──────────┬───────────────┘                 │\n"
  result &= "└──────────────────┼─────────────────────────────────┘\n"
  result &= "                   │ Unix socket (JSON/\\n)\n"
  result &= "┌──────────────────┼─────────────────────────────────┐\n"
  result &= "│                  ▼                                 │\n"
  result &= "│               gtmd (daemon)                        │\n"
  result &= "│  ┌──────────────┴──────────────┐                   │\n"
  result &= "│  │  Daemon state + cmd handler │                   │\n"
  result &= "│  └──────────────┬──────────────┘                   │\n"
  result &= "│  ┌──────────────┴──────────────┐                   │\n"
  result &= "│  │  AudioBackend (FFmpeg/ALSA) │                   │\n"
  result &= "│  └─────────────────────────────┘                   │\n"
  result &= "│  ┌─────────────────────────────┐                   │\n"
  result &= "│  │  SQLite library.db          │                   │\n"
  result &= "│  └─────────────────────────────┘                   │\n"
  result &= "│  ┌─────────────────────────────┐                   │\n"
  result &= "│  │  yt-dlp (search/stream/dl)  │                   │\n"
  result &= "│  └─────────────────────────────┘                   │\n"
  result &= "└─────────────────────────────────────────────────────┘\n"
  result &= "```\n\n"
  result &= "# OPTIONS\n\n"
  result &= "`--debug`\n"
  result &= ":   Enable debug logging to stderr.\n\n"
  result &= "`--help`, `-h`\n"
  result &= ":   Display help and exit.\n\n"
  result &= "`--version`, `-v`\n"
  result &= ":   Display version and exit.\n\n"
  result &= "# COMMANDS\n\n"
  result &= "When invoked with a subcommand, **gtm** connects to the daemon and\n"
  result &= "operates in headless mode:\n\n"

  # CLI subcommands table
  for c in cli:
    if c.name == "help" or c.name == "version":
      let cmdLine = if c.name == "version": "`--version`, `-v`" else: "`help`"
      result &= cmdLine & "\n"
      result &= ":   " & c.desc & "\n\n"
    elif c.name == "daemon":
      result &= "`daemon`\n"
      result &= ":   Start the background daemon process (auto-started by the TUI).\n\n"
    else:
      result &= "`" & c.name & "`"
      if c.args.len > 0: result &= " " & c.args
      result &= "\n:   " & c.desc & "\n\n"

  # Examples section (from source defs via tools/docs.nim)
  result &= "# EXAMPLES\n\n"
  for e in examples:
    result &= e.title & "\n\n```" & e.lang & "\n" & e.code & "\n```\n\n"

  # TUI keybindings section
  result &= "# TUI KEYBINDINGS\n\n"
  result &= "The following commands are available in the TUI. Most have default\n"
  result &= "keybindings; these can be remapped via the configuration file.\n\n"

  # Categorize commands
  type CmdCat = tuple[cat: string, cmds: seq[TuiCmd]]
  var categories: seq[CmdCat]

  template addCat(name: string, ids: seq[string]) =
    var cmds: seq[TuiCmd]
    for id in ids:
      for c in tui:
        if c.id == id: cmds.add(c)
    if cmds.len > 0: categories.add((name, cmds))

  addCat("Playback", @["toggle_play_pause", "stop_playback", "seek_forward", "seek_backward", "next_track", "prev_track"])
  addCat("Volume", @["volume_up", "volume_down", "toggle_mute"])
  addCat("Navigation", @["nav_up", "nav_down", "enter_filter", "play_selected", "go_to_first", "go_to_last"])
  addCat("Selection", @["toggle_select_mode", "select_all", "remove_selected"])
  addCat("Tabs", @["tab_now_playing", "tab_library", "tab_settings"])
  addCat("System", @["show_help", "show_about", "show_trash", "show_equalizer", "show_eq_presets", "quit_background", "quit_daemon", "command_palette", "change_theme", "leader_menu"])
  addCat("Playlists & Queue", @["save_playlist", "create_playlist", "delete_playlist", "rename_playlist", "add_to_playlist", "queue_picker", "toggle_favourite", "import_m3u", "toggle_shuffle", "toggle_repeat", "sleep_timer"])
  addCat("YouTube & Spotify", @["yt_search", "spotify_url", "yt_recommended"])
  addCat("Tools", @["fuzzy_finder", "rescan_library"])

  for (catName, cmds) in categories:
    result &= "## " & catName & "\n\n"
    for c in cmds:
      var keyStr = ""
      for i, k in pairs(c.keys):
        if i > 0: keyStr &= ", "
        # Map key names to display format
        var dk = k
        case dk
        of "Space": dk = "Space"
        of "Enter": dk = "Enter"
        of "Slash": dk = "/"
        of "Colon": dk = ":"
        of "Comma": dk = ","
        of "Dot": dk = "."
        of "Plus": dk = "+"
        of "Equals": dk = "="
        of "Minus": dk = "-"
        of "Underscore": dk = "_"
        of "Up": dk = "Up"
        of "Down": dk = "Down"
        of "Left": dk = "Left"
        of "Right": dk = "Right"
        of "ShiftS": dk = "Shift+S"
        of "ShiftR": dk = "Shift+R"
        of "ShiftG": dk = "Shift+G"
        of "ShiftQ": dk = "Shift+Q"
        of "ShiftJ": dk = "Shift+J"
        of "ShiftK": dk = "Shift+K"
        of "ShiftX": dk = "Shift+X"
        of "ShiftA": dk = "Shift+A"
        of "ShiftT": dk = "Shift+T"
        of "AltF": dk = "Alt+F"
        of "AltY": dk = "Alt+Y"
        of "AltA": dk = "Alt+A"
        of "AltD": dk = "Alt+D"
        of "AltR": dk = "Alt+R"
        of "AltP": dk = "Alt+P"
        of "AltI": dk = "Alt+I"
        of "AltE": dk = "Alt+E"
        of "AltC": dk = "Alt+C"
        of "AltH": dk = "Alt+H"
        of "AltT": dk = "Alt+T"
        of "AltS": dk = "Alt+S"
        of "AltX": dk = "Alt+X"
        of "CtrlU": dk = "Ctrl+U"
        of "CtrlD": dk = "Ctrl+D"
        of "CtrlN": dk = "Ctrl+N"
        of "CtrlP": dk = "Ctrl+P"
        of "CtrlF": dk = "Ctrl+F"
        of "CtrlG": dk = "Ctrl+G"
        of "CtrlL": dk = "Ctrl+L"
        of "CtrlS": dk = "Ctrl+S"
        of "CtrlR": dk = "Ctrl+R"
        of "g+g": dk = "g g"
        else:
          if dk.len == 1: discard
          elif dk.startsWith("Shift"): dk = "Shift+" & dk[5..^1]
          elif dk.startsWith("Ctrl"): dk = "Ctrl+" & dk[4..^1]
          elif dk.startsWith("Alt"): dk = "Alt+" & dk[3..^1]
        keyStr &= "`" & dk & "`"
      result &= keyStr & "\n"
      result &= ":   " & c.desc & "\n\n"

  result &= "# FILES\n\n"
  result &= "`~/.config/gtm/config.json`\n"
  result &= ":   User configuration file (theme, volume, crossfade, keybindings, etc.).\n\n"
  result &= "`~/.config/gtm/config.jsonc`\n"
  result &= ":   Optional JSONC configuration file (overrides config.json).\n\n"
  result &= "`$XDG_DATA_HOME/gtm/gtm.db`\n"
  result &= ":   SQLite database (music library, playlists, queue, playback state).\n\n"
  result &= "`$XDG_RUNTIME_DIR/gtm/gtmd.sock`\n"
  result &= ":   Unix socket for TUI\\-daemon communication.\n\n"
  result &= "`$XDG_RUNTIME_DIR/gtm/gtmd.pid`\n"
  result &= ":   PID file for the running daemon instance.\n\n"
  result &= "# ENVIRONMENT\n\n"
  result &= "`HOME`\n"
  result &= ":   Used to locate the configuration directory.\n\n"
  result &= "`XDG_RUNTIME_DIR`\n"
  result &= ":   Used for the daemon socket and PID file.\n\n"
  result &= "`XDG_CONFIG_HOME`\n"
  result &= ":   Used for the config file location (default: `~/.config`).\n\n"
  result &= "`XDG_DATA_HOME`\n"
  result &= ":   Used for the library database and download directory.\n\n"
  result &= "`TERM`\n"
  result &= ":   Terminal type for true\\-color detection and Kitty protocol support.\n\n"
  result &= "# BUGS\n\n"
  result &= "Report bugs and feature requests at:\n"
  result &= "<https://github.com/prjctimg/gtm/issues>\n\n"
  result &= "# SEE ALSO\n\n"
  result &= "`gtmd`(1), `ffplay`(1), `yt-dlp`(1)\n"

proc generateGtmdManpage(cmds: seq[DaemonCmd]; events: seq[AudioEvent]; examples: seq[DocExample]): string =
  result = "% GTMD(1) User Manuals\n"
  result &= "% prjctimg\n"
  result &= "% v" & versionStr() & "\n"
  result &= "\n"
  result &= "# NAME\n\n"
  result &= "gtmd - background music playback daemon (IPC server)\n\n"
  result &= "# SYNOPSIS\n\n"
  result &= "`gtmd` [*options*]\n\n"
  result &= "# DESCRIPTION\n\n"
  result &= "**gtmd** is a standalone audio playback daemon. It plays audio via\n"
  result &= "FFmpeg + ALSA, maintains a music library in SQLite, and exposes a\n"
  result &= "JSON\\-over\\-Unix\\-socket IPC interface. It supports:\n\n"
  result &= "- Local audio file playback (FLAC, MP3, Ogg, WAV, AAC, Opus, WMA)\n"
  result &= "- YouTube streaming (via yt-dlp)\n"
  result &= "- Gapless crossfade with configurable duration and curve\n"
  result &= "- 10-band graphic equalizer with presets\n"
  result &= "- Playlist and favourites management\n"
  result &= "- MPRIS D-Bus interface (when built with dbus)\n"
  result &= "- Sleep timer and idle shutdown\n"
  result &= "- Background directory scanning\n\n"

  result &= "```\n"
  result &= "┌─────────────────────────────────────────────────────┐\n"
  result &= "│                  gtmd (daemon)                      │\n"
  result &= "│                                                     │\n"
  result &= "│  ┌──────────────┐     select() loop (16ms)         │\n"
  result &= "│  │  Unix socket  │◄─── read cmds, write resp+events │\n"
  result &= "│  └──────┬───────┘                                   │\n"
  result &= "│         ▼                                           │\n"
  result &= "│  ┌──────────────┐                                   │\n"
  result &= "│  │ parseCmd()   │──► executeCommand()               │\n"
  result &= "│  └──────────────┘                                   │\n"
  result &= "│         ▼                                           │\n"
  result &= "│  ┌──────────────────────┐     ┌─────────────────┐   │\n"
  result &= "│  │ AudioBackend          │     │ SQLite library   │   │\n"
  result &= "│  │  ├─ MixerBackend      │     │  ├─ tracks       │   │\n"
  result &= "│  │  └─ FfmpegBackend     │     │  ├─ playlists    │   │\n"
  result &= "│  │  pollEvents() ──►     │     │  ├─ favourites   │   │\n"
  result &= "│  │  events → broadcast   │     │  ├─ downloads    │   │\n"
  result &= "│  └──────────────────────┘     │  └─ trash        │   │\n"
  result &= "│  ┌──────────────────────┐     └─────────────────┘   │\n"
  result &= "│  │ yt-dlp processes     │                            │\n"
  result &= "│  │  ├─ search           │                            │\n"
  result &= "│  │  ├─ stream resolve   │                            │\n"
  result &= "│  │  ├─ download         │                            │\n"
  result &= "│  │  └─ playlist fetch   │                            │\n"
  result &= "│  └──────────────────────┘                            │\n"
  result &= "└─────────────────────────────────────────────────────┘\n"
  result &= "```\n\n"

  result &= "# OPTIONS\n\n"
  result &= "`--debug`\n"
  result &= ":   Enable debug logging.\n\n"
  result &= "`--help`\n"
  result &= ":   Display help and exit.\n\n"

  result &= "# IPC TRANSPORT\n\n"
  result &= "| Field | Value |\n"
  result &= "|---|---|\n"
  result &= "| Socket family | `AF_UNIX` / `SOCK_STREAM` |\n"
  result &= "| Socket path | `$XDG_RUNTIME_DIR/gtm/gtmd.sock`\n"
  result &= "| Framing | Newline\\-delimited JSON |\n"
  result &= "| Encoding | UTF-8 |\n\n"

  result &= "## Message format\n\n"
  result &= "Request (client → daemon):\n\n"
  result &= "```json\n"
  result &= "{\"cmd\": \"<command>\", \"arg1\": value1, ...}\n"
  result &= "```\n\n"
  result &= "Response (daemon → client):\n\n"
  result &= "```json\n"
  result &= "{\"ok\": true, \"field1\": value1, ...}\n"
  result &= "```\n\n"
  result &= "Events (daemon → client, unsolicited):\n\n"
  result &= "```json\n"
  result &= "{\"events\": [{\"kind\": 1, ...}, ...]}\n"
  result &= "```\n\n"

  result &= "# COMMANDS\n\n"
  result &= "All commands use the wire format `{\"cmd\": \"<name>\", ...}`.\n"
  result &= "Every response includes `\"ok\"` (boolean) unless noted.\n\n"

  # Group commands
  let groups = {
    "Playback Control": @["play", "pause", "toggle_pause", "stop", "seek", "next", "prev", "load_file", "resume", "status", "now_playing", "get_state", "ping"],
    "Volume": @["set_volume", "get_volume"],
    "Queue": @["queue_add", "queue_remove", "queue_remove_path", "queue_clear", "queue_validate", "queue_list", "queue_set_cursor"],
    "Playback Mode": @["set_shuffle", "set_repeat", "set_sleep_timer"],
    "Crossfade": @["prepare_next", "crossfade", "set_crossfade_duration", "set_crossfade_curve"],
    "Equalizer": @["set_eq_band", "set_eq_preset", "list_eq_presets"],
    "Library": @["get_library", "add_track", "update_track_path", "scan", "delete_track", "restore_track", "permanent_delete_trash", "list_trash", "purge_trash"],
    "Playlists": @["create_playlist", "delete_playlist", "rename_playlist", "add_to_playlist", "remove_from_playlist", "list_playlists", "get_playlist_tracks"],
    "Favourites": @["add_favourite", "remove_favourite", "get_favourites"],
    "State": @["get_full_state", "get_state", "get_volume"],
    "YouTube": @["yt_search", "yt_search_poll", "yt_search_cancel", "yt_resolve_stream", "yt_resolve_stream_poll", "yt_download", "yt_download_poll", "yt_cancel_download", "yt_list_downloads", "yt_fetch_playlist", "yt_fetch_playlist_poll", "yt_set_config", "yt_get_search_history", "yt_clear_search_history"],
    "Spotify": @["sp_set_config", "sp_list_downloads"],
    "Cover Art & Lyrics": @["get_cover_art", "get_lyrics", "search_lyrics"],
    "Lifecycle": @["quit"]
  }.toTable()

  for groupName, wires in groups:
    result &= "## " & groupName & "\n\n"
    for wire in wires:
      var found: DaemonCmd
      var ok = false
      for c in cmds:
        if c.wire == wire:
          found = c; ok = true; break
      if not ok:
        continue
      result &= "#### `" & found.wire & "`\n\n"
      if found.args.len > 0:
        result &= "| Arg | Type | Description |\n"
        result &= "|---|---|---|\n"
        for a in found.args:
          let atype = case a
            of "seconds", "duration", "gain_db": "float"
            of "volume", "band", "enabled", "mode", "minutes", "playlist_id", "track_id", "position", "index", "page_size", "max_concurrent", "trash_id", "permanent", "queue_length": "int"
            of "path", "title", "channel", "name", "query", "url", "cookie_source", "js_runtime", "download_dir", "prev_cmd", "data", "album", "artist": "string"
            else: "string"
          result &= "| `" & a & "` | " & atype & " |  |\n"
        result &= "\n"
      result &= "Request: `{\"cmd\": \"" & found.wire & "\""
      for a in found.args:
        result &= ", \"" & a & "\": <value>"
      result &= "}`\n\n"
      result &= "Response: `{\"ok\": true"
      if found.wire in ["get_volume", "get_state", "get_full_state", "status", "now_playing", "get_library", "list_playlists", "get_playlist_tracks", "queue_list", "get_favourites", "yt_search_poll", "yt_list_downloads", "yt_fetch_playlist_poll", "yt_get_search_history", "sp_list_downloads", "list_eq_presets", "get_cover_art", "get_lyrics", "search_lyrics", "list_trash"]:
        result &= ", ..."
      result &= "}`\n\n"

  result &= "# EXAMPLES\n\n"
  for e in examples:
    result &= "### " & e.title & "\n\n```" & e.lang & "\n" & e.code & "\n```\n\n"

  result &= "# EVENTS\n\n"
  result &= "Events are pushed asynchronously in JSON arrays:\n\n"
  result &= "```json\n"
  result &= "{\"events\": [{\"kind\": 0, ...}, ...]}\n"
  result &= "```\n\n"
  result &= "| Kind | Name | Extra fields | Description |\n"
  result &= "|---|---|---|---|\n"
  for e in events:
    result &= "| `" & $e.kind & "` | `" & e.name & "`"
    result &= " | " & e.fields & " | " & e.desc & " |\n"
  result &= "\n"

  result &= "# FILES\n\n"
  result &= "`$XDG_DATA_HOME/gtm/gtm.db`\n"
  result &= ":   SQLite database (schema: tracks, artists, albums, playlists, favourites, downloads, trash, playback_state).\n\n"
  result &= "`$XDG_RUNTIME_DIR/gtm/gtmd.sock`\n"
  result &= ":   Unix domain socket for IPC.\n\n"
  result &= "`$XDG_RUNTIME_DIR/gtm/gtmd.pid`\n"
  result &= ":   PID file for singleton enforcement.\n\n"
  result &= "# ENVIRONMENT\n\n"
  result &= "`XDG_RUNTIME_DIR`\n"
  result &= ":   Used for the daemon socket and PID file.\n\n"
  result &= "`XDG_DATA_HOME`\n"
  result &= ":   Used for the library database and download directory.\n\n"
  result &= "# BUGS\n\n"
  result &= "Report bugs and feature requests at:\n"
  result &= "<https://github.com/prjctimg/gtm/issues>\n\n"
  result &= "# SEE ALSO\n\n"
  result &= "`gtm`(1), `ffplay`(1), `yt-dlp`(1)\n"

# ── Main ─────────────────────────────────────────────────────────────

when isMainModule:
  echo "[genman] extracting CLI subcommands..."
  let cli = extractCliSubcmds()
  echo "  found ", cli.len, " subcommands"
  for c in cli: echo "    ", c.name, " — ", c.desc

  echo "[genman] extracting TUI commands..."
  let tui = extractTuiCommands()
  echo "  found ", tui.len, " commands"
  for c in tui: echo "    ", c.id, " (", c.name, ")"

  echo "[genman] extracting daemon commands..."
  let dcmd = extractDaemonCommands()
  echo "  found ", dcmd.len, " commands"
  for c in dcmd: echo "    ", c.wire, " — ", c.enumName

  echo "[genman] extracting audio events..."
  let evt = extractAudioEvents()
  echo "  found ", evt.len, " events"
  for e in evt: echo "    ", e.kind, " ", e.name

  if not dirExists(DocsDir): createDir(DocsDir)

  echo "[genman] extracting CLI examples..."
  let cliEx = cliExamples()
  echo "  found ", cliEx.len, " examples"

  echo "[genman] extracting daemon examples..."
  let dmdEx = daemonExamples()
  echo "  found ", dmdEx.len, " examples"

  if not dirExists(DocsDir): createDir(DocsDir)

  echo "[genman] generating docs/gtm.1.md..."
  let gtmMan = generateGtmManpage(cli, tui, cliEx)
  writeFile(DocsDir / "gtm.1.md", gtmMan)
  echo "  wrote ", gtmMan.splitLines().len, " lines"

  echo "[genman] generating docs/gtmd.1.md..."
  let gtmdMan = generateGtmdManpage(dcmd, evt, dmdEx)
  writeFile(DocsDir / "gtmd.1.md", gtmdMan)
  echo "  wrote ", gtmdMan.splitLines().len, " lines"

  echo "[genman] done"

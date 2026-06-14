import os, json, strutils, osproc
import client, state, library, audio

type
  Subcommand* = enum
    scNone, scPlay, scPause, scStop, scNext, scPrev, scToggle,
    scVolume, scShuffle, scRepeat, scSleep,
    scStatus, scNow, scKill, scDaemon, scHelp, scVersion

  CliArgs* = object
    subcmd*: Subcommand
    targets*: seq[string]
    volumeLevel*: int
    shuffleEnabled*: bool
    repeatMode*: int
    sleepMinutes*: int

proc parseSubcmd(name: string): Subcommand =
  case name
  of "play": scPlay
  of "pause", "toggle": scToggle
  of "stop": scStop
  of "next": scNext
  of "prev": scPrev
  of "volume": scVolume
  of "shuffle": scShuffle
  of "repeat": scRepeat
  of "sleep": scSleep
  of "status": scStatus
  of "now": scNow
  of "kill": scKill
  of "daemon": scDaemon
  of "help", "--help", "-h": scHelp
  of "--version", "-v": scVersion
  else: scNone

proc parseArgs*(args: seq[string] = os.commandLineParams()): CliArgs =
  result = CliArgs(subcmd: scNone)
  if args.len == 0: return
  let first = args[0]
  let cmd = parseSubcmd(first)
  if cmd == scNone:
    result.targets = loadFromArgs(args)
    return
  result.subcmd = cmd
  case cmd
  of scVolume:
    if args.len > 1:
      try: result.volumeLevel = parseInt(args[1])
      except: result.volumeLevel = 80
    else: result.volumeLevel = -1
  of scShuffle:
    if args.len > 1:
      result.shuffleEnabled = args[1].toLowerAscii() in ["1", "true", "on", "yes"]
    else:
      result.shuffleEnabled = true
  of scRepeat:
    if args.len > 1:
      try: result.repeatMode = parseInt(args[1])
      except: result.repeatMode = 1
    else:
      result.repeatMode = 1
  of scSleep:
    if args.len > 1:
      try: result.sleepMinutes = parseInt(args[1])
      except: result.sleepMinutes = 5
  of scPlay:
    result.targets = loadFromArgs(args[1..^1])
  else: discard

proc simpleDaemonCmd(cmd: string): JsonNode =
  var cli = newDaemonClient()
  cli.ensureDaemon()
  result = daemonSimpleCmd(cli, cmd)

proc printVersion*() =
  echo "gtm " & GTM_VERSION
  echo "Copyright (C) 2026 prjctimg <prjctimg@outlook.com>"
  echo "Website: https://prjctimg.me"
  echo "License GPL-3.0"
  echo "This is free software: you are free to change and redistribute it."
  echo "There is NO WARRANTY, to the extent permitted by law."

proc execSubcommand*(args: CliArgs): bool =
  result = true
  case args.subcmd
  of scNone:
    result = false
  of scVersion:
    printVersion()
  of scPlay:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    if args.targets.len > 0:
      discard cli.loadFile(args.targets[0])
      cli.play()
    echo "Playing: ", if args.targets.len > 0: args.targets[0] else: ""
  of scPause, scToggle:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    cli.togglePause()
    echo "Toggled pause"
  of scStop:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    cli.stop()
    echo "Stopped"
  of scNext:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    discard daemonSimpleCmd(cli, "next")
    echo "Next track"
  of scPrev:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    discard daemonSimpleCmd(cli, "prev")
    echo "Previous track"
  of scVolume:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    if args.volumeLevel >= 0:
      cli.setVolume(args.volumeLevel)
      echo "Volume set to ", args.volumeLevel
    else:
      let resp = simpleDaemonCmd("get_volume")
      echo "Volume: ", resp{"volume"}.getInt(80)
  of scShuffle:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    discard cli.setShuffle(args.shuffleEnabled)
    echo "Shuffle: ", (if args.shuffleEnabled: "on" else: "off")
  of scRepeat:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    discard cli.setRepeat(args.repeatMode)
    echo "Repeat: mode ", args.repeatMode
  of scSleep:
    var cli = newDaemonClient()
    cli.ensureDaemon()
    discard cli.setSleepTimer(args.sleepMinutes)
    echo "Sleep timer: ", args.sleepMinutes, " minutes"
  of scStatus:
    let resp = simpleDaemonCmd("status")
    echo "State: ", resp{"state"}.getStr("unknown")
    echo "Track: ", resp{"track"}.getStr("")
    echo "Volume: ", resp{"volume"}.getInt(80)
    echo "Time: ", formatTime(resp{"time_pos"}.getFloat(0.0))
    echo "Duration: ", formatTime(resp{"duration"}.getFloat(0.0))
  of scNow:
    let resp = simpleDaemonCmd("now_playing")
    echo "Now Playing:"
    echo "  Track: ", resp{"track"}.getStr("")
    echo "  State: ", resp{"state"}.getStr("unknown")
    echo "  Volume: ", resp{"volume"}.getInt(80)
    echo "  Time: ", formatTime(resp{"time_pos"}.getFloat(0.0))
    echo "  Duration: ", formatTime(resp{"duration"}.getFloat(0.0))
  of scKill:
    const pidPath = stateDir() & "/gtmd.pid"
    if fileExists(pidPath):
      try:
        let pid = readFile(pidPath).strip().parseInt()
        discard execCmd("kill " & $pid & " 2>/dev/null")
        echo "gtm daemon stopped (pid ", pid, ")"
      except: echo "Error stopping daemon"
    else: echo "No daemon running"
  of scDaemon:
    discard
  of scHelp:
    echo "Usage: gtm [subcommand] [args]"
    echo ""
    echo "Subcommands:"
    echo "  (no subcommand)   Launch TUI music player"
    echo "  daemon            Start background daemon (auto-started by TUI)"
    echo "  play <path|url>   Play a file or URL via daemon"
    echo "  pause/toggle      Toggle play/pause"
    echo "  stop              Stop playback"
    echo "  next              Skip to next track"
    echo "  prev              Go to previous track"
    echo "  volume [level]    Get/set volume (0-100)"
    echo "  shuffle [on/off]   Toggle shuffle mode"
    echo "  repeat [mode]      Set repeat mode (0=none, 1=all, 2=one)"
    echo "  sleep [minutes]    Set sleep timer in minutes"
    echo "  status            Show current playback status"
    echo "  now               Show current track info"
    echo "  kill              Stop the daemon process"
    echo "  help              Show this help"
    echo "  --version, -v     Show version information"
    echo ""
    echo "Examples:"
    echo "  gtm                     Launch TUI"
    echo "  gtm ~/Music/album/      Scan directory and launch TUI"
    echo "  gtm play song.mp3       Play a file"
    echo "  gtm pause               Toggle pause from terminal"
    echo "  gtm volume 50           Set volume to 50%"
    echo "  gtm next                Next track"
    echo "  gtm --version           Show version"

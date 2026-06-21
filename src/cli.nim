## CLI subcommand parser and dispatch
##
## Parses argv into a Subcommand enum and optional arguments, then
## executes the corresponding action by sending IPC messages to the
## running daemon (or spawning it for `daemon` and `play`).
##
## ┌────────────────────────────────────────────────┐
## │  CLI entry (from gtm.nim main)                  │
## │                                                 │
## │  parseArgs(argv) ──► CliArgs(subcmd, targets)   │
## │       │                                         │
## │       ▼                                         │
## │  case subcmd:                                   │
## │    scDaemon ──► spawn daemon, wait, exit        │
## │    scPlay   ──► send IPC play, may spawn daemon │
## │    scKill   ──► send IPC quit                   │
## │    scStatus ──► send IPC status, print result   │
## │    scVolume ──► send IPC get/set volume         │
## │    …etc      ──► send IPC cmd, print response   │
## └────────────────────────────────────────────────┘

import os, json, strutils, osproc, terminal
import session, state, library, audio

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

template withDaemon(body: untyped): untyped =
  var cli {.inject.} = newDaemonSession()
  cli.ensureRunning()
  body

proc simpleDaemonCmd(cmd: string): JsonNode =
  var cli = newDaemonSession()
  cli.ensureRunning()
  cli.daemonSimpleCmd(cmd)

proc printVersion*() =
  echo "gtm " & GTM_VERSION
  echo "Copyright (C) 2026 prjctimg <prjctimg@outlook.com>"
  echo "Website: https://prjctimg.me"
  echo "License GPL-3.0"
  echo "This is free software: you are free to change and redistribute it."
  echo "There is NO WARRANTY, to the extent permitted by law."

proc useColor(): bool =
  stdout.isatty()

proc stateColor(state: string): string =
  case state
  of "playing": "\e[32m" & state & "\e[0m"  # green
  of "paused":  "\e[33m" & state & "\e[0m"  # yellow
  of "stopped": "\e[31m" & state & "\e[0m"  # red
  else: state

proc execSubcommand*(args: CliArgs): bool =
  result = true
  case args.subcmd
  of scNone:
    result = false
  of scVersion:
    printVersion()
  of scPlay:
    withDaemon:
      if args.targets.len > 0:
        discard cli.loadFile(args.targets[0])
        cli.play()
        let resp = simpleDaemonCmd("now_playing")
        let title = resp{"track"}.getStr(args.targets[0])
        if useColor():
          echo "\e[32m\u25B6\e[0m Playing: \e[36m" & title.splitFile().name.replace(".", " ") & "\e[0m"
        else:
          echo "Playing: ", title.splitFile().name.replace(".", " ")
      else:
        cli.play()
        echo "Playback resumed"
  of scPause, scToggle:
    withDaemon:
      cli.togglePause()
      if useColor():
        echo "\e[33m\u23F8\e[0m Toggled pause"
      else:
        echo "Toggled pause"
  of scStop:
    withDaemon:
      cli.stop()
      if useColor():
        echo "\e[31m\u23F9\e[0m Stopped"
      else:
        echo "Stopped"
  of scNext:
    withDaemon:
      discard cli.daemonSimpleCmd("next")
      if useColor():
        echo "\e[34m\u23ED\e[0m Next track"
      else:
        echo "Next track"
  of scPrev:
    withDaemon:
      discard cli.daemonSimpleCmd("prev")
      if useColor():
        echo "\e[34m\u23EE\e[0m Previous track"
      else:
        echo "Previous track"
  of scVolume:
    if args.volumeLevel >= 0:
      withDaemon:
        cli.setVolume(args.volumeLevel)
        if useColor():
          echo "\e[36mVolume\e[0m set to \e[1m" & $args.volumeLevel & "%\e[0m"
        else:
          echo "Volume set to ", args.volumeLevel
    else:
      let resp = simpleDaemonCmd("get_volume")
      let vol = resp{"volume"}.getInt(80)
      if useColor():
        echo "\e[36mVolume:\e[0m \e[1m" & $vol & "%\e[0m"
      else:
        echo "Volume: ", vol
  of scShuffle:
    withDaemon:
      discard cli.request(%*{"cmd": "set_shuffle", "enabled": args.shuffleEnabled})
      if useColor():
        let on = if args.shuffleEnabled: "\e[32mON\e[0m" else: "\e[31mOFF\e[0m"
        echo "\e[33m\u1F500\e[0m Shuffle: ", on
      else:
        echo "Shuffle: ", (if args.shuffleEnabled: "on" else: "off")
  of scRepeat:
    withDaemon:
      discard cli.request(%*{"cmd": "set_repeat", "mode": args.repeatMode})
      if useColor():
        echo "\e[34m\u1F501\e[0m Repeat: mode \e[1m" & $args.repeatMode & "\e[0m"
      else:
        echo "Repeat: mode ", args.repeatMode
  of scSleep:
    withDaemon:
      discard cli.request(%*{"cmd": "set_sleep_timer", "minutes": args.sleepMinutes})
      if useColor():
        echo "\e[33m\u23F0\e[0m Sleep timer: \e[1m" & $args.sleepMinutes & "m\e[0m"
      else:
        echo "Sleep timer: ", args.sleepMinutes, " minutes"
  of scStatus:
    let resp = simpleDaemonCmd("status")
    let st = resp{"state"}.getStr("unknown")
    let track = resp{"track"}.getStr("")
    let vol = resp{"volume"}.getInt(80)
    let tpos = formatTime(resp{"time_pos"}.getFloat(0.0))
    let dur = formatTime(resp{"duration"}.getFloat(0.0))
    if useColor():
      echo stateColor(st) & "  \e[36m" & track.splitFile().name.replace(".", " ") & "\e[0m"
      echo "  \e[2mVolume:\e[0m \e[1m" & $vol & "%\e[0m  \e[2mTime:\e[0m " & tpos & " / " & dur
    else:
      echo "State: ", st
      echo "Track: ", track
      echo "Volume: ", vol
      echo "Time: ", tpos
      echo "Duration: ", dur
  of scNow:
    let resp = simpleDaemonCmd("now_playing")
    let st = resp{"state"}.getStr("unknown")
    let track = resp{"track"}.getStr("")
    let vol = resp{"volume"}.getInt(80)
    let tpos = formatTime(resp{"time_pos"}.getFloat(0.0))
    let dur = formatTime(resp{"duration"}.getFloat(0.0))
    if useColor():
      echo "\e[1mNow Playing:\e[0m"
      echo "  \e[36m" & track.splitFile().name.replace(".", " ") & "\e[0m"
      echo "  " & stateColor(st) & "  \e[2mVol:\e[0m \e[1m" & $vol & "%\e[0m"
      echo "  \e[2m" & tpos & " / " & dur & "\e[0m"
    else:
      echo "Now Playing:"
      echo "  Track: ", track
      echo "  State: ", st
      echo "  Volume: ", vol
      echo "  Time: ", tpos
      echo "  Duration: ", dur
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

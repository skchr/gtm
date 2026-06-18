import json

type
  DocExample* = object
    title*: string
    lang*: string
    code*: string
    request*: JsonNode
    response*: JsonNode

proc cliExamples*(): seq[DocExample] =
  result = @[
    DocExample(
      title: "Play a local file:",
      lang: "bash",
      code: "gtm play ~/music/track.flac",
    ),
    DocExample(
      title: "Play a YouTube URL:",
      lang: "bash",
      code: "gtm play https://youtube.com/watch?v=dQw4w9WgXcQ",
    ),
    DocExample(
      title: "Toggle play/pause:",
      lang: "bash",
      code: "gtm pause",
      request: %*{"cmd": "toggle_pause"},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Skip to next track:",
      lang: "bash",
      code: "gtm next",
      request: %*{"cmd": "next"},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Set volume to 75%:",
      lang: "bash",
      code: "gtm volume 75",
      request: %*{"cmd": "set_volume", "volume": 75},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Query current volume:",
      lang: "bash",
      code: "gtm volume",
      request: %*{"cmd": "get_volume"},
      response: %*{"ok": true, "volume": 80},
    ),
    DocExample(
      title: "Enable shuffle:",
      lang: "bash",
      code: "gtm shuffle on",
      request: %*{"cmd": "set_shuffle", "enabled": true},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Set repeat mode to repeat one:",
      lang: "bash",
      code: "gtm repeat 2",
      request: %*{"cmd": "set_repeat", "mode": 2},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Set sleep timer (30 minutes):",
      lang: "bash",
      code: "gtm sleep 30",
      request: %*{"cmd": "set_sleep_timer", "minutes": 30},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Show playback status:",
      lang: "bash",
      code: "gtm status",
      request: %*{"cmd": "status"},
      response: %*{"ok": true, "volume": 80, "state": "playing", "duration": 245.0, "track_title": "Song"},
    ),
    DocExample(
      title: "Show current track:",
      lang: "bash",
      code: "gtm now",
      request: %*{"cmd": "now_playing"},
      response: %*{"ok": true, "title": "Bohemian Rhapsody", "artist": "Queen", "album": "A Night at the Opera", "duration": 354.0},
    ),
    DocExample(
      title: "Query status programmatically with jq:",
      lang: "bash",
      code: "gtm status | jq '.volume, .state'",
      request: %*{"cmd": "status"},
      response: %*{"ok": true, "volume": 80, "state": "playing"},
    ),
    DocExample(
      title: "Start the daemon in background and run commands:",
      lang: "bash",
      code: "gtm daemon &\ngtm play ~/music/song.ogg\ngtm next",
    ),
  ]

proc daemonExamples*(): seq[DocExample] =
  result = @[
    DocExample(
      title: "Play a track (socat):",
      lang: "bash",
      code: "echo '{\"cmd\":\"play\"}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/gtm/gtmd.sock\n# {\"ok\":true}",
      request: %*{"cmd": "play"},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Load and start a local file (socat):",
      lang: "bash",
      code: "echo '{\"cmd\":\"load_file\",\"path\":\"/home/user/music/track.flac\"}' | \\\n  socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/gtm/gtmd.sock\n# {\"ok\":true}",
      request: %*{"cmd": "load_file", "path": "/home/user/music/track.flac"},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Query volume (socat):",
      lang: "bash",
      code: "echo '{\"cmd\":\"get_volume\"}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/gtm/gtmd.sock\n# {\"ok\":true,\"volume\":80}",
      request: %*{"cmd": "get_volume"},
      response: %*{"ok": true, "volume": 80},
    ),
    DocExample(
      title: "Set volume (socat):",
      lang: "bash",
      code: "echo '{\"cmd\":\"set_volume\",\"volume\":60}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/gtm/gtmd.sock\n# {\"ok\":true}",
      request: %*{"cmd": "set_volume", "volume": 60},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Listen for events (daemon keeps connection open):",
      lang: "bash",
      code: "socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/gtm/gtmd.sock <<'EOF'\n{\"cmd\":\"play\"}\nEOF\n# Response:\n# {\"ok\":true}\n# Incoming events as playback progresses:\n# {\"events\":[{\"kind\":1,\"state\":\"playing\",\"track_path\":\"/home/user/music/track.flac\",\"time_pos\":0,\"duration\":253.0}]}\n# {\"events\":[{\"kind\":5,\"time_pos\":15.2}]}\n# {\"events\":[{\"kind\":5,\"time_pos\":30.5}]}",
      request: %*{"cmd": "play"},
      response: %*{"ok": true},
    ),
    DocExample(
      title: "Scripted interaction from a shell script:",
      lang: "bash",
      code: "#!/bin/sh\nSOCK=$XDG_RUNTIME_DIR/gtm/gtmd.sock\n\n# Send command and read one response line\nsend_cmd() {\n  echo \"$1\" | socat - UNIX-CONNECT:\"$SOCK\" 2>/dev/null | head -1\n}\n\n# Start playback\nsend_cmd '{\"cmd\":\"play\"}'\n\n# Set volume\nsend_cmd '{\"cmd\":\"set_volume\",\"volume\":60}'\n\n# Get current track info\nsend_cmd '{\"cmd\":\"now_playing\"}'",
    ),
    DocExample(
      title: "Programmatic access from Nim:",
      lang: "nim",
      code: "import std/net, std/json\n\nlet sock = newSocket()\nsock.connect(\"$XDG_RUNTIME_DIR/gtm/gtmd.sock\", Port(0))  # AF_UNIX\nsock.send(\"{\\\"cmd\\\":\\\"ping\\\"}\\n\")\nlet resp = sock.recvLine()\necho parseJson(resp)\n# {\"ok\": true}",
      request: %*{"cmd": "ping"},
      response: %*{"ok": true},
    ),
  ]

proc lyricsExamples*(): seq[DocExample] =
  result = @[
    DocExample(
      title: "Parse a sidecar LRC file:",
      lang: "lrc",
      code: "[ti:Test Song]\n[ar:Test Artist]\n[00:01.50]First line\n[00:05.00]Second line",
    ),
    DocExample(
      title: "Look up the current lyric line at a time position:",
      lang: "nim",
      code: "let idx = currentLrcLine(lyrics, 3.0)  # returns 0 (Intro)\nlet idx = currentLrcLine(lyrics, 5.0)  # returns 1 (Verse 1)",
      request: %*{"title": "Test Song", "artist": "Test Artist"},
    ),
    DocExample(
      title: "Empty lyrics return -1:",
      lang: "nim",
      code: "let idx = currentLrcLine(LrcData(lines: @[]), 0.0)\nassert idx == -1",
    ),
  ]

proc audioExamples*(): seq[DocExample] =
  result = @[
    DocExample(
      title: "Crossfade duration frame calculation (5 s at 44100 Hz):",
      lang: "nim",
      code: "let frames = int(5.0 * 44100.float32)\nassert frames == 220500",
    ),
  ]

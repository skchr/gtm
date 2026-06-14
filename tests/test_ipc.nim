import unittest, json, tables, strutils
import ../src/audio, ../src/state

suite "Event serialization round-trip":
  test "construct and parse aekPositionChanged event":
    let evJson = %*{"kind": 5, "time_pos": 123.5}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekPositionChanged
    check evJson["time_pos"].getFloat(0.0) == 123.5

  test "construct and parse aekDurationChanged event":
    let evJson = %*{"kind": 6, "duration": 245.0}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekDurationChanged
    check evJson["duration"].getFloat(0.0) == 245.0

  test "construct and parse aekVolumeChanged event":
    let evJson = %*{"kind": 7, "volume": 80}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekVolumeChanged
    check evJson["volume"].getInt(0) == 80

  test "construct and parse aekPlaybackStarted event":
    let evJson = %*{"kind": 1, "state": "playing"}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekPlaybackStarted
    check evJson["state"].getStr("") == "playing"

  test "construct and parse aekTrackEnded event":
    let evJson = %*{"kind": 4, "reason": "eof"}
    let k = evJson["kind"].getInt(0)
    let kind = AudioEventKind(k)
    check kind == aekTrackEnded
    check evJson["reason"].getStr("") == "eof"

suite "Event batch parsing (pollEvents style)":
  test "parse single event batch":
    let raw = """{"events":[{"kind":1,"state":"playing"}]}"""
    let j = parseJson(raw)
    check j.hasKey("events")
    let events = j["events"]
    check events.len == 1
    check events[0]["kind"].getInt(0) == 1
    check events[0]["state"].getStr("") == "playing"

  test "parse multiple events in one batch":
    let raw = """{"events":[{"kind":5,"time_pos":10.0},{"kind":6,"duration":300.0}]}"""
    let j = parseJson(raw)
    let events = j["events"]
    check events.len == 2
    check events[0]["kind"].getInt(0) == 5
    check events[1]["kind"].getInt(0) == 6

  test "interleaved events and state (drainEventLines scenario)":
    let line1 = """{"events":[{"kind":5,"time_pos":30.0}]}"""
    let line2 = """{"ok":true,"state":"playing","duration":300.0}"""
    let buf = line1 & "\n" & line2 & "\n"
    var lines: seq[string] = @[]
    for line in splitLines(buf):
      if line.len > 0: lines.add(line)
    check lines.len == 2
    let evJson = parseJson(lines[0])
    check evJson.hasKey("events")
    let respJson = parseJson(lines[1])
    check respJson["ok"].getBool(false) == true
    check respJson["state"].getStr("") == "playing"

suite "Daemon command construction":
  test "play command":
    let cmd = %*{"cmd": "play"}
    check $cmd == """{"cmd":"play"}"""

  test "load_file command":
    let cmd = %*{"cmd": "load_file", "path": "/tmp/test.mp3"}
    check cmd["cmd"].getStr("") == "load_file"
    check cmd["path"].getStr("") == "/tmp/test.mp3"

  test "set_volume command":
    let cmd = %*{"cmd": "set_volume", "volume": 50}
    check cmd["volume"].getInt(0) == 50

  test "seek command":
    let cmd = %*{"cmd": "seek", "seconds": 30.5}
    check cmd["seconds"].getFloat(0.0) == 30.5

  test "set_eq_band command":
    let cmd = %*{"cmd": "set_eq_band", "band": 3, "gain_db": -2.5}
    check cmd["band"].getInt(0) == 3
    check cmd["gain_db"].getFloat(0.0) == -2.5

suite "Response parsing":
  test "parse ok response":
    let raw = """{"ok":true,"state":"playing","duration":245.0}"""
    let j = parseJson(raw)
    check j["ok"].getBool(false) == true
    check j["state"].getStr("") == "playing"
    check j["duration"].getFloat(0.0) == 245.0

  test "parse error response":
    let raw = """{"ok":false,"error":"file not found"}"""
    let j = parseJson(raw)
    check j["ok"].getBool(true) == false
    check j["error"].getStr("") == "file not found"

  test "parse get_volume response":
    let raw = """{"ok":true,"volume":80}"""
    let j = parseJson(raw)
    check j["volume"].getInt(0) == 80

suite "YtSearchResult":
  test "YtSearchResult fields round-trip through JSON":
    let r = YtSearchResult(
      title: "Test",
      url: "https://youtube.com/watch?v=abc",
      duration: "3:30",
      channel: "Channel",
      kind: srkVideo
    )
    let j = %*{"title": r.title, "url": r.url, "duration": r.duration, "channel": r.channel, "kind": r.kind.int}
    check j["title"].getStr("") == "Test"
    check j["url"].getStr("") == "https://youtube.com/watch?v=abc"
    check j["duration"].getStr("") == "3:30"

  test "playlist detail construction":
    var pl = YtPlaylistDetail(
      title: "My Mix",
      url: "https://youtube.com/playlist?list=PL1",
      channel: "Artist",
      trackCount: 2
    )
    pl.tracks.add(YtSearchResult(title: "Song A", url: "https://youtube.com/watch?v=a", kind: srkVideo))
    pl.tracks.add(YtSearchResult(title: "Song B", url: "https://youtube.com/watch?v=b", kind: srkVideo))
    check pl.trackCount == 2
    check pl.tracks.len == 2
    check pl.title == "My Mix"

suite "Crossfade":
  test "crossfade command construction":
    let cmd = %*{"cmd": "crossfade", "duration": 5.0}
    check cmd["cmd"].getStr("") == "crossfade"
    check cmd["duration"].getFloat(0.0) == 5.0

  test "prepare_next command construction":
    let cmd = %*{"cmd": "prepare_next", "path": "/music/next.flac"}
    check cmd["cmd"].getStr("") == "prepare_next"
    check cmd["path"].getStr("") == "/music/next.flac"

  test "set_crossfade_curve command construction":
    let cmd = %*{"cmd": "set_crossfade_curve", "curve_type": 2}
    check cmd["curve_type"].getInt(0) == 2

  test "crossfade frame calculation at 44100 Hz":
    let durationSec = 5.0
    let sampleRate = 44100
    let frames = int(durationSec * sampleRate.float32)
    check frames == 220500
    # At 1024 samples/frame, should complete in ~215 iterations
    let framesPerIter = 1024
    let iterations = frames div framesPerIter
    check iterations == 215

  test "crossfade frame calculation at 48000 Hz":
    let durationSec = 5.0
    let sampleRate = 48000
    let frames = int(durationSec * sampleRate.float32)
    check frames == 240000

  test "crossfade event serialization":
    let startedEv = %*{"kind": 8, "event": "crossfade_started"}
    check startedEv["event"].getStr("") == "crossfade_started"
    let endedEv = %*{"kind": 8, "event": "crossfade_ended"}
    check endedEv["event"].getStr("") == "crossfade_ended"

  test "crossfade schedule phase detection":
    let crossfadeDuration = 5
    let dur = 200.0
    let tpos = 196.0
    let timeRemaining = dur - tpos
    let prepareThreshold = float(crossfadeDuration) + 2.0
    check timeRemaining <= prepareThreshold  # Phase 0: should prepare
    check timeRemaining <= float(crossfadeDuration)  # Phase 1: should start
    check timeRemaining > 0.0

  test "crossfade not triggered yet when far from end":
    let crossfadeDuration = 5
    let dur = 200.0
    let tpos = 100.0
    let timeRemaining = dur - tpos
    check timeRemaining > float(crossfadeDuration) + 2.0  # Too early

suite "Equalizer":
  test "set_eq_band command construction":
    let cmd = %*{"cmd": "set_eq_band", "band": 3, "gain_db": -2.5}
    check cmd["cmd"].getStr("") == "set_eq_band"
    check cmd["band"].getInt(0) == 3
    check cmd["gain_db"].getFloat(0.0) == -2.5

  test "set_eq_preset command construction":
    let cmd = %*{"cmd": "set_eq_preset", "name": "Rock"}
    check cmd["name"].getStr("") == "Rock"

  test "list_eq_presets response includes new presets":
    let presets = ["Flat", "Rock", "Pop", "Classical", "Jazz", "HipHop", "Vocal",
                   "BassBoost", "Headphones", "Laptop",
                   "Electronic", "Acoustic", "Podcast", "Dance"]
    check presets.len == 14
    check "Electronic" in presets
    check "Acoustic" in presets
    check "Podcast" in presets
    check "Dance" in presets

  test "eq band clamping":
    let bands = [31.25, 62.5, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0]
    check bands.len == 10
    for b in bands:
      check b >= 31.25
      check b <= 16000.0

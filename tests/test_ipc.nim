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

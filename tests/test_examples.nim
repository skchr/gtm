import unittest, json, os, strutils
import ../src/audio, ../src/state, ../src/lyrics
import ../tools/docs

proc findExample(examples: seq[DocExample]; substr: string): DocExample =
  for e in examples:
    if e.title.find(substr) >= 0:
      return e
  result = examples[0]

proc checkIpcExample(e: DocExample) =
  ## Validates an IPC example's request and response structure.
  check e.request != nil
  check e.request.hasKey("cmd")
  let cmd = e.request["cmd"].getStr("")
  check cmd.len > 0
  check e.response != nil
  check e.response.hasKey("ok")
  check e.response["ok"].kind == JBool
  check e.response["ok"].getBool(false) == true
  case cmd
  of "set_volume":
    check e.request.hasKey("volume")
    check e.request["volume"].kind == JInt
    let v = e.request["volume"].getInt(0)
    check v >= 0 and v <= 100
  of "get_volume":
    check e.response.hasKey("volume")
    check e.response["volume"].kind == JInt
  of "set_shuffle":
    check e.request.hasKey("enabled")
    check e.request["enabled"].kind == JBool
  of "set_repeat":
    check e.request.hasKey("mode")
    check e.request["mode"].kind == JInt
  of "set_sleep_timer":
    check e.request.hasKey("minutes")
    check e.request["minutes"].kind == JInt
  of "load_file":
    check e.request.hasKey("path")
    check e.request["path"].kind == JString
    check e.request["path"].getStr("").len > 0
  of "status", "now_playing":
    discard  # optional fields checked in response parsing suite
  else:
    discard

suite "gtm CLI examples":
  for e in cliExamples():
    test e.title:
      if e.request != nil and e.response != nil:
        checkIpcExample(e)
      else:
        check e.code.len > 0

suite "gtm status | jq response parsing (programmatic access)":
  for e in cliExamples():
    let cmd = e.request{"cmd"}.getStr("")
    if cmd in ["status", "now_playing", "get_volume"] and e.response != nil:
      test e.title & " — parse response":
        check e.response["ok"].getBool(false) == true
        case cmd
        of "status":
          check e.response.hasKey("state")
          check e.response["state"].kind == JString
          check e.response.hasKey("volume")
          check e.response["volume"].kind == JInt
          if e.response.hasKey("duration"):
            check e.response["duration"].kind == JFloat
        of "now_playing":
          check e.response.hasKey("title")
          check e.response["title"].kind == JString
          check e.response.hasKey("artist")
          check e.response["artist"].kind == JString
          check e.response.hasKey("album")
          check e.response["album"].kind == JString
        of "get_volume":
          check e.response.hasKey("volume")
          check e.response["volume"].kind == JInt
        else: discard

suite "gtmd socat examples (IPC protocol)":
  for e in daemonExamples():
    if e.request != nil and e.response != nil:
      test e.title:
        checkIpcExample(e)

suite "gtmd event streaming examples":
  let evEx = findExample(daemonExamples(), "events")
  test "parse playback started event":
    check "{kind:1" in evEx.code or "\"kind\":1" in evEx.code
    check "{kind:5" in evEx.code or "\"kind\":5" in evEx.code

  test "parse position changed events":
    check "\"time_pos\":15.2" in evEx.code
    check "\"time_pos\":30.5" in evEx.code

  test "multiple position events in sequence":
    let count = evEx.code.count("\"kind\":5")
    check count >= 2

suite "Nim socket API examples":
  let nimEx = findExample(daemonExamples(), "Nim")
  test "construct ping command (as in Nim example)":
    check nimEx.request["cmd"].getStr("") == "ping"
    check nimEx.response["ok"].getBool(false) == true

  test "parse ping response":
    check nimEx.response["ok"].getBool(false) == true

  test "recvLine-style IPC round-trip":
    check nimEx.request["cmd"].getStr("") == "ping"
    check nimEx.response["ok"].getBool(false) == true

  test "newSocket + connect + send + recvLine pattern (IPC framing only)":
    check "newSocket()" in nimEx.code
    check "recvLine()" in nimEx.code
    check "ping" in nimEx.code

suite "Shell script example — send_cmd function":
  let shEx = findExample(daemonExamples(), "shell script")
  test "send_cmd constructs correct JSON":
    check "'{\"cmd\":\"play\"}'" in shEx.code
    check "'{\"cmd\":\"now_playing\"}'" in shEx.code

  test "send_cmd with set_volume":
    check "'{\"cmd\":\"set_volume\",\"volume\":60}'" in shEx.code

  test "send_cmd returns ok response pattern":
    check "send_cmd" in shEx.code
    check "socat" in shEx.code

suite "LRC lyrics examples":
  test "parseLrc handles sidecar format":
    let path = "/tmp/gtm_test_example_lrc.nim"
    writeFile(path, "[ti:Test Song]\n[ar:Test Artist]\n[00:01.50]First line\n[00:05.00]Second line\n")
    let lrc = parseLrc(path)
    removeFile(path)
    check lrc.title == "Test Song"
    check lrc.artist == "Test Artist"
    check lrc.lines.len == 2
    check lrc.lines[0].text == "First line"
    check lrc.lines[1].text == "Second line"
    check lrc.lines[1].timestamp > lrc.lines[0].timestamp

  test "currentLrcLine returns correct index at time position":
    let lrc = LrcData(
      lines: @[
        LrcLine(timestamp: 0.0, text: "Intro"),
        LrcLine(timestamp: 5.0, text: "Verse 1"),
        LrcLine(timestamp: 15.0, text: "Chorus"),
      ]
    )
    check currentLrcLine(lrc, 0.0) == 0
    check currentLrcLine(lrc, 2.0) == 0
    check currentLrcLine(lrc, 5.0) == 1
    check currentLrcLine(lrc, 10.0) == 1
    check currentLrcLine(lrc, 15.0) == 2
    check currentLrcLine(lrc, 20.0) == 2

  test "currentLrcLine returns -1 for empty lyrics":
    let lrc = LrcData(lines: @[])
    check currentLrcLine(lrc, 0.0) == -1

suite "Crossfade example parity":
  test "crossfade_duration 5s at 44100":
    let durationSec = 5.0
    let sampleRate = 44100
    let frames = int(durationSec * sampleRate.float32)
    let framesPerIter = 1024
    let iterations = frames div framesPerIter
    check frames == 220500
    check iterations == 215
    check iterations * framesPerIter <= frames

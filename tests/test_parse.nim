import unittest, json, strutils
import ../src/ytdlp, ../src/state
export appendCookieArgs, appendJsRuntimeArgs

suite "parseYtJsonLine":
  test "parses a valid audio result":
    let raw = """{"id":"abc123","title":"Test Audio","webpage_url":"https://youtube.com/watch?v=abc123","duration":245.5,"channel":"TestChannel","ie_key":"Youtube"}"""
    let r = parseYtJsonLine(raw)
    check r.title == "Test Audio"
    check r.url == "https://youtube.com/watch?v=abc123"
    check r.duration == "4:05"
    check r.channel == "TestChannel"
    check r.kind == srkVideo

  test "parses a playlist result":
    let raw = """{"title":"Mix","webpage_url":"https://youtube.com/playlist?list=PL123","ie_key":"YoutubePlaylist","channel":"Channel"}"""
    let r = parseYtJsonLine(raw)
    check r.kind == srkPlaylist
    check r.title == "Mix"

  test "parses result with uploader instead of channel":
    let raw = """{"id":"xyz","title":"Song","url":"https://youtube.com/watch?v=xyz","duration":180,"uploader":"ArtistName"}"""
    let r = parseYtJsonLine(raw)
    check r.channel == "ArtistName"
    check r.kind == srkVideo

  test "handles missing duration":
    let raw = """{"id":"x","title":"No Dur","url":"https://youtube.com/watch?v=x"}"""
    let r = parseYtJsonLine(raw)
    check r.duration == ""
    check r.title == "No Dur"

  test "handles empty string":
    let r = parseYtJsonLine("")
    check r.title.len == 0

  test "handles invalid JSON":
    let r = parseYtJsonLine("this is not json")
    check r.title.len == 0

  test "parses flat playlist format":
    let raw = """{"_type":"playlist","title":"My Playlist","webpage_url":"https://youtube.com/playlist?list=PL1","ie_key":"Youtube","entries":[]}"""
    let r = parseYtJsonLine(raw)
    check r.kind == srkPlaylist
    check r.title == "My Playlist"

  test "duration formats correctly":
    let cases = [
      ("""{"title":"A","url":"x","duration":0}""", "0:00"),
      ("""{"title":"B","url":"x","duration":59}""", "0:59"),
      ("""{"title":"C","url":"x","duration":60}""", "1:00"),
      ("""{"title":"D","url":"x","duration":3661}""", "61:01"),
    ]
    for (raw, expected) in cases:
      let r = parseYtJsonLine(raw)
      check r.duration == expected

suite "appendCookieArgs":
  test "file path source adds --cookies arg":
    var args1: seq[string] = @[]
    appendCookieArgs(args1, "/path/to/cookies.txt")
    check args1 == @["--cookies", "/path/to/cookies.txt"]

  test "browser source adds --cookies-from-browser":
    var args2: seq[string] = @[]
    appendCookieArgs(args2, "firefox")
    check args2 == @["--cookies-from-browser", "firefox"]

suite "appendJsRuntimeArgs":
  test "empty runtime adds nothing":
    var args3: seq[string] = @[]
    appendJsRuntimeArgs(args3, "")
    check args3.len == 0

  test "runtime adds args":
    var args4: seq[string] = @[]
    appendJsRuntimeArgs(args4, "node")
    check "node" in args4
    check "ejs:github" in args4

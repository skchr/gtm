# Package
version     = "0.1.0"
author      = "prjctimg"
description = "Terminal music player based on FFmpeg and nimwave. "
license     = "MIT"
srcDir      = "src"
bin         = @["gtm"]

# nimlanguageserver entry points - tells nimsuggest which files are project roots
entryPoints = @["src/gtm.nim"]

# Dependencies
requires "nim >= 2.0.0"
requires "nimwave >= 1.2.1"
requires "illwave >= 0.1.0"
requires "ansiutils >= 0.1.0"

task test, "Run all tests":
  exec "nim r --path:src tests/test_parse.nim"
  exec "nim r --path:src tests/test_ipc.nim"

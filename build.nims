import strutils

const
  GTM_SRC = "src/gtm.nim"
  GTMD_SRC = "src/gtmd.nim"
  MAN_SRC = "docs/gtm.1.md"
  MAN_DST = "bin/gtm.1"

proc sh(cmd: string) =
  echo "  -> " & cmd
  discard staticExec(cmd)

proc checkCmd(name, test: string): bool =
  let r = staticExec(test).strip
  if r.len == 0:
    echo "  ! " & name & " not found — skipping dependent steps"
    return false
  echo "    " & name & ": " & r
  true

proc detectVersion: string =
  let tag = staticExec("git describe --tags --abbrev=0 2>/dev/null").strip
  if tag.len > 0:
    let dirty = staticExec("git diff --quiet HEAD 2>/dev/null || echo '-dirty'").strip
    result = tag & dirty
  else:
    result = staticExec("git rev-parse --short=7 HEAD 2>/dev/null").strip
  if result.len == 0: result = "0.0.0-dev"

proc buildManpage(version: string) =
  if not dirExists("bin"):
    mkDir("bin")
  if fileExists("bin/gtm.1"):
    echo "    manpage already present: bin/gtm.1"
    return
  let hasPandoc = checkCmd("pandoc", "pandoc --version 2>/dev/null | head -1")
  if not hasPandoc:
    echo "    pandoc not found, manpage: bin/gtm.1 not generated"
    return
  if fileExists(MAN_SRC):
    sh("pandoc " & MAN_SRC & " -s -t man -o " & MAN_DST & " --variable=version:" & version)
    echo "    manpage -> " & MAN_DST

proc buildBinary(src, label: string, version:string ) =
  if not fileExists(src):
    echo "  " & src & " not found"
    return
  let flags = "-d:release" &
    " -d:gtmVersion:" & version &
    " -d:gtmBuildTime:"
  sh("nim c " & flags & " " & src & " 2>&1")

when isMainModule:
  var buildTui = true
  var buildDmd = true
  if paramCount() > 0:
    buildTui = false
    buildDmd = false
    for i in 1..paramCount():
      if paramStr(i) == "-t": buildTui = true
      if paramStr(i) == "-d": buildDmd = true

  echo ""
  echo "build gtm"
  echo ""

  let version = detectVersion()
  echo "  Version: " & version
  echo ""

  echo "-- Prerequisites --"
  discard checkCmd("nim", "nim --version 2>/dev/null | head -1")
  discard checkCmd("gcc", "gcc --version 2>/dev/null | head -1")
  discard checkCmd("dbus-1", "pkg-config --modversion dbus-1 2>/dev/null")
  discard checkCmd("viu", "viu --version 2>/dev/null")
  echo ""

  echo "-- Manpage --"
  buildManpage(version)
  echo ""

  echo "-- Build --"
  if buildDmd:
    buildBinary(GTMD_SRC, "gtmd", version)
  if buildTui:
    buildBinary(GTM_SRC, "gtm", version)
  echo ""

  echo "-- Summary --"
  if fileExists("bin/gtm"):
    echo "  bin/gtm:  " & staticExec("ls -lh bin/gtm 2>/dev/null | cut -d' ' -f5").strip
  if fileExists("bin/gtmd"):
    echo "  bin/gtmd: " & staticExec("ls -lh bin/gtmd 2>/dev/null | cut -d' ' -f5").strip
  if fileExists(MAN_DST):
    echo "  " & MAN_DST & ": " & staticExec("ls -lh " & MAN_DST & " 2>/dev/null | cut -d' ' -f5").strip

import strutils, os

const
  GTM_SRC = "src/gtm.nim"
  GTMD_SRC = "src/gtmd.nim"
  MAN_SRC = "docs/gtm.1.md"
  MAN_DST = "bin/gtm.1"

proc sh(cmd: string) =
  echo "  -> " & cmd
  let output = staticExec(cmd)
  if output.len > 0:
    echo output

proc checkCmd(name, test: string): bool =
  let r = staticExec(test).strip
  if r.len == 0:
    echo "  ! " & name & " not found — skipping dependent steps"
    return false
  echo "    " & name & ": " & r
  true

var forcedTag: string

proc detectVersion: string =
  if forcedTag.len > 0:
    let clean = if forcedTag.startsWith("v"): forcedTag[1..^1] else: forcedTag
    return clean
  let tag = staticExec("git describe --tags --abbrev=0 2>/dev/null").strip
  if tag.len > 0:
    let clean = if tag.startsWith("v"): tag[1..^1] else: tag
    let dirty = staticExec("git diff --quiet HEAD 2>/dev/null || echo '-dirty'").strip
    result = clean & dirty
  else:
    result = staticExec("git rev-parse --short=7 HEAD 2>/dev/null").strip
  if result.len == 0: result = "0.0.0-dev"

proc selectTagInteractive: string =
  let tags = staticExec("git tag --sort=-version:refname 2>/dev/null").strip
  if tags.len == 0:
    echo "  ! No tags found"
    return ""
  let lines = tags.splitLines
  echo "\nAvailable tags:"
  for i, t in lines:
    echo "  " & $(i+1) & ". " & t
  while true:
    let input = staticExec("read -p 'Enter number (1-" & $lines.len & "): ' input && echo $input").strip
    let idx = input.parseInt - 1
    if idx >= 0 and idx < lines.len:
      return lines[idx]
    echo "  Invalid selection"

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

proc buildBinary(src, label: string, version: string, musl: bool = false, android: bool = false, staticLinux: bool = false, pulse: bool = false) =
  if not fileExists(src):
    echo "  " & src & " not found"
    return
  var flags = "-f -d:release" &
    " -d:GTM_VERSION:" & version &
    " -d:GTM_BUILD_TIME:"
  if musl:
    flags &= " --gcc.exe:musl-gcc --gcc.linkerexe:musl-gcc -d:staticFfmpeg -d:musl"
  if android:
    flags &= " -d:android --gcc.exe:cc --gcc.linkerexe:cc"
  if staticLinux:
    flags &= " -d:staticFfmpeg"
  if pulse:
    flags &= " -d:usePulseAudio"
  sh("nim c " & flags & " " & src)

  if android:
    let binName = "bin/" & label
    if fileExists("termux-elf-cleaner"):
      sh("termux-elf-cleaner " & binName)
    elif fileExists("/usr/bin/termux-elf-cleaner"):
      sh("/usr/bin/termux-elf-cleaner " & binName)
    else:
      echo "  ! termux-elf-cleaner not found — skipping ELF post-processing for " & binName

  echo ""

  echo "-- Git Hooks --"
  sh("git config core.hooksPath .githooks")

when isMainModule:
  var buildTui = false
  var buildDmd = false
  var buildMusl = false
  var buildAndroid = false
  var buildStaticLinux = false
  var buildPulse = false
  for i in 1..paramCount():
    let p = paramStr(i)
    if p == "-t": buildTui = true
    if p == "-d": buildDmd = true
    if p == "-m" or p == "--musl": buildMusl = true
    if p == "--android": buildAndroid = true
    if p == "--pulse": buildPulse = true
    if p == "--static-linux": buildStaticLinux = true
    if p.startsWith("--tag:"): forcedTag = p[6..^1]
    elif p == "--tag":
      if i < paramCount() - 1:
        forcedTag = paramStr(i+2)  # next arg is tag value
      else:
        forcedTag = selectTagInteractive()
  if not buildTui and not buildDmd:
    buildTui = true
    buildDmd = true

  echo ""
  echo "build gtm"
  echo ""

  let version = detectVersion()
  echo "  Version: " & version
  if buildMusl: echo "  Target: musl (static)"
  if buildAndroid: echo "  Target: android (static)"
  if buildPulse: echo "  PulseAudio: enabled"
  if buildStaticLinux: echo "  Target: linux (static FFmpeg)"
  echo ""

  echo "-- Prerequisites --"
  discard checkCmd("nim", "nim --version 2>/dev/null | head -1")
  if buildAndroid:
    discard  # Android (Termux/NDK) uses different toolchain
  elif buildStaticLinux:
    discard
  else:
    discard checkCmd("gcc", "gcc --version 2>/dev/null | head -1")
    discard checkCmd("dbus-1", "pkg-config --modversion dbus-1 2>/dev/null")
    discard checkCmd("viu", "viu --version 2>/dev/null")
  echo ""

  echo "-- Shell Completions --"
  if not buildAndroid:
    sh("nim r tools/gencompletions.nim completions")
  echo ""

  echo "-- Manpage --"
  if not buildAndroid:
    buildManpage(version)
  echo ""

  echo "-- Build --"
  if buildDmd:
    buildBinary(GTMD_SRC, "gtmd", version, musl = buildMusl, android = buildAndroid, staticLinux = buildStaticLinux, pulse = buildPulse)
  if buildTui:
    buildBinary(GTM_SRC, "gtm", version, musl = buildMusl, android = buildAndroid, staticLinux = buildStaticLinux, pulse = buildPulse)
  echo ""

  echo "-- Summary --"
  if fileExists("bin/gtm"):
    echo "  bin/gtm:  " & staticExec("ls -lh bin/gtm 2>/dev/null | cut -d' ' -f5").strip
  if fileExists("bin/gtmd"):
    echo "  bin/gtmd: " & staticExec("ls -lh bin/gtmd 2>/dev/null | cut -d' ' -f5").strip
  if fileExists(MAN_DST):
    echo "  " & MAN_DST & ": " & staticExec("ls -lh " & MAN_DST & " 2>/dev/null | cut -d' ' -f5").strip

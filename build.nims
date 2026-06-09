import os, strutils

const
  GTM_SRC = "src/gtm.nim"
  GTMD_SRC = "src/gtmd.nim"
  MAN_SRC = "docs/gtm.1.md"
  MAN_DST = "bin/gtm.1"

proc exec(cmd: string): bool =
  echo "  -> " & cmd
  let outp = staticExec(cmd)
  let ec = staticExec("echo $?").strip.parseInt  # unreliable in nims
  echo outp
  true

proc sh(cmd: string) =
  echo "  -> " & cmd
  discard staticExec(cmd)

proc checkCmd(name, test: string): bool =
  let r = staticExec(test).strip
  if r.len == 0:
    echo "  [WARN] " & name & " not found — skipping dependent steps"
    return false
  echo "  [OK]   " & name & ": " & r
  true

proc detectVersion: string =
  let tag = staticExec("git describe --tags --abbrev=0 2>/dev/null").strip
  if tag.len > 0:
    let dirty = staticExec("git diff --quiet HEAD 2>/dev/null || echo '-dirty'").strip
    result = tag & dirty
  else:
    result = staticExec("git rev-parse --short=7 HEAD 2>/dev/null").strip
  if result.len == 0: result = "0.0.0-dev"

proc detectBuildTime: string =
  staticExec("date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null").strip

proc buildManpage(version: string) =
  if not dirExists("bin"):
    mkDir("bin")
  if fileExists("bin/gtm.1"):
    echo "  [OK]   manpage already present: bin/gtm.1"
    return
  let hasPandoc = checkCmd("pandoc", "pandoc --version 2>/dev/null | head -1")
  if not hasPandoc:
    echo "  [SKIP] pandoc not found, manpage: bin/gtm.1 not generated"
    return
  if fileExists(MAN_SRC):
    sh("pandoc " & MAN_SRC & " -s -t man -o " & MAN_DST & " --variable=version:" & version)
    echo "  [OK]   manpage -> " & MAN_DST

proc buildBinary(src, label: string, version, buildTime: string) =
  if not fileExists(src):
    echo "  [SKIP] " & src & " not found"
    return
  let flags = "-d:release" &
    " -d:gtmVersion:" & version &
    " -d:gtmBuildTime:" & buildTime
  sh("nim c " & flags & " " & src & " 2>&1")

proc checkSyntax(src: string) =
  if not fileExists(src):
    echo "  [SKIP] " & src & " not found"
    return
  sh("nim check " & src & " 2>&1")

when isMainModule:
  echo ""
  echo "═══ gtm build script ═══"
  echo ""

  let version = detectVersion()
  let buildTime = detectBuildTime()
  echo "  Version: " & version
  echo "  Built:   " & buildTime
  echo ""

  # Stage 1: prerequisites
  echo "── Prerequisites ──"
  discard checkCmd("nim", "nim --version 2>/dev/null | head -1")
  discard checkCmd("gcc", "gcc --version 2>/dev/null | head -1")
  echo ""

  # Stage 2: manpage
  echo "── Manpage ──"
  buildManpage(version)
  echo ""

  # Stage 3: syntax check
  echo "── Syntax Check ──"
  checkSyntax(GTM_SRC)
  checkSyntax(GTMD_SRC)
  echo ""

  # Stage 4: build
  echo "── Build ──"
  buildBinary(GTMD_SRC, "gtmd", version, buildTime)
  buildBinary(GTM_SRC, "gtm", version, buildTime)
  echo ""

  # Stage 5: summary
  echo "── Summary ──"
  if fileExists("bin/gtm"):
    echo "  bin/gtm:  " & staticExec("ls -lh bin/gtm 2>/dev/null | cut -d' ' -f5").strip
  if fileExists("bin/gtmd"):
    echo "  bin/gtmd: " & staticExec("ls -lh bin/gtmd 2>/dev/null | cut -d' ' -f5").strip
  if fileExists(MAN_DST):
    echo "  " & MAN_DST & ": " & staticExec("ls -lh " & MAN_DST & " 2>/dev/null | cut -d' ' -f5").strip
  echo ""
  echo "═══ done ═══"

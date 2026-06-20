import os, strutils

switch("define", "gtm")
switch("outdir", "bin")
switch("define", "useFFmpeg")
switch("define", "useSqlite")
switch("define", "ssl")
switch("threads", "on")
switch("threadAnalysis", "off")

let projectDir = currentSourcePath().parentDir()

switch("path", projectDir / "src")
switch("path", projectDir / "vendor")
switch("path", projectDir / "vendor/nimwave")
switch("path", projectDir / "vendor/illwave")
switch("path", projectDir / "vendor/ansiutils")

proc gitVersion(): string =
  when defined(release):
    result = staticExec("git describe --tags --abbrev=0 2>/dev/null").strip()
    if result.len > 0: return
  result = staticExec("git rev-parse --short=7 HEAD 2>/dev/null").strip()
  if result.len == 0:
    result = "0.2.0"
switch("define", "gtmVersion:" & gitVersion())

when defined(useSqlite):
  switch("passC", "-I" & projectDir / "vendor/sqlite")

# Optional MPRIS support via libdbus-1 + nim-dbus (not on Android/Termux)
when not defined(android) and not defined(termux):
  when (staticExec("pkg-config --exists dbus-1 2>/dev/null && echo yes || echo no").strip == "yes"):
    switch("define", "useMpris")
    switch("passC", staticExec("pkg-config --cflags dbus-1").strip)
    switch("passL", staticExec("pkg-config --libs dbus-1").strip)
    # nim-dbus source path (cloned from https://github.com/zielmicha/nim-dbus)
    const nimDbusPath {.strdefine.} = "/tmp/nim-dbus"
    if dirExists(nimDbusPath):
      switch("path", nimDbusPath)

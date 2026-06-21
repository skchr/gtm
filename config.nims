import os, strutils

switch("define", "gtm")
switch("outdir", "bin")
switch("define", "useFFmpeg")
switch("define", "useSqlite")
switch("define", "ssl")

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

# MPRIS support via libdbus-1 + nim-dbus (vendored)
switch("define", "useMpris")
switch("path", projectDir / "vendor/nim-dbus")

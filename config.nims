import os, strutils

switch("define", "gtm")
switch("outdir", "bin")
switch("define", "useFFmpeg")
switch("define", "useSqlite")

let projectDir = currentSourcePath().parentDir()

switch("path", projectDir / "src")

proc findDepPath(name: string): string =
  let envVar = name.toUpperAscii() & "_PATH"
  if existsEnv(envVar):
    return getEnv(envVar)
  let relative = projectDir / ".." / ".." / "sources" / name / "src"
  if dirExists(relative):
    return relative
  for kind, dir in walkDir(getHomeDir() / ".nimble" / "pkgs"):
    if kind == pcDir and dir.startsWith(getHomeDir() / ".nimble" / "pkgs" / name):
      let srcDir = dir / "src"
      if dirExists(srcDir):
        return srcDir
  quit("Cannot find dependency '" & name & "'. Set the " & envVar & " environment variable or install the package via nimble.")

proc gitVersion(): string =
  when defined(release):
    result = staticExec("git describe --tags --abbrev=0 2>/dev/null").strip()
    if result.len > 0: return
  result = staticExec("git rev-parse --short=7 HEAD 2>/dev/null").strip()
  if result.len == 0:
    result = "0.2.0"
switch("define", "gtmVersion:" & gitVersion())

switch("path", findDepPath("nimwave"))
switch("path", findDepPath("illwave"))
switch("path", findDepPath("ansiutils"))

when defined(useSqlite):
  switch("passC", "-I" & projectDir / "vendor/sqlite")

# Optional MPRIS support via libdbus-1 + nim-dbus
when (staticExec("pkg-config --exists dbus-1 2>/dev/null && echo yes || echo no").strip == "yes"):
  switch("define", "useMpris")
  switch("passC", staticExec("pkg-config --cflags dbus-1").strip)
  switch("passL", staticExec("pkg-config --libs dbus-1").strip)
  # nim-dbus source path (cloned from https://github.com/zielmicha/nim-dbus)
  const nimDbusPath {.strdefine.} = "/tmp/nim-dbus"
  if dirExists(nimDbusPath):
    switch("path", nimDbusPath)

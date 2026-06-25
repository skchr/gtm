import os, strutils


when defined(android):
  let ndkDir = getEnv("ANDROID_NDK", "")
  if ndkDir.len > 0:
    let sysrootInc = ndkDir / "toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include"
    if dirExists(sysrootInc):
      switch("passC", "-I" & sysrootInc)

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

# MPRIS support via nim-dbus (vendored, uses dynlib at runtime)
switch("define", "useMpris")
switch("path", projectDir / "vendor/nim-dbus")

# Suppress vendor-library warnings (nim-dbus uses deprecated types)
switch("warning", "Deprecated:off")
switch("warning", "HoleEnumConv:off")
switch("warning", "CStringConv:off")
switch("warning", "XDeclaredButNotUsed:off")
switch("hint", "DuplicateModuleImport:off")

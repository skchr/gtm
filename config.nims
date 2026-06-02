import os

switch("define", "gtm")
switch("outdir", "bin")
switch("define", "useMiniAudio")
switch("define", "useSqlite")

let projectDir = currentSourcePath().parentDir()

switch("path", projectDir / "src")
switch("path", "/home/prjctimg/sources/nimwave/src")
switch("path", "/home/prjctimg/sources/illwave/src")
switch("path", "/home/prjctimg/sources/ansiutils/src")

when defined(useSqlite):
  switch("passC", "-I" & projectDir / "vendor/sqlite")

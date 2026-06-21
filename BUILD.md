# Building gtm from source

## Prerequisites

### Required build tools

| Tool | Version | Repository |
|------|---------|-----------|
| [Nim](https://nim-lang.org) | >= 2.0.0 | https://github.com/nim-lang/Nim |
| [GCC](https://gcc.gnu.org) (or clang) | any | https://github.com/gcc-mirror/gcc |
| [pkg-config](https://www.freedesktop.org/wiki/Software/pkg-config/) | any | https://github.com/pkgconf/pkgconf |

### Required system libraries

| Library | Linux | macOS |
|---------|-------|-------|
| FFmpeg (libavformat, libavcodec, libavutil, libswresample) | `libavformat-dev libavcodec-dev libavutil-dev libswresample-dev` | `ffmpeg` via Homebrew |
| [ALSA](https://www.alsa-project.org) | `libasound2-dev` | Not needed |
| [SQLite](https://www.sqlite.org) | Vendored (no system dep) | Vendored |
| [dbus-1](https://www.freedesktop.org/wiki/Software/dbus/) (optional, MPRIS) | `libdbus-1-dev` (runtime only) | Not needed |

FFmpeg: https://github.com/FFmpeg/FFmpeg
ALSA: https://github.com/alsa-project/alsa-lib
dbus: https://github.com/freedesktop/dbus

### Required vendor dependencies (bundled in `vendor/`)

| Library | Repository |
|---------|-----------|
| nimwave | https://github.com/juancarlospaco/nimwave |
| illwave | https://github.com/juancarlospaco/illwave |
| ansiutils | https://github.com/juancarlospaco/ansiutils |
| nim-dbus | https://github.com/zielmicha/nim-dbus |

All vendor dependencies are bundled directly under `vendor/`. No submodules or external clones needed.

### Runtime dependencies

| Tool | Purpose | Repository |
|------|---------|-----------|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | YouTube streaming, search, download | https://github.com/yt-dlp/yt-dlp |
| [spotDL](https://github.com/spotDL/spotify-downloader) (optional) | Spotify playlist import | https://github.com/spotDL/spotify-downloader |


### Optional build tools

| Tool | Purpose | Repository |
|------|---------|-----------|
| [pandoc](https://pandoc.org) | Generate manpage from markdown | https://github.com/jgm/pandoc |

## Build commands

```bash
# Build both TUI and daemon (release)
nim e build.nims

# Build TUI only
nim e build.nims -t

# Build daemon only
nim e build.nims -d

# Syntax checks
nim check src/gtm.nim
nim check src/gtmd.nim

# Regenerate manpages
nim r tools/genman.nim
```

## Platform-specific notes

### Linux (Debian/Ubuntu)

```bash
sudo apt-get install -y \
  libavformat-dev libavcodec-dev libavutil-dev \
  libswresample-dev libasound2-dev libdbus-1-dev
```

### macOS

```bash
brew install ffmpeg pkg-config
```

### Verifying a successful build

After building, the binaries are at `bin/gtm` and `bin/gtmd`:
```bash
ls -lh bin/gtm bin/gtmd
./bin/gtm --version
./bin/gtmd --help
```

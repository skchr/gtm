# gtm on Termux

## Prerequisites

```bash
pkg update && pkg upgrade
pkg install nim musl-ffmpeg musl-nim make git
pkg install yt-dlp    # optional — YouTube/Spotify playback
```

## Build

```bash
# Static musl build (recommended — single binary, no .so bundling)
nim e build.nims --termux

# Or dynamic build
nim c -d:release -d:android -d:gtmVersion:0.70.0 src/gtm.nim
nim c -d:release -d:android -d:gtmVersion:0.70.0 src/gtmd.nim
```

Binaries are written to `bin/gtm` and `bin/gtmd`.

## Configuration

gtm stores config at `~/.config/gtm/config.json` and data at `~/.local/share/gtm/`.

### Audio

On Termux, ALSA is not available. gtm falls back to a no-op audio stub.
To hear audio, you must have a working audio setup in Termux:

```bash
# If using termux-media-player:
termux-media-player play /path/to/audio.mp3

# In gtm, you can stream YouTube/Spotify via yt-dlp:
gtm https://youtube.com/watch?v=...
```

### Notifications

Termux does not support D-Bus desktop notifications.
gtm will gracefully skip notification sending on Android.

### Keyboard Mode

gtm auto-detects Termux and sets the keyboard mode to `kmTermux`.
This avoids Alt/Fn keybindings that may not work in Termux's keyboard layer.
You can change this in Settings → System → Keyboard Mode.

## Limitations

- **Audio**: No native ALSA/PulseAudio. Audio playback is via yt-dlp streaming or
  external media players.
- **MPRIS**: D-Bus MPRIS interface is disabled. Remote control from other apps is
  not available on Termux.
- **Desktop notifications**: Skipped on Android.
- **`pactl` device detection**: Not available — device name shows as "Android".

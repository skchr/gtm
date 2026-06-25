# gtm on Termux

## Prerequisites

```bash
pkg update && pkg upgrade
pkg install nim musl-ffmpeg musl-nim make git
pkg install yt-dlp    # optional — YouTube/Spotify playback
```

## Build

```bash
# Build with Android/Termux flags
nim e build.nims --android
```

Binaries are written to `bin/gtm` and `bin/gtmd`.

### ELF Post-Processing

Android 14+ requires Thread Local Storage (TLS) segments to be aligned to
at least 64 bytes on ARM64. The Nim compiler may generate 8-byte alignment,
which causes a runtime crash. Run `termux-elf-cleaner` on the compiled
binaries to fix this:

```bash
pkg install termux-elf-cleaner
termux-elf-cleaner bin/gtm bin/gtmd
```

The `build.nims --android` target runs `termux-elf-cleaner` automatically
if it is installed.

## Configuration

gtm stores config at `~/.config/gtm/config.json` and data at `~/.local/share/gtm/`.

### Keyboard Setup

Virtual keyboards lack physical Ctrl and Alt keys. Termux provides key
mappings to compensate:

- **Volume Down** acts as **Ctrl** (e.g., Volume Down+C = Ctrl+C)
- **Volume Up + W/A/S/D** sends arrow keys

For one-touch access to Esc, Tab, and arrow keys, add an extra-keys row:

```bash
cp docs/termux.properties.example ~/.termux/termux.properties
# Then restart Termux or run: termux-reload-settings
```

If your mobile keyboard buffers keystrokes and disrupts TUI interaction,
ensure `enforce-char-based-input=true` is set in `termux.properties`.

### Music Directory

gtm checks `/sdcard/Music` first on Termux (via `$HOME/storage/shared/Music`).
If not found, it falls back to `$HOME/Music`. Run `termux-setup-storage` to
access shared storage.

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

### System Info

The About tab shows system information (OS, CPU, memory, tool versions).
On Termux, `/etc/os-release` is not available, so the OS line may be empty.
Tool versions (nim, ffmpeg, yt-dlp, etc.) are queried at runtime and will
appear if the corresponding packages are installed.

## Limitations

- **Audio**: No native ALSA/PulseAudio. Audio playback is via yt-dlp streaming or
  external media players.
- **MPRIS**: D-Bus MPRIS interface is disabled. Remote control from other apps is
  not available on Termux.
- **Desktop notifications**: Skipped on Android.
- **`pactl` device detection**: Not available — device name shows as "Android".
- **System info**: OS and some hardware details may not be detectable on Android.

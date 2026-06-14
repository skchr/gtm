% GTM(1) User Manuals
% prjctimg
% v0.2.0

# NAME

gtm - terminal music player with YouTube integration, crossfade

# SYNOPSIS

| `gtm` [*options*] [*file*...]
| `gtm` *command* [*args*...]
| `gtmd` [*options*]

# DESCRIPTION

**gtm** is a terminal-based music player. It supports local audio files,
YouTube streaming, playlist management, album art display, and gapless crossfade playback.

The player is split into two binaries:

`gtm`
:   Terminal UI client — renders the player interface and accepts keyboard
    input.

`gtmd`
:   Background daemon — owns audio playback (FFmpeg + ALSA), manages the
    music library (SQLite), and communicates with the TUI over a Unix
    socket at `/tmp/gtm-daemon.sock`.

# OPTIONS

`--debug`
:   Enable debug logging to stderr.

`--help`
:   Display help and exit.

`--version`
:   Display version and exit.

# COMMANDS

When invoked with a subcommand, **gtm** operates in headless mode:

`play` *url*|*file*
:   Play the given URL or file immediately.

`enqueue` *url*|*file*
:   Add the given URL or file to the playback queue.

`pause`
:   Toggle pause on the currently playing track.

`next`
:   Skip to the next track.

`prev`
:   Go back to the previous track.

`stop`
:   Stop playback.

`volume` *level*
:   Set volume (0-100).

`status`
:   Print current playback status as JSON.

`list-playlists`
:   List saved playlists.

# TUI KEYBINDINGS

## Playback
`Space`
:   Toggle play/pause.

`n`
:   Next track.

`p`
:   Previous track.

`s`
:   Stop playback.

`.` / `Right`
:   Seek forward 5 seconds.

`,` / `Left`
:   Seek backward 5 seconds.

`Shift+J` / `+`
:   Volume up 5%.

`Shift+K` / `-`
:   Volume down 5%.

`m`
:   Toggle mute.

## Navigation
`j` / `Down`
:   Move selection down.

`k` / `Up`
:   Move selection up.

`g` `g`
:   Jump to first item.

`Shift+G`
:   Jump to last item.

`/`
:   Enter filter/search mode.

`Enter`
:   Play selected item.

## Tabs
`1`
:   Now Playing tab.

`2`
:   Library tab.

`3`
:   Playlists tab.

`4`
:   Settings tab.

## Selection
`v`
:   Enter/exit multi-select mode.

`Shift+X`
:   Remove selected items.

`Shift+A`
:   Add selected items to playlist.

## Playlists
`a`
:   Create playlist.

`d`
:   Delete playlist.

`r`
:   Rename playlist.

## System
`?`
:   Toggle help overlay.

`:`
:   Command palette.

`Shift+T`
:   Cycle theme.

`q`
:   Quit TUI (daemon stays running).

`Shift+Q`
:   Quit and stop daemon.

`Shift+S`
:   Toggle shuffle.

`Shift+R`
:   Cycle repeat mode (Off → All → One).

# FILES

`~/.config/gtm/config.json`
:   User configuration file (theme, volume, crossfade, etc.).

`~/.config/gtm/gtm.sqlite`
:   SQLite database (music library, playlists, queue).

`/tmp/gtm-daemon.sock`
:   Unix socket for TUI-daemon communication.


# ENVIRONMENT

`HOME`
:   Used to locate the configuration directory and default `~/Music`
    library path.

`TERM`
:   Terminal type for true-color detection.

# BUGS

Report bugs and feature requests at:
<https://github.com/prjctimg/gtm/issues>

# SEE ALSO

`gtmd`(1), `ffplay`(1), `yt-dlp`(1), `viu`(1)

# fish completion for gtm
function __gtm_list_audio_files
    set -l dir (commandline -ct)
    if test -z "$dir"
        set dir "."
    end
    set -l parent (dirname $dir)
    if test "$parent" = "."
        set parent "."
    end
    for f in $parent/*.{mp3,flac,ogg,m4a,wav,opus,aac,wma,alac,aiff,ape}
        if test -f "$f"
            echo (basename "$f")
        end
    end
end

complete -c gtm -f
complete -c gtm -n "__fish_use_subcommand" -a "play" -d "Play a file or URL"
complete -c gtm -n "__fish_use_subcommand" -a "pause" -d "Pause playback"
complete -c gtm -n "__fish_use_subcommand" -a "stop" -d "Stop playback"
complete -c gtm -n "__fish_use_subcommand" -a "next" -d "Skip to next track"
complete -c gtm -n "__fish_use_subcommand" -a "prev" -d "Skip to previous track"
complete -c gtm -n "__fish_use_subcommand" -a "toggle" -d "Toggle play/pause"
complete -c gtm -n "__fish_use_subcommand" -a "volume" -d "Get or set volume (0-100)"
complete -c gtm -n "__fish_use_subcommand" -a "shuffle" -d "Toggle shuffle mode"
complete -c gtm -n "__fish_use_subcommand" -a "repeat" -d "Cycle repeat mode"
complete -c gtm -n "__fish_use_subcommand" -a "sleep" -d "Set sleep timer (minutes)"
complete -c gtm -n "__fish_use_subcommand" -a "status" -d "Show playback status"
complete -c gtm -n "__fish_use_subcommand" -a "now" -d "Show now-playing track"
complete -c gtm -n "__fish_use_subcommand" -a "kill" -d "Kill the daemon"
complete -c gtm -n "__fish_use_subcommand" -a "daemon" -d "Run daemon in foreground"
complete -c gtm -n "__fish_use_subcommand" -a "help" -d "Show this help"
complete -c gtm -n "__fish_use_subcommand" -a "version" -d "Show version"
complete -c gtm -n "__fish_seen_subcommand_from play" -k -a "(__gtm_list_audio_files)"
complete -c gtm -n "__fish_seen_subcommand_from play" -l "music-dir" -d "Music directory" -r

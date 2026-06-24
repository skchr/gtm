# bash completion for gtm
_gtm_completions() {
    local cur prev words cword
    _init_completion || return

    local subcommands="play pause stop next prev toggle volume shuffle repeat sleep status now kill daemon help version"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
        return 0
    fi

    if [[ $cword -ge 2 && ${words[1]} == "play" ]]; then
        local music_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gtm/audio"
        if [[ -d "$music_dir" ]]; then
            while IFS= read -r -d '' f; do
                COMPREPLY+=("$(basename "$f")")
            done < <(find "$music_dir" -type f \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.m4a' -o -iname '*.wav' -o -iname '*.opus' -o -iname '*.aac' -o -iname '*.wma' -o -iname '*.alac' -o -iname '*.aiff' -o -iname '*.ape' \) -printf '%f\0' 2>/dev/null)
        fi
        COMPREPLY+=($(compgen -f -- "$cur"))
        return 0
    fi
}

complete -F _gtm_completions gtm

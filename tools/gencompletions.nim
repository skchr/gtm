import os

const subcommands* = @[
  "play", "pause", "stop", "next", "prev", "toggle",
  "volume", "shuffle", "repeat", "sleep",
  "status", "now", "kill", "daemon", "help", "version"
]

const subcommandDescs*: array[16, string] = [
  "Play a file or URL",
  "Pause playback",
  "Stop playback",
  "Skip to next track",
  "Skip to previous track",
  "Toggle play/pause",
  "Get or set volume (0-100)",
  "Toggle shuffle mode",
  "Cycle repeat mode",
  "Set sleep timer (minutes)",
  "Show playback status",
  "Show now-playing track",
  "Kill the daemon",
  "Run daemon in foreground",
  "Show this help",
  "Show version"
]

proc genFish(dir: string) =
  let content = """# fish completion for gtm
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
"""
  writeFile(dir / "gtm.fish", content)

proc genZsh(dir: string) =
  let content = """# zsh completion for gtm
#compdef gtm

_gtm_audio_files() {
    local -a files
    files=(${~1}/*.{mp3,flac,ogg,m4a,wav,opus,aac,wma,alac,aiff,ape}(N.))
    _files -W "$1" -g "*.($(IFS='|'; echo ${(j:|:)${(@)${(@)files:t}%.*}}))"
}

_gtm() {
    local -a subcommands
    subcommands=(
        'play:Play a file or URL'
        'pause:Pause playback'
        'stop:Stop playback'
        'next:Skip to next track'
        'prev:Skip to previous track'
        'toggle:Toggle play/pause'
        'volume:Get or set volume (0-100)'
        'shuffle:Toggle shuffle mode'
        'repeat:Cycle repeat mode'
        'sleep:Set sleep timer (minutes)'
        'status:Show playback status'
        'now:Show now-playing track'
        'kill:Kill the daemon'
        'daemon:Run daemon in foreground'
        'help:Show this help'
        'version:Show version'
    )

    _arguments -C \
        '1: :->subcmd' \
        '*: :->args' && return 0

    case $state in
        subcmd)
            _describe 'subcommand' subcommands
            ;;
        args)
            case $words[1] in
                play)
        local music_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gtm/audio"
                    _alternative \
                        "files:audio file:_files -W \"$music_dir\" -g \"*.(${music_extensions:-mp3|flac|ogg|m4a|wav|opus|aac|wma|alac|aiff|ape})\"" \
                        'url:URL:(http https)'
                    ;;
            esac
            ;;
    esac
}

_gtm "$@"
"""
  writeFile(dir / "_gtm", content)

proc genBash(dir: string) =
  let content = """# bash completion for gtm
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
"""
  writeFile(dir / "gtm.bash", content)

proc genElvish(dir: string) =
  let content = """# elvish completion for gtm
set edit:completion:arg-completer[gtm] = {|@args|
    var subcommands = [play pause stop next prev toggle volume shuffle repeat sleep status now kill daemon help version]
    var subcmd-descs = [
        &play=  'Play a file or URL'
        &pause= 'Pause playback'
        &stop=  'Stop playback'
        &next=  'Skip to next track'
        &prev=  'Skip to previous track'
        &toggle='Toggle play/pause'
        &volume='Get or set volume (0-100)'
        &shuffle='Toggle shuffle mode'
        &repeat='Cycle repeat mode'
        &sleep= 'Set sleep timer (minutes)'
        &status='Show playback status'
        &now=   'Show now-playing track'
        &kill=  'Kill the daemon'
        &daemon='Run daemon in foreground'
        &help=  'Show this help'
        &version='Show version'
    ]
    if (eq (count $args) 1) {
        edit:complex-candidate $args[0] &display-suffix=' '$subcmd-descs[$args[0]]
        (each {|cmd| edit:complex-candidate $cmd &display-suffix=' '$subcmd-descs[$cmd] } $subcommands)
    } elif (eq (count $args) 2) {
        if (eq $args[1] play) {
            edit:arg-completer[gtm] $@args
        }
    }
}
"""
  writeFile(dir / "gtm.elv", content)

proc genNu(dir: string) =
  let content = """# nushell completion for gtm
module completions {
    export extern gtm [
        subcommand?: string@"gtm subcommands"
        ...args: string
    ]

    def "gtm subcommands" [] {
        [
            { value: "play", description: "Play a file or URL" }
            { value: "pause", description: "Pause playback" }
            { value: "stop", description: "Stop playback" }
            { value: "next", description: "Skip to next track" }
            { value: "prev", description: "Skip to previous track" }
            { value: "toggle", description: "Toggle play/pause" }
            { value: "volume", description: "Get or set volume (0-100)" }
            { value: "shuffle", description: "Toggle shuffle mode" }
            { value: "repeat", description: "Cycle repeat mode" }
            { value: "sleep", description: "Set sleep timer (minutes)" }
            { value: "status", description: "Show playback status" }
            { value: "now", description: "Show now-playing track" }
            { value: "kill", description: "Kill the daemon" }
            { value: "daemon", description: "Run daemon in foreground" }
            { value: "help", description: "Show this help" }
            { value: "version", description: "Show version" }
        ]
    }
}
"""
  writeFile(dir / "gtm.nu", content)

proc genXonsh(dir: string) =
  let content = """# xonsh completion for gtm
from xonsh.completers.tools import *

_GTM_SUBCOMMANDS = {
    'play': 'Play a file or URL',
    'pause': 'Pause playback',
    'stop': 'Stop playback',
    'next': 'Skip to next track',
    'prev': 'Skip to previous track',
    'toggle': 'Toggle play/pause',
    'volume': 'Get or set volume (0-100)',
    'shuffle': 'Toggle shuffle mode',
    'repeat': 'Cycle repeat mode',
    'sleep': 'Set sleep timer (minutes)',
    'status': 'Show playback status',
    'now': 'Show now-playing track',
    'kill': 'Kill the daemon',
    'daemon': 'Run daemon in foreground',
    'help': 'Show this help',
    'version': 'Show version',
}

_AUDIO_EXTS = ('mp3', 'flac', 'ogg', 'm4a', 'wav', 'opus', 'aac', 'wma', 'alac', 'aiff', 'ape')

def _gtm_completer(prefix, line, beg, end, ctx):
    import os
    from pathlib import Path
    parts = line.split()
    if len(parts) <= 1:
        return {k + ' -- ' + v for k, v in _GTM_SUBCOMMANDS.items() if k.startswith(prefix)}
    if len(parts) == 2 and parts[1] == 'play':
        music_dir = os.path.join(os.environ.get('XDG_DATA_HOME', os.path.expanduser('~/.local/share')), 'gtm', 'audio')
        p = Path(music_dir)
        if p.is_dir():
            return {str(f.relative_to(p)) for f in p.rglob('*') if f.suffix.lower()[1:] in _AUDIO_EXTS and str(f.relative_to(p)).startswith(prefix)}
    return set()

completer.register('gtm', _gtm_completer)
"""
  writeFile(dir / "gtm_xonsh.py", content)

proc genAll*(outputDir: string) =
  createDir(outputDir)
  genFish(outputDir)
  genZsh(outputDir)
  genBash(outputDir)
  genElvish(outputDir)
  genNu(outputDir)
  genXonsh(outputDir)
  echo "Generated shell completions in: " & outputDir

when isMainModule:
  let outDir = if paramCount() > 0: paramStr(1) else: "completions"
  genAll(outDir)

# elvish completion for gtm
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

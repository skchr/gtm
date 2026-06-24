# nushell completion for gtm
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

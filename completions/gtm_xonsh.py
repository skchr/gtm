# xonsh completion for gtm
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

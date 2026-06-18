# gtm documentation system

## Overview

All documentation is generated from source code. Manpages are produced by
`tools/genman.nim`, which extracts command definitions, keybindings, and
examples directly from the Nim source files.

## Manpages

Two manpages are generated:

| Source file | Manpage source | Final output |
|-------------|---------------|--------------|
| `src/cli.nim`, `src/gtm.nim`, `tools/docs.nim` | `docs/gtm.1.md` | `bin/gtm.1` |
| `src/daemon.nim`, `src/audio.nim`, `tools/docs.nim` | `docs/gtmd.1.md` | `bin/gtmd.1` |

## How it works

`tools/genman.nim` parses source code to extract:

| Data | Source | Method |
|------|--------|--------|
| CLI subcommands (15) | `src/cli.nim` | Hardcoded table matching `parseSubcmd` wire names |
| TUI commands (47) | `src/gtm.nim` | Parses `registerCommand()` call sites |
| Daemon commands (72) | `src/daemon.nim` | Parses `parseDaemonCommand` case branches + `executeCommand` |
| Audio events (11) | `src/audio.nim` | Parses `AudioEventKind` enum |
| Examples | `tools/docs.nim` | `DocExample` objects with title, code, request/response |

### Examples

Example code blocks are defined as `DocExample` objects in `tools/docs.nim`.
These are split into three groups:

- `cliExamples()` — CLI usage examples (bash)
- `daemonExamples()` — daemon IPC examples (socat, shell scripts, Nim socket API)
- `lyricsExamples()` — LRC parsing examples
- `audioExamples()` — audio processing examples

## Updating documentation

### Regenerate manpages

```bash
nim r tools/genman.nim
```

### Automatic regeneration on push

A pre-push git hook (`.githooks/pre-push`) automatically regenerates manpages
before every push. It runs `nim r tools/genman.nim` and stages+commits any
changes to `docs/gtm.1.md` and `docs/gtmd.1.md`.

To skip this hook for a push:

```bash
git push --no-verify
```

### Adding a new CLI subcommand

1. Add the entry to `src/cli.nim` (in the `parseSubcmd` case and `execSubcommand`
   proc).
2. Update the hardcoded table in `tools/genman.nim`'s `extractCliSubcmds()`.
3. Optionally add a `DocExample` in `tools/docs.nim`.
4. Regenerate: `nim r tools/genman.nim`.

### Adding a new TUI command

1. Call `registerCommand(id, name, desc, keys, handler)` in `src/gtm.nim`.
2. The generator picks it up automatically via `extractTuiCommands()`.
3. Regenerate: `nim r tools/genman.nim`.

### Adding a new daemon command

1. Add the wire name to the `DaemonCommandKind` enum in `src/daemon.nim`.
2. Add the case to `parseDaemonCommand` and `executeCommand`.
3. The generator picks it up automatically via `extractDaemonCommands()`.
4. Regenerate: `nim r tools/genman.nim`.

### Adding examples

Add `DocExample` objects to `tools/docs.nim` in the appropriate proc:
`cliExamples()`, `daemonExamples()`, `lyricsExamples()`, or `audioExamples()`.

### Format reference

Manpage source files use Pandoc markdown (roff-compatible via `pandoc -s -t man`).

| Element | Pandoc syntax |
|---------|---------------|
| Section heading | `# NAME` |
| Subsection | `## Subsection` |
| Bold | `**text**` |
| Code | `` `code` `` |
| Code block | ```` ```lang … ``` ```` |
| List | `- item` |
| Definition list | `term` then `:   definition` |

## Test coverage

Documentation examples are validated by `tests/test_examples.nim`:

- Every CLI example with `request`/`response` fields is checked for valid IPC structure
- Every daemon example is checked for protocol compliance
- LRC examples are parsed and verified against expected output
- Crossfade example parity is checked against audio calculations

```bash
nim r --path:src tests/test_examples.nim
```

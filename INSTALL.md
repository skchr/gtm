# Installing gtm

## One-liner (requires published releases)

```bash
curl -sf https://raw.githubusercontent.com/skchr/gtm/main/install.sh | sh
```

Override version or prefix:

```bash
VERSION=0.5.3 PREFIX=/usr/local curl -sf https://raw.githubusercontent.com/skchr/gtm/main/install.sh | sh
```

The install script supports Linux (amd64, arm64) and macOS (amd64, arm64).

## From source

See [BUILD.md](BUILD.md) for full build dependencies.

```bash
# Build both binaries
nim e build.nims

# Install to ~/.local/bin
cp bin/gtm  ~/.local/bin/gtm
cp bin/gtmd ~/.local/bin/gtmd
```

## Post-install

Ensure the install directory is in your `PATH`:

```bash
# For ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"

# For /usr/local/bin (usually already in PATH)
```

### Runtime requirements

- Linux with `/dev/shm` (for the visualizer)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) for YouTube streaming
- True-color terminal recommended
- Nerd Font optional (emoji fallback provided)

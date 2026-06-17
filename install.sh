#!/bin/sh
# gtm — one-line install script
# Usage: curl -sf https://raw.githubusercontent.com/skchr/gtm/main/install.sh | sh
#
# Environment variables:
#   VERSION  – release tag to install (default: latest)
#   PREFIX   – install directory prefix (default: $HOME/.local)
#
# NOTE: This script downloads release artifacts from GitHub.
# No CI/CD is set up yet — ask the maintainer to publish builds before using.
set -eu

REPO="prjctimg/gtm"
VERSION="${VERSION:-latest}"
PREFIX="${PREFIX:-$HOME/.local}"

# --- Platform detection ---
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
linux) ;;
darwin) ;;
*)
  echo "gtm does not support '$OS' yet. Expected Linux or Darwin"
  exit 1
  ;;

esac

case "$ARCH" in
x86_64 | amd64) ARCH="amd64" ;;
aarch64 | arm64) ARCH="arm64" ;;
*)
  echo "gtm: unsupported architecture '$ARCH' (expected amd64 or arm64)"
  exit 1
  ;;
esac

if [ "$VERSION" = "latest" ]; then
  DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/gtm-${OS}-${ARCH}.tar.gz"
else
  DOWNLOAD_URL="https://github.com/$REPO/releases/download/v${VERSION}/gtm-${OS}-${ARCH}.tar.gz"
fi

# --- Temp directory ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "gtm: downloading $DOWNLOAD_URL"
curl -#fL "$DOWNLOAD_URL" -o "$TMPDIR/gtm.tar.gz"

echo "gtm: extracting"
tar xzf "$TMPDIR/gtm.tar.gz" -C "$TMPDIR"

echo "gtm: installing to $PREFIX/bin/"
mkdir -p "$PREFIX/bin"
cp "$TMPDIR/gtm" "$PREFIX/bin/gtm"
cp "$TMPDIR/gtmd" "$PREFIX/bin/gtmd"
chmod +x "$PREFIX/bin/gtm" "$PREFIX/bin/gtmd"

echo "gtm: done — installed successfully"
echo "  gtm  -> $PREFIX/bin/gtm"
echo "  gtmd -> $PREFIX/bin/gtmd"
echo "Make sure $PREFIX/bin is in your \$PATH"
echo ""

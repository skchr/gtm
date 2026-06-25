TERMUX_PKG_HOMEPAGE=https://github.com/skchr/gtm
TERMUX_PKG_DESCRIPTION="Terminal-based music player, library manager, and streamer with Spotify and YouTube support"
TERMUX_PKG_LICENSE=MIT
TERMUX_PKG_MAINTAINER=@skchr
TERMUX_PKG_SRCURL=https://github.com/skchr/gtm/archive/refs/tags/v${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=SKIP
TERMUX_PKG_DEPENDS="nim, musl-ffmpeg, musl-nim"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXTRA_MAKE_ARGS="--android"
TERMUX_PKG_AUTO_UPDATE=true

termux_step_make() {
	nim e build.nims --android
}

termux_step_make_install() {
	install -Dm755 bin/gtm  $TERMUX_PREFIX/bin/gtm
	install -Dm755 bin/gtmd $TERMUX_PREFIX/bin/gtmd
}

# gtm Android cross-compilation image
# Build:   docker build -t ghcr.io/skchr/gtm-android-builder:latest .
# Push:    docker push ghcr.io/skchr/gtm-android-builder:latest
# Use:     docker run --rm -v $PWD:/src ghcr.io/skchr/gtm-android-builder:latest \
#            nim c -d:release -d:android \
#              --gcc.exe:aarch64-linux-android21-clang \
#              --gcc.linkerexe:aarch64-linux-android21-clang \
#            src/gtmd.nim

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl ca-certificates unzip pkg-config nasm \
    libc6-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Nim 2.2.2 (pick arch: x86_64 → linux_x64, aarch64 → linux_arm64)
RUN ARCH_NIM="$(uname -m)" && \
    case "$ARCH_NIM" in \
      x86_64|amd64) NIM_ARCH="x64" ;; \
      aarch64|arm64) NIM_ARCH="arm64" ;; \
      *) echo "Unknown arch $ARCH_NIM"; exit 1 ;; \
    esac && \
    curl -sL "https://nim-lang.org/download/nim-2.2.2-linux_${NIM_ARCH}.tar.xz" -o /tmp/nim.tar.xz \
    && tar xJf /tmp/nim.tar.xz -C /opt \
    && mv /opt/nim-2.2.2 /opt/nim \
    && rm /tmp/nim.tar.xz
ENV PATH=/opt/nim/bin:$PATH

# Download Android NDK r27c
RUN curl -sL https://dl.google.com/android/repository/android-ndk-r27c-linux.zip -o /tmp/ndk.zip \
    && unzip -q /tmp/ndk.zip -d /opt \
    && rm /tmp/ndk.zip
ENV ANDROID_NDK=/opt/android-ndk-r27c
ENV NDK_TOOLCHAIN=$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64
ENV PATH=$NDK_TOOLCHAIN/bin:$PATH

# Build FFmpeg 7.1 statically for aarch64-android
RUN curl -sL https://ffmpeg.org/releases/ffmpeg-7.1.tar.gz -o /tmp/ffmpeg.tar.gz \
    && tar xzf /tmp/ffmpeg.tar.gz -C /tmp \
    && cd /tmp/ffmpeg-7.1 \
    && ./configure --enable-static --disable-shared --enable-pic \
       --enable-cross-compile \
       --prefix=/opt/ffmpeg-android \
       --target-os=android --arch=aarch64 \
       --cc=aarch64-linux-android21-clang \
       --cxx=aarch64-linux-android21-clang++ \
       --ar=llvm-ar --ranlib=llvm-ranlib --strip=llvm-strip \
       --ld=aarch64-linux-android21-clang \
       --disable-programs --disable-doc \
       --disable-encoders --disable-muxers --disable-devices --disable-filters \
       --disable-bsfs --disable-postproc --disable-network \
       --enable-decoder='mp3*,aac*,flac,vorbis,opus,pcm*,wmav*,wmapro,ape,wavpack,tta,alac,dca,dts*,ac3*,eac3,truehd,dsd*,cook,speex,nellymoser,adpcm*,atrac3*,mlp,sipr,tak,twinvq,binkaudio*,mp1,mp2,qdm2,qdmc,mace*,g723*,g729,gsm*' \
       --enable-demuxer='*' --enable-parsers --enable-protocol=file \
       --enable-swresample \
    && make -j$(nproc) \
    && make install \
    && cd / && rm -rf /tmp/ffmpeg*

ENV PKG_CONFIG_PATH=/opt/ffmpeg-android/lib/pkgconfig
ENV CC=aarch64-linux-android21-clang
ENV CXX=aarch64-linux-android21-clang++
ENV LD=aarch64-linux-android21-clang
ENV AR=llvm-ar
ENV RANLIB=llvm-ranlib
ENV STRIP=llvm-strip

WORKDIR /src
CMD ["/bin/bash"]

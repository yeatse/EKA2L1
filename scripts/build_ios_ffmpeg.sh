#!/usr/bin/env bash
#
# Build the bundled FFmpeg source for iOS without dirtying the submodule.
#
# Usage:
#   scripts/build_ios_ffmpeg.sh simulator
#   scripts/build_ios_ffmpeg.sh device
#   scripts/build_ios_ffmpeg.sh all

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_SRC="${ROOT_DIR}/src/external/ffmpeg"
DEPLOYMENT_TARGET="${EKA2L1_IOS_DEPLOYMENT_TARGET:-16.0}"
JOBS="${EKA2L1_IOS_FFMPEG_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

common_configure_flags=(
    --disable-everything
    --disable-shared
    --enable-static
    --enable-pic
    --disable-asm
    --disable-avdevice
    --disable-filters
    --disable-programs
    --disable-network
    --disable-avfilter
    --disable-postproc
    --disable-encoders
    --disable-doc
    --disable-ffplay
    --disable-ffprobe
    --disable-ffmpeg
    --enable-zlib
    --enable-decoder=h264
    --enable-decoder=mpeg4
    --enable-decoder=h263
    --enable-decoder=h263p
    --enable-decoder=mpeg2video
    --enable-decoder=mjpeg
    --enable-decoder=mjpegb
    --enable-decoder=aac
    --enable-decoder=aac_latm
    --enable-decoder=wavpack
    --enable-decoder=amrnb
    --enable-decoder=amrwb
    --enable-decoder=mp3
    --enable-decoder=pcm_s16le
    --enable-decoder=pcm_s8
    --enable-demuxer=h264
    --enable-demuxer=m4v
    --enable-demuxer=mp3
    --enable-demuxer=mpegvideo
    --enable-demuxer=mpegps
    --enable-demuxer=mjpeg
    --enable-demuxer=mov
    --enable-demuxer=avi
    --enable-demuxer=aac
    --enable-demuxer=amr
    --enable-demuxer=amrnb
    --enable-demuxer=amrwb
    --enable-demuxer=pcm_s16le
    --enable-demuxer=pcm_s8
    --enable-demuxer=wav
    --enable-encoder=pcm_s16le
    --enable-muxer=amr
    --enable-muxer=avi
    --enable-muxer=mp3
    --enable-muxer=wav
    --enable-muxer=pcm_s16le
    --enable-muxer=pcm_s8
    --enable-muxer=ogg
    --enable-parser=h264
    --enable-parser=mpeg4video
    --enable-parser=mpegvideo
    --enable-parser=aac
    --enable-parser=aac_latm
    --enable-parser=mpegaudio
    --enable-protocol=file
)

build_one() {
    local label="$1"
    local sdk="$2"
    local min_flag="$3"
    local prefix="${ROOT_DIR}/build/ios-${label}/ios-ffmpeg"
    local build_dir="${ROOT_DIR}/build/ios-${label}/ffmpeg-build"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"

    mkdir -p "${build_dir}"
    pushd "${build_dir}" >/dev/null

    echo "==> Configuring FFmpeg for iOS ${label} (${sdk})"
    "${FFMPEG_SRC}/configure" \
        --prefix="${prefix}" \
        --target-os=darwin \
        --arch=arm64 \
        --cpu=armv8-a \
        --cc="$(xcrun --sdk "${sdk}" -f clang)" \
        --cxx="$(xcrun --sdk "${sdk}" -f clang++)" \
        --sysroot="${sdk_path}" \
        --enable-cross-compile \
        --extra-cflags="-arch arm64 -isysroot ${sdk_path} ${min_flag}=${DEPLOYMENT_TARGET} -Os -D__STDC_CONSTANT_MACROS" \
        --extra-ldflags="-arch arm64 -isysroot ${sdk_path} ${min_flag}=${DEPLOYMENT_TARGET}" \
        "${common_configure_flags[@]}"

    echo "==> Building FFmpeg for iOS ${label}"
    make -j"${JOBS}"
    make install
    popd >/dev/null
}

case "${1:-all}" in
    simulator)
        build_one simulator iphonesimulator -mios-simulator-version-min
        ;;
    device)
        build_one device iphoneos -miphoneos-version-min
        ;;
    all|"")
        build_one device iphoneos -miphoneos-version-min
        build_one simulator iphonesimulator -mios-simulator-version-min
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Usage: $0 [device|simulator|all]" >&2
        exit 2
        ;;
esac

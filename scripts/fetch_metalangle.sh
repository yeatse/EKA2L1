#!/usr/bin/env bash
#
# Fetch + package the MetalANGLE (GLES -> Metal) prebuilt as an iOS xcframework
# for the ANGLE-over-Metal backend (see docs/ios_metal_angle_plan.md).
#
# Produces: src/external/metalangle/MetalANGLE.xcframework  (ios-arm64 device +
# ios-arm64-simulator), arm64-only.
#
# Why this script exists (and isn't a plain download): the upstream MetalANGLE
# release ships per-platform *fat* frameworks whose arm64 *simulator* slice is
# tagged with the legacy LC_VERSION_MIN_IPHONEOS load command (no simulator
# platform). Modern dyld then refuses to load it into an arm64 iOS Simulator
# process. We thin to arm64 and rewrite that slice's load command to
# LC_BUILD_VERSION platform=7 (iOS Simulator) with `vtool`, then repackage.
#
# Re-run this to regenerate the vendored xcframework from scratch.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

TAG="${METALANGLE_TAG:-gles3-0.0.8}"
BASE="https://github.com/kakashidinho/metalangle/releases/download/${TAG}"
STAGE="${ROOT_DIR}/.angle_stage"
OUT="${ROOT_DIR}/src/external/metalangle/MetalANGLE.xcframework"

# minos / sdk stamped into the re-tagged simulator slice.
SIM_MINOS="${SIM_MINOS:-12.0}"
SIM_SDK="${SIM_SDK:-18.0}"

mkdir -p "${STAGE}"
cd "${STAGE}"

echo "==> downloading MetalANGLE ${TAG} (device + simulator frameworks)"
curl -fSL --retry 3 -o sim.zip "${BASE}/MetalANGLE.framework.ios.simulator.zip"
curl -fSL --retry 3 -o dev.zip "${BASE}/MetalANGLE.framework.ios.zip"

/bin/rm -rf sim dev simfx devfx
unzip -oq sim.zip -d sim
unzip -oq dev.zip -d dev

echo "==> simulator slice: thin -> arm64, re-tag as iOS-Simulator (platform 7)"
mkdir -p simfx
cp -R sim/MetalANGLE.framework simfx/
lipo sim/MetalANGLE.framework/MetalANGLE -thin arm64 -output simfx_arm64.bin
vtool -arch arm64 -set-build-version 7 "${SIM_MINOS}" "${SIM_SDK}" -replace \
    -output simfx/MetalANGLE.framework/MetalANGLE simfx_arm64.bin

echo "==> device slice: thin -> arm64"
mkdir -p devfx
cp -R dev/MetalANGLE.framework devfx/
lipo dev/MetalANGLE.framework/MetalANGLE -thin arm64 -output devfx/MetalANGLE.framework/MetalANGLE

echo "==> creating ${OUT}"
/bin/rm -rf "${OUT}"
mkdir -p "$(dirname "${OUT}")"
xcodebuild -create-xcframework \
    -framework devfx/MetalANGLE.framework \
    -framework simfx/MetalANGLE.framework \
    -output "${OUT}"

echo "==> done:"
plutil -p "${OUT}/Info.plist" | grep -iE "LibraryIdentifier|SupportedPlatformVariant" || true
du -sh "${OUT}"

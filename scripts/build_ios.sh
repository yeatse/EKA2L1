#!/usr/bin/env bash
#
# Stage-0 iOS build validation script.
#
# Generates Xcode projects under build/ios-device and build/ios-simulator
# using cmake/ios.toolchain.cmake, then runs `xcodebuild` for each. The goal
# at this stage is "the build graph configures and compiles end to end";
# code signing failures during the bundle step are not treated as fatal.
#
# Usage:
#   scripts/build_ios.sh                 # build both device + simulator
#   scripts/build_ios.sh device          # device only (PLATFORM=OS64)
#   scripts/build_ios.sh simulator       # simulator only (SIMULATORARM64)
#   scripts/build_ios.sh clean           # remove build/ios-* directories
#
# Environment variables:
#   EKA2L1_IOS_DEPLOYMENT_TARGET   default 18.0
#   EKA2L1_IOS_CONFIGURATION       default Debug
#   EKA2L1_IOS_SCHEME              default EKA2L1
#
# This script intentionally does not require Qt or any signing identity.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

DEPLOYMENT_TARGET="${EKA2L1_IOS_DEPLOYMENT_TARGET:-18.0}"
CONFIGURATION="${EKA2L1_IOS_CONFIGURATION:-Debug}"
SCHEME="${EKA2L1_IOS_SCHEME:-EKA2L1}"

build_one() {
    local label="$1"
    local platform="$2"
    local sdk="$3"
    local build_dir="build/ios-${label}"

    echo "==> Configuring ${label} (PLATFORM=${platform}, sdk=${sdk})"
    # CMake 4.x dropped compatibility with cmake_minimum_required < 3.5, and
    # several bundled submodules (glm, ext-boost, ...) still declare older
    # minimums. Pin a policy floor for the whole graph until those submodules
    # are bumped upstream.
    cmake -S . -B "${build_dir}" \
        -G Xcode \
        -DCMAKE_TOOLCHAIN_FILE=cmake/ios.toolchain.cmake \
        -DPLATFORM="${platform}" \
        -DDEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
        -DEKA2L1_IOS_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5

    echo "==> Building ${label}"
    xcodebuild \
        -project "${build_dir}/EKA2L1.xcodeproj" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -sdk "${sdk}" \
        CODE_SIGNING_ALLOWED=NO \
        build
}

case "${1:-all}" in
    clean)
        rm -rf build/ios-device build/ios-simulator
        echo "Removed build/ios-device and build/ios-simulator"
        ;;
    device)
        build_one device OS64 iphoneos
        ;;
    simulator)
        build_one simulator SIMULATORARM64 iphonesimulator
        ;;
    all|"")
        build_one device OS64 iphoneos
        build_one simulator SIMULATORARM64 iphonesimulator
        ;;
    *)
        echo "Unknown command: ${1}" >&2
        echo "Usage: $0 [device|simulator|all|clean]" >&2
        exit 2
        ;;
esac

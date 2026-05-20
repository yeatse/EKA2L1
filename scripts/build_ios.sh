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
#   scripts/build_ios.sh smoke           # build sim, install + launch on
#                                        # the booted iPhone simulator, grep
#                                        # log for EKA2L1_SMOKE: PASS / FAIL
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

smoke_test() {
    local sim_app="build/ios-simulator/src/emu/ios/${CONFIGURATION}-iphonesimulator/EKA2L1.app"
    local bundle_id="${EKA2L1_IOS_BUNDLE_ID:-com.eka2l1.emulator}"
    local timeout_s="${EKA2L1_IOS_SMOKE_TIMEOUT:-30}"

    if [ ! -d "${sim_app}" ]; then
        echo "==> Smoke: simulator .app missing, building first"
        build_one simulator SIMULATORARM64 iphonesimulator
    fi

    local booted
    booted="$(xcrun simctl list devices booted 2>/dev/null \
        | awk -F '[()]' '/Booted/ { print $2; exit }')"
    if [ -z "${booted}" ]; then
        echo "Smoke: no booted iPhone simulator. Boot one in Simulator.app first." >&2
        exit 3
    fi
    echo "==> Smoke: target simulator ${booted}"

    xcrun simctl terminate "${booted}" "${bundle_id}" >/dev/null 2>&1 || true
    xcrun simctl install "${booted}" "${sim_app}"
    xcrun simctl launch --terminate-running-process "${booted}" "${bundle_id}" >/dev/null

    local started_at
    started_at="$(date +%s)"
    local deadline=$((started_at + timeout_s))
    local marker=""
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        marker="$(xcrun simctl spawn "${booted}" log show --last 5s \
                    --predicate "process == \"EKA2L1\"" 2>/dev/null \
                  | grep -E 'EKA2L1_SMOKE: (PASS|FAIL)' \
                  | tail -1 || true)"
        if [ -n "${marker}" ]; then
            break
        fi
        sleep 1
    done

    xcrun simctl terminate "${booted}" "${bundle_id}" >/dev/null 2>&1 || true

    if [ -z "${marker}" ]; then
        echo "Smoke: timeout after ${timeout_s}s without EKA2L1_SMOKE marker" >&2
        exit 4
    fi

    echo "${marker}"
    if echo "${marker}" | grep -q 'EKA2L1_SMOKE: PASS'; then
        exit 0
    fi
    exit 5
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
    smoke)
        build_one simulator SIMULATORARM64 iphonesimulator
        smoke_test
        ;;
    all|"")
        build_one device OS64 iphoneos
        build_one simulator SIMULATORARM64 iphonesimulator
        ;;
    *)
        echo "Unknown command: ${1}" >&2
        echo "Usage: $0 [device|simulator|smoke|all|clean]" >&2
        exit 2
        ;;
esac

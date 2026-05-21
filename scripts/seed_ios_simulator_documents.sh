#!/usr/bin/env bash
# Copy the local roms/ tree (and any .sis packages alongside it) into the
# booted iOS simulator's EKA2L1 sandbox Documents directory, mirroring the
# layout that IosEmulator expects (see IOS_PORTING_PLAN.md §"iOS sandbox
# 目录布局"):
#
#   <Documents>/roms/<rom-folder>/...   ← extracted ROM folders
#   <Documents>/sis/<package>.sis       ← user-supplied SIS packages
#
# Requires:
#   * A booted simulator (Xcode → Simulator → File → Open Simulator).
#   * The EKA2L1.app installed once before (otherwise the data container
#     does not exist yet — run `scripts/build_ios.sh smoke` first).
#
# Usage:
#   scripts/seed_ios_simulator_documents.sh              # copy everything
#   scripts/seed_ios_simulator_documents.sh --dry-run    # show what would copy

set -euo pipefail

BUNDLE_ID="${EKA2L1_IOS_BUNDLE_ID:-com.eka2l1.emulator}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="${EKA2L1_IOS_SEED_SRC:-$REPO_ROOT/roms}"
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ ! -d "$SRC_ROOT" ]]; then
    echo "Source directory does not exist: $SRC_ROOT" >&2
    echo "Set EKA2L1_IOS_SEED_SRC to override, or create $SRC_ROOT." >&2
    exit 1
fi

booted_count="$(xcrun simctl list devices booted | awk '/Booted/{n++} END{print n+0}')"
if [[ "$booted_count" -eq 0 ]]; then
    echo "No booted simulator. Boot one (open -a Simulator) and rerun." >&2
    exit 1
fi

if ! container="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)"; then
    echo "Could not locate EKA2L1 data container for $BUNDLE_ID." >&2
    echo "Install the app first: scripts/build_ios.sh smoke" >&2
    exit 1
fi

DOCS="$container/Documents"
ROMS_DST="$DOCS/roms"
SIS_DST="$DOCS/sis"

echo "==> Simulator EKA2L1 sandbox: $DOCS"

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        eval "$@"
    fi
}

run mkdir -p \"$ROMS_DST\" \"$SIS_DST\"

# Treat every direct subdirectory of $SRC_ROOT as a ROM folder and copy it
# verbatim. Files at the top level with .sis/.sisx extensions go into sis/.
shopt -s nullglob
for entry in "$SRC_ROOT"/*; do
    base="$(basename "$entry")"
    if [[ -d "$entry" ]]; then
        echo "    rom  $base"
        run rsync -a --delete \"$entry/\" \"$ROMS_DST/$base/\"
    else
        case "$base" in
            *.sis|*.sisx|*.SIS|*.SISX)
                echo "    sis  $base"
                run cp -f \"$entry\" \"$SIS_DST/$base\"
                ;;
            *) ;;
        esac
    fi
done

echo "==> Done."

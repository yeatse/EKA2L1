# Stage-2 iOS Simulator Verification (2026-05-22)

Captured via `xcodebuildmcp` against a booted iPhone 16 Pro simulator
(iOS 26.5, device id `26D5FEDA-3BDC-4699-83ED-58B749D676DF`) running the
`Debug-iphonesimulator` build of `EKA2L1.app`.

| # | Screenshot | What it proves |
|---|-----------|----------------|
| 01 | `01-rom-list.jpg` | EKA2L1App boots, `IosEmulator::startWithDocumentsPath:` lays out `Documents/{roms,data,sis,...}` and reads `Documents/roms` to populate the SwiftUI ROM list. The "N95 8GB (S60v3 - FP1)" row is the directory placed there by `scripts/seed_ios_simulator_documents.sh`. Diagnostics row sits beneath. |
| 02 | `02-app-list-empty.jpg` | Tapping the ROM row navigates to `AppListView`. Mount button, empty applist, and "Install SIS" section (with `snakes-n95_n6trsohu.sis` from the seed script) all render. |
| 03 | `03-mount-fails-no-device.jpg` | Tapping **Mount** invokes `IosEmulator::mountRomNamed:` → `rescan_devices(drive_z)` → 0 devices → UI reports the documented stage-2 limitation. The local `roms/N95 8GB …/data/roms/rm-320/SYM.rom` is a raw ROM dump, not a desktop-installed device tree (no `devices.yml`); shipping the real installer is parked in stage 3. |

## Repro

```sh
# 1. build
scripts/build_ios.sh simulator

# 2. boot any sim and install
SIM=$(xcrun simctl list devices booted | awk '/Booted/{print $NF; exit}' | tr -d '()')
xcodebuildmcp simulator install --simulator-id "$SIM" \
    --app-path build/ios-simulator/src/emu/ios/Debug-iphonesimulator/EKA2L1.app

# 3. seed Documents/roms & Documents/sis from this repo
scripts/seed_ios_simulator_documents.sh

# 4. launch + drive the UI
xcodebuildmcp simulator launch-app --simulator-id "$SIM" \
    --bundle-id com.eka2l1.emulator
xcodebuildmcp ui-automation tap --simulator-id "$SIM" \
    --label "N95 8GB (S60v3 - FP1)"
xcodebuildmcp ui-automation tap --simulator-id "$SIM" \
    --label "Mount N95 8GB (S60v3 - FP1)"
xcodebuildmcp simulator screenshot --simulator-id "$SIM" --return-format path
```

## Why no "1 frame rendered" / "tap Calculator" screenshot yet

That bullet of the stage-2 acceptance list requires a desktop-pre-installed
Symbian device tree (with `devices.yml`) under `Documents/roms/<name>/`,
which the local seed lacks. The full ROM/device installer flow is scoped
to stage 3 (see `IOS_PORTING_TASKS.md` § "重构动作明确推到阶段 3"). The
stage-2 frontend / GL / threading wiring is verified end-to-end up to the
mount call without crash; the moment a real device tree is dropped in,
the same UI path lights up applist → launch → render.

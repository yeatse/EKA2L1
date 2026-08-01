# iOS Port — Investigation Log Index

Each entry is a deep-dive into a non-trivial bug or design question hit during the
iOS port: symptom, how it was narrowed down, and the conclusion/fix. Newest first.

| Date | Doc |
|---|---|
| 2026-08-01 | [Debug write command descriptor bound](./debug-command-write-descriptor-bound.md) |
| 2026-08-01 | [Dragon.World flickers black on every server recomposite](./dragon-world-empty-redraw-black-flicker.md) |
| 2026-07-30 | [Ashen stops before its first frame after stale-handle validation](./ios-ngage-object-handle-alias-regression.md) |
| 2026-07-30 | [Sky Force stays white on the 6680](./ios-6680-sky-force-window-opcode.md) |
| 2026-07-30 | [A ScreenPlay stride fix breaks landscape DSA on the 5320](./ios-5320-landscape-dsa-stride-regression.md) |
| 2026-07-30 | [Talking Tom loses audio and flashes black between actions](./ios-talking-tom-audio-and-frame-composition.md) |
| 2026-07-30 | [Talking Tom recording corrupts the host heap on iOS](./ios-talking-tom-recording-input-race.md) |
| 2026-07-30 | [Talking Tom stays black on X7: incomplete Belle MMF dispatch](./ios-talking-tom-belle-mmf-ipc-stall.md) |
| 2026-07-30 | [Sky Force Reloaded corrupts the X7 display](./ios-sky-force-reloaded-x7-framebuffer-stride.md) |
| 2026-07-30 | [Angry Birds Rio's main menu repeatedly starts TZSERVER](./ios-angry-birds-rio-tzserver-retry.md) |
| 2026-07-29 | [A guest's undefined STRD calls host address 0](./ios-dyncom-null-addressing-mode.md) |
| 2026-07-29 | [N-Gage Store re-entry jumps to an unmapped function pointer](./ngage-store-codeseg-data-relocation.md) |
| 2026-07-29 | [N-Gage Launcher Store hangs, reports OOM, or renders black](./ios-ngage-launcher-store-applist-recognize-hang.md) |
| 2026-07-28 | [N-Gage Launcher freezes while exiting: incomplete ETel notification cancels](./ios-ngage-launcher-rsk-etel-cancel-hang.md) |
| 2026-07-28 | [N-Gage Launcher exit deadlocks in the window focus callback](./ios-window-callback-lock-self-deadlock.md) |
| 2026-07-28 | [System menu corrupts UIKit collection storage](./ios-system-menu-context-menu-crash.md) |
| 2026-07-28 | [Bloks shows no app icon: SVGB `<text>` coordinate lists](./svgb-text-coordinate-lists.md) |
| 2026-07-27 | [First ThreadSanitizer pass over the iOS build](./ios-tsan-first-pass.md) |
| 2026-07-27 | [TestFlight crash triage, round 7](./ios-testflight-crash-triage-r7.md) |
| 2026-07-27 | [Play-done callback deadlocks a guest `Play()`](./ios-audio-play-done-kernel-lock-deadlock.md) |
| 2026-07-27 | [Audio keeps playing after "Exit Game"](./ios-audio-outlives-killed-app.md) |
| 2026-07-27 | [`ekatests` build and runtime failures](./ekatests-build-and-runtime-failures.md) |
| 2026-07-27 | [Installing a second device hangs until backgrounding](./ios-device-install-idle-event-lost-wakeup.md) |
| 2026-07-27 | [Flexible mapping detach left stale CPU TLB entries](./FLEXIBLE_MAPPING_DETACH_STALE_TLB.md) |
| 2026-07-27 | [X7 Asphalt 6 launch & race path — Belle SDK rebuild follow-up](./ios-asphalt6-x7.md) |
| 2026-07-26 | [Worms shows no app icon: MIF entries can hold a gzipped SVG](./mif-gzipped-svg-icons.md) |
| 2026-07-26 | [X-Plore exit kills the emulator: window teardown races the redraw walker](./ios-window-teardown-redraw-race.md) |
| 2026-07-25 | [N-Gage Tetris freezes: the stray-signal filter ate real completions](./ios-ngage-tetris-absorbed-signal-hang.md) |
| 2026-07-25 | [X-Plore on the N-Gage: EColor4K makes a guest allocate zero-byte surfaces](./ios-ngage-color4k-zero-byte-surface.md) |
| 2026-07-24 | [N-Gage folder import deadlocks while the guest is idle](./ios-ngage-folder-import-idle-deadlock.md) |
| 2026-07-23 | [Rescan devices — case-sensitivity data loss and a reset() crash](./ios-rescan-devices-case-and-reset-crash.md) |
| 2026-07-22 | [MMF `more_buffer` callback leaks the kernel lock on a throw](./ios-mmf-callback-kernel-lock-leak.md) |
| 2026-07-22 | [AudioUnit render callback must be a `noexcept` boundary](./ios-audiounit-render-callback-noexcept.md) |
| 2026-07-22 | [Angry Birds in-game "X" exit — null callback](./ios-angrybirds-exit-null-callback.md) |
| 2026-07-22 | [Native-only scripting patches on iOS](./ios-native-scripting-patches.md) |
| 2026-07-22 | [S60v3 empty Avkon menu breakpoint patch](./s60v3-empty-avkon-menu-breakpoint-patch.md) |
| 2026-07-21 | [Launch screen-kick vs. animation redraw font-atlas race](./ios-launch-kick-redraw-font-atlas-race.md) |
| 2026-07-21 | [TestFlight crash triage, round 5](./ios-testflight-crash-triage-r5.md) |
| 2026-07-17 | [Single-member intrusive ring corruption](./ios-intrusive-ring-single-member-corruption.md) |
| 2026-07-16 | [SMS PDU non-virtual destructor crash](./ios-sms-pdu-nonvirtual-destructor-crash.md) |
| 2026-07-16 | [Stale CPU TLB on cross-process decommit](./STALE_CPU_TLB_ON_CROSS_PROCESS_DECOMMIT.md) |
| 2026-07-16 | [S60v5 accelerometer inversion](./ios-s60v5-accelerometer-panel-mount.md) |
| 2026-07-16 | [`User::After` completion null-deref on teardown](./ios-notify-sleep-teardown-null-deref.md) |
| 2026-07-16 | [System-language switch app-list reload](./ios-language-switch-applist-reload.md) |
| 2026-07-16 | [6680 application launch exit](./ios-6680-avkon-app-launch-exit.md) |
| 2026-07-15 | [Legacy AIF icon mask polarity](./ios-legacy-aif-icon-mask-polarity.md) |
| 2026-07-14 | [Asphalt 6 menu car material](./asphalt6-menu-car-material-investigation.md) |
| 2026-07-13 | [X7 Asphalt 6 launch & race path](./ios-asphalt6-x7.md) |
| 2026-07-13 | [iOS CoreMotion async IPC crash](./ios-sensor-async-ipc-crash.md) |
| 2026-07-11 | [5320 Camera panic 49](./ios-5320-camera-panic49.md) |
| 2026-07-11 | [Camera menu over viewfinder](./ios-camera-menu-over-viewfinder.md) |
| 2026-07-11 | [ipc_msg refcount UAF](./ios-ipc-msg-refcount-uaf.md) |
| 2026-07-10 | [TestFlight crash triage, round 2](./ios-testflight-crash-triage-r2.md) |
| 2026-07-08 | [N-Gage installer popup & game launch](./ios-ngage-installer-popup-and-game-launch.md) |
| 2026-07-08 | [N-Gage ONE launch deadlock — handoff](./ios-ngage-one-launch-deadlock-handoff.md) |
| 2026-07-08 | [TestFlight crash triage, round 1](./ios-testflight-crash-triage.md) |
| 2026-07-07 | [Stray-signal accounting — follow-up](./stray-signal-accounting-followup.md) |
| 2026-07-05 | [iOS productization checklist](./ios-productization-checklist.md) |
| 2026-06-15 | [Metal via ANGLE plan](./ios_metal_angle_plan.md) |
| 2026-06-14 | [dyncom optimization plan](./dyncom_optimization_plan.md) |
| 2026-06-14 | [Snakes / dyncom performance](./ios_snakes_perf.md) |
| 2026-06-14 | [Final Battle timer stray signal](./ios-final-battle-timer-stray.md) |
| 2026-06-13 | [Calculator Options menu hang](./ios-calculator-options-menu-hang.md) |
| 2026-06-05 | [Optimized-build Snakes stray signal](./ios-optimized-build-snakes-stray-signal.md) |
| 2026-06-03 | [Device missing patch DLLs](./ios-device-missing-patch-dlls.md) |
| 2026-06-02 | [App-list icons (SVG/MIF decode)](./ios-applist-icons.md) |
| 2026-06-02 | [Native AudioUnit backend](./ios-audiounit-backend.md) |
| 2026-06-02 | [Calculator EAGL magenta screen](./ios-calculator-eagl-magenta.md) |
| 2026-06-02 | [Document picker import](./ios-document-picker-import.md) |
| 2026-06-02 | [DSP / FFmpeg reconnection](./ios-dsp-ffmpeg.md) |
| 2026-06-02 | [Guest PC=0 deadloop](./ios-guest-pc0-deadloop.md) |
| 2026-06-02 | [Log flood pins CPU](./ios-log-flood-cpu.md) |
| 2026-06-02 | [Mount chunk SIGBUS](./ios-mount-chunk-sigbus.md) |
| 2026-06-02 | [mprotect silently strips W^X](./ios-mprotect-wx-strip.md) |
| 2026-06-02 | [Real ROM install pipeline](./ios-rom-install-pipeline.md) |
| 2026-06-02 | [SIS install silent write failure](./ios-sis-install-write-fail.md) |
| 2026-06-02 | [Snakes stray-signal freeze](./ios-snakes-stray-signal.md) |
| 2026-06-02 | [VFS case-sensitive path resolution](./ios-vfs-case-sensitive-path.md) |
| 2026-06-02 | [S60v5 AVKON FEP / PtiEngine stall](./s60v5-avkon-fep-pti.md) |
| 2026-07-31 | [Haptics-triggered AudioAnalytics crash](./ios-haptics-audioanalytics-crash.md) |
| 2026-08-01 | [A3F DevSound recording never delivers](./a3f-devsound-recording-never-delivers.md) |
| 2026-08-01 | [EKA1 GLES HLE patch path](./eka1-gles-hle-patch-path.md) |
| 2026-08-01 | [S60v2 binary colour-key icon mask](./s60v2-binary-colour-key-icon-mask.md) |

## Archived planning docs

These tracked the initial port to completion and are no longer updated:

- [`IOS_PORTING_PLAN.md`](./IOS_PORTING_PLAN.md) — original iOS port proposal/roadmap.
- [`IOS_PORTING_TASKS.md`](./IOS_PORTING_TASKS.md) — stage-by-stage task tracker with verification results and a changelog; the closest thing to a full project history.

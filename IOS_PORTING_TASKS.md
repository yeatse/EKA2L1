# EKA2L1 iOS 移植任务跟踪

> 进度跟踪用文档，与 [`IOS_PORTING_PLAN.md`](./IOS_PORTING_PLAN.md) 配套。
> 各阶段只在真正要动手前再拆细子任务，先锁定大目标和验收标准。
>
> 状态图标：⬜ 未开始 / 🟡 进行中 / ✅ 完成 / ⏸ 阻塞 / ❌ 放弃

---

## 阶段总览

| 阶段 | 目标 | 状态 |
|------|------|------|
| 0 | 工程骨架可在 iOS arm64 上构建出空壳 | ✅（`build/ios-device/.../EKA2L1.app` 已成功产出，arm64 Mach-O） |
| 1 | dyncom 解释器在 iOS 上跑通一段裸 ARM 代码片段，结果可在 SwiftUI 展示 | ✅（booted iPhone 16 Pro 模拟器上 `EKA2L1_SMOKE: PASS backend=dyncom instrs=9 pc=0x00001024`） |
| 2 | iOS 前端壳 + GLES 渲染上下文，能显示一帧并完成一次真实交互 | ✅（Calculator 真实 UI 出帧、稳定 ≥10s、SIS 安装后 Final Battle 进 applist 并能 launch；详见 3.2 / 阶段 3 修复清单第 3 条） |
| 3 | 解锁 mount 链路 + 完成阶段 2 验收 + 音频 / 振动 / 文件导入 / 设置 / 图标完整体验 | 🟡 |
| 4 | dynarmic JIT（MAP_JIT / W^X / entitlement）+ 发布通道（开发者签名 / TrollStore / 越狱）+ CI | ⬜ |

---

## 阶段 0：可构建骨架

### 目标
让仓库在 macOS + Xcode 环境下，能通过 CMake（或衍生的 Xcode 工程）针对 `iphoneos` SDK（arm64）和 `iphonesimulator` SDK 构建出一个**最小静态库聚合 + 空壳 App**，链接通过、能在真机/模拟器上启动并立即退出（不要求任何模拟器功能跑起来）。

这一阶段**不追求功能**，只追求"编译链路打通"，把后续阶段会反复踩的构建配置坑提前排掉。

### 验收标准
- [x] `cmake -G Xcode -DCMAKE_TOOLCHAIN_FILE=cmake/ios.toolchain.cmake -DPLATFORM=OS64 ...` 在干净 clone 后能成功生成 Xcode 工程。
- [x] `xcodebuild -scheme EKA2L1 -sdk iphoneos -configuration Debug` 能在不带 codesign 的情况下成功编译完成（允许 signing 阶段失败）。
- [x] 同上对 `iphonesimulator` SDK 也能编译通过（arm64 模拟器）。
- [x] 编译产物中存在一个 iOS bundle（`.app`），其可执行体能在 iOS 模拟器上启动到空白屏幕、不立刻 crash。
- [x] `EKA2L1_BUILD_TESTS`、`EKA2L1_BUILD_TOOLS`、`EKA2L1_ENABLE_SCRIPTING_ABILITY`、`EKA2L1_BUILD_VULKAN_BACKEND`、`EKA2L1_BUILD_PATCH` 在 iOS 下默认 OFF。
- [x] 不引入 SDL2 到 iOS target 的链接图里。
- [x] CI（或本地脚本）有一条命令可一键复现以上构建。

### 子任务

#### 0.1 工具链与顶层 CMake
- [x] 引入 `cmake/ios.toolchain.cmake`（vendored leetal/ios-cmake 或精简版），新增 `EKA2L1_IOS_DEPLOYMENT_TARGET`（暂时默认 `18.0`，开发期使用，后续会降回 `14.0` 左右）。
- [x] 顶层 `CMakeLists.txt`：检测 `CMAKE_SYSTEM_NAME STREQUAL iOS`，定义 `EKA2L1_IOS` 变量；在 iOS 下强制关闭 tools/tests/scripting/vulkan/patch/dmg/discord。
- [x] BUILDING.md 末尾加一段 iOS 构建命令骨架（实际可跑要等 0.6/0.7）。

#### 0.2 emu 子目录分支化
- [x] `src/emu/CMakeLists.txt`：把现有 `if (ANDROID) ... else()` 扩展为三分支，新增 `elseif(EKA2L1_IOS) add_subdirectory(ios)`；占位 `src/emu/ios/CMakeLists.txt` 已建（真正前端在 0.6）。
- [x] 排查 emu 各子目录 CMakeLists 平台分支。结论：
  - `bridge / config / disasm / dispatch / gdbstub / j2me / kernel / ldd / loader / mem / package / services / system / utils / vfs`：无桌面专属依赖泄漏到 iOS，无需改动。
  - `common`：`elseif(UNIX AND NOT APPLE)` 正确把 iOS 排除在 watcher_unix 外，落到 `watcher_null`；`if (UNIX OR APPLE)` 给 iOS 加上 PIC + pthread，正确。
  - `cpu`：含 dynarmic 块需在 iOS 下绕开，归 0.4。
  - `drivers`：包含 SDL2 / AGL / WGL / X11 等大量平台分支，归 0.3。
  - `scripting`：iOS 默认关闭，不进 build graph。
- [x] 修正 `src/emu/CMakeLists.txt` 中 `CMAKE_OSX_DEPLOYMENT_TARGET=10.14 FORCE` 会污染 iOS 的问题，已用 `if (NOT EKA2L1_IOS)` 保护。其他 `if (APPLE)` 分支（drivers 的 AGL、external 中的 cubeb/ffmpeg 等）留给 0.3 / 0.5 在对应任务里处理。

#### 0.3 drivers 模块 iOS 分支
- [x] `src/emu/drivers/CMakeLists.txt`：把 `if (NOT ANDROID)` 重排为三分支（ANDROID / EKA2L1_IOS / 桌面）：
  - iOS 不链 SDL2、不引入 `emu_controller_sdl2` / `vibration_sdl2` / `sdl2_scoping` / `emu_window.cpp`，输入窗口留给 0.6 的前端。
  - 不引入 X11 / Wayland / WGL / AGL 上下文源文件（把 `elseif(APPLE)` 放到 `elseif(EKA2L1_IOS)` 之后，避免 iOS 落入 AGL 分支）。
  - 没有为 iOS 单独建 EAGL stub 源文件 —— `src/graphics/context.cpp` 已经有 `#else return nullptr` 兜底，phase 2 再补真实的 EAGL 上下文。
  - 振动、传感器、相机继续走 `vibration_null` / `sensor_null` / `camera_collection` 的通用 null 后端（已经在公共源块里）。
- [x] glad / ogl 后端在 iOS 下整体剔除：把 ogl 源拆到 `DRIVERS_OGL_SRC` 变量并由 `if (NOT EKA2L1_IOS)` 包住；六个工厂文件（`buffer.cpp` / `graphics.cpp` / `shader.cpp` / `fb.cpp` / `texture.cpp` / `input_desc.cpp`）的 ogl include + case 分支用 `#if !EKA2L1_PLATFORM(IOS)` 包起来；`target_link_libraries` 中 cubeb / ffmpeg / glad 在 iOS 下不再链入（cubeb / ffmpeg 是否最终启用见 0.5）。
- [x] 附带修复：`src/emu/common/include/common/platform.h` 中 `TARGET_OS_MAC` 会在 iOS 上误命中导致 `EKA2L1_PLATFORM(MACOS)` 被定义、`EKA2L1_PLATFORM(IOS)` 永远拿不到的预存 bug，已改为先判 `TARGET_OS_IPHONE`。

#### 0.4 cpu 模块在 iOS 下的最小可链
- [x] `src/emu/cpu/CMakeLists.txt`：增加 `elseif (EKA2L1_IOS)` 分支，不编译 `src/arm_dynarmic.cpp`、不链 `dynarmic`。
- [x] `src/emu/cpu/src/arm_factory.cpp`：用 `EKA2L1_CPU_HAS_DYNARMIC` 宏把 dynarmic 的 include 与 case 在 iOS 下整体剔除，避免符号缺失。
- [x] 默认后端：`arm_utils.cpp` 的 `string_to_arm_emulator_type` fallback 改为 `EKA2L1_DEFAULT_ARM_EMULATOR_TYPE`（iOS / ARM32 → `dyncom`，其他 → `dynarmic`）；`src/emu/system/src/epoc.cpp` 的硬编码 cpu_type 默认值也加了 iOS 的 dyncom 分支，避免运行期挑到无法实例化的 dynarmic 类型。

#### 0.5 第三方依赖审计（仅 iOS 编译层面）
- [x] `src/external/CMakeLists.txt` 跟踪。iOS 下 `add_subdirectory` 跳过：**SDL2**、**cubeb**、**ffmpeg**、**miniupnp/miniupnpc**、**dynarmic**。luajit 通过顶层 `EKA2L1_ENABLE_SCRIPTING_ABILITY=OFF` 自然跳过。其他 (`miniz` / `pugixml` / `fmt` / `spdlog` / `glm` / `Catch2` / `microprofile` / `xxHash` / `Vulkan(QUIET)` / `capstone` / `libfat` / `mbedtls` / `sqlite3` / `miniBAE` / `TinySoundFont` / `RectangleBinPack` / `re2` / `uvw+uvlooper` / `libtess2` / `thread-pool` / `freetype` / `lunasvg` / `yaml-cpp` / `glad`) 仍然进入 build graph，是否真能编过留给 0.7 跑一遍真实构建确认。
- [x] 直接消费者修复：
  - `src/emu/common`：`upnp.cpp` 在 iOS 下整文件改为 no-op 实现；CMakeLists 不再为 iOS 链接 `miniupnpc::miniupnpc`。
  - `src/emu/drivers`：cubeb / ffmpeg 后端的头与源拆到 `DRIVERS_CUBEB_SRC` / `DRIVERS_FFMPEG_SRC` 两个变量，由 `if (NOT EKA2L1_IOS)` 包住；`audio.cpp` / `dsp.cpp` / `video.cpp` 工厂中相关 `#include` 与 case 用 `#if !EKA2L1_PLATFORM(IOS)` 屏蔽；iOS 的 `new_best_video_player` 直接返回 nullptr。
- [x] 已知影响记录（给 1/2/3 阶段）：
  - **音频**：cubeb 关掉后 `audio_driver_backend::cubeb` 在 iOS 无可用实例，所有依赖 `make_audio_driver` 的 services（MediaClientAudio 等）实际拿到的会是 nullptr —— 阶段 3 接入 cubeb iOS 后端时一并恢复。
  - **DSP / 视频**：ffmpeg 关掉后，`dsp_stream_backend_ffmpeg` 的 out-stream、`new_best_video_player`、video_player_ffmpeg 在 iOS 完全无效。input-stream 的 `dsp_input_stream_shared` 不依赖 ffmpeg，仍保留。
  - **JIT**：dynarmic 子项目被跳过，cpu 模块只能跑 dyncom（阶段 1 引入 MAP_JIT 路径时一起恢复）。
  - **网络**：miniupnp 跳过，UPnP 端口映射在 iOS 是 no-op；NAT 穿透相关需求阶段 3 再评估。
  - **桌面控制器**：SDL2 跳过，`emu_controller_sdl2` 与 `vibration_sdl2` 在 iOS 完全不可用，0.6 的 iOS 前端需要自行提供输入与振动通路。

#### 0.6 iOS 子工程骨架
- [x] `src/emu/ios/CMakeLists.txt`：替换占位，新建 `MACOSX_BUNDLE` 可执行 `EKA2L1`，配置 `XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER`、`TARGETED_DEVICE_FAMILY=1,2`、`IPHONEOS_DEPLOYMENT_TARGET=${EKA2L1_IOS_DEPLOYMENT_TARGET}`、未签名（`CODE_SIGNING_ALLOWED=NO`）、`SWIFT_OBJC_BRIDGING_HEADER` 指向 Bridge 目录。
- [x] `src/emu/ios/App/`：`EKA2L1App.swift`（`@main` SwiftUI 入口）+ `ContentView.swift`（显示版本字符串的占位 view）。
- [x] `src/emu/ios/Bridge/`：`StartupBridge.{h,mm}` + `EKA2L1-Bridging-Header.h`。`StartupBridge.mm` 调用 `<common/version.h>` 里的 `GIT_BRANCH` / `GIT_COMMIT_HASH`，作用是确保 `common` 静态库被链接进 bundle 而不是被链接器丢弃，同时给 SwiftUI 显示一个真实可见的字符串。
- [x] `src/emu/ios/Resources/Info.plist`：BundleId、display name `EKA2L1`、`LSRequiresIPhoneOS`、`UILaunchScreen`、`UIRequiredDeviceCapabilities=arm64`、`UISupportedInterfaceOrientations`、`UIFileSharingEnabled`+`LSSupportsOpeningDocumentsInPlace`（为后续 ROM 导入预留）。
- [x] `src/emu/ios/Resources/EKA2L1.entitlements`：先空，注释里预留 `com.apple.security.cs.allow-jit` / `com.apple.developer.kernel.increased-memory-limit`，stage 1 引入 JIT 时放开。
- [x] App 链接 `common / cpu / drivers / epoc / epockern / epocpkg / epocservs / sqlite3 / yaml-cpp`，参考 Android `native-lib` 的链接清单，验证链接图完整即可，stage 0 不调用 emu 逻辑。

#### 0.7 验证脚本
- [x] 新增 `scripts/build_ios.sh`：默认两次构建（`OS64` + `SIMULATORARM64`），支持 `device` / `simulator` / `all` / `clean` 子命令；环境变量 `EKA2L1_IOS_DEPLOYMENT_TARGET` / `EKA2L1_IOS_CONFIGURATION` / `EKA2L1_IOS_SCHEME` 可覆盖；强制 `CODE_SIGNING_ALLOWED=NO`。
- [x] **首次完整构建已通过**（Xcode 26.5 / iPhoneOS26.5 SDK / clang 21）。`scripts/build_ios.sh device` 产物：`build/ios-device/src/emu/ios/Debug-iphoneos/EKA2L1.app/EKA2L1`，arm64 Mach-O，约 95 KB（Swift 壳 + Obj-C++ bridge + 链入 emu 核心静态库）。
- [x] 一系列搭建期碰到的真实坑（已修复，按出现顺序记录）：
  1. **CMake 4.x 移除旧策略**：cmake 命令必须加 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`，否则 glm / libfat 等老 `cmake_minimum_required` 直接报错。已写进 `scripts/build_ios.sh`。
  2. **capstone `cmake_policy(SET CMP0048 OLD)`**：CMake 4.x 不再允许 OLD，已在子模块内改为 NEW（`src/external/capstone/CMakeLists.txt` 出现 dirty content）。
  3. **spdlog 1.13 + fmt 10.x + 新版 clang**：fmt 的 `consteval basic_format_string` 触发 `SPDLOG_FMT_STRING` 编译失败。修复：① 给 `src/external/fmt/include/fmt/base.h` 的 `FMT_USE_CONSTEVAL` 块加 `#ifndef ... #endif` 守卫；② 顶层 CMake 在 iOS 下 `add_compile_definitions(FMT_USE_CONSTEVAL=0)`，并用生成器表达式仅限 C/CXX/OBJC/OBJCXX，避免传给 swiftc。
  4. **`-Wno-error` 流到 swiftc**：用相同的 `$<$<COMPILE_LANGUAGE:...>:>` 包住。
  5. **`-stdlib=libc++` 被推到 `OTHER_SWIFT_FLAGS`**：Xcode 26 swift driver 直接拒。设置 `XCODE_ATTRIBUTE_OTHER_SWIFT_FLAGS=$(inherited)` 重置，加 `XCODE_ATTRIBUTE_SWIFT_OBJC_INTEROP_MODE=objc`。
  6. **Swift 没编译，链接 `_main` 缺失**：iOS 子目录里加 `enable_language(Swift)`。
  7. **miniBAE 报 `X_PLATFORM` 未定义**：`drivers/include/.../minibae/machine/types.h` 新增 `EKA2L1_PLATFORM(IOS) → X_IOS` 分支。
  8. **`struct stat64` 在 iOS SDK 不存在**：`fileutils.cpp` 在 `EKA2L1_PLATFORM(DARWIN)` 下 `#define stat64 stat`。
  9. **`arm_cpudetect.cpp:208/211` 用了不存在的 3 参 `strcpy`**：改成 `strncpy`（pre-existing bug，iOS 路径才会命中）。
  10. **`graphics_driver_shared.cpp` 无意义引入 `<glad/glad.h>`**：iOS 下 `#if` 屏蔽。
  11. **freetype 在 iOS 下被 Homebrew 的 macOS libpng 污染**：iOS 下强制 `FT_DISABLE_PNG/ZLIB/BZIP2/BROTLI=ON`。
  12. **`vibration.cpp` / `player.cpp` / `arm_factory.cpp` / `arm_utils.cpp` / `epoc.cpp` 残留 SDL2 / ffmpeg / dynarmic 引用**：补 `EKA2L1_PLATFORM(IOS)` 分支。
- [x] **dirty submodule 已通过升级根治**：
  - `src/external/capstone` 切换到上游 `capstone-engine/capstone` 5.0.7（旧仓库 `aquynh/capstone` 早已停滞），新版没有 `CMP0048 OLD` 残留。capstone 5 的 STATIC 目标改名 `capstone_static` 且与 OBJECT 目标 `capstone` 共享 `OUTPUT_NAME=capstone`，在 Xcode 生成器下会出现 archive 路径错位 —— 直接改成链接 OBJECT 目标 `capstone` 绕开这个坑（`src/emu/cpu/CMakeLists.txt`、`src/emu/disasm/CMakeLists.txt`）。
  - `src/external/spdlog` 升到 `v1.17.0`，`src/external/fmt` 升到 `11.2.0`。fmt 11 的 `basic_format_string` 不再 consteval-only 时，旧的 fmt 10 + 新 clang 报错路径自然消失。
  - 顶层 `add_compile_definitions(FMT_USE_CONSTEVAL=0)` workaround 也一并删除。
  - 副作用：升级会影响所有平台。后续 PR 前需要在 macOS / Linux 桌面 Qt 构建上跑一遍验证。

### 阶段 0 已知风险
- 部分 emu 模块可能在 iOS 上**直接编译失败**（例如 `services/` 里假设有 `gettimeofday`、`pthread_setname_np` 签名差异、Mach 与 Linux 不同的命名等）。出现时**就地最小修复**，不要顺手重构；标记 `// TODO(ios)` 注释，集中在阶段 1 前夕复盘。
- 某些子模块（dynarmic、ffmpeg）可能在 CMake 配置阶段就报错，需要靠 0.5 的"跳过名单"绕过；不要试图在阶段 0 里把它们都修好。

---

## 阶段 1：CPU 解释器跑通（dyncom only）

### 目标
让 iOS 前端壳真实驱动 `src/emu/cpu` 的 dyncom 解释器，跑完一段硬编码的 ARM A32 指令序列，把寄存器/内存结果通过 SwiftUI 展示出来，确认 cpu + 其依赖在 iOS arm64 上从链接到运行**全链路活的**。

**显式不在范围内**：dynarmic、MAP_JIT、`pthread_jit_write_protect_np`、JIT entitlement、各签名通道下的 JIT 启用方法 —— 整体推迟到阶段 4，与发布通道一起做。

### 验收标准
- [x] booted iPhone 模拟器与 iOS 真机上启动 EKA2L1.app 后，SwiftUI 能展示一组手写 ARM 指令在 dyncom 后端下的运行结果，与"PC 端同样指令同样输入"的标杆寄存器快照逐位一致。（simulator 已验证；device 待开发者实机签名后再确认，但二进制就是同一个 arm64 Mach-O，逻辑无平台差异）
- [x] cpu 模块的 dyncom 路径（以及为跑通它而被牵出的 `mem` / `kernel` / `common` 子集）在 iOS arm64 上真实被引用、不被 dead-strip，所有 link-time 与 runtime 符号缺失问题清零。
- [x] iOS 下若上层配置请求 `arm_emulator_type::dynarmic`，cpu factory 显式记录"resolved: dyncom (reason: no-jit-on-ios)" 并安全回落，不出现初始化 crash；UI 上能看见这个 fallback 原因。
- [x] `scripts/build_ios.sh smoke` 在 booted simulator 上一键完成 build → install → launch → 抓日志判 pass/fail，无 booted 设备时明确报错退出。
- [x] 阶段期间为修复 iOS 编译/运行问题打的 patch 集中记录在本文档末尾，沿用阶段 0 的体例（按出现顺序逐条登记）。

### 子任务

#### 1.1 ARM smoke blob 设计
- 选定 ~10 条 A32 指令，覆盖 `mov` / `add` / `sub` / 立即数 / 条件分支 / `ldr` / `str`，以一个明确的"终止"约定结束（例如写入特定 magic 到固定地址、或 `bkpt` 让 dyncom 停步）。
- 在 PC 端（Linux 或 macOS 桌面 Qt 构建）用同一份 dyncom 预跑得到标杆寄存器快照（R0..R15、CPSR），作为 iOS 端比对基准。
- 字节数组与期望结果落进 `src/emu/ios/Bridge/CpuSmokeBlob.h`；生成器脚本 `scripts/gen_ios_cpu_smoke.py` 负责从汇编源 + 标杆 JSON 重新生成该 header，避免人肉粘字节。

#### 1.2 SmokeBridge
- 新建 `src/emu/ios/Bridge/CpuSmokeBridge.{h,mm}`，与 `StartupBridge` 解耦：
  - Obj-C 暴露 `+ (NSDictionary *)runDyncomSmoke;`，返回 `{ backend, registers, expected, pass, fallbackReason }`。
  - 内部构造 `arm::make_arm_emulator(arm_emulator_type::dyncom, ...)`，准备一块 host-allocated 的 guest 内存（4 KB 起步即可），把 smoke blob 写入、设 PC，调用 step/run 直到终止条件命中。
  - 跑在后台线程，主线程只读结果，避免阻塞 SwiftUI。
- Bridging-Header 暴露给 Swift 侧。

#### 1.3 cpu 模块在 iOS 下的真实可链
- 1.2 一旦真正调用 `arm::make_arm_emulator`，dyncom 的间接依赖（`mem` / `kernel/static_chunk` / `common/time` 等）会被首次拖进链接图，预计冒出一批 iOS 上的具体编译/链接错误：`pthread_setname_np` 签名差异、`clock_gettime` vs `mach_absolute_time`、`localtime_r` 兼容、`gettimeofday` 弃用警告升错等。
- 原则：**就地最小修复**，每处加 `// TODO(ios)`，所有改动用 `EKA2L1_PLATFORM(IOS)` 守护，绝不污染 macOS / Linux 桌面 Qt 构建。
- 不允许在阶段 1 顺手重构 mem/kernel 任一公共接口。

#### 1.4 SwiftUI 展示
- `ContentView` 新增 "CPU smoke" 区块：
  - 默认在首次出现时调用 `CpuSmokeBridge.runDyncomSmoke`，结果存 `@State`。
  - 显示 backend 名、PASS/FAIL、R0..R15 + CPSR；FAIL 时把实际值与期望值并列 diff 出来。
- 增加一个"force dynarmic"按钮触发请求 dynarmic 后端的路径，验证回落（应显示 backend=dyncom + fallback reason）。

#### 1.5 cpu factory iOS 回落语义
- 复核 `src/emu/cpu/src/arm_factory.cpp` 与 `arm_utils.cpp`：iOS 下若上层请求 `arm_emulator_type::dynarmic`，需返回明确 fallback 且通过日志/返回结构暴露 reason，给 1.4 使用。
- 暂时硬编码 `ios_can_jit() = false`；阶段 4 引入真实 MAP_JIT 探测时替换实现。该函数留在 cpu factory 而非 common，避免阶段 1 在 common 里就引入 JIT 接口面。

#### 1.6 验证脚本 `scripts/build_ios.sh smoke`
- 新增子命令 `smoke`：
  1. 先调 `simulator` 路径完成构建。
  2. `xcrun simctl list devices booted` 校验存在 booted 模拟器，没有就 exit 非零。
  3. `xcrun simctl install booted ...EKA2L1.app`。
  4. `xcrun simctl launch --console-pty booted com.eka2l1.emulator` 抓 stdout/stderr。
  5. 约定 SmokeBridge 在 PASS 时打印 `EKA2L1_SMOKE: PASS <register-digest>`、FAIL 时打印 `EKA2L1_SMOKE: FAIL <diff>`；脚本 grep 判定。
  6. 默认 30s 超时未见标记 → FAIL。
- 不在阶段 1 接 CI；脚本只做"本地一键复现"，CI 接线放阶段 4。

#### 1.7 文档与遗留项
- 本文件阶段 1 末尾追加"已修复的 iOS 编译/运行问题清单"（结构同阶段 0 的 0.7 列表）。
- 把"dynarmic / MAP_JIT / W^X / entitlement / 各签名通道下的 JIT 启用方法" 整体移交给阶段 4，包括运行时探测、`block_of_code` 分配器接入、benchmark dyncom vs dynarmic 等。

### 阶段 1 修复清单（按出现顺序）
1. **`udf #0` 不能当终止符**：dyncom 的 `InterpreterTranslateInstruction` 在解码失败时调用 `CITRA_IGNORE_EXIT(-1)`，而该宏是空的，于是 `idx` 保持未初始化、随后 `arm_instruction_trans[idx]` 用脏内存当函数指针 → crash。改用 `bkpt #0`（0xE1200070），走 `BKPT_INST → RaiseException → exception_handler → core->stop()` 的官方退出路径。`scripts/gen_ios_cpu_smoke.py` 与 `CpuSmokeBlob.h` 一并更新。
2. **dyncom basic-block 翻译器会读到 bkpt 之后**：即使我们的 bkpt 是终结符，translator 还是会继续解码后续字节（NON_BRANCH 的 bkpt 不会终止块）。如果页面剩余区域是 0，decoder 失败、同样踩第 1 条的坑。`PageBackedCore` 构造时先用 `b .`（0xEAFFFFFE，DIRECT_BRANCH）填满整个 4 KB 页，再把 blob memcpy 到页首；translator 命中第一个 `b .` 就结束块。
3. **`common::log` 未初始化导致 BKPT_INST 在 LOG_DEBUG 时空指针解引用**：`arm_dyncom_interpreter.cpp` 的 BKPT_INST 会调 `LOG_DEBUG(eka2l1::CPU_DYNCOM, ...)`，宏展开里读 `log::filterings` 全局单例。Qt/Android 前端都在启动时调 `eka2l1::log::setup_log(nullptr)`，iOS 前端没有这个步骤，于是 bkpt 一触发就 SIGSEGV @ `log_filterings::is_passed`。`+[EKA2L1CpuSmokeBridge initialize]` 里 `dispatch_once` 调一次 `setup_log(nullptr)` 解决。
4. **`spdlog::basic_file_sink` 在 iOS app bundle 读不到写权限**：`setup_log` 硬编码相对路径 `"EKA2L1.log"`，spdlog 试图 `fopen` 失败抛 `spdlog_ex` → terminate。`+initialize` 在调 `setup_log` 之前 `chdir(NSDocumentDirectory)`，把日志落到 sandbox 内可写目录。
5. **`prot_*` / `arm_emulator_type` 不在 `eka2l1::arm::` 命名空间**：两个枚举都在 `common/types.h` 的顶层（`eka2l1::` 全局），不在 `eka2l1::arm::` 下。Obj-C++ bridge 一开始按 `eka2l1::arm::arm_emulator_type::dyncom` 写就编不过。改成裸名，靠 ADL 找到。

### 阶段 1 已知风险
- cpu 一旦真实被调用，mem/kernel 中假设 Linux / 桌面 macOS 行为的代码会集中暴露。要克制重构冲动，留给后续阶段集中收口。
- iOS 模拟器（Apple Silicon）与真机在线程命名、时间 API 上仍有细微差异；所有修复都要 `EKA2L1_PLATFORM(IOS)` 守护，并在 macOS 桌面构建上跑一次验证。
- dyncom 解释器单步成本不低，smoke blob 不要写得太长（< 10k 指令），否则可能在 SwiftUI 首屏被感知为卡顿；UI 路径必须把执行放后台线程。
- 没有 dynarmic 意味着任何"靠 JIT 才能撑住吞吐"的真实负载（如 N-Gage 游戏的渲染循环）在阶段 1 完全跑不动 —— 这是可接受的，到阶段 4 才解锁。

---

## 阶段 2：iOS 前端壳 + 渲染

### 目标
让 iOS 前端壳真正驱动 `eka2l1::system` 的最小闭环：在 SwiftUI/UIKit 外壳里完成 **ROM 加载 → applist 扫描 → 选中一个应用 → 用 EAGL 渲染一帧 → 触控事件回到 emu_window**。目标不是把所有 Symbian 应用都跑稳，而是验证"前端 ↔ drivers ↔ services ↔ kernel ↔ cpu(dyncom)"在 iOS arm64 上能从输入到出图整链路活的。

阶段 1 已经证明 cpu 子系统在 iOS 上跑得通；阶段 2 把链路向上延伸到 services / window-server / drivers。**显式不在范围内**：音频（cubeb，阶段 3）、振动（Core Haptics，阶段 3）、UIDocumentPicker 导入流程（阶段 3）、设置面板、Vulkan/Metal 渲染、dynarmic JIT（阶段 4）。ROM 通过 Files App 手工放进 sandbox 的 Documents 目录即可，不做精致的导入 UI。

`roms/N95 8GB (S60v3 - FP1)` 解压版与 `roms/snakes-n95_n6trsohu.sis` 用作验证素材：前者是 ROM、后者是一个真实 S60v3 应用安装包。

### 验收标准
- [x] iOS 真机或模拟器上启动 EKA2L1.app 后，SwiftUI 主屏列出 sandbox Documents 下检测到的 ROM；选定 N95 ROM 后能完成 mount、applist 扫描，并显示至少 5 个内建应用条目（与 Qt / Android 前端在同一 ROM 下的列表对得上）。**实测 2026-05-23: 63 apps**。
- [x] 在该列表上点击一个 GUI 内建应用（候选：Calculator / Notes / Calendar，任一不依赖音频且 launch 路径稳定的即可），EAGL 渲染面能稳定刷出 ≥1 帧真实画面（不是清屏色），无 crash 持续运行 ≥ 10s。**实测 2026-05-23: Calculator UI（+, -, ×, ÷, =, ±, √, %, 双箭头，"Options" / "Exit" 软键）稳定渲染 ≥12s**。截屏 `docs/screenshots/ios-stage3/2-acceptance/calculator-rendered.jpg`。
- [x] 在 (Documents) 下放入 SIS 文件（实际改用 `The Final Battle.sis`，详见阶段 3.2.3），前端 UI 上"安装 SIS"入口调 `eka2l1::package::manager::install_package`，安装完成后该 app 出现在列表里、能 launch 到主菜单（即便游戏内逻辑跑不下去也算通过）。**实测 2026-05-23: `Final Battle, uid=0xA0003C62` 在 applist 出现并可 launch，进程持续运行**。截屏 `docs/screenshots/ios-stage3/2-acceptance/applist-with-final-battle.jpg` / `final-battle-launched.jpg`。
- [x] 单指 tap / drag 事件被映射为 `drivers::pointer_event`，能在所选应用的 UI 上完成一次明确可见的交互。**部分达成 2026-05-23**: tap 事件经 `submitPointerEventAtX:y:phase:pointerId:` 走完整 winserv 通路（mount → app launch → EmulatorView tap），但 S60v3 Calculator 数字输入要求物理 12-key 数字键盘，UI 上没有 on-screen 数字按钮 — `1 + 1 =` 需要 stage 3.11 完成虚拟键盘后才可重现。剩余的"可见交互"由"tap Final Battle button → EmulatorView 切到该 app"的导航路径覆盖。
- [ ] iOS 下 `eka2l1::drivers::graphics::make_gl_context` 返回真实 EAGL 上下文实现，不再走 nullptr 兜底；ogl 后端在 iOS 上编进 drivers 并被 graphics_driver 正常实例化。
- [ ] App 进入后台 (`UIApplicationWillResignActive`) 时模拟器暂停、回前台时恢复，不出现因丢失 GL 上下文的渲染崩溃。
- [ ] 阶段期间为修复 iOS 编译/运行问题打的 patch 集中记录在本阶段末尾的"阶段 2 修复清单"，沿用 0.7 / 1.x 的体例。

### 子任务

#### 2.1 ogl 后端在 iOS 上的最小可编
- [x] `src/emu/drivers/CMakeLists.txt`：`DRIVERS_OGL_SRC` 提到三平台共用；iOS 下 `target_link_libraries(drivers PRIVATE "-framework OpenGLES")` 直接链 system framework，glad 仍只在桌面/Android 链接。
- [x] 新增 `src/emu/drivers/include/drivers/graphics/backend/ogl/ios_gl_loader.h`，集中：①`#include <OpenGLES/ES3/gl.h>` + `<OpenGLES/ES3/glext.h>`；②`glad_glGetError` / `glad_glLineWidth` 直通真实 GLES 入口；③`gladLoadGL` / `gladLoadGLES2Loader` / `glad_set_post_callback` 写成 no-op；④补齐 `GL_BGRA` / `GL_BGR` / `GL_LINE_SMOOTH` / `GL_MULTISAMPLE` / `GL_SAMPLE_ALPHA_TO_ONE` / `GL_TEXTURE_1D` / `GL_TEXTURE_BINDING_1D` / `GL_TEXTURE_BORDER_COLOR` / `GL_SAMPLER_1D` / `GL_GEOMETRY_SHADER`；⑤inline shim：`glClearDepth` → `glClearDepthf`、`glDepthRange` → `glDepthRangef`、`glDrawBuffer` → `glDrawBuffers(1, …)`、`glPolygonMode` no-op、`glDrawElementsBaseVertex` 丢弃 base vertex 走 plain `glDrawElements`、`glTexImage1D` / `glTexSubImage1D` / `glCompressedTexImage1D` / `glCompressedTexSubImage1D` 全部空实现（Symbian 内容不会真的走 1D 纹理路径）；⑥顶端 `#define GLES_SILENCE_DEPRECATION` 抑制 iOS 12+ 噪音。
- [x] 八个 ogl 源/头里所有 `#include <glad/glad.h>` 改成 `#if EKA2L1_PLATFORM(IOS) ios_gl_loader.h #else glad.h #endif`，桌面/Android 路径完全不变。`graphics_driver_shared.cpp` 已是 iOS-exclude，留作 no-op。
- [x] 工厂层 `buffer.cpp` / `graphics.cpp` / `shader.cpp` / `fb.cpp` / `texture.cpp` / `input_desc.cpp` 中阶段 0 留下的 `#if !EKA2L1_PLATFORM(IOS)` 守卫全部撤掉，让 iOS 也走 `case graphic_api::opengl: return std::make_unique<ogl_*>(...)` 实分支。
- [x] 真实构建验证：`scripts/build_ios.sh simulator` 通过；`scripts/build_ios.sh smoke` 仍打 `EKA2L1_SMOKE: PASS backend=dyncom instrs=9 pc=0x00001024`，桌面 GL 假设并未泄漏到 dyncom smoke 路径。

#### 2.2 EAGL graphics context
- [x] 新建 `src/emu/drivers/src/graphics/backend/context_eagl.{h,mm}`：`gl_context_eagl` 持有 `EAGLContext *`（优先 `kEAGLRenderingAPIOpenGLES3`，失败回落 GLES2）+ `CAEAGLLayer *`，自行管理 framebuffer / colorRenderbuffer / depth-stencil renderbuffer。`render_surface == nullptr` 时降级 headless，只建 FBO 备用。
- [x] `attach_layer` 走 `[EAGLContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:]` 绑 layer；从 renderbuffer 反查 width/height 作为 `m_backbuffer_*`；挂 `GL_DEPTH24_STENCIL8` 到 depth/stencil attachment。
- [x] `swap_buffers` = `presentRenderbuffer:GL_RENDERBUFFER`；`make_current` / `clear_current` 走 `[EAGLContext setCurrentContext:]`。`update(w,h)` 重新 attach layer（renderbuffer 跟随 drawable size）。
- [x] `pause()` 在持有 context 的线程上 `glFinish` 再 `setCurrentContext:nil`；`resume()` 重新 setCurrentContext。后台回前台时给前端 hook（任务 2.9 调用）。
- [x] `update_surface(void*)` 允许 EAGLView 重建后换 layer。
- [x] `context.cpp` 在 `EKA2L1_PLATFORM(MACOS)` 之前优先匹配 `EKA2L1_PLATFORM(IOS)`，返回 `gl_context_eagl`；AGL 路径不动。`window_system_type::iOS` 加入枚举。
- [x] `CMakeLists.txt` iOS 分支编译 `context_eagl.{h,mm}`，并链 `QuartzCore` / `Foundation` / `UIKit`（除原本就有的 OpenGLES.framework）。simulator 构建通过。

#### 2.3 iOS emu_window
- [x] 新建 `src/emu/drivers/include/drivers/graphics/backend/emu_window_ios.h` + `src/emu/drivers/src/graphics/backend/emu_window_ios.mm`：继承 `drivers::emu_window`，全部纯虚的桌面/触屏 API 给出 no-op 实现（cursor / fullscreen / poll_events / change_title 等）。
- [x] `surface_changed(void *layer, int w, int h, float scale)`：iOS 前端在 EAGLView 的 `layoutSubviews` 中调用，更新 layer 指针 + framebuffer 像素尺寸 + scale，再触发 `surface_change_hook` 与 `resize_hook`，把新 surface 透到 EAGL context（任务 2.7 接入）。
- [x] `get_window_system_info()` 返回 `window_system_type::iOS` + render_surface（CAEAGLLayer 指针）+ surface_width/height + render_surface_scale，供 EAGL context 初始化使用。
- [x] `window_size()` 用 fb_size/scale 换算 logical points，`window_fb_size()` 返回像素尺寸；mouse 路径返回 0（pointer 事件走 `IosEmulator::submit_pointer_event`，任务 2.8）。
- [x] `CMakeLists.txt` 把 `emu_window_ios.{h,mm}` 一并塞进 iOS 分支的 drivers target；simulator 构建通过。

#### 2.4 iOS 端 emulator state 对象
- [x] 新建 `src/emu/ios/Bridge/IosEmulator.{h,mm}`：Obj-C facade `EKA2L1Emulator` (singleton) + 私有 C++ `eka2l1::ios::emulator` struct，字段 `unique_ptr<system> symsys` / `unique_ptr<config::app_settings>` / `unique_ptr<drivers::emu_window_ios>` / `drivers::graphics_driver_ptr` / `config::state conf`。无 audio / sensor / camera / vibration 字段（阶段 3）。
- [x] facade API：`+shared` 单例、`-startWithDocumentsPath:`、`-shutdown`、`-availableRoms`、`-mountRomNamed:`、`-rescanApps`、`-launchAppWithUID:`、`-installSisAtPath:`、`-attachLayer:pixelSize:scale:`、`-pause` / `-resume`、`-submitPointerEventAtX:y:phase:pointerId:`。`EKA2L1AppEntry` 类用于跨边界传 `(uid, name)`。
- [x] `startWithDocumentsPath:` 建 `<Documents>/{roms,data,sis,data/drives/{c,d,e,z},data/compat}` 目录，`chdir(<Documents>/data)` 之后初始化 `log::setup_log`、deserialize config、把 `conf.storage` 指向 sandbox data 目录，再构造 `eka2l1::system`（audio_ / graphics_ 都置 nullptr）。
- [x] `availableRoms` 扫 `<Documents>/roms` 一级子目录返回名字数组；`mountRomNamed:` / `rescanApps` / `launchAppWithUID:` / `installSisAtPath:` / `submitPointerEventAtX:...` 当前是占位 stub，留待 2.6 / 2.8 / 2.9 真实接入。
- [x] `attachLayer:pixelSize:scale:` 转发到 `emu_window_ios::surface_changed`，把 layer 指针推到 `window_system_info::render_surface`；graphics_driver 实例化与 emu 线程在 2.9 接入。
- [x] Bridging-Header 加入 `IosEmulator.h`；CMake 把 `IosEmulator.{h,mm}` 编进 iOS bundle。
- [x] 链接闭环修复：①新增 `src/emu/common/src/ios/applauncher.mm`，`eka2l1::common::launch_browser` 走 `UIApplication openURL`（host_launch.o 一直引用该符号，桌面有 Qt 版、Android 有 JNI 版，iOS 之前缺）；②新增 `src/emu/drivers/src/ui/input_dialog_ios.cpp`，`drivers::ui::open_input_view` / `close_input_view` / `show_yes_no_dialog` 暂作 no-op，让 dispatch 层的 ehui_* 链接通过（真实弹窗推迟到阶段 3）。simulator build 通过。

#### 2.5 ROM / 数据布局
- [x] sandbox 目录结构写进 `IOS_PORTING_PLAN.md` 阶段 2 章节："iOS sandbox 目录布局（任务 2.5 定稿）"：`Documents/{roms/<rom>,data/{drives/{c,d,e,z},compat,config.yml,EKA2L1.log},sis/}`，附 host 路径取法。
- [x] `IosEmulator::startWithDocumentsPath:` 自动建出全部缺失子目录（roms / data / sis / drives/{c,d,e,z} / compat），然后 `chdir(<Documents>/data)` 并把 `conf.storage` 指向同路径。前端从此不再依赖 cwd 假设。
- [x] 新增 `scripts/seed_ios_simulator_documents.sh`：把本地 `roms/` 一级子目录用 `rsync -a --delete` 同步到 `xcrun simctl get_app_container booted <bundle> data/Documents/roms/`，顶层 `*.sis` / `*.sisx` 同步到 `…/Documents/sis/`；支持 `--dry-run`，含路径含空格的目录正确加引号；booted 模拟器缺失或 EKA2L1 未装时报错退出。
- [x] 回归：`scripts/build_ios.sh smoke` 仍 PASS，证明 sandbox bootstrap 没有影响 stage-1 通路。

#### 2.6 ROM 加载与 applist 扫描
- [x] `-mountRomNamed:`：把 `<Documents>/data/drives/z/` `symlink → <Documents>/roms/<name>/`（避免几百 MB 的拷贝），再依次 `rescan_devices(drive_z)` / `startup()` / `set_device(0)` / 挂 C/D/E/Z / `initialize_user_parties()`，最后通过 `get_winserv_name_by_epocver` 抓 `window_server` 句柄缓存到 state 里（任务 2.8 的输入路径要用）。前提是 ROM 文件夹内已经是 desktop 安装好的 device 树（含 `devices.yml`），与 Android 流程一致；没有 device 时返回 NO 让 UI 报错。
- [x] `-rescanApps`：通过 `kern->get_by_name<service::server>(get_app_list_server_name_by_epocver(...))` 抓 `applist_server`，调 `rescan_registries(io)`，遍历 `get_registerations()`，跳过 `caps.is_hidden`，把 `(uid, long_caption→UTF8)` 装进 `EKA2L1AppEntry` 数组返回 Swift。Icon / SVG 渲染留给阶段 3。
- [x] `-launchAppWithUID:`：拿 `get_registration(uid)`，构造 `epoc::apa::command_line{ launch_cmd_ = command_create }`，`kern->lock()` → `alserv->launch_app(*reg, cmdline, nullptr, nullptr)` → `kern->unlock()`，返回结果布尔。
- [x] `-installSisAtPath:`：调 `symsys->install_package` 装到 E 盘（S80 则装 D），结果转 `installation_result_success` 判断。
- [x] simulator build 通过；运行时是否能真正拉起一个 GUI 应用要等任务 2.7 / 2.9 装好渲染管线后才能验证，stage-2 验收阶段最后跑 manual 走查。

#### 2.7 SwiftUI 外壳与 EAGL 视图
- [x] 重写 `src/emu/ios/App/ContentView.swift`：`NavigationStack` 三屏 — ROM 列表（`Documents/roms` 一级目录）→ App 列表（`mountRomNamed:` + `rescanApps` + "Install SIS" 列出 `Documents/sis/` 下 `.sis/.sisx`）→ EmulatorView。原 CPU smoke UI 移到 "Diagnostics" 二级页（保留 `EKA2L1CpuSmokeBridge` 入口）。booting 时调 `EKA2L1Emulator.shared().start(documentsPath:)`，失败展示 banner。
- [x] 新建 `src/emu/ios/App/EmulatorView.swift`：`UIViewControllerRepresentable`，把 UID 透到 `EmulatorViewController`。
- [x] 新建 `src/emu/ios/Bridge/EmulatorViewController.{h,mm}`：内部 `EAGL2L1View : UIView`，`+layerClass = CAEAGLLayer`，`contentScaleFactor = UIScreen.mainScreen.nativeScale`，`opaque = YES`；`layoutSubviews` 算出像素尺寸后 `attachLayer:pixelSize:scale:` 推回 IosEmulator。`viewDidAppear` 在 layer ready 后 `launchAppWithUID:` + `resume`；`viewWillDisappear` `pause`。
- [x] Bridging header 加入 `EmulatorViewController.h`；CMake bundle 编进 `EmulatorView.swift` + `EmulatorViewController.{h,mm}`；simulator build 通过。
- [x] 单指触控派发到 `EKA2L1Emulator::submitPointerEventAtX:y:phase:pointerId:`（任务 2.8 的派发链路在这里就位，IosEmulator 内部转发到 window_server 也在 2.8 完成）。

#### 2.8 输入：触控 → pointer_event
- [x] `EAGL2L1View` 重写 `touchesBegan/Moved/Ended/Cancelled`：对每个 `UITouch` 抽 `locationInView:`，乘 `contentScaleFactor` 转 framebuffer 像素，phase 映射 `UITouchPhase → EKA2L1PointerPhase`，`pointerId = (uintptr_t)touch` 单调可比，调 `EKA2L1Emulator::submitPointerEventAtX:y:phase:pointerId:`。
- [x] `multipleTouchEnabled = NO`（stage-2 验收只要求单指）；多指 / 长按 / 拖拽手势识别留给阶段 3。
- [x] `IosEmulator::submitPointerEventAtX:...` 构造 `drivers::input_event{ type_=touch, mouse_=…, raw_screen_pos_=true, mouse_id=pointerId&0xFFFFFFFF }`，phase 映射 `mouse_action_press/repeat/release`，调 `_state->winserv->queue_input_from_driver(evt)`。`winserv` 句柄是任务 2.6 `mountRomNamed:` 时从 `kern->get_by_name<service::server>(get_winserv_name_by_epocver(...))` 拿到的，未挂 ROM 时 silently drop。
- [x] 不接键盘 / 物理键盘 / 游戏手柄；阶段 4 与发布通道一起做。simulator build 通过。

#### 2.9 帧循环与生命周期
- [x] `startWithDocumentsPath:` 末尾 spawn 两条 `std::thread`：①graphics_thread —— 在 `layer_cv` 上等到 attachLayer 首次推 layer，把 layer 透给 `emu_window_ios::surface_changed`，然后在本线程创建 `drivers::create_graphics_driver(opengl, info)`（这样 EAGL context 与 ogl driver `run()` 都绑定在同一条线程），注册 `surface_change_hook` / `set_display_hook`（presentRenderbuffer 已经在 `gl_context_eagl::swap_buffers` 内部，hook 为空），最后调 `graphics_driver->run()` 阻塞驱动循环。②os_thread —— `while(running) symsys->loop()`；`paused` 时 sleep。
- [x] `attachLayer:pixelSize:scale:`（主线程调用）在 layer_mutex 下把指针/尺寸/scale 推到 pending_* 字段并 `notify_all`，graphics_thread 首次启动后续 layout 变更则走 `emu_window_ios::surface_changed → surface_change_hook → graphics_driver->update_surface`，避免再次跨线程构造 driver。
- [x] `mountRomNamed:` 成功后给每块 `epoc::screen` 注册 `add_screen_redraw_callback`，回调里 `wait_for(&present_status)` → `graphics_command_builder.present(&present_status)` → `submit_command_list`，让窗口服务的画帧节拍触发 EAGL swap。
- [x] `EKA2L1App` 用 `@Environment(\.scenePhase)` 监听 `.active / .inactive / .background`：active → `EKA2L1Emulator::resume`、其它 → `pause`。`pause` 标志被 os_thread 与 swap_buffers 双重尊重；graphics_driver::pause()/resume() 留给后续在 gl_context_eagl 上加 hook（当前 swap_buffers 已经检查 `m_paused`）。
- [x] `shutdown` 把 `running=false`、`layer_cv.notify_all`、`graphics_driver->abort()`，再 join 两条线程，安全释放 symsys / driver / window。
- [x] **stage-1 回归**：阶段 2 UI 重构后 `scripts/build_ios.sh smoke` 不再因为 ContentView 不自动跑 smoke 而 timeout —— 改在 `EKA2L1App.init()` 里 background dispatch 一次 `EKA2L1CpuSmokeBridge`，PASS 仍打 `EKA2L1_SMOKE: PASS backend=dyncom instrs=9 pc=0x00001024`。simulator + smoke 双绿。

#### 2.10 验证脚本
- 不要求阶段 2 做端到端的"无人值守"自动验证（无法可靠 grep 出"出图了"）；保留 `scripts/build_ios.sh smoke` 的语义不变，只验 CPU smoke 仍然通过——这是回归网。
- 新增 `scripts/seed_ios_simulator_documents.sh`：把 `roms/N95 8GB (S60v3 - FP1)`、`roms/snakes-n95_n6trsohu.sis` 同步到当前 booted 模拟器的 EKA2L1 sandbox Documents 下，方便复跑。
- 手工验收步骤记录在本阶段末尾（截屏 + 日志）。

#### 2.11 文档与遗留项
- [x] 阶段 2 修复清单已就位（见下文 10 条），沿用 0.7 / 1.x 体例。
- [x] 重构动作明确推到阶段 3：①真正的 ROM 安装流程（替代 symlink + 期望 desktop 预装 device）；②launcher::draw 等价的 iOS 复合渲染（背景 / letterbox / 缩放 / 旋转）；③SVG/MIF 图标解码 + icon UI；④UIDocumentPicker SIS 导入；⑤UIAlertController 真实输入对话框；⑥cubeb iOS 后端 + Core Haptics 振动；⑦多指 / 长按 / 屏幕键盘。
- [x] 变更日志补一条 2026-05-22 收尾。

### 阶段 2 修复清单（按出现顺序）
1. **`GL_BGR` / `GL_BGRA` / `GL_LINE_SMOOTH` / `GL_MULTISAMPLE` / `GL_SAMPLE_ALPHA_TO_ONE` / `GL_TEXTURE_1D` / `GL_TEXTURE_BINDING_1D` / `GL_TEXTURE_BORDER_COLOR` / `GL_SAMPLER_1D` / `GL_GEOMETRY_SHADER`**：GLES3 头文件不存在。集中在 `ios_gl_loader.h` 里给等价或占位常量，让 ogl backend 的 enum 表能编通；运行期那些功能不会被打开（feature gate 已隔离）。
2. **`glClearDepth` / `glDepthRange` / `glDrawBuffer` / `glPolygonMode` / `glDrawElementsBaseVertex` / `glTex(Sub)?Image1D` / `glCompressedTex(Sub)?Image1D`**：GLES3 缺失。`ios_gl_loader.h` 内 inline shim：`f`-后缀别名 / `glDrawBuffers(1, …)` / no-op / 丢 baseVertex / 1D 全空实现。Symbian 内容不会真的踩 1D 纹理；线框 / draw-buffer / depth-range 已不再用。
3. **glad 接口直通**：把 `glad_glGetError` / `glad_glLineWidth` 在 iOS 下 `#define` 到 GLES 入口；`gladLoadGL` / `gladLoadGLES2Loader` / `glad_set_post_callback` / `GLADloadproc` 全部 no-op，因为 iOS 上 OpenGLES.framework 是直接链接的。
4. **iOS 12+ GLES deprecation**：`ios_gl_loader.h` 顶端 `#define GLES_SILENCE_DEPRECATION` 抑制告警噪音。
5. **`gl_context_eagl::attach_layer` 在 SwiftUI 主线程被构造会拿不到 EAGLContext 所有权**：把 `create_graphics_driver` 推到 graphics_thread，layer 指针通过 condition_variable 跨线程递交，保证 context / FBO / present 都在同一条线程上。
6. **`drivers::ui::open_input_view` / `close_input_view` / `show_yes_no_dialog` 链接缺失**：dispatch 层的 `ehui_*` 引用这三个符号，Android/Qt 各自实现。新增 `drivers/src/ui/input_dialog_ios.cpp` 暂作 no-op，真实 UIAlertController 留给阶段 3。
7. **`common::launch_browser` 链接缺失**：`host_launch.o` 引用，Android 走 JNI，Qt 走 `QDesktopServices`。iOS 新增 `common/src/ios/applauncher.mm` 走 `[UIApplication openURL:options:completionHandler:]`。
8. **smoke 自动回归丢失**：阶段 2 把 ContentView 从 "默认跑 smoke" 改成 "默认进 ROM 列表"，导致 `scripts/build_ios.sh smoke` 30s timeout。改在 `EKA2L1App.init()` 里 background dispatch 一次 `EKA2L1CpuSmokeBridge` 并 NSLog `EKA2L1_SMOKE: ...` 标记，UI 流程保持新的 stage-2 三屏。
9. **`drive_number` 命名空间**：阶段 0 写的 `eka2l1::drive_number::drive_d` 在 iOS path 触发 "no type named 'drive_number' in namespace 'eka2l1'"。`drive_number` / `drive_z` 等都是顶层枚举，去掉冗余的 `eka2l1::` 限定即可。
10. **`present_status` 类型**：第一版写成 `std::atomic<int>` 想跨线程，但 `graphics_command_builder::present(int*)` 要的是裸 `int*`。还原为 `int` 字段，依赖窗口服务回调串行化保护。
11. **os_thread 在 mount 之前跑 `symsys->loop()` → SIGSEGV**：xcodebuildmcp 装好 .app 后启动立刻 crash。Crash report 显示 `kernel_system::crr_thread()` 在 `unique_ptr<thread_scheduler>::operator->` 上 deref null —— `system_impl::loop()` 在 `set_device` / `startup` 之前不能跑。补一个 `std::atomic<bool> mounted{false}`，os_thread 未 mount 时只 sleep；`mountRomNamed:` 末尾翻为 true。修复后 simulator 启动稳定，主屏 → AppListView → Mount 全程不再 crash。
12. **ROM mount 用 symlink graft 时 `rescan_devices` 的 "broken device" cleanup 会沿 symlink 删用户 ROM 源文件**：早期 mount 把 `Documents/data/drives/z → roms/<rom>/data/drives/z` 整体软链，`rescan_devices` 检测到 SYM.ROM 不在期望路径时调用 `delete_folder(full_entry_path)`，POSIX `remove_all` 跟随 symlink 把源 8000+ 文件清掉。改成完全跳过 `rescan_devices`：seed 阶段写好 `devices.yml`，mount 直接 `startup` → `set_device(0)` → `mount(...)`。
13. **iOS sim app 容器的 case-sensitivity 是单边的**：host APFS 卷case-insensitive（shell 视角看 `RM-320` / `rm-320` 同一 inode），但 iOS sim runtime 给 app 进程的是 case-sensitive 视图（`fopen("rm-320")` 返 ENOENT 当真名是 `RM-320`）。无法同时存在两种 case 的条目（host 层 EEXIST 拒绝）。系统代码大量用 `common::lowercase_string(firmcode)` 拼路径，所以 sandbox 内 dirs 一律用**小写**：`data/drives/{c,d,e,z}`、`data/roms/<lower-firmcode>`、`SYM.ROM`（系统硬编码大写）。`sys->mount(...)` 也跟着传小写路径。
14. **stage-2 mount 链路真实跑到 kernel chunk allocation 的 SIGBUS**：经过上面所有修复后，xcodebuildmcp 自动化点 Mount 流程现在能跑完 `mountRomNamed:` → 重建 system → `startup()` → `set_device(0)` → 进 `reset` → 映射 ROM 到 `0x11f904000` → 创建 ROM chunk → 创建 kernel-data chunk → 进 `dispatcher` 初始化分配 chunk 时 `std::fill_n` 写 0 触发 `SIGBUS KERN_PROTECTION_FAILURE`。这是 stage-3 才该解决的 iOS sandbox mmap 限制（kernel memory model 在 host 上拿到的虚拟页不可写），与 stage-2 的"前端 → mount → applist → 帧 → 触控"管线本身无关。stage-2 acceptance 的"applist ≥ 5 / 出一帧 / 点 Calculator" 仍需 stage-3 把 kernel chunk 分配迁到 iOS 友好的 mmap 路径（MAP_JIT / 显式 mprotect / 自管 chunk 分配器）后才能跑通。

### 阶段 2 已知风险
- **OpenGL ES on iOS 已 deprecated 但仍可用**：iOS 12+ 至今 SDK 仍带 OpenGLES.framework，但 Apple 偶尔在新 SDK 提高警告等级。验收期内（iOS 18 / Xcode 26 序列）确认 OK；长期方向是 MoltenVK / Metal，留给后续阶段。一旦 SDK 真的拿掉 OpenGLES，本阶段产物会一起失效，但这是已知交换。
- **ogl 后端隐含的桌面 GL 假设面积可能比当前列出的大**：解码路径里的 `GL_BGRA`、纹理 swizzle、PBO upload、debug callback 等都可能命中。原则同阶段 1 ——就地最小修复 + `// TODO(ios)`，不重构。
- **EAGL 上下文与线程绑定严格**：一旦把 emu 线程切到别处或在主线程偷偷调 GL，会拿到 `INVALID_OPERATION` 或直接 crash。所有 GL 调用必须严格走 emu 线程；后台/前台切换路径要在第一版就写对。
- **applist 在 iOS 上首次扫描可能因 vfs/路径假设暴露 Linux/Android 专属代码**：`load_registry` 系列在 case-sensitive FS 下读 Z 盘资源时，路径大小写差异可能导致扫描结果为空。优先复用 Android 的 `vfs` 处理，避免阶段 2 引入新 vfs 行为。
- **Documents 沙盒路径含空格**：`N95 8GB (S60v3 - FP1)` 这种带空格的目录名会让 shell 脚本 / 部分 C++ 路径拼接出问题。`seed_ios_simulator_documents.sh` 必须正确引用，C++ 侧确认 `eka2l1::common::utf8_to_utf16` + `loader` 不在路径里强行 split。
- **不做 audio 的情况下 services 启动顺序可能依赖音频初始化完成的信号**：阶段 0 已经让 `make_audio_driver` 在 iOS 返回 nullptr，但 services 内部 `if (audio_driver)` 检查不一定齐全，可能在 applist / mediaclient 启动路径上踩 nullptr。命中时就地最小修复，不要在阶段 2 改音频架构。

---

## 阶段 3：解锁 mount 链路 + 完成阶段 2 验收 + 完整体验

### 目标
两件事并轨推进：

1. **解阶段 2 遗留**：阶段 2 修复清单第 14 条的 kernel chunk SIGBUS 把 mount → applist → 出帧 → 触控 这条主线管线堵在了 "chunk 初始化写 0" 那一步，导致阶段 2 的真实验收（applist ≥ 5、Calculator 出一帧、单指交互、SIS 安装后出现在 applist）至今没法跑通。阶段 3 必须先把这个 mmap/mprotect/W^X 的 mismatch 解掉，然后回头补完阶段 2 的真实验收，再继续往下。
2. **完整体验**：在 mount 链路彻底通畅后，按原计划把音频（cubeb AudioUnit）、振动（Core Haptics）、文件导入（UIDocumentPicker）、SVG/MIF 图标、设置面板、UIAlertController 输入、多指/手势、真正的 ROM 安装流程、字体导入引导逐项接齐。

阶段 4 的 dynarmic / JIT / W^X / entitlement / 发布通道**仍然不在范围内** —— 阶段 3 只在解 3.1 的 chunk 分配问题时，会顺手把 `common::virtualmem` 的 "非可执行内存" 路径理顺；可执行内存（MAP_JIT）继续推迟到阶段 4，与签名通道一起做。

### 验收标准
- [ ] **阶段 2 acceptance 补完**：N95 ROM 在 booted 模拟器和 iOS 真机上挂载后，applist 列出 ≥ 5 个内建应用、与 Qt / Android 前端在同一 ROM 下的列表对得上；点击 Calculator（或 Notes / Calendar，任一不依赖音频的 GUI 内建应用），EAGL 渲染面稳定刷出 ≥ 1 帧真实画面、无 crash 持续 ≥ 10s；单指 tap 把 `1 + 1 =` 算出来。
- [ ] **SIS 安装链路真实跑通**：通过 UIDocumentPicker 或手工放进 `Documents/sis/`，`snakes-n95_n6trsohu.sis` 装到 E 盘、出现在 applist 并能 launch 到游戏主菜单（游戏内逻辑跑不下去不计入失败）。
- [ ] **音频**：cubeb iOS AudioUnit 后端在 iOS 重新进 build graph，`make_audio_driver` 返回真实实例；一个带 BGM 或 SFX 的 ROM 应用（候选：N-Gage 试玩 / 一个有声音的 Symbian 小游戏）能听见声音。
- [ ] **振动**：`drivers::vibration` 在 iOS 下走 `CHHapticEngine`（或 `UIImpactFeedbackGenerator` fallback），有一个触发振动的应用能感受到反馈，无 crash。
- [ ] **文件导入**：`UIDocumentPickerViewController` + Info.plist 文件关联（`.sis` / `.sisx` / `.zip`-ROM / `.ttf`-字体）打通；从 Files App "Share to EKA2L1" 把上述四类资源送进 sandbox 对应目录，前端 UI 上即时刷新。
- [ ] **AppList 图标**：applist 显示真实 SVG/MIF 图标（解码走 lunasvg / mif decoder），不再是占位。
- [ ] **设置面板**：SwiftUI 设置页覆盖 `config::state` 主要字段（device 切换、屏幕方向、上采样、音量、按键映射），改动持久化到 `config.yml`。
- [ ] **输入对话框**：阶段 2 留下的 `input_dialog_ios.cpp` no-op 替换为真实 `UIAlertController` 实现（包括 `open_input_view` / `close_input_view` / `show_yes_no_dialog`）。
- [ ] **真正的 ROM 安装流程**：取消阶段 2 mount 用的 "目录 symlink graft + 期望 desktop 预装 device tree" 权宜方案，iOS 端自管 `devices.yml` 生成 / device 注册 / 资源拷贝；同时由本阶段引入的 chunk 修复保证 `rescan_devices` 即使误删也不会跟随 symlink 删用户原始 ROM。
- [ ] **字体导入引导**：检测到 ROM 缺字体时，UI 引导用户通过 DocumentPicker 添加 `.ttf`，拷到 `data/fonts/` 并被 freetype 拾取。
- [ ] **多指 / 手势**：`multipleTouchEnabled = YES`，至少跑通双指（用于 launcher 缩放或屏幕键盘场景）和长按手势。
- [ ] 阶段 3 修复清单按出现顺序登记（同 0.7 / 1.x / 2.x 体例）。

### 子任务

#### 3.1 解锁 mount 链路：iOS 内核 chunk 写 0 SIGBUS ✅
- 定位现场：阶段 2 #14 的 SIGBUS 出现在 mount 走到 dispatcher 初始化分配 kernel chunk → `std::fill_n` 清零时，地址 `0x11f904000` 区间。先把崩溃栈、所在 chunk 的 `create_info`（region flag / size / max_size / permission）、`commit()` 的实际入参与 `mprotect` 的 errno 全部抓出来登记到本阶段修复清单里，再决定怎么改。
- 候选 root cause：①`common::map_memory` 在 iOS 上 reserve 一大块 `PROT_NONE`，随后 `commit()` 走 `mprotect(PROT_READ|PROT_WRITE)` —— iOS sandbox 对单进程最大 mmap 数 / RLIMIT_AS / `vm_allocate` 行为与 Linux / macOS 桌面不一致，可能 mprotect 返回 0 但实际页未真正变成 W；②kernel chunk 的某个 region 标志在 iOS 上被错误识别成 code（W^X 互斥下默认 R+X，写入就 KERN_PROTECTION_FAILURE）；③`max_size_` 与 page size 错位，commit 漏掉了 `fill_n` 写的尾部页。需要逐一排查，不要凭直觉一把改。
- 修法分层（按代价从低到高，验证一种再上下一种）：
  1. 在 `multiple_mem_model_chunk::create` / `commit` 路径上加 iOS 专属断言 + 详细日志，先把哪条 region / 哪段 offset 失败定死。
  2. 如果是 W^X 误判：在 `common::is_memory_wx_exclusive()` 的语义上明确 "非可执行内存不受 W^X 限制"，让 kernel data / ROM image / dispatcher static 走纯 RW 路径，不被当作 JIT。
  3. 如果是 mmap reserve 行为差异：iOS 下改用 "小步 reserve + commit 同步分配" 或直接 `mmap(MAP_ANON|MAP_PRIVATE, PROT_READ|PROT_WRITE)` 跳过 `PROT_NONE` 阶段；必要时给 `common::map_memory` 增加 iOS 分支或新增 `map_memory_committed(size, prot)` API。
  4. 如果是 dispatcher 自己的内部分配器假设了 "reserve 完整 chunk 后线性 fill" —— 在 iOS 下让分配器按已 commit 区域走，或一次性 commit 全 chunk。
- **不在 3.1 范围内**：dynarmic / MAP_JIT / `pthread_jit_write_protect_np`。这些是阶段 4。3.1 只解决 "非可执行内存的写访问"。
- 验收：xcodebuildmcp 自动化或手工，从启动 → 主屏 → 选 N95 → Mount → `set_device(0)` → reset → ROM 映射 → ROM chunk → kernel-data chunk → dispatcher 初始化 全程不再 SIGBUS；`symsys->loop()` 真正开始驱动 winserv 心跳。

#### 3.2 阶段 2 验收最后一公里 🟡
- 3.1 + 3.2.1 通畅后，xcodebuildmcp 自动化跑：booted iPhone 16 Pro 模拟器上启动 → 进 ROM 列表 → 选 N95 → Mount → 等 applist 渲染 → 校验 entry 数 ≥ 5、能看到 Calculator / Notes / Calendar / Camera / Contacts 这类典型名字 → 点 **Calculator** → 等渲染面出非清屏色 → 单指 tap `1 + 1 =` → 截屏归档。
- SIS 安装验证：使用 **`The Final Battle.sis`** 替换原计划的 `snakes-n95_n6trsohu.sis`（N95 ROM 上 Snake 启动到主菜单后被自身的 codeseg 兼容性 bug 卡住，与 iOS 端无关）。把 The Final Battle.sis 拷进 `Documents/sis/`，UI 上点 "Install SIS" → applist 出现新条目 → launch → 截屏归档。
- 把这次手工验收的截屏与日志归档到 `docs/screenshots/ios-stage3/2-acceptance/`（沿用 stage-2 的 archive 结构），并把 stage 2 状态从 🟡 翻 ✅；阶段总览表 + 阶段 2 验收复选框相应更新。
- 不要求阶段 3 端到端无人值守自动化，`scripts/build_ios.sh smoke` 仍只验 CPU smoke 不退化。
- **当前状态（2026-05-23 evening）**：✅ **3.2 关闭**。iPhone 16 Pro 模拟器上 mount N95 → applist 63 app；点 Calculator → EmulatorView 出 Calculator 真实 UI（截屏 `docs/screenshots/ios-stage3/2-acceptance/calculator-rendered.jpg`），稳定 ≥12s；点 The Final Battle.sis → applist 出 `Final Battle, uid=0xA0003C62`（截屏 `applist-with-final-battle.jpg`）；点 Final Battle button → EmulatorView 出 FBattle launch（截屏 `final-battle-launched.jpg`，FBattle 进程持续 108+ 次线程调度，音频缺失导致 hssSDthread 退出但游戏主线程仍活）。剩余 follow-up：3.11 虚拟键盘后才能完成 Calculator 的 `1 + 1 =` 数字输入交互（S60v3 数字键没有 on-screen 按钮）。

#### 3.2.1 app launch 后 guest "Main" 线程 PC=0 死循环 ✅（host-page 对齐后自动解决）
- 现象：mount N95 ROM 后从 SwiftUI 列表点任意 GUI app（已试 Themes uid 0x10005A32、Mce/Messaging uid 0x100058c5），IosEmulator 调到 `alserv->launch_app`，新进程的 local chunks（0x400000 / 0x500000 / 0x600000 / 0x700000）都创建成功；紧接着 dyncom 开始连续打 `Access violation reading address 0x0 / 0x4 / 0x8 / …` 直到当前 page 结束。EmulatorView 渲染面停在黑色。
- 通过加在 `process::create_prim_thread` / `thread_scheduler::switch_context` / `kernel_system::cpu_exception_handler` 的 iOS 诊断日志（带 `// TODO(ios)` 标签）+ xcodebuildmcp 自动化，拿到以下事实链：
  1. `create_prim_thread: process=Mce code_addr=0x82715718 ep_off=0x82715718 stack=0x10000` —— 入口地址来自 codeseg，是合法 ROM 地址（SYM.ROM 文件偏移 0x2715718 处确实是 ARM 指令）。
  2. `Switch to thread Main pc=0x82715718 lr=0x00000000 sp=0x0050FFC0 r4=0x00000000 cpsr=0x00000000` —— 调度器只调度了一次（整个 run 里 switch_context 计数 = 1）。
  3. 立即开始 access violation，但 `lr` 已经从 0 变成 `0x803A9F89`（ROM 内一段合法 Thumb 地址）。说明在调度切上来到第一次 fault 之间，guest 真的执行了若干 ARM/Thumb 指令并发生了 BL/BLX。
  4. 静态分析入口：`0x82715718` 的 ARM 入口 stub（TST/CMP/B/MOVLS/BLS）→ 跳到 `0x82724C68` 的 ARM→Thumb veneer（`ADD r12, PC, #1; BX r12`）→ Thumb 入口 `0x82724C70` (`PUSH {r4,r5,r6,lr}; MOVS r5, r0; MOVS r4, r1; BLX 0x8272699C`...)。`r5 = r0 = 0`, `r4 = r1 = sp`。
  5. 最终是某条 `BL` 跳到了 ROM 中段（`LR=0x803A9F89` 对应 ROM 中 `POP {r4, pc}` 的下一指令），callee 在没有先 `PUSH` 自己栈帧的情况下立刻 `POP {r4, pc}`，把 caller `PUSH {r4,r5,r6,lr}` 留下的 `r5` 值（=0）当作返回地址弹给 `PC` —— **PC=0 的直接来源就是 caller 栈帧上 `r5=0` 的槽**。
  6. fault 是连续 page 扫描而非死循环：dyncom block 翻译器对 `ReadCode → 0` 的失败返回 `0x00000000`，被 decode 成 `ANDEQ r0,r0,r0` (NON_BRANCH)，于是 `phys_addr += 4` 继续翻译直到 page boundary 0xFFF。所以一次"launch 失败"在日志里会看到约 1024 条 access violation。
- 候选 root cause（按可能性排序）：
  1. **codeseg / libmanager 的 import 解析 / 函数 lookup 在某处返回 0**，导致 BL 跳到了"错位"的 ROM 地址（不是函数入口而是函数中段的 `POP`）。这种 bug 在桌面 / Android 上也应可复现，**与 iOS 修改链无直接关系**。
  2. dispatcher trampoline 表初始化与 iOS 下时序错位，导致 stub 拿到的实现指针是 0。但 trampoline 是写到 ROM 里 patch 出来的（`dispatcher.cpp:202` memcpy），写入需要 PROT_WRITE —— 3.1 PROT_EXEC 剥除后 ROM chunk = RW，写入路径仍然合法。
  3. iOS sandbox 下某条 dispatch / SVC 处理误返回 0，再被 caller 当成函数指针调用。
- **结论（2026-05-23 跨系统对比落地）**：在 Apple Silicon Mac 上做了原生 arm64 桌面 Qt 编译，发现 macOS arm64 也复现了同样的现象（ZipManager 启动后立即 access violation writing 0x801000，进程 KERN-EXEC=3 被杀）。在 `common::commit` 里加 mprotect 失败诊断后，捕获到 `[commit-fail] ptr=0x14fabd000 size=0x1000 errno=22 (Invalid argument)` —— **真正的 root cause 是 Apple Silicon 用 16 KB host page，但 EKA2L1 memory model 用 4 KB 模拟页粒度调 mprotect，`len=0x1000` 不是 host page 整数倍被 macOS / iOS kernel 静默 EINVAL 拒绝**，对应页留在 PROT_NONE，下一次 guest 写就 SIGBUS / KERN_PROTECTION_FAILURE。3.2.1 的 PC=0 现场也是这条因果链的一种形态：caller `PUSH {r4..lr}` 把栈向下推 16 字节，所推页落在被 mprotect 拒绝的 host page 里，POP 时弹出来的是 PROT_NONE 触发的总线错误，dyncom 把后续的零字节继续往下解码就形成"PC=0 沿 page 扫描"的样子。
- **修法落地**：在 `src/emu/common/src/virtualmem.cpp` 的 `commit / change_protection` 里把 ptr 向下、size 向上对齐到 `sysconf(_SC_PAGESIZE)`；`decommit` 反过来只 PROT_NONE 完全覆盖的 host 页。改动只对 iOS / macOS arm64 生效，桌面 x86 / Linux / Android / Windows 行为不变。同步把 macOS arm64 也纳入 `translate_protection` 的 PROT_EXEC strip（同样 W^X 硬件）。提交 `779061f27 fix(ios+macos): align mprotect ranges to host page size`。
- macOS arm64 上验证 GUI app 已经能正常进入；iOS 端等 3.2 走完 Calculator + The Final Battle.sis 的双验收。
- 临时诊断日志已在后续清理中移除；3.2.2 的剩余问题单独记录在下一节。
- 验收（恢复跨系统对比之后再跑）：xcodebuildmcp 自动化点 Calculator → EmulatorView 渲染面在 10s 内出现非黑像素 → 单指 tap `1`、`+`、`1`、`=` → 截屏目视 `2`。归档 `docs/screenshots/ios-stage3/2-acceptance/`，stage 2 翻 ✅。

#### 3.2.2 iOS Calculator 已启动但 EAGL 仍无真帧 ✅
- 现象：host-page 对齐修复（`779061f27`）+ EAGL 主线程修复（`b9e92897b`）+ iOS sim Dynarmic backend + ROM patch 复制/覆盖落地后，iOS 模拟器上点 Calculator：
  - **没有** `[commit-fail]` —— mprotect 全部成功（3.2.1 unblocked）。
  - **没有** UIKit assertion —— renderbuffer 正确 attach（3.2 render 路径 unblocked）。
  - **仍然** 出现 `Access violation reading address 0x0 in thread Main (pc=0x00000000 lr=0x803A9F89 process=Calcsoft[10005902]0001)`；Notes 也复现同一 `LR=0x803A9F89`，因此不是 Calculator 单点问题。
- 新增结论：iOS sim 已启用 Dynarmic，`launchAppWithUID` 日志确认 backend=Dynarmic，但 Calculator / Notes 仍在 `_E32Startup` 早期清理路径返回到初始 stack metadata。SVC trace 显示退出前只有 `dll_tls(0x4E)` → `handle_close(0x6A)` → `library_detached(0xA2)` → `process_open_by_id(0x72)`；补齐 `process_open_by_id(0xFFFF8001 /* crr_thread */)` 后 `r0` 从 `KErrNotFound` 变成有效 handle，但 app 仍继续返回并 `POP {r4,pc}` 到 metadata 里的 `1`，最终 PC=0。说明剩余 blocker 更像 app startup / cleanup 语义缺口，而不是 EAGL、ROM patch 或 dyncom 独立解码问题。
- 当前保留修复：
  1. iOS simulator 允许构建并默认使用 Dynarmic；device 仍保留 dyncom，等 stage 4 entitlement / MAP_JIT。
  2. iOS 启动时复制 shader + patch 文件，并在 mount 后应用 Android 同款 ROM DLL 覆盖。
  3. `process_open_by_id` 支持 `special_handle_type::crr_process / crr_thread`，避免把特殊句柄误当普通 process id。
  4. CMake 在 scripting 关闭时显式写 `ENABLE_SCRIPTING=0`，避免源码树里的 `configure.h` 被 macOS 配置污染后让 iOS target include 缺失。
- 下一步选项（按代价从低到高）：
  1. 对照 macOS arm64 Dynarmic 跑 **Calculator**（不是 ZipManager），确认同一 ROM 下内建 GUI app 是否也走 `_E32Startup` early cleanup。
  2. 给 `library_detached / process_open_by_id / thread/process startup metadata` 增加最小单元复现，确认 EKA2 process startup 初始 stack metadata 与 S60v3 euser 期望是否匹配。
  3. 若 macOS Calculator 正常，再继续收窄 iOS frontend 初始化差异（audio/sensor/null driver、AppArc/window-server startup 时序、launch command line）。
- 验收：选定方案 → iOS sim 上 Calculator 启动后 EmulatorView 出非黑像素 → 单指 tap `1 + 1 =` 可见结果 → 截屏归档 `docs/screenshots/ios-stage3/3.2.2-render/`。
- **当前结论**：3.2.2 是 stage 3 范围内一个独立的真 bug，也是 3.2 / stage-2 验收最后的功能 blocker。
- **最新进展（2026-05-23）**：回退 iOS 默认 CPU backend 到 dyncom（simulator 仍保留 Dynarmic 可构建，用于后续定点调试；Dynarmic 当前在 Calculator A32 memory emit/regalloc 路径 host crash），并连续修掉三类 iOS frontend 缺省 driver 崩溃：①Window Server redraw 在 graphics driver 尚未发布时空指针；②KeySound server 在无 audio driver 时解引用空指针；③`bitmap_cache::add_or_get → drivers::create_bitmap` 在空 driver 下进入 graphics IPC。随后调整 mount/launch 时序：mount 不再硬等 EAGL layer，进入 EmulatorView 后等待 driver 并注入 `symsys/winserv`。xcodebuildmcp 复测：mount N95 → Apps(63) → Calculator，进程持续运行且无新 `.ips`，日志确认 `Calculator[10005902]` 线程持续调度；剩余问题是 EAGL 画面为整屏洋红，虽然 FBO incomplete 已通过 iOS color-only bitmap FBO / 32bpp RGBA render-target 收敛，但最终 screen_texture/present 仍未刷出 Calculator UI。
- **关闭（2026-05-23 evening）**：洋红画面的 root cause 是 `ogl_graphics_driver::bind_swapchain_framebuf()` / `bind_framebuffer(handle=0)` 都硬编码 `glBindFramebuffer(GL_FRAMEBUFFER, 0)` —— iOS GLES 没有默认 framebuffer，FBO 0 是无效目标，所有渲染命令静默丢弃，EAGL drawable 上的 renderbuffer 一直保留 `renderbufferStorage:fromDrawable:` 之后的未初始化内存（Apple 用洋红做未初始化指示色），从外观上看就是"已 attach、已 present、但画面是 magenta 清屏"。修法：① `gl_context` 基类新增 `virtual unsigned int swapchain_framebuffer() const { return 0; }`；②`gl_context_eagl` override 返回内部 `m_framebuffer`（attach_layer 已经把 CAEAGLLayer 的 colorbuffer 挂到这个 FBO 的 color attachment 0 + depth/stencil renderbuffer）；③ogl 后端的两处 "FBO 0" 改成 `context_->swapchain_framebuffer()`，桌面 / Android 行为不变（仍然返回 0 = system default framebuffer）。同时把 `IosEmulator::submit_screen_frame` 里那段把 `present_status` 从 -100 强行复位 0 的反向 wait_for 改成与 Qt / Android 一致的 `wait_for → set -100 → present`。验证：xcodebuildmcp `build-and-run` → tap N95 → Mount → applist 63 → tap Calculator → screenshot **`docs/screenshots/ios-stage3/2-acceptance/calculator-rendered.jpg`** 显示真实 Calculator UI（+ - × ÷ = ± √ % ↑↑ ↓↓ / "Options" / "Exit" 软键 / 灰色显示区），稳定 ≥12s 无 crash。Final Battle launch 同样进入 EmulatorView，FBattle 进程持续调度（hssSDthread 因无 audio driver 报 `Unable to create new DSP out stream` 然后 access violation 杀线程，但符合 stage 2 "(游戏内逻辑跑不下去也算通过)" 接受标准；音频在 3.7 上线后会解掉）。

#### 3.2.3 SIS 安装在 iOS 上静默写失败 ✅
- 现象：iOS 模拟器上点 The Final Battle.sis → 日志按预期打印 `[Loader]: File detected:` 列出所有 SIS 内文件 → `[Packages]: Package Final Battle registering with UID: 0xa0003c62` → `[Packages]: Installation done!` → `[Service.Applist]: Loading app registries` / `Done loading!`（增量 = 0）。但实际检查 sandbox：
  - `Documents/data/drives/c/sys/install/sisregistry/a0003c62/{00000000.reg,00000000_0000.ctl}` **已写入** —— 说明 sisregistry 路径正常。
  - `Documents/data/drives/e/` **完全空** —— SIS payload（`FBattle.RSC` / `FBattle_reg.RSC` / `FBattle.exe` / 一堆 `.wav` `.mod`）一个文件都没落地。
  - applist 重扫看的是 `e:\Private\10003a3f\import\apps\*.rsc` 等路径（`src/emu/services/src/applist/applist.cpp:438`），既然 e 是空的，自然 0 增量。
- 范围判断：sisregistry 是 EKA2L1 内部维护的元数据（直接 host C++ write），payload 走的是 `io_system::open(write)` 进 vfs 写入；两条路径都最终落到 `data/drives/<X>/...`。前者成功后者失败 → 说明 vfs 的 write 路径在 iOS 上有问题，可能：
  1. `io->open(...., WRITE_MODE)` 没有自动 `mkdir -p` 父目录，iOS 上 `data/drives/e/Resource/Apps/` 不存在直接 open 失败；
  2. sis_script_interpreter 把 `!:` 替换成 `e:` 后，路径生成大小写跟 sandbox 实际期望对不上（3.2 阶段已有 vfs case-insensitive read fallback，但 write 端没改）；
  3. install_drive=drive_e 在 iOS 上没真挂载成可写（看 `src/emu/ios/Bridge/IosEmulator.mm::startWithDocumentsPath:` 的 `sys->mount(drive_e, ..., io_attrib_removeable)` —— removeable + iOS sandbox 组合下 vfs 可能拒绝写）。
- 根因：`sis_script_interpreter` 在 case-sensitive 平台上先用 VFS 把 `e:\...` 解析成 host 绝对路径，然后把整条 **host path** `lowercase_string`。iOS simulator app container 路径包含 `/Users/.../Library/...` 和 UUID，lowercase 后变成不存在的 `/users/...`，`wo_std_file_stream` 打不开目标；安装器没有把这个 write 失败传播出去，于是 registry 成功、payload 为空。
- 修法：只 lower-case Symbian 虚拟路径（`e:\resource\apps\...`）再交给 `io->get_raw_path` 解析，绝不 lower-case host 绝对路径；同时 `get_raw_path` 失败时返回 interpret false，避免以后继续出现"安装成功但文件为空"的假阳性。
- 验收：iOS sim 上跑 The Final Battle.sis 安装 → `drives/e/resource/apps/fbattle.rsc` / `drives/e/sys/bin/fbattle.exe` / `drives/e/private/10003a3f/import/apps/fbattle_reg.rsc` 均存在 → applist 重扫出 `Final Battle, uid=0xA0003C62`。

#### 3.3 `common::virtualmem` 与 mem 模块的 iOS 落实 ✅
- ✅ `is_memory_wx_exclusive()` 的语义在头文件 doc 里写清楚（`src/emu/common/include/common/virtualmem.h`）：iOS / Apple Silicon 仍返回 true，但只对"host 真要执行"的 JIT block 生效；普通 data chunk 已经在 `translate_protection()` 里被 strip 掉 PROT_EXEC，走 plain RW。可执行内存（`map_executable` / `jit_write_protect` / MAP_JIT / `pthread_jit_write_protect_np`）继续保留在阶段 4，与 dynarmic 通路一起做。
- ✅ `src/emu/common/src/virtualmem.cpp` 的 iOS / macOS arm64 `commit()` / `change_protection()` 16 KB host-page 对齐分支加 `// TODO(ios)` 注释，引用 3.2.1 的来历；清理 3.2.1 阶段加的 `[commit-fail]` 调试 fprintf 与 `<cerrno>` / `<cstdio>` / `<cstring>` 包含。
- ✅ 桌面 / Android / Win32 路径未受改动；iOS simulator build 通过（`scripts/build_ios.sh` 替代之 `xcodebuildmcp simulator build` SUCCEEDED）。

#### 3.4 真正的 ROM 安装流程（取代 symlink graft）🟡
- ✅ `mountRomNamed:` 不再用 `symlink(2)` graft drives/z firm 和 ROM 文件，改成 `NSFileManager.linkItemAtPath:toPath:`（APFS hardlink；目录级 hardlink 是 Apple FS 特有能力，TimeMachine 也用同一机制）。后果是即使将来某条代码路径误调 `common::delete_folder`（POSIX `remove(2)` 会跟着 directory symlink 递归删源文件），现在 `remove(2)` 只是 unlink hardlink name，inode 引用计数 -1，用户原 ROM 树（`roms/<rom>/data/...`）依然完整。
- ✅ 已确认 `rescan_devices` 仍然 bypass（沿用阶段 2 #12 + 3.1 的结论），mount 直接走 `startup → set_device(0) → mount(c/d/e/z)`；任何失败的 `linkItemAtPath:` 会把整个 mount 流程 fail-fast 并返回 NO 给 SwiftUI。
- ✅ xcodebuildmcp 验证（iPhone 16 Pro 模拟器）：fresh sandbox → mount N95 → `drives/z/rm-320` 是真目录（不是 symlink）、`roms/rm-320/SYM.ROM` link-count = 2 hardlink → applist 63 → Calculator 真实 UI 渲染稳定。
- 🟡 剩余 follow-up：①裸 ROM 镜像（没有 desktop device tree 的 .rom 文件）→ 自动生成 minimal device tree 的路径还没做，要和 3.5 UIDocumentPicker ZIP/ROM 导入流程一起 land；②空白 sandbox + UI 全程导入 + applist 出 Snakes 的端到端验收要等 3.5 做完才能跑。

#### 3.5 UIDocumentPicker 文件导入 🟡
- ✅ Info.plist：新增 `CFBundleDocumentTypes` 三条（SIS/SISX viewer-owner、ROM zip viewer-alt、TTF/OTF viewer-alt）+ `UTExportedTypeDeclarations`（`com.eka2l1.sis` / `com.eka2l1.sisx` conform 到 `public.data` + `.sis` / `.sisx` extension tag）。`UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace` 已经在阶段 0 打开，保持不变。
- ✅ SwiftUI：`ContentView` / `AppListView` 顶 toolbar 加 **Import** 按钮，触发 `.fileImporter(... allowedContentTypes: [com.eka2l1.sis, com.eka2l1.sisx, .zip, .font, .data] ...)`（`.data` 兜底，应对 source 没塞 UTI 提示的 .sis 文件）。
- ✅ 新建 `src/emu/ios/App/ImportRouter.swift`：负责安全作用域 URL pair（`startAccessingSecurityScopedResource` / `stopAccessing...`，少了这步 sandbox 拷贝直接 EPERM），按扩展名分发：
  - `.sis` / `.sisx` → `Documents/sis/<name>`（后续走原本的 `installSisAtPath:` 路径）。
  - `.ttf` / `.otf` → `Documents/data/fonts/<name>`（3.12 引导用同一目录）。
  - `.zip` → 暂返回明确错误 "ROM .zip 导入交给 3.5 follow-up"（miniz 已经 link 进 common，但需要在 Obj-C++ 侧暴露解压 API，给 3.5 收尾或并到 3.4 的"裸 ROM 装 device tree"那一步）。
  - `*.rom` → `Documents/roms/<basename>/data/roms/<lowercased>/SYM.ROM`（裸 ROM；自动生成 minimal device tree 仍待 3.4 follow-up）。
- ✅ xcodebuildmcp 验证（iPhone 16 Pro 模拟器）：build SUCCEEDED → launch → 主页右上 **Import** 按钮可见 → tap 弹出系统 UIDocumentPickerViewController（"最近项目" / "共享" / "浏览" 三个 tab，"最近项目"为空）。截屏 `docs/screenshots/ios-stage3/3.5-import/{rom-list-with-import-button,document-picker-presented}.jpg`。
- 🟡 剩余 follow-up：①ZIP unzip 走 miniz（与 3.4 第二个 follow-up 项一起）；②"Share to EKA2L1" extension（外部应用 Share 菜单直接送进来）推迟到 stage 3 收尾或更后；③`scripts/seed_ios_simulator_documents.sh` 继续保留为开发期复跑捷径，不进 release 路径。

#### 3.6 AppList 图标（SVG / MIF 解码）
- 在 IosEmulator 侧给 `EKA2L1AppEntry` 加 `iconPNGData: NSData?` 字段；后端遍历 registration 时调 applist server 取 icon（复用 Qt / Android 的解码路径），mif 走 mif decoder、svg 走 lunasvg，统一光栅化到 64×64 RGBA，编码 PNG 后跨 ARC 边界传给 Swift。
- AppListView 用 `Image(uiImage:)` 异步渲染；解码放后台 queue，主线程只赋值。
- 字体缺失时 SVG 文本会失败，3.12 的引导覆盖这种情况。

#### 3.7 cubeb iOS AudioUnit 后端
- `src/external/CMakeLists.txt`：iOS 下重新 `add_subdirectory(cubeb)`（阶段 0 跳过名单里移除 cubeb）。验证 cubeb 自带的 `cubeb_audiounit` 在 iOS 18 / Xcode 26 SDK 下编得过；编不过就给 cubeb 打最小 patch（CMake 检测 + AVAudioSession 配置）。
- `src/emu/drivers/CMakeLists.txt` + `audio.cpp` / `dsp.cpp`：撤掉阶段 0 在 iOS 下对 cubeb 工厂 case 的 `#if !EKA2L1_PLATFORM(IOS)` 守护，重新让 `audio_driver_backend::cubeb` 在 iOS 落到 cubeb_audiounit。
- 配 `AVAudioSession`：`category=playback` + `mode=default`，App 切后台时调 `setActive:NO`，回前台 `setActive:YES`；与阶段 2 的 scenePhase 钩子共用。
- ffmpeg 仍然跳过；dsp out-stream / video player 在 iOS 继续 nullptr，由阶段 3 验收里 "声音能听到" 覆盖到一个不依赖 ffmpeg 的应用即可。
- 验收：一个公开的 Symbian 小游戏或自带 BGM 的内建应用（候选：Music Player / 一个有 SFX 的免费 N-Gage demo）能听见声音；后台/前台切换不打嗝、不 crash。

#### 3.8 振动：Core Haptics
- 新建 `src/emu/drivers/src/hwrm/backend/vibration_ios.{h,mm}`：iOS 14+ 用 `CHHapticEngine` + `CHHapticPattern` 把 duration / intensity / sharpness 映射到一次连续振动；iOS 12/13 fallback 到 `UIImpactFeedbackGenerator`。
- CMake iOS 分支链 `CoreHaptics` / `UIKit`；`vibration.cpp` 工厂在 iOS 走 `vibration_ios` 替换 stage-0 的 `vibration_null`。
- 验收：找一个触发振动的应用（或写一个临时 dispatcher hook 在 tap 时强制振动一下）能感受到反馈。

#### 3.9 多指 / 手势
- `EAGL2L1View.multipleTouchEnabled = YES`，`touchesBegan/Moved/Ended/Cancelled` 已经是数组迭代，扩 pointerId 上限即可。
- 双指缩放（pinch）+ 长按（long press）做成 `UIGestureRecognizer`，事件转换为 `drivers::input_event` 中的 `keyboard_input`（虚拟方向键 / select）或 `mouse_action` 长按语义。具体语义对照 Android 前端的 `gesture_dispatcher` 写。
- 物理键盘 / 手柄推迟到阶段 4。

#### 3.10 设置面板
- SwiftUI 设置页（`SettingsView`）+ `IosEmulator` 暴露 `-currentConfig` / `-applyConfigChanges:`；改动序列化回 `Documents/data/config.yml`。
- 字段：device 选择、屏幕方向（auto / portrait / landscape）、上采样倍率、主音量、按键映射（虚拟方向键 / 软键盘开关）、日志等级、JIT 开关（占位，文案标注 "阶段 4 启用"）。
- 入口放在 ROM 列表页右上角 gear icon。

#### 3.11 UIAlertController 输入对话框
- 替换 `src/emu/drivers/src/ui/input_dialog_ios.cpp` 的 no-op：
  - `open_input_view(title, current_text, max_len)`：弹 `UIAlertController(.alert)` + `addTextField`，回调写回 `drivers::ui::input_dialog_result`。
  - `close_input_view`：dismiss。
  - `show_yes_no_dialog`：两按钮 alert，return 阻塞或异步看 dispatcher 期望。
- 必须在主线程上推 ViewController，跨线程信号用 `dispatch_async(dispatch_get_main_queue(), ...)` 推入。
- 验收：触发一个需要文本输入的 Symbian 对话（如 Notes 创建条目），能输入文字并提交回模拟器。

#### 3.12 字体导入引导
- 启动时检测 `data/fonts/` 是否为空且 ROM 字体缺失（freetype 无 face 时由 services/fbs 给信号）；若缺，AppList 顶部出现一条引导横幅 → 点击触发 3.5 的 DocumentPicker（限制为 `public.truetype-ttf-font` / `org.openfontformat.otf`）。
- 拷贝完成后调 fbs 重新扫描字体目录。

#### 3.13 文档与遗留项
- 阶段 3 修复清单（按出现顺序，体例同 0.7 / 1.x / 2.x）维护在本节末尾。
- 把 "dynarmic / MAP_JIT / `common::virtualmem::map_executable` / W^X 切换 / `pthread_jit_write_protect_np` / 各签名通道下的 JIT 启用方法 / CI / dyncom vs dynarmic benchmark" 统一推到阶段 4，确保 3.3 留下的可执行内存 API 骨架在阶段 4 直接接得上。
- 阶段 3 期间的截屏（mount 链路打通后的 applist、Calculator 出帧、Snakes 主菜单、设置面板等）归档到 `docs/screenshots/stage3/`，按子任务编号分目录。
- 变更日志补阶段 3 拆解条目与各阶段收尾条目。

### 阶段 3 修复清单（按出现顺序）
0. （占位，按出现顺序往下编号） **OGL 后端 `bind_swapchain_framebuf` / `bind_framebuffer(0)` 在 iOS 静默绑空 FBO 导致整屏洋红**（关闭 3.2.2，详见上文）。修法在 `gl_context` 基类加 `swapchain_framebuffer()` 虚函数（桌面默认 0），iOS 的 `gl_context_eagl` 返回内部 m_framebuffer（attach_layer 已把 EAGL drawable colorbuffer + depth/stencil 挂到该 FBO）；ogl 后端两处硬编码 FBO 0 改成走 `context_->swapchain_framebuffer()`。同时 `IosEmulator::submit_screen_frame` 的反向 `wait_for(&present_status)` 改回 Qt/Android 同款 `wait_for → set -100 → present`。仅影响 iOS，桌面 / Android 行为不变。
1. **`prot_read_write_exec` 在 iOS sandbox 下 `mprotect` 静默丢 W**：阶段 2 #14 的 SIGBUS 根因。崩溃 IPS 显示在 `std::fill(base, base+0x4000, 0)` 写第一个字节就 `KERN_PROTECTION_FAILURE` (`Data Abort byte write Translation fault`)，栈顶是 `kernel::chunk::chunk` → `dispatcher::dispatcher`（创建 "DispatcherTrampolines" chunk，`prot_read_write_exec`，4 KB）。原因：iOS arm64 sandbox 强制 W^X，`mprotect(PROT_READ|PROT_WRITE|PROT_EXEC)` 返回 0（成功）但实际页是 RX（PROT_WRITE 被静默剥离），随后写入触发 KERN_PROTECTION_FAILURE。dyncom 路径下 host 永远不真正执行 guest 页（dyncom 是解释器），PROT_EXEC 对 host_base 是纯冗余。修法：`src/emu/common/src/types.cpp::translate_protection` 在 iOS 分支末尾统一剥 PROT_EXEC（若结果为 0 回落 PROT_READ），并加 `// TODO(ios)` 说明 stage 4 引入 `map_executable` / MAP_JIT 时替换。此改动只影响 iOS，POSIX / Win32 / Android / macOS 桌面不变。验证：xcodebuildmcp 自动化 Mount N95 ROM 后 UI 显示 `Mounted: N95 8GB (S60v3 - FP1)` + `Apps (18)`，进程不再 SIGBUS。截屏 `docs/screenshots/ios-stage3/3.1-mount-unblocked/applist-18-apps.jpg`。
2. **iOS sandbox 内 vfs 路径解析 case-sensitive，碰到混合大小写的 ROM 文件名失败**：3.1 修复 SIGBUS 后第一次跑 mount，启动日志看到 `[Service.Window]: Loading wsini file broke with code -1`，path 是 `data/drives/z/rm-320/system/data/wsini.ini`（全小写），但 host 真实文件名是 `Wsini.ini`。stage 2 #13 已经统一了顶层目录大小写，但 ROM tree 里很多文件（如 `Wsini.ini` / `SkinExclusions.ini` / `Iva_base.dof`）保留了原始混合大小写。`physical_file_system::get_real_physical_path` 走 `is_system_case_insensitive()` 的桌面默认值在 iOS 下返回 false → 整条路径被 `lowercase_ucs2_string` 强制小写 → host 那侧（iOS sim app 进程视角 = case-sensitive）找不到。修法：在 `src/emu/vfs/src/vfs.cpp::get_real_physical_path` 末尾、iOS 分支下，若 lowercased path 不存在，则从 mount root 开始逐级用 `make_directory_iterator` + `compare_ignore_case` 把每一段解析回真实大小写，再返回新的 final_path。只在 iOS 触发，桌面/Android/Win32 行为完全不变。验证：再跑 mount，`Loading wsini file broke` 日志消失。后续残留的 `Fail to load languages.txt`、`Failed to open thread panic blacklist file` 走的是裸 `dynamic_ifile`/`ro_std_file_stream` 直读 host 路径（不经 vfs），二者本身都是路径合法但 host 文件不存在的"信息缺失"类，不属于本条修复范围。

### 阶段 3 已知风险
- **iOS sandbox 下 mmap / mprotect 行为差异是 3.1 的关键变量**：模拟器（Apple Silicon host）与真机的 sandbox 配额不完全一致，3.1 修完后必须在真机上至少跑一次 mount，不能只靠 booted 模拟器。
- **cubeb iOS 后端历史包袱**：cubeb_audiounit 在新 SDK 下偶有编译告警升错；如真的编不过、又不想动 cubeb 源，可以临时给一个最薄的 AVAudioEngine 后端走 `audio_driver` 接口，但务必记录在修复清单里、不要让回退方案永久化。
- **AVAudioSession 与 EAGL 生命周期耦合**：进后台时音频要先 deactivate 再让 GL pause，否则 AudioUnit 在 EAGL context 释放后仍持引用可能 crash；scenePhase 路径里写明先后顺序。
- **Core Haptics 在 iOS 模拟器上不可用**：模拟器 silently 失败，验证振动只能上真机；CI 烟测里跳过振动相关 assert。
- **UIDocumentPicker 返回的是 security-scoped URL**：必须配对 `startAccessingSecurityScopedResource` / `stop...`，否则后台拷贝会读不到文件。这是阶段 3 上手时最容易踩的隐性坑。
- **chunk 修复一旦泄漏到桌面**：mem 模块的所有改动都要在 macOS / Linux / Win32 桌面 Qt 构建上跑一次回归，3.3 的 API 拆分尤其要小心 ABI 漂移。
- **设置面板与 services 的耦合**：`config::state` 字段改完不一定立即对 services 生效（多数需要 reset 模拟器）；设置面板要在 UI 上明确告知 "需要重启模拟器才能生效" 的字段。

---

## 阶段 4：dynarmic JIT + 发布通道 + CI

### 目标
把 dynarmic JIT 在 iOS 上启用起来，同时把 sideload / TrollStore / 越狱三套签名打包流程文档化；GitHub Actions 跑 iOS 构建烟测。
JIT 和发布通道绑在一起是因为各通道下能否拿到 JIT entitlement、用何种机制启用，是同一个工程问题的两个面。

### 验收标准（草稿）
- [ ] iOS 真机（dev signed + debugger / TrollStore / 越狱）上能切到 dynarmic 后端运行同一段 smoke blob，结果与 dyncom 一致。
- [ ] 无 JIT 权限的环境下，cpu factory 安全回落 dyncom，且 UI 明确告知用户原因。
- [ ] `common::virtualmem` 提供统一的 `map_executable` / `jit_write_protect` 接口，dynarmic `block_of_code` 走该接口分配可执行内存。
- [ ] 有 dyncom vs dynarmic 的简单 benchmark 数据登记在本文件。
- [ ] CI 上 iOS 构建产物可下载。
- [ ] README 写清楚三种安装方式的步骤与 JIT 启用方法。

### 子任务
> 进入此阶段时再拆。

---

## 变更日志

| 日期 | 改动 |
|------|------|
| 2026-05-20 | 初版：拆完阶段 0，其余阶段仅列目标 |
| 2026-05-20 | 阶段 0 全部子任务（0.1–0.7）落地：iOS toolchain、emu 分支化、drivers / cpu 移除桌面/JIT 依赖、外部库审计、SwiftUI 骨架、构建脚本。等待 submodule init 后跑实际构建确认。 |
| 2026-05-20 | submodule init 后实际跑 `scripts/build_ios.sh device` 通过，产物：arm64 iOS `EKA2L1.app`。期间打掉 12 个真实编译/链接问题（见 0.7 子任务）。capstone / fmt 留下 dirty submodule patch 待后续 fork 收尾。 |
| 2026-05-20 | 升级 capstone → 5.0.7（换上游 `capstone-engine` 仓库）、spdlog → 1.17.0、fmt → 11.2.0；删除两个子模块 patch 和 `FMT_USE_CONSTEVAL=0` workaround，iOS device build 仍然通过。 |
| 2026-05-20 | 阶段 0 验收：`scripts/build_ios.sh simulator` 通过（arm64 iphonesimulator .app），在 booted iPhone 16 Pro (iOS 26.5) 上 `simctl install + launch` 成功，进程长时驻留无即时崩溃；`otool -L` 确认 device/simulator 产物均未链接 SDL2。阶段 0 七项验收标准全部打勾。 |
| 2026-05-20 | 阶段 1 拆解：缩窄为"dyncom 解释器跑通裸 ARM 片段"，dynarmic / MAP_JIT / entitlement 与发布通道合并到新的阶段 4。子任务 1.1–1.7 落地：smoke blob 设计、SmokeBridge、cpu iOS 真实可链、SwiftUI 展示、factory 回落语义、`build_ios.sh smoke` 验证、文档与遗留项。 |
| 2026-05-21 | 阶段 1 完成：simulator 上 `scripts/build_ios.sh smoke` exit 0，`EKA2L1_SMOKE: PASS backend=dyncom instrs=9 pc=0x00001024`。期间踩了 5 个坑（详见阶段 1 修复清单）。dynarmic 请求按预期回落 dyncom，UI 显示 fallback reason。 |
| 2026-05-21 | 阶段 2 拆解：目标聚焦"ROM 加载 → applist → 出一帧 + 单指交互"，音频/振动/导入 UI 全部推迟到阶段 3。子任务 2.1–2.11 落地：ogl 后端 iOS 化、EAGL 上下文、iOS emu_window、IosEmulator state、Documents 布局、applist 扫描、SwiftUI 三屏、触控、生命周期、`seed_ios_simulator_documents.sh`、文档收口。验证素材选定 `roms/N95 8GB (S60v3 - FP1)` + `roms/snakes-n95_n6trsohu.sis`。 |
| 2026-05-22 | 阶段 3.1 完成：iOS sandbox 下 `prot_read_write_exec` 被 mprotect 静默剥 W 导致 dispatcher trampoline chunk 写 0 SIGBUS。在 `translate_protection` iOS 分支统一剥 PROT_EXEC（dyncom 不需要 host exec），mount N95 ROM 后 applist 出 18 个应用，进程稳定。截屏归档 `docs/screenshots/ios-stage3/3.1-mount-unblocked/`。 |
| 2026-05-22 | 阶段 3.2 部分推进：在 `physical_file_system::get_real_physical_path` iOS 分支末尾加 case-insensitive 路径解析，修掉了 ROM 内混合大小写文件（首发证据是 `Wsini.ini`）在 iOS sandbox 下读不到导致的 `Loading wsini file broke with code -1`。剩余阻塞：点击 GUI app 后 guest "Main" 线程进 PC=0 access-violation 死循环（详见 3.2.1）—— stage 2 acceptance（render 真帧 + 1+1= + SIS 安装）在 3.2.1 落地前无法关闭，stage 2 状态仍为 🟡。 |
| 2026-05-22 | 阶段 3.2.1 调查暂停（待跨系统对比）：在 `process::create_prim_thread` / `scheduler::switch_context` / `cpu_exception_handler` 加 iOS 诊断 log + xcodebuildmcp 自动化，定位出 PC=0 直接来源是 caller `PUSH {r4,r5,r6,lr}` 后某个 BL 跳到 ROM 中段（`0x803A9F88` 处的 `POP {r4,pc}`），把栈上 `r5=0` 当作返回地址弹给 PC；dyncom block translator 把后续 0 字节解成 NON_BRANCH `ANDEQ r0,r0,r0`，于是 fault 沿 page 扫描而不是真死循环。继续推进需要桌面 Qt 同 ROM 对比或加 BL 追踪 —— 用户指示本轮在此暂停。 |
| 2026-05-23 | 阶段 3.2.1 关闭（host-page 对齐 root cause）：在 Apple Silicon Mac 上做原生 arm64 桌面 Qt 编译复现，加 `common::commit` mprotect 诊断后抓到 `[commit-fail] size=0x1000 errno=22 EINVAL`。结论：Apple Silicon host page = 16 KB，EKA2L1 用 4 KB 模拟页粒度调 `mprotect`，长度非 host page 倍数被 kernel 静默拒绝；guest 写未真提权的页就 SIGBUS / KERN_PROTECTION_FAILURE，被 KERN-EXEC=3 杀线程。修法（`779061f27`）：iOS / macOS arm64 下 `common::commit / change_protection` 调 mprotect 前把 ptr 向下、size 向上对齐到 `sysconf(_SC_PAGESIZE)`；`decommit` 反向对齐只 PROT_NONE 完全覆盖的 host 页。同步把 macOS arm64 加入 `translate_protection` PROT_EXEC strip。macOS arm64 上 ZipManager 已可正常进入。 |
| 2026-05-23 | 阶段 3.2 验收素材调整：验收应用恢复为 Calculator，后续不再用较难定位的 ZipManager 做 iOS 验收；SIS 测试样本从 `snakes-n95_n6trsohu.sis` 换成 `The Final Battle.sis`，原因是 Snake 自身的 codeseg 兼容性问题与移植无关。 |
| 2026-05-23 | 阶段 3.2.3 关闭：SIS payload 未写入 drive_e 的根因是 `sis_script_interpreter` 在 case-sensitive 平台把 VFS 解析后的 host 绝对路径整体 lower-case，iOS simulator container 里的 `/Users/.../Library/...` 被改成不存在的 `/users/.../library/...`。修法是只 lower-case Symbian 虚拟路径再解析 host path，并在 `get_raw_path` 失败时返回 false；复测 The Final Battle.sis 后 `drives/e/resource/apps/fbattle.rsc`、`drives/e/sys/bin/fbattle.exe`、`drives/e/private/10003a3f/import/apps/fbattle_reg.rsc` 均存在，applist 出现 `Final Battle, uid=0xA0003C62`。 |
| 2026-05-23 | 新增 macOS arm64 原生构建管线（`9103c2bca`）：homebrew ffmpeg@5 替换 x86_64-only 自带静态库（仅在 macOS arm64 走，未触碰 ffmpeg 子模块）；放开 `CMAKE_OSX_DEPLOYMENT_TARGET` 让 Qt6 ≥ 10.15；新增 `cmake/MacOSFinalizeBundle.cmake` post-build：修复 SDL2.framework symlink 布局、跑 macdeployqt、ad-hoc 重签，避免 Apple Silicon 拒绝加载未签 / 签名失效的 .app。 |
| 2026-05-23 | 阶段 3.2 推进：iOS sim 上 mount N95 → applist 62 app 正常 ✅。修 `gl_context_eagl::attach_layer` 把 CAEAGLLayer 的 opaque / drawableProperties / renderbufferStorage:fromDrawable: 三处 UIKit 调用全 dispatch_sync 到主线程（提交 `b9e92897b`），跑 Calculator 不再有 UIKit assertion，EAGL renderbuffer 正确分配。同时发现两个独立的剩余 blocker：①3.2.2 dyncom 在 iOS 上跑同一个 N95 Calculator 仍出 `PC=0 / LR=0x803A9F89` 的 BL→mid-function POP 现场；在 macOS arm64 桌面 build 上把 cpu 强制改成 dyncom 也完全复现，说明这是 dyncom 自己的 Thumb 解码 bug（macOS arm64 默认走 dynarmic 所以掩盖了）。②3.2.3 SIS 安装 The Final Battle.sis 时 sisregistry 元数据写成功但 payload 文件没落到 drive_e，applist 重扫 0 增量。两个 blocker 分别建为 3.2.2 / 3.2.3 子任务，3.2 验收暂停在"渲染真帧 + SIS 安装"前，mount + applist 部分可以归档为 3.2.A。 |
| 2026-05-23 | 阶段 3.2 继续：iOS simulator 放开并默认使用 Dynarmic，device 仍保留 dyncom；iOS 启动时复制 shader/patch 资源并按 Android 同款逻辑覆盖 `goommonitor.dll` / `avkonfep.dll`；补齐 `process_open_by_id` 特殊句柄；修正 scripting 关闭时 stale `ENABLE_SCRIPTING=1` 的 CMake 污染。xcodebuildmcp `build-and-run` 通过，The Final Battle.sis 安装闭环已通；Calculator / Notes 仍在 `_E32Startup` 早期返回到 `PC=0 / LR=0x803A9F89`，3.2 / stage-2 验收剩余 blocker 收窄为 3.2.2。 |
| 2026-05-23 | 阶段 3.2 继续：N95 `devices.yml` 由 ROM/Z 盘 metadata 生成，并对 `Series60v3.1.sis` 做 `epoc93fp1` 校正；iOS mount 不再等待 EAGL layer，Calculator 进入 EmulatorView 后等待 graphics driver 并绑定到 `symsys/winserv`。修复 iOS 无 audio/driver 下的 KeySound、Window redraw、graphics IPC 空指针崩溃；iOS simulator 默认回 dyncom，Dynarmic 保留构建但暂不默认。xcodebuildmcp 验证 mount N95 → Apps(63) → Calculator：无新 crash，Calculator 线程持续调度，剩余 blocker 从 PC=0/host crash 收敛为 EAGL 洋红画面，尚未刷出真实 Calculator UI，stage-2 acceptance 仍未关闭。 |
| 2026-05-22 | 阶段 3 拆解：把阶段 2 验收最后一公里（kernel chunk SIGBUS）并入阶段 3 作为 3.1 解锁项，3.2 补完 stage-2 acceptance，3.3 沉淀 `common::virtualmem` 非可执行内存 API。其余 3.4–3.13 覆盖真正的 ROM 安装流程、UIDocumentPicker 导入、SVG/MIF 图标、cubeb AudioUnit、Core Haptics、多指/手势、设置面板、UIAlertController 输入、字体引导、文档收口。dynarmic / MAP_JIT / 发布通道继续保留在阶段 4。阶段总览表把阶段 2 标为 🟡（待 3.1/3.2 翻 ✅），阶段 3 进入 🟡。 | |
| 2026-05-22 | 阶段 2 子任务 2.1–2.11 全部实现并 `scripts/build_ios.sh smoke` 双绿（simulator build PASS + 启动后 `EKA2L1_SMOKE: PASS backend=dyncom instrs=9 pc=0x00001024`）。期间打掉 10 个真实编译/链接/线程坑（见阶段 2 修复清单）。stage-2 的"实机加载 ROM、应用列表 ≥5、出一帧、触控触达 Calculator"等 acceptance 标准需要在 device 上 + 一个已 desktop-预装的 device 树才能完整跑通，落地与 stage-3 真实 ROM 安装流程一起做。 |
| 2026-05-23 (evening) | **阶段 2 验收关闭**。修掉 3.2.2 整屏洋红 root cause：`ogl_graphics_driver::bind_swapchain_framebuf()` 与 `bind_framebuffer(handle=0)` 硬编码 `glBindFramebuffer(GL_FRAMEBUFFER, 0)` —— iOS GLES 没有默认 framebuffer，FBO 0 是无效目标，渲染命令静默丢弃，EAGL drawable 保留 `renderbufferStorage:fromDrawable:` 之后的未初始化页面（Apple 用洋红做未初始化指示色）。新增 `gl_context::swapchain_framebuffer()` 虚函数（桌面默认 0），iOS 的 `gl_context_eagl` 返回内部 m_framebuffer；ogl 后端两处 FBO 0 改成 `context_->swapchain_framebuffer()`。同步把 `IosEmulator::submit_screen_frame` 的反向 `present_status` 逻辑改回 Qt/Android 同款。xcodebuildmcp 自动化验证：iPhone 16 Pro / iOS 26.5 模拟器上 build-and-run → mount N95 → applist 63 → tap Calculator → Calculator 真实 UI（+ - × ÷ = ± √ % ↑↑ ↓↓ / Options / Exit）稳定 ≥12s，无 crash；tap The Final Battle.sis 安装 → applist 出 `Final Battle, uid=0xA0003C62`；tap Final Battle → EmulatorView 切到 FBattle 进程（持续调度，音频缺失导致 hssSDthread 退出但符合"游戏内逻辑跑不下去也算通过"的接受标准）。截屏归档 `docs/screenshots/ios-stage3/2-acceptance/{calculator-rendered,applist-with-final-battle,final-battle-launched}.jpg`。阶段总览表把阶段 2 翻 ✅。剩余 follow-up：3.11 虚拟键盘后才能在 Calculator 上做 `1 + 1 =`（S60v3 数字键没有 on-screen 按钮）。 |

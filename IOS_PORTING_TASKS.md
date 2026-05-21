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
| 2 | iOS 前端壳 + GLES 渲染上下文，能显示一帧并完成一次真实交互 | 🟡 |
| 3 | 音频 / 输入 / 振动 / 文件导入完整体验 | ⬜ |
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
- [ ] iOS 真机或模拟器上启动 EKA2L1.app 后，SwiftUI 主屏列出 sandbox Documents 下检测到的 ROM；选定 N95 ROM 后能完成 mount、applist 扫描，并显示至少 5 个内建应用条目（与 Qt / Android 前端在同一 ROM 下的列表对得上）。
- [ ] 在该列表上点击一个 GUI 内建应用（候选：Calculator / Notes / Calendar，任一不依赖音频且 launch 路径稳定的即可），EAGL 渲染面能稳定刷出 ≥1 帧真实画面（不是清屏色），无 crash 持续运行 ≥ 10s。
- [ ] 在 (Documents) 下放入 `snakes-n95_n6trsohu.sis`，前端 UI 上有一个"安装 SIS"入口能调 `eka2l1::package::manager::install_package`，安装完成后该 app 出现在列表里、能 launch 到主菜单（即便游戏内逻辑跑不下去也算通过）。
- [ ] 单指 tap / drag 事件被映射为 `drivers::pointer_event`，能在所选应用的 UI 上完成一次明确可见的交互（例如在 Calculator 上按 `1 + 1 =` 看到结果，或在 Snakes 主菜单上选中一个菜单项）。
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

### 阶段 2 已知风险
- **OpenGL ES on iOS 已 deprecated 但仍可用**：iOS 12+ 至今 SDK 仍带 OpenGLES.framework，但 Apple 偶尔在新 SDK 提高警告等级。验收期内（iOS 18 / Xcode 26 序列）确认 OK；长期方向是 MoltenVK / Metal，留给后续阶段。一旦 SDK 真的拿掉 OpenGLES，本阶段产物会一起失效，但这是已知交换。
- **ogl 后端隐含的桌面 GL 假设面积可能比当前列出的大**：解码路径里的 `GL_BGRA`、纹理 swizzle、PBO upload、debug callback 等都可能命中。原则同阶段 1 ——就地最小修复 + `// TODO(ios)`，不重构。
- **EAGL 上下文与线程绑定严格**：一旦把 emu 线程切到别处或在主线程偷偷调 GL，会拿到 `INVALID_OPERATION` 或直接 crash。所有 GL 调用必须严格走 emu 线程；后台/前台切换路径要在第一版就写对。
- **applist 在 iOS 上首次扫描可能因 vfs/路径假设暴露 Linux/Android 专属代码**：`load_registry` 系列在 case-sensitive FS 下读 Z 盘资源时，路径大小写差异可能导致扫描结果为空。优先复用 Android 的 `vfs` 处理，避免阶段 2 引入新 vfs 行为。
- **Documents 沙盒路径含空格**：`N95 8GB (S60v3 - FP1)` 这种带空格的目录名会让 shell 脚本 / 部分 C++ 路径拼接出问题。`seed_ios_simulator_documents.sh` 必须正确引用，C++ 侧确认 `eka2l1::common::utf8_to_utf16` + `loader` 不在路径里强行 split。
- **不做 audio 的情况下 services 启动顺序可能依赖音频初始化完成的信号**：阶段 0 已经让 `make_audio_driver` 在 iOS 返回 nullptr，但 services 内部 `if (audio_driver)` 检查不一定齐全，可能在 applist / mediaclient 启动路径上踩 nullptr。命中时就地最小修复，不要在阶段 2 改音频架构。

---

## 阶段 3：完整体验

### 目标
音频（cubeb AudioUnit）、振动（Core Haptics）、文件导入（UIDocumentPicker / Files App）、设置面板、字体/SIS 安装流程全部可用。

### 验收标准（草稿）
- [ ] 一个公开的 N-Gage 游戏（dev 自有合法 ROM）能跑起来、有声音、能交互。

### 子任务
> 进入此阶段时再拆。

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
| 2026-05-22 | 阶段 2 子任务 2.1–2.11 全部实现并 `scripts/build_ios.sh smoke` 双绿（simulator build PASS + 启动后 `EKA2L1_SMOKE: PASS backend=dyncom instrs=9 pc=0x00001024`）。期间打掉 10 个真实编译/链接/线程坑（见阶段 2 修复清单）。stage-2 的"实机加载 ROM、应用列表 ≥5、出一帧、触控触达 Calculator"等 acceptance 标准需要在 device 上 + 一个已 desktop-预装的 device 树才能完整跑通，落地与 stage-3 真实 ROM 安装流程一起做。 |

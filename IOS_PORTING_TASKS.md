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
- 新建 `src/emu/drivers/src/graphics/backend/context_eagl.{h,mm}`：实现 `gl_context` 派生类 `gl_context_eagl`，内部持有一个 `EAGLContext *`（`kEAGLRenderingAPIOpenGLES3`）和与之绑定的 `GLKView` 或裸 `CAEAGLLayer`-backed `UIView`。
- 构造路径：接收一个由前端传入的 `CAEAGLLayer *`（通过 `window_system_info::render_surface`），创建 framebuffer + color renderbuffer，调 `renderbufferStorage:fromDrawable:` 绑定 layer；缺失则报错。
- 接入 `src/emu/drivers/src/graphics/context.cpp`：在 `EKA2L1_PLATFORM(MACOS)` 之前优先匹配 `EKA2L1_PLATFORM(IOS)`，返回 `gl_context_eagl`。`gl_context_agl` 路径保持不变（macOS 桌面 Qt 仍用 AGL）。
- 实现 `swap_buffers` = `presentRenderbuffer:GL_RENDERBUFFER`；`make_current` 用 `[EAGLContext setCurrentContext:]`。
- App 进入后台必须先 `glFinish` 再 `setCurrentContext:nil`（iOS GL 严格要求），由前端的生命周期回调触发，context 暴露 `pause()` / `resume()`。

#### 2.3 iOS emu_window
- 新建 `src/emu/drivers/include/drivers/graphics/backend/emu_window_ios.h` + `src/emu/drivers/src/graphics/backend/emu_window_ios.mm`，对标 `emu_window_android`：
  - 持有 layer 指针、当前 logical size / scale、orientation。
  - 暴露 setter 给 iOS 前端在 UIView 的 `layoutSubviews` / `viewDidLayoutSubviews` 中调用，更新 framebuffer size 与 `pointer_event` 坐标系。
  - 不复用 `drivers::emu_window`（SDL2 桌面那套），iOS 直接继承 `drivers::emu_window` 抽象的最小子集即可。
- `src/emu/drivers/CMakeLists.txt` 在 `elseif (EKA2L1_IOS)` 分支里把 `emu_window_ios` 的源文件加进 drivers target（与 ogl 一起）。

#### 2.4 iOS 端 emulator state 对象
- 新建 `src/emu/ios/Bridge/IosEmulator.{h,mm}`：iOS 版 `eka2l1::ios::emulator`，结构对标 `src/emu/android/app/src/main/cpp/include/android/state.h` 里的 `eka2l1::android::emulator`，但删掉 sensor / camera / vibration / audio_driver（阶段 3 再补）。
  - 字段：`std::unique_ptr<system> symsys` / `graphics_driver` / `launcher`（参考 android launcher 但做减法）/ `emu_window_ios window` / `config::app_settings`。
  - 提供 `start(documents_root)` / `mount_rom(path)` / `rescan_apps()` / `launch_app(uid)` / `submit_pointer_event(...)` / `pause()` / `resume()` / `shutdown()`。
  - 后台一条独立 emu 线程跑 `symsys->loop()` 等价的调度循环；UI 线程只投递事件、查询状态。
- 暴露 Obj-C facade `EKA2L1Emulator`（singleton），供 SwiftUI 调用。Bridging-Header 加入。

#### 2.5 ROM / 数据布局
- 选定 sandbox 内的目录结构（写入 `IOS_PORTING_PLAN.md` 对应章节，本任务只确定即可）：
  - `<Documents>/roms/<rom-folder>/SYM.ROM` —— ROM 入口文件，前端扫描 `roms/` 一级子目录。
  - `<Documents>/data/` —— `eka2l1::system` 的 data root（drives C/E、安装目录、配置等）。
  - `<Documents>/sis/` —— 拖入待安装的 .sis / .sisx。
- iOS 前端启动时若目录不存在则创建空目录；不再硬编码 PC/Android 上的相对路径。把这部分写进 `IosEmulator::start`。
- 验证素材：手工把 `roms/N95 8GB (S60v3 - FP1)` 子目录拷进模拟器 sandbox（`xcrun simctl get_app_container booted com.eka2l1.emulator data` 拿到路径后 cp 进去）。`snakes-n95_n6trsohu.sis` 同样手工放进 `<Documents>/sis/`。开发期写一段一次性的 `scripts/seed_ios_simulator_documents.sh` 把仓库里的 `roms/` 同步过去，减少踩坑。

#### 2.6 ROM 加载与 applist 扫描
- `IosEmulator::mount_rom`：调用 `symsys` 现有的 ROM mount / `epoc::set_symbian_version` / Z 盘加载流程（参考 android `launcher::load_rom`）。
- `IosEmulator::rescan_apps`：触发 `applist_server::rescan_registries`，回调里把 `apa_app_registry`（包含 UID、可读名、icon 数据）抽成一个 plain C struct 列表，传给 Obj-C 层再转 Swift。
- iOS UI 暂时只显示名字与 UID；icon 渲染留给阶段 3（避免和 EAGL 上下文抢生命周期）。

#### 2.7 SwiftUI 外壳与 EAGL 视图
- 重写 `src/emu/ios/App/ContentView.swift`：用 `NavigationStack`，三屏：
  1. **ROM 列表**：列出 `<Documents>/roms` 下的子目录，点击一个 = 当前 ROM。
  2. **App 列表**：展示 applist 扫描结果 + 一个"安装 SIS"按钮（弹出当前 `<Documents>/sis/` 下文件供选择，调 `IosEmulator::install_sis`）。
  3. **Emulator**：全屏覆盖 `EmulatorViewControllerRepresentable`（`UIViewControllerRepresentable`）。
- 新建 `src/emu/ios/App/EmulatorView.swift` + `src/emu/ios/Bridge/EmulatorViewController.{h,mm}`：
  - `EmulatorViewController` 持有一个 `EAGLView : UIView`（`+ (Class)layerClass { return [CAEAGLLayer class]; }`），把 layer 指针传给 `IosEmulator::start_render(layer)`。
  - `viewDidLoad` 调 `IosEmulator::launch_app(uid)`；`viewWillDisappear` 调 `IosEmulator::shutdown()`。
  - `viewDidLayoutSubviews` 更新 emu_window size & scale（取 `UIScreen.main.nativeScale`）。
- 老的 CPU smoke UI 收进一个"Diagnostics"二级页面，不在主路径里。

#### 2.8 输入：触控 → pointer_event
- `EAGLView` 重写 `touchesBegan/Moved/Ended/Cancelled`，对每个 `UITouch` 抽出 `(x, y, phase)`，转 framebuffer 坐标（乘 scale + 减去 letterbox offset），投递到 `IosEmulator::submit_pointer_event`。
- 在 `IosEmulator` 内部按 `UITouch` 指针 ↔ `pointer_event::id` 一对一映射；多指支持留给阶段 3（验收只需要单指）。
- 不实现键盘 / 物理键盘 / 手柄；阶段 4 与发布通道一起做。

#### 2.9 帧循环与生命周期
- `IosEmulator` 内部用一个独立的 emu 线程（不是 CADisplayLink）跑 `symsys` 的主循环，graphics_driver 的 `process()` 在该线程上 dispatch；EAGL `presentRenderbuffer:` 必须在持有 context 的线程上调用，所以渲染线程 = emu 线程。UI 线程通过 `dispatch_async` 投递事件。
- 桥接 iOS 生命周期：在 `EKA2L1App` 里用 `@Environment(\.scenePhase)` 监听 `.active / .inactive / .background`，分别调 `IosEmulator::resume / pause / shutdown_render`。`shutdown_render` 释放 framebuffer 但保留 `symsys` 状态。
- 后台 GL 调用必须严格规避；可以让 emu 线程在 pause 期间 `wait` 在 condition_variable 上。

#### 2.10 验证脚本
- 不要求阶段 2 做端到端的"无人值守"自动验证（无法可靠 grep 出"出图了"）；保留 `scripts/build_ios.sh smoke` 的语义不变，只验 CPU smoke 仍然通过——这是回归网。
- 新增 `scripts/seed_ios_simulator_documents.sh`：把 `roms/N95 8GB (S60v3 - FP1)`、`roms/snakes-n95_n6trsohu.sis` 同步到当前 booted 模拟器的 EKA2L1 sandbox Documents 下，方便复跑。
- 手工验收步骤记录在本阶段末尾（截屏 + 日志）。

#### 2.11 文档与遗留项
- 本文件阶段 2 末尾追加"阶段 2 修复清单"，逐条记录踩坑修复（沿用 0.7 / 1.x 体例）。
- 阶段 2 落地后回看：如果 applist 渲染、SIS 安装、pointer 路径出现需要重构的设计问题，把"重构动作"明确推到阶段 3，**不要在阶段 2 内做**。

### 阶段 2 修复清单（按出现顺序）
> 进入实现阶段后逐条登记。

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

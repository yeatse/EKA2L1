# EKA2L1 iOS 移植任务跟踪

> 进度跟踪用文档，与 [`IOS_PORTING_PLAN.md`](./IOS_PORTING_PLAN.md) 配套。
> 各阶段只在真正要动手前再拆细子任务，先锁定大目标和验收标准。
>
> 状态图标：⬜ 未开始 / 🟡 进行中 / ✅ 完成 / ⏸ 阻塞 / ❌ 放弃

---

## 阶段总览

| 阶段 | 目标 | 状态 |
|------|------|------|
| 0 | 工程骨架可在 iOS arm64 上构建出空壳 | ⬜ |
| 1 | CPU 解释器跑通 + dynarmic JIT 可选启用 | ⬜ |
| 2 | iOS 前端壳 + GLES 渲染上下文，能显示一帧 | ⬜ |
| 3 | 音频 / 输入 / 振动 / 文件导入完整体验 | ⬜ |
| 4 | 发布通道（开发者签名 / TrollStore / 越狱） + CI | ⬜ |

---

## 阶段 0：可构建骨架

### 目标
让仓库在 macOS + Xcode 环境下，能通过 CMake（或衍生的 Xcode 工程）针对 `iphoneos` SDK（arm64）和 `iphonesimulator` SDK 构建出一个**最小静态库聚合 + 空壳 App**，链接通过、能在真机/模拟器上启动并立即退出（不要求任何模拟器功能跑起来）。

这一阶段**不追求功能**，只追求"编译链路打通"，把后续阶段会反复踩的构建配置坑提前排掉。

### 验收标准
- [ ] `cmake -G Xcode -DCMAKE_TOOLCHAIN_FILE=cmake/ios.toolchain.cmake -DPLATFORM=OS64 ...` 在干净 clone 后能成功生成 Xcode 工程。
- [ ] `xcodebuild -scheme EKA2L1 -sdk iphoneos -configuration Debug` 能在不带 codesign 的情况下成功编译完成（允许 signing 阶段失败）。
- [ ] 同上对 `iphonesimulator` SDK 也能编译通过（arm64 模拟器）。
- [ ] 编译产物中存在一个 iOS bundle（`.app`），其可执行体能在 iOS 模拟器上启动到空白屏幕、不立刻 crash。
- [ ] `EKA2L1_BUILD_TESTS`、`EKA2L1_BUILD_TOOLS`、`EKA2L1_ENABLE_SCRIPTING_ABILITY`、`EKA2L1_BUILD_VULKAN_BACKEND`、`EKA2L1_BUILD_PATCH` 在 iOS 下默认 OFF。
- [ ] 不引入 SDL2 到 iOS target 的链接图里。
- [ ] CI（或本地脚本）有一条命令可一键复现以上构建。

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
- [ ] `src/external/CMakeLists.txt` 跟踪：哪些子目录在 iOS 下会失败，先用 `if (NOT EKA2L1_IOS)` 暂时跳过非必需项：SDL2、luajit、ffmpeg、cubeb、miniBAE、miniupnp、libuv。
- [ ] 必需可编项（capstone、fmt、spdlog、yaml-cpp、pugixml、xxHash、re2、freetype、mbedtls、lunasvg、sqlite3、stb、libfat、libtess2、glm、thread-pool、RectangleBinPack、TinySoundFont）逐个标记构建结果。
- [ ] ffmpeg / cubeb / luajit 即便阶段 0 没有跑通，需要把"被谁依赖、关掉后影响哪些 service"记录下来，给阶段 1/2/3 用。

#### 0.6 iOS 子工程骨架
- [ ] 新建 `src/emu/ios/CMakeLists.txt`，产出一个 iOS bundle target（`MACOSX_BUNDLE` + `XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER`）。
- [ ] `src/emu/ios/App/`：最小 SwiftUI App（或 UIKit AppDelegate + 一个空 UIViewController）。可暂用 Swift；与 C++ 的桥放后续阶段。
- [ ] `src/emu/ios/Resources/Info.plist`：BundleId、display name、最低 iOS 版本、`UILaunchScreen`、`UIRequiredDeviceCapabilities = arm64`。
- [ ] `src/emu/ios/Resources/EKA2L1.entitlements`：先放空白，预留 `com.apple.security.cs.allow-jit`、`com.apple.developer.kernel.increased-memory-limit`（实际开关放阶段 1）。
- [ ] App target 链接顶层聚合静态库（common/cpu/kernel/services/...），先不调用任何符号，仅验证链接图完整。

#### 0.7 验证脚本
- [ ] 新增 `scripts/build_ios.sh`：固定参数生成 Xcode 工程 + 跑 `xcodebuild` for `iphoneos` 与 `iphonesimulator` 两个 sdk。
- [ ] 跑一次完整流程，记录耗时与产物路径，更新本文档"验收标准"的勾选状态。

### 阶段 0 已知风险
- 部分 emu 模块可能在 iOS 上**直接编译失败**（例如 `services/` 里假设有 `gettimeofday`、`pthread_setname_np` 签名差异、Mach 与 Linux 不同的命名等）。出现时**就地最小修复**，不要顺手重构；标记 `// TODO(ios)` 注释，集中在阶段 1 前夕复盘。
- 某些子模块（dynarmic、ffmpeg）可能在 CMake 配置阶段就报错，需要靠 0.5 的"跳过名单"绕过；不要试图在阶段 0 里把它们都修好。

---

## 阶段 1：CPU 跑通

### 目标
EKA2L1 能在 iOS 真机上加载并执行一段最小的 Symbian ARM 代码（例如 EUSER 的某些函数），先走解释器；在带 JIT entitlement 的环境下能切换到 dynarmic JIT。

### 验收标准（草稿，进入阶段时再细化）
- [ ] iOS 真机上能用 dyncom 解释器跑完一段已知答案的 ARM 指令片段，结果与 PC 端一致。
- [ ] 通过运行时探测决定是否启用 dynarmic JIT；无权限时安全降级。
- [ ] 有一份 dynarmic vs dyncom 的简单 benchmark 数据可供参考。

### 子任务
> 进入此阶段时再拆。

---

## 阶段 2：iOS 前端壳 + 渲染

### 目标
SwiftUI/UIKit 壳能：选择 ROM、选择已安装应用、用 CAEAGLLayer 渲染一帧 EKA2L1 输出；触控事件能转成 emu_window 输入。能跑通一个不依赖音频的 Symbian 内建应用（如 Calculator）。

### 验收标准（草稿）
- [ ] 真机能加载 ROM、列出 apps、点击启动后看到画面。
- [ ] 触控点击映射成指针事件，能完成一次"在 Calculator 上按 1 + 1 =" 的交互。

### 子任务
> 进入此阶段时再拆。

---

## 阶段 3：完整体验

### 目标
音频（cubeb AudioUnit）、振动（Core Haptics）、文件导入（UIDocumentPicker / Files App）、设置面板、字体/SIS 安装流程全部可用。

### 验收标准（草稿）
- [ ] 一个公开的 N-Gage 游戏（dev 自有合法 ROM）能跑起来、有声音、能交互。

### 子任务
> 进入此阶段时再拆。

---

## 阶段 4：发布通道 + CI

### 目标
sideload / TrollStore / 越狱三套签名打包流程文档化；GitHub Actions 跑 iOS 构建烟测。

### 验收标准（草稿）
- [ ] CI 上 iOS 构建产物可下载。
- [ ] README 写清楚三种安装方式的步骤与 JIT 启用方法。

### 子任务
> 进入此阶段时再拆。

---

## 变更日志

| 日期 | 改动 |
|------|------|
| 2026-05-20 | 初版：拆完阶段 0，其余阶段仅列目标 |

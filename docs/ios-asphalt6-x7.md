# X7 Asphalt 6 启动与比赛链路修复

## 结论

Asphalt 6（UID `0x2003B2CC`）在 X7 / rm-707 上的黑屏与卡死不是单一游戏缺陷，而是 Symbian^3/Belle 路径连续命中了 SCDV、Belle executive、ROM DLL 加载、MMF/ALF、Window Server、Accessory 和 Loader 等多处通用仿真缺口。

修复后可稳定完成：启动 → 主菜单触控 → Free Race → Nassau → Normal Race → Mini 选车 → 正式比赛。车辆、赛道和 HUD 正常渲染，调查时实测约 17–27 FPS、车速 199 km/h；没有加入 Asphalt UID、文件名或资源路径特判。

## 复现条件

- iOS 模拟器：iPhone 16 Pro，iOS 26.5
- EKA2L1 设备：X7，firmware code `rm-707`
- 游戏 UID：`0x2003B2CC`
- 游戏安装在当前设备的 E 盘
- CPU：dyncom（默认正常运行路径）
- 启动命令：

  ```sh
  xcodebuildmcp simulator launch-app --json '{
    "simulatorId": "booted",
    "bundleId": "com.eka2l1.emulator",
    "launchArgs": ["-LaunchROMCode", "rm-707", "-LaunchAppUID", "0x2003B2CC", "-LaunchKeypadLayout", "fullscreen"]
  }' --output json
  ```

首次加载资源较慢，启动后应等待至少 30–60 秒再判断画面。

## 根因链

| 阶段 | 现象 | 根因 | 修复 |
|------|------|------|------|
| SCDV 创建设备 | `BITGDI 10` | replacement SCDV 不支持 Belle 请求的 `EColor16MAP` 预乘 alpha 模式 | 复用 32-bit alpha draw device，并保留 `EColor16MAP` display mode |
| Screen surface | 旋转/区域状态错误，继而触发 BITGDI panic | `GetInterface(KSurfaceInterfaceID=8)` 返回不支持，缺少 `MSurfaceId` 和设备旋转接口 | SCDV 提供 ABI 兼容的 surface ID、四方向能力、设置/读取方向 |
| Belle executive | SecLdd 等对象句柄无效 | v10 executive 表缺少/错位的 `ThreadProcess`、server/session 和 logical-device/channel SVC | 补齐 `0x7D..0x84` 映射与通用 HLE logical channel 创建 |
| ROM DLL 加载 | `hxmedpltfm.dll` 无法加载 | ROM 中该文件是非 XIP E32Image；同时 `\sys\bin\*.dll` 是 rooted 但不带盘符 | ROM 文件先识别 E32Image；无盘符 rooted 路径依次在挂载盘符解析 |
| MMF A3F | 启动线程同步 IPC 永久等待 | new-architecture MMF 缺 Stop、priority、client-thread-info 等 opcode | 映射到既有 stop/priority 处理；in-process 音频模型完成 client-thread-info |
| ALF | transition policy 请求语义错误 | 长生命周期通知被当成立即完成的普通 no-op | 保存 pending policy request，并实现 cancel；同步 effect 调用返回序列化成功码 |
| Window Server | screen device 请求挂起 | 缺 `GetCurrentScreenModeAttributes` 和 extension query | 返回 ABI 正确的 60-byte `TSizeMode`，无扩展时完成 `0` |
| Accessory Server | Belle accessory client 挂起 | 只实现了旧 S60v3 opcode | 增加 modern connection subsession、状态查询/通知/取消 |
| Loader | IVE policy server 等待 PDD load | `ELoadPhysicalDevice` 未处理 | 与现有 LDD HLE 策略一致：校验名称并完成成功 |

最后一个阻塞是 MMF new-architecture Stop；补齐后游戏开始持续加载 `.bdae`、shader、车辆和赛道资源，并正常提交 GLES 帧。

日志中针对不存在的 loose `.tga`、`.glsl.config` 和 fallback shader 路径仍会出现 `Trying to open a non-existent file`。游戏会继续从归档资源加载，这些不是启动失败或 guest crash。

## SCDV DLL 制作

### 为什么保留二进制补丁路径

`src/patch/scdv` 已补齐 `EColor16MAP` 与 `MSurfaceId` 的完整 C++ 实现，可用 macOS Symbian DLL 工具链编译。但重新链接整个 DLL 会改变函数布局、导入区、exception descriptor 和压缩结果；旧 ROM 的 replacement DLL 又要求既有 ordinal/ABI 完全不变。因此交付 DLL 以仓库原始 `scdv_general.dll` 为基线，只修改确定的 code bytes，并重新生成 E32 header CRC。

基线信息：

- Git blob：`ec2ffa212c3cc7e0a426adacb656e1b962db3e6a`
- SHA-256：`6ead71eb0538bf519a4a088a2efa4ccec711ed53acc5dad42d105f1b4418b4ee`
- UID：`10000079 10003B19 EE000002`
- ARMV5 / EKA2 / DEFLATE
- code link address：`0x8000`
- code size：`0x6104`
- exports：31，ordinal 表不变

### 一键生成

工具链放在 `~/Developer/symbian` 时执行：

```sh
scripts/build_scdv_belle_patch.sh /tmp/scdv_general_belle.dll
```

脚本会：

1. 从基线 Git blob 取原 DLL，并校验 SHA-256；浅克隆缺少该 blob 时可设置 `SCDV_BASE_DLL=/path/to/original.dll`。
2. 用 `arm-none-eabi-gcc/ld/objcopy` 将 [`surface_stub.S`](../src/patch/scdv/surface_stub.S) 组装为 ARMv5 Thumb position-independent code。
3. 使用 `elf2e32_next` 的 E32 compressor 解压原 image。
4. 由 [`patch_scdv_e32.cpp`](../scripts/tools/patch_scdv_e32.cpp) 做带原字节断言的最小修改。
5. 重新 DEFLATE、更新 UID checksum/header CRC，并用 `verify_e32.py` 校验 UID、CPU、signature、code offset 和 export table。

macOS 工具位置可覆盖：

```sh
SYMBIAN_ROOT="$HOME/Developer/symbian" \
SYMBIAN_DLL_KIT_ROOT="$HOME/Developer/symbian/symbian-dll-agent-kit" \
scripts/build_scdv_belle_patch.sh /tmp/scdv_general_belle.dll
```

### 二进制修改范围

下列 offset 均相对解压后的 E32 code section：

| Offset | 长度 | 用途 |
|--------|------|------|
| `0x1BDE` | 4 | 将 display-mode dispatch 上界扩到 `EColor16MAP` |
| `0x1D72` | 6 | 让 MAP 走 32-bit alpha 构造并保留请求的 display mode |
| `0x247C` | `0x34` | 替换 `CFbsThirtyTwoBitsDrawDevice::GetInterface` dispatch |
| `0x5010` | `0xA0` | 复用未执行的诊断字符串空间保存 `MSurfaceId` 实现、vtable 和 surface ID |

`surface_stub.S` 的 `.org 0x2B94` 表示第二块代码相对 `GetInterface` 的距离。补丁器只写首尾两个有效区间，不会用 `.org` 中间的零填充覆盖原代码。

生成后可进一步检查：

```sh
python3 ~/Developer/symbian/symbian-dll-agent-kit/tools/verify_e32.py \
  /tmp/scdv_general_belle.dll --uid2 0x10003B19 --uid3 0xEE000002

~/Developer/symbian/symbian-dll-agent-kit/.cache/elf2e32-build/elf2e32 \
  --dump=he --e32input=/tmp/scdv_general_belle.dll
```

不同 host compiler 可能生成不同但等价的 DEFLATE bitstream；验收依据是解压后的 code、header/CRC、31 个 exports 和运行回归，不以压缩文件逐字节相同为前提。

### 完整源码编译校验

完整源码仍应能通过工具链编译，以防二进制补丁和 C++ 实现长期漂移：

```sh
cd ~/Developer/symbian/symbian-dll-agent-kit
./scripts/build-dll.sh projects/scdv.env
```

产物位于 `out/scdv_general/`。该路径用于源码/ABI校验；iOS bundle 当前部署的是上述 ABI-preserving binary patch。

## 自动回归

先构建并安装 Release 包：

```sh
EKA2L1_IOS_CONFIGURATION=Release scripts/build_ios.sh simulator
scripts/ios_regression_test.sh --install \
  build/ios-simulator/src/emu/ios/Release-iphonesimulator/EKA2L1.app asphalt6
```

已安装 Release 包时直接运行：

```sh
scripts/ios_regression_test.sh asphalt6
```

脚本要求 booted simulator 已安装 rm-707 与 Asphalt 6，并依赖 `xcodebuildmcp`、`jq`、ImageMagick 和 xcodebuildmcp bundled `axe`。它会保存以下状态到 `/tmp/eka2l1-regression/`：

- Gameloft/Asphalt splash
- 主菜单
- Nassau track select
- race-mode select
- Mini car select
- 赛前预览
- 实际比赛

除截图差异断言外，脚本还检查新增日志中没有 `panic`、`access violation`、`KERN-EXEC` 或 emulation halt。

## 最终验证

- Asphalt 6：正式进入 Nassau Normal Race，车辆/赛道/HUD 正常
- 标准 Release 回归：连续两轮 `PASS=8 FAIL=0`
- Angry Birds X7 触屏/GLES 回归：`PASS=5 FAIL=0`
- SCDV C++ 完整源码：macOS Symbian DLL 工具链编译成功
- SCDV binary patch：E32 header/UID/export 校验成功
- 最终日志：无 Asphalt guest panic、access violation 或 crash

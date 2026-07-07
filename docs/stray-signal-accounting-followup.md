# Stray-signal 根因与根治方向（请求信号量记账重构，接手指南）

> 状态：🟡 未根治，靠补偿层稳定。本文是给后续接手者的路线图。
>
> **一句话结论**：`E32USER-CBase 46`（stray signal）的根因是 EKA2L1 的 HLE 服务会向 guest
> 线程的 request semaphore 发出**真机内核不会产生的多余信号**；当前树内靠
> `thread::wait_for_any_request()` 的吸收机制兜底（工作正常但属于补偿层），根治 =
> 把 `signal_request` 的每一次调用与"一个就绪 AO 或一次 wrapper 唤醒"严格配对的记账重构。

## 1. 问题模型

真机 Symbian 语义：guest 线程的 request semaphore 上，每个 `RequestComplete`
恰好对应一次信号；`CActiveScheduler::Run` 每从 `WaitForAnyRequest` 醒来一次，
就必然能在 AO 队列里找到一个 `active && status != KRequestPending` 的对象。
找不到 = 程序错误 = panic `E32USER-CBase 46`。真机**没有吸收机制**。

EKA2L1 里同一个 semaphore 同时承载：AO 完成、同步 IPC（`SendReceive` sync /
`User::WaitForRequest` wrapper）完成、以及历史上混进来过的 HLE 侧唤醒。任何一处
HLE 代码多发 / 早发 / 补发信号，账就不平，guest 调度器醒来找不到就绪 AO → panic。

## 2. 现有防线（按时间）

| 防线 | 位置 | 修掉的来源 | 文档 |
|------|------|-----------|------|
| `thread::sleep` 双唤醒泄漏修复 | `kernel/src/thread.cpp` | HLE frame-pacing sleep 混入 request semaphore | [`ios-snakes-stray-signal.md`](./ios-snakes-stray-signal.md) |
| vsync notify 走 kernel lock | `dispatch/src/screen.cpp` | 无锁完成扩大时序窗口 | 同上 |
| timer `fire_or_defer` | `kernel/src/timer.cpp` | 定时器在 guest 写好 status 但未 `SetActive` 的窗口内完成 | [`ios-final-battle-timer-stray.md`](./ios-final-battle-timer-stray.md) |
| **吸收机制**（本文主角） | `thread::wait_for_any_request` | 兜住所有残留 stray | [`ios-snakes-stray-signal.md`](./ios-snakes-stray-signal.md) + 2026-07-07 变更日志 |
| 吸收机制的 dynarmic 修复 | 同上 | ctx 快照陈旧 + fast-stub 被拒 → JIT 下吸收失效 | 变更日志 2026-07-07 |

吸收机制的当前形态（三重保护，缺一不可）：

- 只在 `identify_wait_request_stub` 识别为 **direct `User::WaitForAnyRequest`**
  （slow/patched/fast exec stub + `BX LR` 返回）时吸收；
- fast-exec 形态若 **r0 映射到有效内存**，视为 `User::WaitForRequest(TRequestStatus&)`
  wrapper，**绝不吸收**（wrapper 的 do-while 循环会自然吃掉 stray；盲吸收会吞掉
  wrapper 的真信号 → 历史上的"菜单按键被吞死锁"）；
- active scheduler 存在且 `has_ready_request()` 为假才吸收（有就绪 AO 时立即交还 guest）。

## 3. 量化证据（2026-07-07 探针实测，iPhone 16 Pro sim）

- **dyncom 下 Snakes 一次启动画面 ≈ 235 个 stray 被吸收**——机制不是死代码，去掉立即回归 panic。
- dynarmic 下吸收失效（当时的 bug）= Snakes 启动必现 panic，等价于一次"自然去除实验"。
- stray 到达位置的分布随后端时序漂移：dyncom（慢）下多在 park 后到达；dynarmic（快）下
  在 guest 到达 WaitForAnyRequest 前已入队。**dynarmic 是这个问题的时序放大器，
  复现/验证请优先用 JIT 后端压测。**

## 4. 残留 stray 的来源（未根治部分）

探针（见 §6 配方）已排除的嫌疑：

- **双重完成**：未观测到（`notify_info::complete` 完成后清 `sts`，拷贝副本二次完成为 no-op）。
- **complete-before-SetActive 本身**：`fifo::set_listener` / `msv listen` 等在
  SendReceive 内立即完成是合法 Symbian 语义（guest 随后 `SetActive`，信号与就绪 AO
  配对），不是 stray。

先前调查（2026-06）对残留信号做过 reason-tagging：**残留以 `hle-ipc-complete`
（同步 IPC 完成路径）为主**——即同步 `SendReceive` / server 完成与 AO 完成共享
semaphore 时，某些交错下多计了一次。精确的失衡调用点尚未定位到行级。

其他已知可疑点（未逐一审计）：

- `thread.cpp` 异常处理路径：`call_exception_handler` 中 `backup_state == wait_fast_sema`
  时补发 `signal_request()`，与 `restore_before_exception_state` 的
  `wait_for_any_request()` 是否严格配对；
- `semaphore::timeouted` / wait 超时路径与 request semaphore 的交互；
- server/session 终止时对未决消息的批量完成。

## 5. 根治方向（建议路线）

目标：**让吸收计数在全回归流程中恒为 0**，然后把吸收降级为断言/诊断日志，最终删除。

1. ✅ **可观测性（2026-07-07 已落地）**：`kernel::thread::stray_absorbed_count`
   逐次计数，首次及每第 100 次打一行
   `Absorbed stray request signal #N on thread ...`（`thread.cpp`
   `wait_for_any_request` 吸收分支）。日志里 grep `Absorbed stray` 即可度量；
   重构完成与否的唯一判据 = 全流程该计数恒为 0。
2. **枚举审计 `signal_request` 全部调用点**：树内调用点有限（`notify_info::complete`、
   sync IPC 完成、异常路径、sema 等）。对每个调用点写下它应配对的消费方
   （AO dispatch / wrapper wake / sync-send 返回），标注不能自证配对的点。
3. **对失衡点做 reason-tagging 复测**：debug 构建里给每次 signal 附 tag（来源枚举 +
   调用方地址），wait 侧消费时记录 tag；panic/吸收时 dump 未配对 tag 的分布。
   2026-06 的旧探针已证明该方法可行（当时锁定 `hle-ipc-complete` 主导）。
4. **候选设计**（按侵入性排序）：
   - a. 修单点：定位到具体失衡调用点后按 `fire_or_defer` 的思路逐个修（защ最小）；
   - b. 分离计数：同步 IPC 完成不再走共享 request semaphore，改专用事件/计数
     （更接近真机 `iRequestSemaphore` 只服务 AO 的用法；侵入 kernel/ipc 层，
     需过全平台回归）；
   - c. 对照 upstream：diff 本 fork 与 upstream EKA2L1 的 `wait_for_any_request` /
     completion 语义，确认哪些失衡是 fork 引入、哪些 upstream 同样存在。
5. **验收标准**：Snakes（splash + 3D gameplay）、Final Battle、Calculator（Options
   菜单开关）、BIA 全流程在 **dyncom 与 dynarmic 双后端**下 `absorbed=0` 且回归
   8/8、BIA 7/7；然后把吸收换成 `LOG_ERROR` + 计数，跑一个版本周期无报告后删除。

## 6. 探针配方（本次调试验证有效，均为临时代码，勿入提交）

- **完成源标记**：`notify_info::complete` 里按 `sts_real->flags`（pending/active）+
  `requester->request_count()` 过滤，打 `__builtin_return_address(0)`；
  用 `sample <pid> 1` 拿 EKA2L1 加载地址，`atos -o EKA2L1.app/EKA2L1 -l <load>` 解析。
- **吸收路径插桩**：`wait_for_any_request` 的 stub-miss / absorb 分支打
  `ctx.get_pc()`、`*(pc-4)`（SVC 编码）、返回指令、`r0`。
- **SVC 入口 PC 校验**：`kernel_system::set_epoc_version` 的 `system_call_handler`
  里校验 `*(live_pc - 4)` 是否 SVC 编码（`(ins & 0x0F000000) == 0x0F000000`），
  验证后端上下文报告准确性（dyncom/dynarmic 均已验证准确）。
- 日志位置：`Documents/data/EKA2L1.log`；**活配置是 `Documents/data/config.yml`**
  （`Documents/config.yml` 是陈旧遗留，别读错）。

## 7. 风险与红线

- **绝不能盲吸收**：没有 stub 识别 + wrapper 判别 + ready-AO 检查的任何"吞信号"
  扩展都会复现"按键被吞 / 同步 IPC 死锁"（历史已踩过两次）。
- 改动 `wait_for_any_request` / completion 语义后，dyncom 与 dynarmic **两个后端都要**
  过回归（时序不同，单后端通过不代表安全），最少：`scripts/ios_regression_test.sh` 8/8 ×2 +
  Snakes 进 3D gameplay ×2 + `scripts/ios_bia_gameplay_test.sh` 7/7。
- EKA1 不携带 request_status flags，所有基于 flags 的判断都要保持 `is_eka1()` 分支语义。

# Independent ARMv5/v6 interpretation on iOS

The experimental `armv6` backend keeps the guest integer and VFP registers, CPSR, FPSCR and thread ID in a single context. ARM and Thumb code pages are keyed by address space, page number and instruction set. Decoding produces data consumed by statically compiled handlers. The backend allocates no executable memory. At revision `78d7a9438` it stopped creating or stepping a Dyncom CPU. It shares Thumb instruction normalization and VFP arithmetic with the existing interpreter. An unhandled encoding raises a guest exception. The existing interpreter remains available while compatibility testing continues.

A page handler can retire several operations before returning to the scheduler. A fused pair still has two entry points, and a budget of one retires only the first instruction. A memory miss publishes the guest state at the faulting instruction before invoking the MMU. The exclusive monitor receives the scheduled core so it resolves the correct address space. Floating-point register transfers preserve raw bits, and the scalar arithmetic path preserves cumulative inexact status when guest code reads FPSCR.

## Fixed-work throughput

The following measurements used an arm64 Release executable on the iOS simulator at `78d7a9438`. A diagnostic build took guest register snapshots at scheduling boundaries during play. A separate reference interpreter recorded the initial and final contents of every touched page in private memory. Each replay started from the same registers and memory and retired 4,096 instructions. All three backends matched the expected architectural context and final memory at the instruction boundary. Measurements used the median of 36 warmed runs per snapshot and then the median across snapshots for each game.

| Guest scene | Snapshots | Dyncom ns/instruction | Thumb block ns/instruction | ARMv6 ns/instruction | Throughput vs Dyncom | Throughput vs Thumb block |
|---|---:|---:|---:|---:|---:|---:|
| Reset Generation, arcade | 7 | 4.059 | 3.672 | 2.797 | 1.45× | 1.31× |
| Angry Birds, first level | 17 | 5.005 | 5.147 | 4.333 | 1.16× | 1.19× |
| Glow Air Hockey, level 1-1 | 15 | 6.510 | 6.083 | 5.300 | 1.23× | 1.15× |

These samples repeatedly visit the same few game routines. The capture accepts intervals that complete without a syscall, exception or exclusive access. Boot, cold code translation and host rendering are outside the timed interval. The 1.45× target across games is still open.

## CPU cost in a running match

Random arena layouts made Reset Generation comparisons across launches noisy. A fork-only diagnostic build at `f5bda508d` switched engines at scheduling boundaries within one match. It alternated eight eight-second windows in B-A-A-B-A-B-B-A order with four windows per backend. Here B denotes the previous Thumb block backend and A denotes the new interpreter. The measurements below are medians. CPU time includes user and system time of the simulator app process. The denominator counts submitted guest frames. The diagnostic wrapper copies the guest context at the compact backend boundary, which can affect small differences.

| Game | Thumb block CPU ms/frame | ARMv6 CPU ms/frame | Thumb block frames/s | ARMv6 frames/s |
|---|---:|---:|---:|---:|
| Reset Generation | 31.24 | 27.60 | 23.55 | 23.47 |
| Angry Birds | 22.20 | 22.25 | 56.98 | 57.80 |
| Glow Air Hockey | 23.62 | 23.95 | 35.33 | 35.53 |

Reset Generation used about 12% less CPU per submitted frame in this match. The two other games showed no convincing reduction in process CPU per frame. These timings precede the removal of the cold interpreter. The simulator measurements do not establish iPhone Air power consumption.

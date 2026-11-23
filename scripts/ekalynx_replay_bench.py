#!/usr/bin/env python3
# Compare ekalynx ns/instruction of two arm_replay builds over recorded snapshots.
#
# Record snapshots with a simulator build launched with
#   SIMCTL_CHILD_EKA2L1_REPLAY_CAPTURE_DIR=<dir> xcrun simctl launch booted com.eka2l1.emulator
# then, in game, write "<process name substring> <label> <count>" to <dir>/trigger
# (the process name is "[<uid3 hex>]NNNN", e.g. "ea6aeee1 tiandidao 48").
# Build arm_replay for each revision with scripts/cpu_difftest.sh (build/host-difftest/src/emu/cpu/arm_replay),
# copy the binaries to distinct paths and run:
#   scripts/ekalynx_replay_bench.py <base arm_replay> <candidate arm_replay> <dir> [rounds]
# arm_replay also fails if either backend diverges from the recorded result.
import glob, math, os, re, statistics, subprocess, sys
base, cand, d = sys.argv[1], sys.argv[2], sys.argv[3]
rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 5
traces = sorted(glob.glob(os.path.join(d, "*.trace")))
res = {b: {} for b in (base, cand)}
for r in range(rounds):
    for b in ((base, cand) if r % 2 == 0 else (cand, base)):
        out = subprocess.run([b] + traces, capture_output=True, text=True)
        if out.returncode:
            sys.exit(f"{b} failed: {out.stderr.strip()}")
        for line in out.stdout.splitlines():
            path, mode, _, _, ns = line.split()
            if mode == "5":
                res[b].setdefault(path, []).append(float(ns))
games = {}
for t in traces:
    games.setdefault(re.sub(r"-\d+\.trace$", "", os.path.basename(t)), []).append(t)
def gm(xs): return math.exp(sum(map(math.log, xs)) / len(xs))
print(f"{'game':12} {'n':>3} {'base':>8} {'cand':>8} {'speedup':>8} {'worst':>7}")
for g, ts in games.items():
    b = [statistics.median(res[base][t]) for t in ts]
    c = [statistics.median(res[cand][t]) for t in ts]
    ratios = [x / y for x, y in zip(b, c)]
    print(f"{g:12} {len(ts):3} {gm(b):8.3f} {gm(c):8.3f} {gm(ratios):7.3f}x {min(ratios):6.3f}x")

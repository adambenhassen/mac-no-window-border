#!/usr/bin/env python3
"""Measure entry CPU cost and target timer gaps using only children launched here.

Build first: make probe tests/timerloop
Usage: python3 tests/entrybench.py > build/entrybench.json
The probe runs entries back-to-back. CPU/entry is useful for comparing versions;
it is not an idle CPU measurement of NoBorder or a real-time latency guarantee.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def reap(process):
    _, status, usage = os.wait4(process.pid, 0)
    process.returncode = os.waitstatus_to_exitcode(status)
    return usage.ru_utime + usage.ru_stime


def measure(mode, log_dir):
    target_log = log_dir / f"{mode}-target.log"
    probe_log = log_dir / f"{mode}-probe.log"
    target = probe = None
    try:
        with target_log.open("w") as output:
            launched = time.monotonic()
            target = subprocess.Popen([str(ROOT / "tests/timerloop")], stdout=output)
            time.sleep(0.5)  # Exclude startup timer gaps.
            warmup_lines = len(target_log.read_text().splitlines())
            started = time.monotonic()
            probe_cpu = 0.0
            if mode != "baseline":
                with probe_log.open("w") as output:
                    probe = subprocess.Popen([
                        str(ROOT / "build/noborder-probe"), "run-repeat",
                        str(target.pid), "0", mode, "400",
                    ], stdout=output)
                    probe_cpu = reap(probe)
            time.sleep(max(0, 5 - (time.monotonic() - started)))
            samples = target_log.read_text().splitlines()[warmup_lines:]
            # A stopped timer must not look like an excellent latency result.
            before = int(samples[-1].split()[1])
            time.sleep(0.3)
            after = int(target_log.read_text().splitlines()[-1].split()[1])
            assert target.poll() is None and after > before, "target died or timer stopped"
            target.terminate()
            target_cpu = reap(target)
            target_wall = time.monotonic() - launched
        gaps = [int(line.split()[3]) for line in samples if line.startswith("fired ")]
        result = {"mode": mode, "max_timer_gap_us": max(gaps),
                  "target_cpu_s": round(target_cpu, 6), "target_wall_s": round(target_wall, 3)}
        if mode != "baseline":
            lines = probe_log.read_text().splitlines()
            # run-repeat intentionally exits 1 for a normal run (0 denotes its timeout test).
            assert probe.returncode == 1 and len(lines) == 400, "probe did not finish all attempts"
            ok = [line for line in lines if "result=ok " in line]
            assert ok, "no successful entries to measure"
            assert all("result=ok " in line or "result=not-parked " in line for line in lines), lines
            times = sorted(int(re.search(r"stop_us=(\d+)", line)[1]) for line in ok)
            all_times = sorted(int(re.search(r"stop_us=(\d+)", line)[1]) for line in lines)
            deferred_times = [int(re.search(r"stop_us=(\d+)", line)[1]) for line in lines
                              if "result=not-parked " in line]
            result.update(attempts=len(lines), entries=len(ok), deferred=len(deferred_times),
                          suspended_deferrals=sum(t > 0 for t in deferred_times),
                          deferred_max_us=max(deferred_times, default=0),
                          attempt_p95_us=all_times[int(len(all_times) * .95)],
                          probe_cpu_s=round(probe_cpu, 6),
                          cpu_us_per_entry=round(probe_cpu * 1e6 / len(ok)),
                          entry_p50_us=times[len(times) // 2],
                          entry_p95_us=times[int(len(times) * .95)],
                          entry_max_us=max(times))
        return result
    finally:
        for child in [probe, target]:
            if child is not None and child.poll() is None:
                child.terminate()
                child.wait()


if __name__ == "__main__":
    log_dir = ROOT / "build" / f"entrybench-{time.time_ns()}"
    log_dir.mkdir()
    print(json.dumps({"logs": str(log_dir),
                      "results": [measure(mode, log_dir) for mode in ["baseline", "key", "noop"]]}, indent=2))

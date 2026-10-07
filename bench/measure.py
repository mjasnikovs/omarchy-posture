"""Run a helper command, report first-line latency, peak RSS, avg CPU %.
Usage: python measure.py NAME -- CMD...
"""
import json, os, subprocess, sys, time

name = sys.argv[1]
cmd = sys.argv[sys.argv.index("--") + 1:]
tck = os.sysconf("SC_CLK_TCK")
t0 = time.time()
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
first = None
hwm = 0
cpu = 0.0
lines = 0
ms = []
for line in p.stdout:
    lines += 1
    if first is None:
        first = time.time() - t0
    try:
        d = json.loads(line)
        ms.append(d.get("ms", d.get("pre_ms", 0) + d.get("inf_ms", 0)))
        with open(f"/proc/{p.pid}/status") as f:
            for l in f:
                if l.startswith("VmHWM"):
                    hwm = int(l.split()[1]) // 1024
        with open(f"/proc/{p.pid}/stat") as f:
            st = f.read().rsplit(")", 1)[1].split()
            cpu = (int(st[11]) + int(st[12])) / tck
    except (ValueError, FileNotFoundError):
        pass
wall = time.time() - t0
p.wait()
ms.sort()
print(json.dumps({"name": name, "frames": lines, "first_out_s": round(first or -1, 2),
                  "peak_rss_mb": hwm, "cpu_s": round(cpu, 2), "cpu_pct_one_core": round(cpu / wall * 100, 2),
                  "median_frame_ms": round(ms[len(ms) // 2], 2) if ms else None}))

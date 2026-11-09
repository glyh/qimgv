#!/usr/bin/env python3
"""Baseline harness for qimgv (ticket #8).

Runs the in-tree QIMGV_BENCH probe against the four workloads fixed in #6,
with an external VmRSS sampler that survives the app crashing, and reports
median/spread over N reps.

Harness, pinned (see the ticket comment for why):
  * binary      zig build -Doptimize=ReleaseFast
  * platform    QT_QPA_PLATFORM=offscreen, QT_SCALE_FACTOR=1
  * cold cache  sync + drop_caches before every rep (needs root)
  * governor    performance while running, restored afterwards
  * reps        median of 5, min/max reported
  * corpora     /home/lyh/pullground/qimgv-bench/{coco5000,w3-100mp}

Markers the probe emits (TSV, ms from process start):
  window-shown, grid-interactive, first-thumbnail,
  image-ready (pixmap handed to the viewer), image-visible (same instant),
  step (per image switch), scroll (per grid scroll)

Usage: bench.py [w1|w3|w4|w4-nopreload|w2 ...] [--reps N] [--out DIR]
"""
import argparse
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time

ROOT = "/home/lyh/pullground/qimgv"
BIN = f"{ROOT}/zig-out/bin/qimgv"
BENCH = "/home/lyh/pullground/qimgv-bench"
COCO5K = f"{BENCH}/coco5000"
COCO200 = "/tmp/bench-coco200"
W3 = f"{BENCH}/w3-100mp/12402_textures_glow-in-dark_by-haberdoedas-5bsnvq1qtis-unsplash_8736x11648.jpg"

WORKLOADS = {
    # name: (argv path, plan, terminal marker, timeout s, extra conf)
    "w1": ((COCO5K,), "open", "image-ready", 90, {}),
    "w3": ((W3,), "open", "image-ready", 90, {}),
    "w4": ((COCO200,), "step:200", "drive-done", 180, {}),
    "w4-nopreload": ((COCO200,), "step:200", "drive-done", 180, {"usePreloader": "false"}),
    "w2": ((COCO5K,), "scroll:60", "drive-done", 120, {}),
}


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def drop_caches():
    r = sh("sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'")
    if r.returncode != 0:
        print("  ! drop_caches failed (no root?):", r.stderr.strip(), file=sys.stderr)


def set_governor(value):
    path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    r = sh(f"sudo -n sh -c 'echo {value} > {path}'")
    if r.returncode != 0:
        print(f"  ! governor {value} failed (no root?)", file=sys.stderr)


def sampler(pid, out_path, stop):
    """VmRSS every 50 ms; runs in a thread so a crashed app still leaves a file."""
    with open(out_path, "w") as f:
        f.write("t_ms\trss_kb\tanon_kb\tfile_kb\n")
        t0 = time.monotonic()
        while not stop.is_set():
            try:
                with open(f"/proc/{pid}/status") as s:
                    vals = {}
                    for line in s:
                        if line.startswith(("VmRSS:", "RssAnon:", "RssFile:")):
                            k, v = line.split(":")
                            vals[k] = int(v.split()[0])
                f.write("%d\t%s\t%s\t%s\n" % (
                    int((time.monotonic() - t0) * 1000),
                    vals.get("VmRSS", 0), vals.get("RssAnon", 0), vals.get("RssFile", 0)))
                f.flush()
            except FileNotFoundError:
                break
            except Exception:
                pass
            time.sleep(0.05)


def parse_tsv(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 3:
            try:
                rows.append((parts[0], int(parts[1]), int(parts[2])))
            except ValueError:
                pass
    return rows


def run_rep(wl, rep, outdir):
    path_arg, plan, terminal, timeout, conf = WORKLOADS[wl]
    tag = f"{wl}-rep{rep}"
    tsv = f"{outdir}/{tag}.tsv"
    rssout = f"{outdir}/{tag}.rss"
    cfg = f"{outdir}/cfg-{tag}"
    os.makedirs(f"{cfg}/qimgv", exist_ok=True)
    if conf:
        with open(f"{cfg}/qimgv/qimgv.conf", "w") as f:
            f.write("[General]\n" + "".join(f"{k}={v}\n" for k, v in conf.items()))
    env = dict(os.environ,
               XDG_CONFIG_HOME=cfg,
               QIMGV_BENCH="1",
               QIMGV_BENCH_OUT=tsv,
               QIMGV_BENCH_PLAN=plan,
               QT_QPA_PLATFORM="offscreen",
               QT_SCALE_FACTOR="1")
    if os.path.exists(tsv):
        os.remove(tsv)

    drop_caches()
    t0 = time.monotonic()
    proc = subprocess.Popen([BIN, *path_arg], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stop = threading.Event()
    th = threading.Thread(target=sampler, args=(proc.pid, rssout, stop), daemon=True)
    th.start()

    rows = []
    deadline = t0 + timeout
    idle_wait = 6.0 if plan.startswith("step") or plan.startswith("scroll") else 3.0
    last_seen = None
    while time.monotonic() < deadline:
        time.sleep(0.2)
        rows = parse_tsv(tsv)
        if any(r[0] == terminal for r in rows):
            # let the idle-RSS tail settle after the last action
            time.sleep(3.0)
            break
        cur = len(rows)
        if cur == last_seen:
            if time.monotonic() - t0 > idle_wait and cur > 0:
                time.sleep(2.0)   # nothing more is coming; keep the idle tail
                break
        else:
            last_seen = cur
    stop.set()
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
    th.join(1)
    rows = parse_tsv(tsv)

    rss = []
    if os.path.exists(rssout):
        for line in open(rssout):
            p = line.split()
            if p and p[0].isdigit():
                rss.append(tuple(int(x) for x in p))
    peak = max((r[1] for r in rss), default=0)
    tail = [r[1] for r in rss[-40:]]
    idle = statistics.median(tail) if tail else 0
    return {"tag": tag, "rows": rows, "peak_rss_kb": peak, "idle_rss_kb": idle,
            "wall_ms": int((time.monotonic() - t0) * 1000)}


def summarize(wl, reps):
    marks = {}
    for r in reps:
        for kind, seq, ms in r["rows"]:
            marks.setdefault(kind, []).append(ms)
    out = {"workload": wl, "peak_rss_kb": [r["peak_rss_kb"] for r in reps],
           "idle_rss_kb": [r["idle_rss_kb"] for r in reps]}
    for kind in ("window-shown", "grid-interactive", "first-thumbnail", "image-ready",
                 "step", "scroll", "open-failed"):
        if kind in marks:
            v = marks[kind]
            out[kind] = {"n": len(v), "median": statistics.median(v),
                         "min": min(v), "max": max(v)}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workloads", nargs="*", default=["w1", "w3", "w4", "w4-nopreload", "w2"])
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--out", default="/tmp/bench-run")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    set_governor("performance")
    results = {}
    try:
        for wl in args.workloads:
            reps = [run_rep(wl, i, args.out) for i in range(args.reps)]
            s = summarize(wl, reps)
            results[wl] = s
            print(json.dumps(s, indent=1))
            sys.stdout.flush()
    finally:
        set_governor("powersave")
        with open(f"{args.out}/summary.json", "w") as f:
            json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Second wave: finish the COCO parquet download by fanning the remaining tail
of each of the 16 original range chunks into 4 sub-ranges.

The original 16 curl processes are killed first; each <name>.partNN holds the
prefix [start, start+len) of its range, so the tail to fetch is
[start+len, end) regardless of how far the killed curl got.
"""
import hashlib, os, subprocess, sys, time

BASE = "https://hf-mirror.com/datasets/detection-datasets/coco/resolve/main/data/"
FILES = [
    ("val-00000-of-00002-c4f2e391ee4aba11.parquet", 403698375,
     "dc7a465827eab75e825eb38c9993e6b04fcf918fc2f034504d5760aedfa71d7c"),
    ("val-00001-of-00002-7af5414a3b178949.parquet", 403728505,
     "fa7fcf60b688c5555b92778ca9654da9400c72d1612b09f3a094a18266e8d859"),
]
OUT = "/tmp/wf/corpus/coco-parquet"
CHUNKS = 8
SUB = 4

jobs = []  # (path, url, start, end, want)
for name, size, _ in FILES:
    step = size // CHUNKS + 1
    for i in range(CHUNKS):
        s = i * step
        e = min(s + step - 1, size - 1)
        if s >= size:
            continue
        prefix = os.path.join(OUT, f"{name}.part{i:02d}")
        have = os.path.getsize(prefix) if os.path.exists(prefix) else 0
        s2 = s + have
        if s2 > e:
            continue
        span = e - s2 + 1
        sub = min(SUB, max(1, span // (1 << 20)))
        sstep = span // sub + 1
        for k in range(sub):
            a = s2 + k * sstep
            b = min(a + sstep - 1, e)
            if a > e:
                continue
            path = os.path.join(OUT, f"{name}.part{i:02d}.tail{k}")
            want = b - a + 1
            if os.path.exists(path) and os.path.getsize(path) == want:
                continue
            jobs.append((path, BASE + name, a, b, want))

print(f"tail jobs: {len(jobs)}, bytes wanted {sum(j[4] for j in jobs)}", flush=True)
procs = []
for path, url, a, b, want in jobs:
    p = subprocess.Popen(
        ["curl", "-sS", "--max-time", "1800", "--retry", "5", "--retry-delay", "2",
         "-o", path, "-r", f"{a}-{b}", "-L", url],
        stderr=subprocess.DEVNULL)
    procs.append((p, path, want))
t0 = time.time()
bad = 0
for p, path, want in procs:
    p.wait()
    got = os.path.getsize(path) if os.path.exists(path) else 0
    if got != want:
        bad += 1
        print(f"SHORT {os.path.basename(path)} {got}/{want}", flush=True)
print(f"wave done in {time.time()-t0:.0f}s, short={bad}", flush=True)

# assemble + verify against the published HF LFS oids
for name, size, sha in FILES:
    dst = os.path.join(OUT, name)
    with open(dst, "wb") as out:
        for i in range(CHUNKS):
            base = os.path.join(OUT, f"{name}.part{i:02d}")
            if os.path.exists(base):
                out.write(open(base, "rb").read())
            k = 0
            while True:
                t = os.path.join(OUT, f"{name}.part{i:02d}.tail{k}")
                if not os.path.exists(t):
                    break
                out.write(open(t, "rb").read())
                k += 1
    h = hashlib.sha256()
    with open(dst, "rb") as f:
        for c in iter(lambda: f.read(1 << 22), b""):
            h.update(c)
    got = h.hexdigest()
    print(f"{name}\n  bytes {os.path.getsize(dst)}/{size}\n  sha256 {got}\n  {'MATCH' if got == sha else 'MISMATCH want ' + sha}", flush=True)
    print(f"  ({time.time()-t0:.0f}s total)", flush=True)

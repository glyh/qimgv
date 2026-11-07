#!/usr/bin/env python3
"""Extract COCO val2017 JPEGs from the detection-datasets/coco parquet shards.

Writes /tmp/wf/corpus/coco5000/ as the original JPEG bytes, named by the COCO
image id recorded in the parquet row.
"""
import hashlib, os, sys
import pyarrow.parquet as pq

SRC = "/tmp/wf/corpus/coco-parquet"
DST = "/tmp/wf/corpus/coco5000"
FILES = [
    "val-00000-of-00002-c4f2e391ee4aba11.parquet",
    "val-00001-of-00002-7af5414a3b178949.parquet",
]
EXPECT = {
    "val-00000-of-00002-c4f2e391ee4aba11.parquet": "dc7a465827eab75e825eb38c9993e6b04fcf918fc2f034504d5760aedfa71d7c",
    "val-00001-of-00002-7af5414a3b178949.parquet": "fa7fcf60b688c5555b92778ca9654da9400c72d1612b09f3a094a18266e8d859",
}

# 1. verify archives against the HF LFS oids before trusting anything inside them
for name in FILES:
    p = os.path.join(SRC, name)
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    got = h.hexdigest()
    ok = got == EXPECT[name]
    print(f"sha256 {name}\n  {got}\n  {'MATCH' if ok else 'MISMATCH ' + EXPECT[name]}", flush=True)
    if not ok:
        sys.exit(1)

os.makedirs(DST, exist_ok=True)
names = []
for name in FILES:
    pf = pq.ParquetFile(os.path.join(SRC, name))
    print(name, "rows", pf.metadata.num_rows, "schema", pf.schema_arrow.names, flush=True)
    for rg in range(pf.metadata.num_row_groups):
        tbl = pf.read_row_group(rg)
        cols = tbl.column_names
        img = tbl.column("image").to_pylist()
        ids = None
        for cand in ("image_id", "id", "coco_id", "file_name"):
            if cand in cols:
                ids = tbl.column(cand).to_pylist()
                idcol = cand
                break
        for i, im in enumerate(img):
            data = im["bytes"]
            if ids is not None:
                stem = str(ids[i])
            else:
                stem = im.get("path") or f"row{rg}_{i}"
            stem = os.path.splitext(os.path.basename(stem))[0]
            fn = f"{stem}.jpg"
            with open(os.path.join(DST, fn), "wb") as f:
                f.write(data)
            names.append(fn)
        print(f"  rg{rg} rows={len(img)} idcol={ids and idcol}", flush=True)

print("total extracted", len(names), "unique", len(set(names)), flush=True)

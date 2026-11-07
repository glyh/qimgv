# The benchmark corpus

Research for <https://github.com/glyh/qimgv/issues/13>. Defines the image set that everything in the baseline (issue 6) is measured on, pinned so it can be re-obtained from the same bytes.

Bytes are **not** committed. Only the pins live in git: URL, sha256, size, and the rule that turns them into a directory.

## Composition

| Part | Files | Size | Pin |
|---|---|---|---|
| **Spine — COCO val2017**, shard 0 | 2 476 JPEG | 403,698,375 B | `sha256 dc7a465827eab75e825eb38c9993e6b04fcf918fc2f034504d5760aedfa71d7c` |
| **Spine — COCO val2017**, shard 1 | 2 476 JPEG | 403,728,505 B | `sha256 fa7fcf60b688c5555b92778ca9654da9400c72d1612b09f3a094a18266e8d859` |
| **Resolution ladder** (imazen 26 MP set) | 13 JPG, **6.9 → 51.1 MP** | 71 MB | all 13 match the corpus's own `manifests/train.tsv` |
| **Format layer — CLIC 2025 test** | 30 PNG, 1360×2048–1648×2048 | 121,173,030 B | `sha256 c479a92b7579f716826822fe892abbe583cfa7cd7f07730a14227a98c7870e92` |
| **WebP layer**, derived from the CLIC PNGs | 30 WebP, q80 | 11,931,854 B | `sha256(d44590179ab884a8dc2e689592e415f8d2d0071fb267b073ff664b6e78dce6f2)` over the sorted `sha256 *.webp` list |
| **W3 — the ~100 MP image** (real Unsplash photograph, **8736×11648 = 101.8 MP**) | 1 JPG | 20,923,635 B | `sha256 246c85ff173ab2c42e3bb1e2daf55eb9ea777da25e457990bd73e12d528fd0f0` |

Total on disk ≈ 1.6 GB. Shard URLs:

```
hf-mirror.com/datasets/detection-datasets/coco/resolve/main/data/val-00000-of-00002-c4f2e391ee4aba11.parquet
hf-mirror.com/datasets/detection-datasets/coco/resolve/main/data/val-00001-of-00002-7af5414a3b178949.parquet
storage.googleapis.com/clic_datasets/clic2025_image_test.zip
```

The parquet pins are the Hugging Face **LFS oids**, and both were re-verified after download (`MATCH` on both shards). The COCO origin host (`images.cocodataset.org`) is unreachable from here — zero bytes in 25 s, broken TLS — so the mirror is the only viable path.

## Reproducing it

1. Fetch the two shards (range requests, resumed from partials; ~17 min at this machine's ~500 KB/s, 64 parallel connections).
2. `sha256sum` both — they must match the oids above.
3. Extract the JPEGs from the parquet `image` column, naming each file by its COCO `image_id`. `pyarrow` is required (a throwaway venv is fine).
4. Verify the CLIC zip, extract, then generate the WebP layer with `magick -quality 80` on the sorted PNGs and check the manifest digest.
5. Verify the 100 MP file against its hash.

Scripts used: `/tmp/wf/fetch_coco_tail.py`, `/tmp/wf/extract_coco.py`.

## Layout

```
/tmp/wf/corpus/
├── coco5000/     4 952 JPEG   ~0.3 MP each    <- W1: the folder-open spine
├── ladder/          13 JPG    6.9-51.1 MP     <- decode cost vs resolution
├── clic/            30 PNG    ~3 MP           <- format/lossless layer
├── webp/            30 WebP    ~3 MP           <- same pixels, different decoder
└── (the 100 MP file lives in the imazen xl set, not in this tree)
```

## The subset rule

**All of val2017, no subsetting.** The folder is the extraction of both shards, sorted by `image_id`. Two people running the steps above get byte-identical directories without needing to agree on a sample.

## Limits, stated rather than hidden

1. **The spine is 4 952 images, not 5 000.** Both shards verify against their published hashes, and extraction is complete (2 476 + 2 476 rows, 4 952 unique ids), so the canonical val2017 set as mirrored carries 4 952. **W1 therefore measures a 4 952-image folder** — a reproducible count beats a round number, and 48 images is inside any plausible measurement noise for folder open. If exactly 5 000 matters later, top up from a source that can be pinned independently and say so in the results.
2. **The spine is low resolution** — every image is 0.25–0.5 MP, so W1 measures *thumbnail-grid folder open at small sizes*, which is the common case but **not** the memory-heavy one. The 1–30 MP claim rests entirely on the 13-file ladder plus the CLIC PNGs. Anyone quoting W1 as "folder open with big photos" is wrong.
3. **The mirror is not the canonical zip.** Byte-identity between this parquet and COCO's own `val2017.zip` cannot be checked from here, because the origin is unreachable. The pin rests on the LFS oid alone.
4. **Licences**: the 100 MP image is Unsplash (permissive); the imazen set publishes its own terms with the corpus; CLIC 2025's test set is distributed for the challenge — **confirm its terms before publishing benchmark results that name it**. COCO's annotations are CC BY 4.0 while its images are Flickr-sourced with per-image licences. None of this blocks local measurement; it blocks *redistribution*, which is why the bytes stay out of git.

## What this does not cover

Animated GIF/WebP, CMYK or 16-bit TIFF, progressive-vs-baseline JPEG skew, files over 100 MP, and anything from a real user's library — including the pathological cases (0-byte files, unreadable permissions, 10 000 files in one directory) that a folder browser actually meets in the wild.

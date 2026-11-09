# Interop: how a Zig slice plugs into qimgv

The rules for adding a Zig module to this tree, decided in [Interop and build: how a
Zig slice plugs into the zig build graph](https://github.com/glyh/iv/issues/10) and
proven by the first slice, which is in the tree: JPEG decode through
`zig/src/decode.zig`, behind `-Dzig-decode` (off by default).

Everything marked **verified** was run on this machine (zig 0.17.0, Qt 6.12.0,
TurboJPEG 3.2.1, clang 20/gcc 16). The checks are in the tree where they can be:
`scripts/zig-decode-check.sh`.

## The shape

One static library, one hand-written C header, one build option.

```
zig/src/root.zig          the Zig core; slices are files it imports
zig/src/decode.zig        slice 1: JPEG decode (libjpeg-turbo via TurboJPEG)
zig/include/qimgv_core.h  the ABI: POD structs, codes, qimg_* functions
qimgv/utils/qzimage.*     the C++ adapter (QImage over a qimg_bitmap)
scripts/zig-decode-check* the pixel-equality check for the decode slice
```

A slice is **not** a separate library. It is `export fn`s added to `zig/src/root.zig`
plus declarations in the one header — slice 2 adds a file, imports it in `root.zig`,
and declares its functions; `build.zig` does not change. That keeps one link line, one
include path, one ABI version.

The library is built **only when a `-Dzig-*` flag is on**, so a plain `zig build`
compiles neither the Zig code nor the header and stays behaviourally identical to a
tree without the slice. This is the kill switch: revert by rebuilding without the
flag, no revert commit, no runtime switch rotting in the shipped binary.

## The build wiring

The parts that are not obvious, all of them load-bearing. The full code is in
`build.zig` (`with_zig_decode`, `zigCore`, `linkApp`).

```zig
// the option, next to with_exiv2 / with_video / with_opencv
const with_zig_decode = b.option(bool, "zig-decode", "decode through zig/src/decode.zig") orelse false;

// the C++ side sees the define and the header directory
if (with_zig_decode) add(&flags, b.allocator, &.{ "-DUSE_ZIG_DECODE", "-Izig/include" });

// the library (one per tree, not one per slice)
const tj_c = b.addTranslateC(.{
    .root_source_file = b.path("zig/src/tj_include.h"),
    .target = target,
    .optimize = optimize,
});
tj_c.addSystemIncludePath(.{ .cwd_relative = pkgConfigVar(b, "includedir", "libturbojpeg") });

const mod = b.createModule(.{
    .root_source_file = b.path("zig/src/root.zig"),
    .target = target,
    .optimize = optimize,
    .pic = true,          // required; see below
    .link_libc = true,    // required for the C allocator and any libc call
});
mod.addImport("tj", tj_c.createModule());
mod.linkSystemLibrary("turbojpeg", .{});
const lib = b.addLibrary(.{ .linkage = .static, .name = "qimgv_core", .root_module = mod });
```

Verified consequences, each one a build failure if you get it wrong:

- **`.pic = true` is mandatory.** Without it the C++ link dies with `relocation
  R_X86_64_32S … can not be used when making a PIE object`. Zig static libraries are
  not PIC by default and the C++ link here is a PIE.
- **`.link_libc = true` is mandatory** as soon as the slice allocates or calls a C
  library: `error: dependency on libc must be explicitly specified in the build
  command`, `C allocator is only available when linking against libc`.
- **`@cImport` does not exist in zig 0.17.** C headers arrive through
  `addTranslateC` + `mod.addImport`. The translated module is cached under
  `zig/src/.zig-cache`.
- **A static archive does not carry its dependencies.** The executable's link line
  gains the slice's libraries (`pkg-config --libs libturbojpeg`). Only the
  `-Dzig-decode` build has `libturbojpeg.so.0` in its NEEDED set.
- **Order matters: archive before the `-l` flags.** With `--as-needed`, a library
  listed before the object that needs it is dropped, and the link fails on
  `qimg_decode`'s references. `linkApp` puts `zig_core` right after the objects.
- **No new dependencies otherwise.** In both builds the NEEDED set is otherwise
  identical to a plain build, so the binary still runs on a stock Qt.
- **A shared object works too**, if a slice is ever linked into `player_mpv`: the
  same archive links into a `-shared` object with `-Wl,--no-undefined`, and
  `dlopen` + `ctypes` call into it (verified). Pass exactly one archive.

`scanSources` walks the tree, so `zig/` needs no entry there: nothing under
`zig/src` is a `.cpp`/`.ui`, and no header there contains `Q_OBJECT`.

## The header

`zig/include/qimgv_core.h` is hand-written C, included by C++ and parsed by moc.

moc 6.12 accepts everything it needs to (verified construct by construct): `extern
"C"` blocks, include guards, `<stdint.h>`/`<stdbool.h>`, `bool` fields, anonymous
unions, `__attribute__((aligned(16)))`, `_Static_assert`, `#define`/`#if`,
function-pointer fields, fields named `signals`/`slots`/`emit`, and unscoped enums in
signal signatures. The generated `moc_*.cpp` compiles, links and runs.

Two traps:

- **`_Bool` passes moc and fails clang++.** moc's parser is lenient; the C++ compiler
  is not. Use `uint8_t` in anything a `.cpp` sees.
- **A file whose text merely contains `Q_OBJECT` is moc'd anyway** (`scanSources`
  recognises moc inputs by substring). Harmless: moc writes a zero-byte `moc_*.cpp`
  and exits 0.

Never in this header: C++ types (`std::`, `QString`, templates, references), `inline`
functions, or any Zig type. The header is the single source of truth for layout; the
Zig side mirrors it with `extern struct`.

## Ownership

**Zig allocates, C++ wraps.** One allocation per bitmap, zero copies, one free path.

```zig
pub const Bitmap = extern struct {   // byte-for-byte qimg_bitmap
    data: ?[*]u8, w: u32, h: u32, stride: u32, fmt: c_int, bytes: u32,
};
```

```cpp
// qimgv/utils/qzimage.cpp — the only file that knows both sides
std::unique_ptr<QImage> QzImage::takeImage(qimg_bitmap &bmp) {
    BitmapOwner owner(bmp);                       // frees on any early return
    bmp = qimg_bitmap{};
    qimg_bitmap *raw = owner.release();
    return std::unique_ptr<QImage>(new QImage(
        raw->data, raw->w, raw->h, raw->stride, fmt, freeBitmap, raw));
}
```

Verified: Qt 6.12 has the `QImageCleanupFunction` constructor
(`qimage.h:89-92`), so **the QImage's destructor is the free**, and Qt calls it once,
on the last copy. Rules that follow:

- Every path that receives a `qimg_bitmap` either wraps it or calls
  `qimg_bitmap_free`; a failed call leaves `out` zeroed and owns nothing.
- `qimg_bitmap.bytes` is `stride * h` — the caller never recomputes a size.
- Internal scratch memory is freed inside the call. Only pixels cross.
- **Do not shallow-copy a QImage and then free the buffer.** `convertToFormat` to the
  same format is a shallow copy; the in-tree checker hits this trap deliberately
  (`zig.copy()`), and anything else that reads pixels after the wrap must do the
  same.

Layout cannot disagree with the C++ side: an `extern struct` prints the same
`size`/`offset`s in `Debug` and `ReleaseFast` and matches C's `sizeof`/`offsetof`
(verified), so the optimisation level is not part of the ABI.

## Errors

Codes cross, messages do not. One enum for the whole core, one numeric range per
slice so codes never collide:

```c
typedef enum qimg_status {
    QIMG_OK = 0,
    QIMG_E_INVALID_ARG = -1, QIMG_E_NO_MEMORY = -2, QIMG_E_IO = -3,
    QIMG_E_UNSUPPORTED = -10, QIMG_E_FORMAT = -11,   /* decode slice: -10 .. -19 */
} qimg_status;
int32_t qimg_status_detail(char *dst, int32_t cap);  /* thread-local, best effort */
```

- Detail is `threadlocal` in Zig, so concurrent pool workers don't clobber each
  other. Logs only, never control flow.
- **No panic may be reachable from an `export fn`.** Verified: `@panic`,
  `unreachable` and a Debug/ReleaseSafe integer overflow all abort the process —
  SIGABRT, exit 134, uncatchable, in **every** optimize mode. In ReleaseFast an
  overflow instead wraps silently. So argument validation and explicit codes are the
  whole strategy, and arithmetic on file-supplied sizes is done in wide types
  (`i64` for `w * num / denom`, never `u32 * f32`-ish shortcuts).
- **Compute-then-store, never store-then-fail.** A function zeroes `out` on entry,
  allocates into locals, and assigns `out.*` only on success; the one failure that
  happens after an allocation frees it first (this is why `decode.zig` has
  `gpa.free(dst)` in the error arm rather than an `errdefer`: a `c_int` return has no
  error union to defer).
- **Nothing throws, either direction.** C++ → Zig carries no exceptions. Zig → C++ is
  where the hazard lives (#7: no exception barrier, 0 `try`/`catch` in libqt6zig), so
  the Zig side never calls Qt and never calls C++ that can throw — only libc and C
  libraries. TurboJPEG specifically, rather than raw libjpeg: libjpeg's error path is
  `error_exit`, which calls `exit()` or longjmps, and there is no `setjmp` across a
  Zig frame. TurboJPEG returns a code.

## Threading

**Qt owns the threads; the Zig core is synchronous and owns none.**

- A slice runs on whatever thread calls it — normally a `Loader`/`Scaler`/
  `Thumbnailer` `QRunnable::run()`. It must be safe to call from several at once: no
  global mutable state, no lazy globals. A `threadlocal` detail buffer is fine.
- The pools are Qt's: `Loader` (2 threads), `Scaler`, `Thumbnailer`, each with its own
  `QThreadPool`. The slice never spawns threads, so there is nothing to join at
  shutdown and nothing to oversubscribe.
- If slice code needs mutual exclusion internally, `std.Thread.Mutex` — invisible
  across the ABI, and it does not call Qt.
- **Lifecycle.** Process-wide Zig state (there is none yet) would be set up from
  `main()` before images load and released after `Thumbnailer::~Thumbnailer()`'s
  `pool->waitForDone()`.
- **Cancellation is the caller's.** Today: results for a folder that changed are
  dropped on arrival (filter by path). #37's generation token arrives as one more
  parameter to a synchronous function — additive, not a redesign.
- **`std.Io` is deliberately not in this ABI.** It would work (an `Io` instance's
  `async`/`concurrent` are documented thread-safe, and one `Threaded` instance served
  6 foreign threads doing `readFile` in a probe), but it brings a second concurrency
  substrate — detached worker threads, `async_limit` defaulting to CPU−1,
  `concurrent_limit` unlimited — into a process whose threads and cancellation
  already belong to Qt. Two owners of "how work runs" is how shutdown races happen.
  Slice 1 reads files through libc stdio for the same reason: in zig 0.17 every
  `std.fs` entry point takes a `std.Io`.

## Optimisation

**One knob, `-Doptimize`, governs both languages.**

- C++ gets `optimizeFlags(optimize)`; the Zig module gets the same
  `std.builtin.Optimize` (`zig build-lib -fPIC -Ofast` vs `clang++ -fPIC -O2 …`).
- Layout is unaffected (see the `extern struct` check above).
- `zig build` with no flags is a **Debug** build, i.e. a trapping binary on purpose:
  a Zig-side bug becomes a crash, not silent corruption. Every packager passes
  `ReleaseFast`: `qimgv/distrib/PKGBUILD`, `scripts/build-qimgv.sh`, and all three
  CI workflows.
- A slice's performance work is measured with `scripts/bench` against the same
  `ReleaseFast` binary that ships (#6, #8).

## Packaging and CI

- **Arch**: `zig` is already in `makedepends`; the slice adds `libturbojpeg` (an
  optdepends-style build knob in `PKGBUILD` terms, a normal dependency of the
  `-Dzig-decode=true` build). Nothing in the install tree changes: the archive is
  linked in statically, and only the slice's own `libturbojpeg` shows up as NEEDED.
- **Stock Qt**: no new Qt dependency in either build.
- **Windows/macOS**: the wiring is platform-neutral, but MinGW's `ld` reading a Zig
  archive and the TurboJPEG package name under MSYS2 are unverified here. The gate is
  `zig build -Doptimize=ReleaseFast` and `… -Dzig-decode=true` in all three workflows
  (`.github/workflows/{linux,windows,macos}.yml`).
- **Both builds in CI**, because the kill switch is build-time: the plain build must
  stay green, and so must the slice build.

## Slice 1: what actually landed

`-Dzig-decode` swaps the decode inside `ImageStatic::loadGeneric()`
(`qimgv/sourcecontainers/imagestatic.cpp`):

```cpp
void ImageStatic::loadGeneric() {
#ifdef USE_ZIG_DECODE
    if(loadViaZig())
        return;                 // QImage wrapped over the Zig bitmap
#endif
    …today's QImageReader path, unmodified…
}
```

- **Every failure falls back to Qt.** `QIMG_E_UNSUPPORTED` (not a JPEG — PNG, WebP,
  ICO, RAW…), `QIMG_E_FORMAT` (truncated or malformed), `QIMG_E_IO`, a format the
  adapter does not know: all of them continue into the `QImageReader` path that ships
  today. A viewer must open at least as many files after the change as before, and
  Qt's JPEG reader is the more forgiving of the two.
- **Full size only.** `qimg_decode` is called with `max_w = max_h = 0`. The
  display-size contract is #38's; the ABI already takes the numbers, and
  `decode.zig` implements TurboJPEG's scaling for a later caller, but nothing passes
  a bound yet.
- **EXIF rotation stays where it was** — `ImageLib::exifRotated(...,
  mDocInfo->exifOrientation())`, applied to the decoded bitmap exactly as before. The
  `qimg_meta` in #11's sketch (orientation returned by the decoder, so
  `documentinfo.cpp`'s second `QImageReader` pass can be cancelled) is **not** part of
  this landing: that pass is a separate, measurable change, and duplicating exiv2's
  EXIF read in Zig would add surface without removing the pass.

Measured with `scripts/zig-decode-check.sh`, which decodes every file twice — Qt and
the slice — and compares after format normalisation:

| input | result |
|---|---|
| COCO val2017, all 4 952 JPEGs | **identical**, 0 mismatches |
| W3 8736×11648 (101.8 MP, progressive) | identical |
| COCO subset re-encoded progressive | identical |
| COCO subset converted to grayscale | identical |
| CLIC PNGs | falls back (`header: Not a JPEG file: starts with 0x89 0x50`) |
| truncated JPEG | falls back (`decode: Premature end of JPEG file`); Qt decodes it |
| junk bytes, no image | Qt fails as well |

So the slice is a **substitution, not a perf claim** — which is what #11 graded it on.
The kill-switch side is verified too: `zig build -Doptimize=ReleaseFast` (no flag)
links no `qimg_*` symbols, has no `libturbojpeg` NEEDED entry, and builds the byte
count it did before.

## Adding slice 2 (the checklist)

1. Add `zig/src/scale.zig`; `pub const scale = @import("scale.zig");` in `root.zig`,
   and `_ = scale;` in the existing `comptime` block.
2. Declare its functions and any new POD struct in `zig/include/qimgv_core.h`; bump
   `QIMGV_ABI_VERSION` only if an existing struct or signature changes.
3. Give it a code range (`QIMG_E_SCALE = -100` and down).
4. Wrap its output in the adapter (`qimgv/utils/qzimage.*`) — a `qimg_bitmap` always
   becomes a `QImage` with `freeBitmap`, never a bare pointer.
5. Put the call behind `#ifdef USE_ZIG_<SLICE>` at the existing seam, with today's
   code as the `#else`, and fall back to it on every error code.
6. Add the `-Dzig-<slice>` option and its `-DUSE_ZIG_<SLICE>`/`-Izig/include` pair to
   the flag list, and its libraries to `link_flags`. The library and link step are
   already wired.
7. Add the flag to the three CI workflows.
8. Extend the equality check (`scripts/zig-decode-check.cpp` is the pattern: same
   input twice, compare after normalisation) and run it on the pinned corpus.
9. Delete the `#else` and retire the option once the slice is graded, or delete the
   Zig file and the `#ifdef` if it lost. A switch that outlives its grading round is a
   bug.

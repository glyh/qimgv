# Interop: how a Zig slice plugs into qimgv

Rules for adding a Zig module to this tree, from [Interop and build: how a Zig slice
plugs into the zig build graph](https://github.com/glyh/iv/issues/10). Slice 1
(decode) is [Which slice goes first…](https://github.com/glyh/iv/issues/11); this
document is what slice 2 (scale) should not have to re-derive.

Everything below marked **verified** was run on this machine (zig 0.17.0, Qt 6.12.0,
clang 20/gcc 16) — the probe commands are named so they can be repeated.

## The shape

One static library, one hand-written C header, one build option.

```
zig/src/root.zig          the whole Zig core; slices are files it imports
zig/include/qimgv_core.h  the ABI: POD structs, enum codes, qz_* functions
qimgv/utils/qzimage.*     the C++ adapter (QImage over a qz_buf, RAII)
```

A slice is **not** a separate library. It is a set of `export fn`s added to
`zig/src/root.zig` plus declarations in the one header. That keeps one link line,
one include path, one place the ABI version lives, and means slice 2 is a new
`.zig` file and new header declarations — no build changes at all.

The library is built **only when a `#ifdef USE_ZIG_*` is on**, so a plain
`zig build` compiles neither the Zig code nor the header (`zig build` stays
behaviourally identical to today). This is #11's kill switch and it is the reason
the option is a flag and not a runtime setting.

## The build wiring

Four edits to `build.zig`, and nothing else. Verified by applying them to a copy of
this tree, adding a stub `zig/src/root.zig`, and running
`zig build -Doptimize=ReleaseFast -Dzig-core=true` (exit 0, `qz_*` symbols in the
resulting binary), then `zig build -Doptimize=ReleaseFast` (exit 0, no Zig library
step at all, no `qz_*` symbols).

```zig
// 1. the option, next to with_exiv2 / with_video / with_opencv
const with_zig_core = b.option(bool, "zig-core", "build and link the zig core") orelse false;

// 2. the flags: the C++ side sees the define and the header directory
if (with_zig_core) add(&flags, b.allocator, &.{ "-DUSE_ZIG_CORE", "-Izig/include" });

// 3. the library itself
fn zigCore(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) std.Build.LazyPath {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "qimgv_core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,          // required; see below
            .link_libc = true,    // required for std.heap.c_allocator / any libc call
        }),
    });
    return lib.getEmittedBin();
}

// 4. the link step: linkApp gains one optional argument, added after the -l flags
if (zig_lib) |lib| run.addFileArg(lib);
```

The library compiles with `zig build-lib -fPIC -Ofast` (from `-Doptimize=ReleaseFast`
plus `.pic`); the C++ side of the same graph compiles with
`clang++ -std=c++17 -fPIC -O2 -DNDEBUG -DQT_NO_DEBUG … -DUSE_ZIG_CORE -Izig/include`.
Two knobs, each language's own spelling of the same level.

Things that are load-bearing, each verified:

- **`.pic = true` is mandatory.** Without it: `relocation R_X86_64_32S against
  '__anon_649' can not be used when making a PIE object`. Zig's static libraries are
  not PIC by default and the C++ link here is a PIE on every Linux distro that
  matters.
- **`.link_libc = true` is mandatory** as soon as the slice mallocs or calls a C
  library (`libjpeg`, `libpng`). Without it: `error: dependency on libc must be
  explicitly specified in the build command` / `C allocator is only available when
  linking against libc`.
- **The C++ side needs `-Izig/include`; moc does not.** `mocFlags()` copies every
  `-I`/`-D` into the moc invocation, but moc also tolerates an include it cannot
  resolve (verified: it produces identical output with and without the flag), so
  what actually needs the include path is the compile of the moc output — and of
  every TU that includes the C header. Both go through the one flag list.
- **`getEmittedBin()` is a real dependency**, not a path guess: the archive is built
  before the link step runs. Verified: the link line carries
  `…/.zig-cache/o/<hash>/libqimgv_core.a`.
- **The archive goes last** on the link line, after the `pkg-config --libs` flags.
  `-l` flags first, archive after — that is the order the spike used.
- **No new runtime dependencies.** `ldd` and `readelf -d` on the linked binary show
  the same NEEDED set as today (Qt6\*, exiv2, libstdc++, libm, libgcc_s, libc). Zig
  does not pull in libunwind or a thread library, and `player_mpv.so` is untouched.
  So the shipped binary still runs on a stock Qt.
- **A shared object works too**, if a slice is ever linked into `player_mpv` rather
  than the executable: linking the same archive into a `-shared` object with
  `-Wl,--no-undefined` succeeds and `dlopen` + `ctypes` calls into it work
  (verified). Pass exactly one archive; passing several stale copies of the same
  archive is how you get `undefined symbol: __zig_probe_stack`.

`build.zig`'s `scanSources` walks the tree, so `zig/` needs no entry in it: nothing
under `zig/src` is `.cpp`/`.ui`/`Q_OBJECT`, and `zig/include` is not a source root.

## The header

`zig/include/qimgv_core.h` is written by hand, in C, and is included by C++ (and by
moc, which parses it). Verified pass with moc 6.12 behind a `Q_OBJECT` header:
`extern "C"` blocks, `#ifndef`/`#pragma once` guards, `#include <stdint.h>`,
`#include <stdbool.h>` + `bool` fields, anonymous unions/structs,
`__attribute__((aligned(16)))`, `_Static_assert`, `#define`/`#if` blocks,
function-pointer typedefs and fields, struct fields named `signals`/`slots`/`emit`,
unscoped `enum` in a signal signature, and `uint8_t*`/`void*` members. The generated
`moc_*.cpp` compiles, links against Qt6Widgets and runs.

Two traps:

- **`_Bool` passes moc but fails the C++ compiler.** moc's parser is lenient; clang++
  rejects `_Bool` in a `.cpp`. Use `uint8_t` (or `bool` from `<stdbool.h>`) in any
  struct a `.cpp` sees.
- **A file whose text merely contains `Q_OBJECT` is moc'd anyway**, because
  `scanSources` recognises moc inputs by substring search. That is harmless: moc
  exits 0 and writes a **zero-byte** `moc_*.cpp`, which compiles to nothing
  (verified). Do not rely on it for anything, but do not "fix" it either.

Never in this header: C++ types (`std::`, `QString`, templates, references),
`inline` functions, or anything moc would have to understand beyond POD. Zig types
never appear either — the header is the single source of truth for layout, and the
Zig side mirrors it with `extern struct` (below).

## Ownership

**Zig allocates, C++ wraps.** One allocation per bitmap, zero copies, one free path.

```zig
const Buf = extern struct {   // byte-for-byte the C qz_buf
    ptr: ?[*]u8, len: usize,
    stride: u32, width: u32, height: u32, format: u32,
};
```

```cpp
// the adapter, qimgv/utils/qzimage.cpp: the only place that knows both sides
static void qz_cleanup(void *info) {
    auto *b = static_cast<qz_buf *>(info);
    qz_buffer_free(b->ptr, b->len);   // zig frees
    delete b;                          // the descriptor only
}
QImage image(qz_buf.ptr, qz_buf.width, qz_buf.height, qz_buf.stride,
             QImage::Format_RGBA8888, qz_cleanup, owned_copy_of_descriptor);
```

Verified: Qt 6.12 has the `QImageCleanupFunction` constructor
(`qimage.h:89-92`), so the QImage's destructor is the free. `QImage` may be copied
freely — the cleanup runs once, on the last copy.

Rules that follow:

- The caller **must** hand the buffer to something that takes ownership (QImage with
  cleanup, or `qz_buffer_free`) on every path, including error paths.
- Partial output on error: a function that returns non-`QZ_OK` must leave `out`
  zeroed and own nothing. C++ never frees a buffer from a failed call.
- No `std.heap.page_allocator`-sized surprises: the size of a returned bitmap is
  `len`/`stride`/`width`/`height` in the struct, not something the caller derives
  from the file header.
- Internal scratch memory belongs to the Zig side and is freed inside the call. Nothing
  but a `qz_buf` crosses the boundary.

Layout is fixed by the header, not by the Zig compiler: the same `extern struct`
prints `size=32 ptr=0 len=8 stride=16 w=20 h=24 fmt=28` in `Debug` and in
`ReleaseFast` and matches the C `sizeof`/`offsetof` (verified). So the optimisation
level can never make the two sides disagree.

## Errors

Codes cross, messages do not. One enum for the whole core, with a numeric range per
slice so codes never collide:

```c
typedef enum qz_status {
    QZ_OK = 0,
    QZ_ERR_INVALID_ARG = 1, QZ_ERR_NO_MEMORY = 2, QZ_ERR_IO = 3,
    QZ_ERR_DECODE = 10, QZ_ERR_UNSUPPORTED = 11, QZ_ERR_TOO_LARGE = 12,  /* decode  */
    QZ_ERR_SCALE = 100,                                                    /* scale */
} qz_status;
int qz_status_detail(char *dst, size_t cap);  /* thread-local, best effort */
```

- Detail is per-thread (`threadlocal` in Zig), so concurrent pool workers do not
  overwrite each other. It is for logs, never for control flow.
- **No panic may be reachable from any `export fn`.** Verified: a `@panic`, an
  `unreachable`, or a Debug/ReleaseSafe integer overflow aborts the process —
  `SIGABRT`, exit 134, uncatchable, in **every** optimize mode. There is no "safety
  net" mode; argument validation and explicit error returns are the whole
  strategy. In `ReleaseFast` an overflow instead wraps silently, so arithmetic on
  file-supplied sizes is checked explicitly (`std.math.mul/add`), not trusted to
  safety checks.
- **Nothing throws across the boundary, in either direction.** Directions matter:
  C++ → Zig carries no exceptions (Zig never throws). Zig → C++ is where the hazard
  lives (#7: libqt6zig has no exception barrier and 0 `try`/`catch`), so **the Zig
  side never calls Qt, and never calls C++ that can throw** — only libc and C
  libraries. The adapter does the Qt work on the C++ side.
- A Zig panic in a release build is still `abort()`; treat every `unreachable`,
  `@panic`, `.?`, `unused`, bounds violation and checked-cast failure in slice code
  as a crash of the user's viewer.

## Threading

**Qt owns the threads; the Zig core is synchronous and owns none.** This mirrors what
upstream does (libqt6zig binds `QThreadPool`, `QRunnable`, `QThread`, `QEventLoop`,
`QMutex`: Zig calls Qt's primitives), and it is the reason `std.Io` is **not** in
this ABI.

- A slice function runs on whatever thread calls it — normally a
  `Loader`/`Scaler`/`Thumbnailer` `QRunnable::run()`. It must be safe to call from
  several of those at once: no global mutable state, no lazy globals, no shared
  handles. A `threadlocal` detail string is fine.
- The pools are Qt's: `Loader` (2 threads), `Scaler`, `Thumbnailer`
  (`thumbnailerThreadCount`), each with its own `QThreadPool`. The slice never
  spawns threads and never starts a thread pool of its own, so there is nothing to
  join at shutdown and nothing to oversubscribe.
- If slice code needs mutual exclusion internally, use `std.Thread.Mutex` inside the
  call. It is invisible across the ABI and does not call Qt.
- **Lifecycle.** Any process-wide Zig state is initialised from `main()` before
  images load and released after `Thumbnailer::~Thumbnailer()`'s
  `pool->waitForDone()`. Nothing on the public ABI takes a destructor order between
  Zig and Qt today, because slice state is per-call.
- **Cancellation is the caller's.** Today: when a folder changes, results for the
  old folder are dropped on arrival (filter by path), which is #11's scope. #37
  adds a generation token to the ABI; because a slice is a plain synchronous
  function, that arrives as one more parameter, not a redesign.

Why not `std.Io`: it is a real interface and it would work (an `Io` instance's
`async`/`concurrent` are documented thread-safe, and one `Threaded` instance served
6 foreign threads doing `readFile` in a probe), but it introduces a second
concurrency substrate — its own detached worker threads, `async_limit` defaults to
CPU-1, `concurrent_limit` unlimited — inside a process whose threads and
cancellation already belong to Qt. Two owners of "how work runs" is exactly the
kind of thing that produces shutdown races in a viewer. Adopting it later is a
slice-level change (it is not in this ABI now).

## Optimisation

**One knob, `-Doptimize`, governs both languages.** No `-Dzig-optimize`.

- C++ gets `optimizeFlags(optimize)` (`-O0 -g` / `-O2 …` / `-Os …` plus
  `QT_NO_DEBUG`), the Zig module gets the same `std.builtin.Optimize`.
- Layout is unaffected: see the `extern struct` check above. A Debug app and a
  ReleaseFast app read the same bytes, and the boundary exists only as `qz_buf`.
- `zig build` with no flags is a **Debug** build, which is a trapping binary on
  purpose (a Zig bug is a crash, not silent corruption). Packagers pass
  `-Doptimize=ReleaseFast` — `qimgv/distrib/PKGBUILD`, `scripts/build-qimgv.sh` and
  all three CI workflows already do.
- A slice's own performance work is measured with the harness in `scripts/bench`
  against the same `-Doptimize=ReleaseFast` binary that ships (#6, #8).

## Packaging and CI

- **Arch**: `zig` is already in `makedepends`; nothing moves. `PKGBUILD` needs no
  new flag beyond the `-Dzig-core`-style one that enables the slice, and the
  installed tree does not change (the archive is statically linked in).
- **Stock Qt**: the binary's NEEDED set is unchanged (verified), so no new
  `depends`, no bundled runtime.
- **Windows/macOS**: not verified on this machine. MinGW's `ld` reading a Zig
  archive is the open question — the CI gate is
  `zig build -Doptimize=ReleaseFast -D<slice>=true` on all three workflows
  (`.github/workflows/{linux,windows,macos}.yml`), added in the same change that
  lands a slice.
- **Both builds in CI.** The plain build must stay green (the kill switch is
  build-time), and so must the slice build. `scripts/bench/bench.py` gains a flag to
  pick which binary produced a row, because the A/B is now across binaries.

## Adding slice 2 (the checklist)

1. Add `zig/src/scale.zig`; `pub const scale = @import("scale.zig");` in `root.zig`.
2. Declare its functions and any new POD struct in `zig/include/qimgv_core.h`; bump
   `QZ_ABI_VERSION` only if an existing struct or signature changes.
3. Give it an error range (`QZ_ERR_SCALE = 100`).
4. Write the C++ adapter in `qimgv/utils/qzimage.*` (wrap the `qz_buf`, own the free).
5. Put the call behind `#ifdef USE_ZIG_<SLICE>` at the existing seam, with today's
   code as the `#else`.
6. Add `-Dzig-<slice>` to `build.zig`'s flag list (the library and link step are
   already wired).
7. Add the flag to the three CI workflows and to the bench runner.
8. Delete the `#else` and retire the option once the slice is graded, or delete the
   Zig file and the `#ifdef` if it lost. A switch that outlives its grading round is
   a bug.

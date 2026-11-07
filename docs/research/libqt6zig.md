# libqt6zig: what it actually binds, and what it costs

Research for <https://github.com/glyh/qimgv/issues/7>. **Verdict: usable.** A Qt6 Widgets program — window, widget, connected signal, interpreted-later text — builds and runs on **zig 0.17.0 + Qt 6.12.0**, which is exactly this machine's toolchain.

## The build, measured

`helloworld` consumer project (`/tmp/wf/libqt6zig-build/hw-consumer`), 47 lines of `main.zig` + 40 lines of `build.zig`, linking four Qt classes (`qwidget`, `qapplication`, `qpushbutton`, `qabstractbutton`):

| | |
|---|---|
| cold build (fresh `ZIG_GLOBAL_CACHE_DIR`) | **151 s**, 88 MB of Zig cache |
| warm rebuild | 39 s |
| artifact | 15.9 MB ELF, with debug info, not stripped |
| links | `libQt6Core`, `libQt6Gui`, `libQt6Widgets`, `libQt6DBus` — dynamically, 45 libs in the closure |
| runs | enters the event loop (`QT_QPA_PLATFORM=offscreen`, still alive at 6 s) |

Upstream's FAQ (full library < 30 min, single example much cheaper) is accurate as far as one example goes.

### The adoption trap nobody documents

A **local path dependency does not work**:

```zig
.libqt6zig = .{ .path = "../libqt6zig" }   // error: no module named 'libqt6zig' available within module '@build'
```

`build.zig` does `@import("libqt6zig").configureQtExeRootModule` at build-script level, and Zig 0.17 only registers that build module for a **URL + hash** dependency. The working form:

```zig
.libqt6zig = .{ .url = "git+https://github.com/rcalixte/libqt6zig#76fbd35d3b4d67721e5ca5cd323c06cd83afeaad",
                .hash = "libqt6zig-6.8.2-OSXtXJRx4BxEkhok6OWmDklZGRHmnWFVTag8HX66JGuq" }
```

That matters for the map: **a vendored checkout cannot be consumed directly** — either the binding is packaged as a pinned URL/hash, or the consumer's `build.zig` stops importing it and re-implements the four options it injects.

### What a consumer compiles

`build.zig` compiles **each Qt class's `.cpp` glue as its own static library**. The consumer writes **no C++ at all**; it names the classes it uses, and Zig compiles only those:

```zig
for (qt_libraries) |lib| exe.root_module.linkLibrary(qt6zig.artifact(lib));
try configureQtExeRootModule(b, exe, .{});
```

So the cost scales with classes touched, not with Qt's size — which is the right shape for qimgv, where a Zig layer would call a handful of Qt entry points.

## Coverage

Counted by counting `pub const Q*` exports in the generated `include/libqt6.zig` against class definitions in each module's public headers (forward declarations `class QFoo;` excluded). Method is documented in `/tmp/wf/libqt6zig-build/count/cov.py`; it was validated only by spot checks, so treat the numbers as directional:

| Module | Qt classes | bound | % |
|---|---|---|---|
| QtCore | 391 | 203 | 51.9% |
| QtGui | 226 | 193 | 85.4% |
| QtWidgets | 196 | 189 | **96.4%** |

The Core figure understates usable coverage badly: the denominator includes template/container classes (`QList`, `QHash`, `QFuture`, `QPromise`, `QProperty`, `QScopedPointer`) that a binding deliberately does not project. 1449 classes are exported overall. The binding source totals ~6.07 M lines of generated Zig.

## Versions and liveness

`HEAD = 76fbd35`, changelog top entry rev94. **rev92 (2 Oct 2026) moved to Zig 0.17; rev91 moved to Qt 6.12** — the two things that decide whether this is usable *here*, and both match. Rev90–94 all landed in October 2026; it is maintained, not abandoned. Qt **private headers are required and are installed** on this machine (2,182 `*_p.h`).

## The hazard to carry into the boundary decision

- `linux_cpp_flags` are only `-nostdinc++ -nostdlib++`. **`-fno-exceptions` / `-fno-rtti` are not used**, there are **0 `try`/`catch` blocks** in the binding, and 66,915 `dynamic_cast`s recover subclass vtables.
- Consequence: a Qt-thrown C++ exception would unwind through `extern "C"` into Zig frames, where it is undefined behaviour. Any Zig↔Qt boundary built on this must forbid Qt calls that can throw, or wrap them.
- The binding is not a neutral choice of "Zig with Qt convenience" — it puts C++ ABI rules back in scope for every call site.

## Verdict

**Usable for qimgv's UI surface** — 96.4% of QtWidgets, no consumer-side C++, 2.5-minute cold build, maintained on the exact Zig and Qt versions installed here. The two real costs are the exception/RTTI boundary and the packaging constraint (URL+hash, not a vendored path). Neither is disqualifying; both belong in the interop ticket's rules.

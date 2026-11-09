const std = @import("std");

const qt_pc_modules = [_][]const u8{ "Qt6Widgets", "Qt6Svg", "Qt6PrintSupport", "Qt6OpenGLWidgets" };

/// The 7 shipping translations. `en_US.ts` is the lupdate template, not a build input.
const translations = [_][]const u8{ "zh_CN", "uk_UA", "es_ES", "de_DE", "fr_FR", "tr_TR", "ja_JP" };

const icon_sizes = [_][]const u8{ "16x16", "22x22", "24x24", "32x32", "36x36", "48x48", "64x64", "128x128", "256x256" };

/// Never part of the CMake build: the .cpp includes "ThumbnailWidgetCmp.h" while the
/// file on disk is "thumbnailwidgetcmp.h", so it has not compiled in years. The header
/// is excluded too, or moc emits a TU referencing symbols nobody defines.
const dead_sources = [_][]const u8{
    "gui/customwidgets/thumbnailwidgetcmp.cpp",
    "gui/customwidgets/thumbnailwidgetcmp.h",
};

/// Directories searched for quoted `#include "..."` when tracking header dependencies.
const include_dirs = [_][]const u8{ "qimgv", "plugins/player_mpv/src" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // -Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall, default Debug: the same
    // "no build type chosen" default CMake had. Packagers pass ReleaseFast explicitly.
    const optimize = b.standardOptimizeOption(.{});

    const with_exiv2 = b.option(bool, "exiv2", "read/write EXIF tags through exiv2") orelse true;
    const with_video = b.option(bool, "video", "build the mpv video player plugin") orelse true;
    const with_opencv = b.option(bool, "opencv", "HQ scaling through OpenCV") orelse false;
    const with_kde = b.option(bool, "kde", "blur behind the window under KDE") orelse false;
    const translations_path = b.option(
        []const u8,
        "translations-path",
        "path baked in at compile time for the installed .qm files",
    ) orelse "/usr/share/qimgv/translations";

    const os = target.result.os.tag;
    const is_windows = os == .windows;
    const is_macos = os == .macos;

    const moc_exe = qtTool(b, "moc") orelse @panic("moc not found: install the Qt 6.8+ development tools");
    const uic_exe = qtTool(b, "uic") orelse @panic("uic not found: install the Qt 6.8+ development tools");
    const rcc_exe = qtTool(b, "rcc") orelse @panic("rcc not found: install the Qt 6.8+ development tools");
    const lrelease_exe = qtTool(b, "lrelease");

    // zig 0.17 carries clang 22 and a gcc 16 libstdc++ needs clang 23, so `zig c++`
    // dies in <cmath>/<type_traits>. Zig's bundled libc++ is not a way out either: a
    // distro Qt is built with libstdc++, and Qt 6.12 puts std:: types in its API
    // (QFile::copy takes std::optional<Permissions>), so libc++-mangled symbols never
    // resolve at link time. C++ therefore compiles with the system compiler; zig owns
    // the graph, the moc/uic/rcc steps, caching and the install tree.
    const cxx = systemCxx(b) orelse @panic("no C++ compiler found: install clang or gcc");

    var flags: std.ArrayList([]const u8) = .empty;
    const add = std.ArrayList([]const u8).appendSlice;
    add(&flags, b.allocator, &.{ "-std=c++17", "-fPIC" }) catch @panic("OOM");
    add(&flags, b.allocator, optimizeFlags(optimize)) catch @panic("OOM");
    add(&flags, b.allocator, pkgConfig(b, "--cflags", &qt_pc_modules)) catch @panic("OOM");
    add(&flags, b.allocator, &.{ "-I.", "-Iqimgv" }) catch @panic("OOM");

    if (with_exiv2) add(&flags, b.allocator, pkgConfig(b, "--cflags", &.{"exiv2"})) catch @panic("OOM");
    if (with_opencv) add(&flags, b.allocator, pkgConfig(b, "--cflags", &.{"opencv4"})) catch @panic("OOM");
    if (with_exiv2) add(&flags, b.allocator, &.{"-DUSE_EXIV2"}) catch @panic("OOM");
    if (with_opencv) add(&flags, b.allocator, &.{"-DUSE_OPENCV"}) catch @panic("OOM");
    if (with_kde) add(&flags, b.allocator, &.{"-DUSE_KDE_BLUR"}) catch @panic("OOM");
    if (with_video) {
        add(&flags, b.allocator, &.{
            "-DUSE_MPV",
            if (is_windows) "-D_QIMGV_PLAYER_PLUGIN=\"player_mpv.dll\"" else "-D_QIMGV_PLAYER_PLUGIN=\"player_mpv.so\"",
        }) catch @panic("OOM");
    }
    if (!is_windows) {
        // On Windows qimgv looks next to the executable instead (Core::loadTranslation).
        add(&flags, b.allocator, &.{b.fmt("-DTRANSLATIONS_PATH=\"{s}\"", .{translations_path})}) catch @panic("OOM");
    }

    // AUTOUIC replacement: one uic run per form, all deposited into a single generated
    // directory so a single include path covers them.
    const ui_dir = b.addWriteFiles();
    const app_sources = scanSources(b, "qimgv", &.{ "tests", "3rdparty" }, is_windows, is_macos);
    for (app_sources.ui) |rel| {
        const run = b.addSystemCommand(&.{ uic_exe, "-o" });
        const generated = run.addOutputFileArg(b.fmt("ui_{s}.h", .{std.fs.path.stem(rel)}));
        run.addFileArg(b.path(rel));
        run.has_side_effects = true;
        _ = ui_dir.addCopyFile(generated, b.fmt("ui_{s}.h", .{std.fs.path.stem(rel)}));
    }
    // A .ui edit has to rebuild the TUs that include its ui_*.h, and only those sources
    // are known to uic — so every form is an input of every C++ TU. Cheap to hash,
    // and only a form edit triggers it.
    var ui_inputs: std.ArrayList(std.Build.LazyPath) = .empty;
    for (app_sources.ui) |rel| {
        ui_inputs.append(b.allocator, b.path(rel)) catch @panic("OOM");
    }

    var objects: std.ArrayList(std.Build.LazyPath) = .empty;

    for (app_sources.cpp) |rel| {
        objects.append(b.allocator, compileOne(
            b,
            cxx,
            flags.items,
            b.path(rel),
            headerDeps(b, rel),
            ui_inputs.items,
            b.fmt("{s}.o", .{tuName(b, rel)}),
            &.{ui_dir.getDirectory()},
        )) catch @panic("OOM");
    }

    // AUTOMOC replacement: one moc run per Q_OBJECT/Q_GADGET header or source. zig
    // caches a run on its argv rather than on the header's content, so the run is
    // forced; an unchanged moc output leaves the downstream compile cached.
    for (app_sources.moc) |rel| {
        const run = b.addSystemCommand(&.{moc_exe});
        run.addArgs(mocFlags(b, flags.items));
        run.setCwd(b.path("."));
        run.addArg("-o");
        const generated = run.addOutputFileArg(b.fmt("moc_{s}.cpp", .{tuName(b, rel)}));
        run.addFileArg(b.path(rel));
        run.has_side_effects = true;
        objects.append(b.allocator, compileOne(
            b,
            cxx,
            flags.items,
            generated,
            headerDeps(b, rel),
            ui_inputs.items,
            b.fmt("moc_{s}.o", .{tuName(b, rel)}),
            &.{ui_dir.getDirectory()},
        )) catch @panic("OOM");
    }

    // AUTORCC replacement.
    {
        const run = b.addSystemCommand(&.{ rcc_exe, "--name", "resources", "-o" });
        const generated = run.addOutputFileArg("qrc_resources.cpp");
        run.addFileArg(b.path("qimgv/resources.qrc"));
        run.has_side_effects = true;
        objects.append(b.allocator, compileOne(
            b,
            cxx,
            flags.items,
            generated,
            &.{},
            &.{},
            "qrc_resources.o",
            &.{},
        )) catch @panic("OOM");
    }

    if (with_opencv) {
        objects.append(b.allocator, compileOne(
            b,
            cxx,
            flags.items,
            b.path("qimgv/3rdparty/QtOpenCV/cvmatandqimage.cpp"),
            headerDeps(b, "qimgv/3rdparty/QtOpenCV/cvmatandqimage.cpp"),
            ui_inputs.items,
            "cvmatandqimage.o",
            &.{},
        )) catch @panic("OOM");
    }

    var link_flags: std.ArrayList([]const u8) = .empty;
    add(&link_flags, b.allocator, pkgConfig(b, "--libs", &qt_pc_modules)) catch @panic("OOM");
    if (with_exiv2) add(&link_flags, b.allocator, pkgConfig(b, "--libs", &.{"exiv2"})) catch @panic("OOM");
    if (with_opencv) add(&link_flags, b.allocator, pkgConfig(b, "--libs", &.{"opencv4"})) catch @panic("OOM");
    if (with_kde) add(&link_flags, b.allocator, pkgConfig(b, "--libs", &.{"KF6WindowSystem"})) catch @panic("OOM");
    if (is_windows) add(&link_flags, b.allocator, &.{"-mwindows", "-Wl,--subsystem,windows"}) catch @panic("OOM");

    const binary = linkApp(b, cxx, objects.items, link_flags.items, "qimgv", is_windows);

    b.getInstallStep().dependOn(&installBinary(b, binary, is_windows, is_macos).step);

    if (with_video) {
        var plugin_flags: std.ArrayList([]const u8) = .empty;
        add(&plugin_flags, b.allocator, flags.items) catch @panic("OOM");
        add(&plugin_flags, b.allocator, pkgConfig(b, "--cflags", &.{"mpv"})) catch @panic("OOM");
        add(&plugin_flags, b.allocator, &.{ "-DQIMGV_PLAYER_MPV_LIBRARY", "-Iplugins/player_mpv/src" }) catch @panic("OOM");

        const plugin_sources = scanSources(b, "plugins/player_mpv/src", &.{"nogl"}, is_windows, is_macos);
        var plugin_objects: std.ArrayList(std.Build.LazyPath) = .empty;
        for (plugin_sources.cpp) |rel| {
            plugin_objects.append(b.allocator, compileOne(
                b,
                cxx,
                plugin_flags.items,
                b.path(rel),
                headerDeps(b, rel),
                &.{},
                b.fmt("plugin_{s}.o", .{tuName(b, rel)}),
                &.{},
            )) catch @panic("OOM");
        }
        for (plugin_sources.moc) |rel| {
            const run = b.addSystemCommand(&.{moc_exe});
            run.addArgs(mocFlags(b, plugin_flags.items));
            run.setCwd(b.path("."));
            run.addArg("-o");
            const generated = run.addOutputFileArg(b.fmt("moc_plugin_{s}.cpp", .{tuName(b, rel)}));
            run.addFileArg(b.path(rel));
            run.has_side_effects = true;
            plugin_objects.append(b.allocator, compileOne(
                b,
                cxx,
                plugin_flags.items,
                generated,
                headerDeps(b, rel),
                &.{},
                b.fmt("moc_plugin_{s}.o", .{tuName(b, rel)}),
                &.{},
            )) catch @panic("OOM");
        }

        var plugin_link: std.ArrayList([]const u8) = .empty;
        add(&plugin_link, b.allocator, pkgConfig(b, "--libs", &qt_pc_modules)) catch @panic("OOM");
        add(&plugin_link, b.allocator, pkgConfig(b, "--libs", &.{"mpv"})) catch @panic("OOM");
        add(&plugin_link, b.allocator, &.{"-shared"}) catch @panic("OOM");

        const plugin_bin = linkApp(b, cxx, plugin_objects.items, plugin_link.items, "player_mpv", is_windows);
        const plugin_name = if (is_windows) "player_mpv.dll" else "player_mpv.so";
        const plugin_install = b.addInstallFileWithDir(
            plugin_bin,
            .{ .custom = if (is_windows) "bin/plugins" else "lib/qimgv" },
            plugin_name,
        );
        b.getInstallStep().dependOn(&plugin_install.step);
    }

    installTranslations(b, lrelease_exe, is_windows);
    installDataFiles(b);
}

// ---------------------------------------------------------------------------

const Scanned = struct {
    cpp: []const []const u8,
    moc: []const []const u8,
    ui: []const []const u8,
};

/// Walks a source tree instead of keeping a file list in the build file, so a new .cpp
/// cannot be forgotten. Directories named in `skip` are ignored, as are the
/// platform-specific directory watchers that do not belong to this target.
fn scanSources(
    b: *std.Build,
    root: []const u8,
    skip: []const []const u8,
    is_windows: bool,
    is_macos: bool,
) Scanned {
    const io = b.graph.io;
    var cpp: std.ArrayList([]const u8) = .empty;
    var moc: std.ArrayList([]const u8) = .empty;
    var ui: std.ArrayList([]const u8) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open {s}: {s}", .{ root, @errorName(err) });
    };
    defer dir.close(io);

    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;

        // The walker joins components with the native separator, so on Windows
        // entry.path is a backslash-separated path. Every test below -- the skip
        // component list, the "watchers/linux/" match, dead_sources, and the object
        // names tuName derives from rel -- is written with '/'. Normalise once here;
        // the raw entry.path is still what the filesystem calls below use.
        const path = blk: {
            const normalised = b.allocator.dupe(u8, entry.path) catch @panic("OOM");
            for (normalised) |*c| {
                if (c.* == '\\') c.* = '/';
            }
            break :blk normalised;
        };

        var skipped = false;
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (parts.next()) |part| {
            for (skip) |s| if (std.mem.eql(u8, part, s)) {
                skipped = true;
            };
        }
        if (!is_windows and std.mem.indexOf(u8, path, "watchers/windows/") != null) skipped = true;
        // The Linux watcher is inotify-only (sys/inotify.h). CMake compiled no watcher at
        // all on Apple -- its APPLE branch is commented out and directorywatcher.cpp falls
        // back to DummyWatcher -- so macOS must not pick this one up.
        if ((is_windows or is_macos) and std.mem.indexOf(u8, path, "watchers/linux/") != null) skipped = true;
        for (dead_sources) |dead| if (std.mem.eql(u8, path, dead)) {
            skipped = true;
        };
        if (skipped) continue;

        const rel = b.fmt("{s}/{s}", .{ root, path });
        if (std.mem.endsWith(u8, path, ".cpp")) {
            cpp.append(b.allocator, b.dupe(rel)) catch @panic("OOM");
        } else if (std.mem.endsWith(u8, path, ".ui")) {
            ui.append(b.allocator, b.dupe(rel)) catch @panic("OOM");
        }
        if (!std.mem.endsWith(u8, path, ".h") and
            !std.mem.endsWith(u8, path, ".hpp") and
            !std.mem.endsWith(u8, path, ".cpp")) continue;

        const text = dir.readFileAlloc(io, entry.path, b.allocator, .limited(4 << 20)) catch continue;
        if (std.mem.indexOf(u8, text, "Q_OBJECT") != null or std.mem.indexOf(u8, text, "Q_GADGET") != null) {
            moc.append(b.allocator, b.dupe(rel)) catch @panic("OOM");
        }
    }

    return .{
        .cpp = cpp.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .moc = moc.toOwnedSlice(b.allocator) catch @panic("OOM"),
        .ui = ui.toOwnedSlice(b.allocator) catch @panic("OOM"),
    };
}

/// Compiles one TU. `headers` are the transitive quoted includes found at configure
/// time; the system compiler's depfile cannot be fed back into zig's cache, so these
/// declared inputs are what makes a header edit rebuild exactly its dependents.
fn compileOne(
    b: *std.Build,
    cxx: []const u8,
    flags: []const []const u8,
    source: std.Build.LazyPath,
    headers: []const std.Build.LazyPath,
    extra_inputs: []const std.Build.LazyPath,
    output_name: []const u8,
    include_dirs_extra: []const std.Build.LazyPath,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ cxx, "-c" });
    run.addArgs(flags);
    // Generated headers (ui_*.h) only exist at make time, so their directory joins the
    // include path as an argument rather than as a baked -I flag.
    for (include_dirs_extra) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(dir);
    }
    run.addFileArg(source);
    run.addArg("-o");
    const obj = run.addOutputFileArg(output_name);
    for (headers) |h| run.addFileInput(h);
    for (extra_inputs) |extra| run.addFileInput(extra);
    return obj;
}

fn linkApp(
    b: *std.Build,
    cxx: []const u8,
    objects: []const std.Build.LazyPath,
    link_flags: []const []const u8,
    name: []const u8,
    is_windows: bool,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{cxx});
    for (objects) |obj| run.addFileArg(obj);
    run.addArg("-o");
    const out = run.addOutputFileArg(if (is_windows) b.fmt("{s}.exe", .{name}) else name);
    run.addArgs(link_flags);
    return out;
}

/// Transitive quoted includes of `start_rel`, as build-root-relative LazyPaths.
fn headerDeps(b: *std.Build, start_rel: []const u8) []const std.Build.LazyPath {
    var seen = std.StringHashMap(void).init(b.allocator);
    var out: std.ArrayList(std.Build.LazyPath) = .empty;
    walkIncludes(b, start_rel, &seen, &out, 0);
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn walkIncludes(
    b: *std.Build,
    rel: []const u8,
    seen: *std.StringHashMap(void),
    out: *std.ArrayList(std.Build.LazyPath),
    depth: u8,
) void {
    if (depth > 48) return;
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, rel, b.allocator, .limited(2 << 20)) catch return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "#include")) continue;
        const rest = std.mem.trimStart(u8, trimmed["#include".len..], " \t");
        if (rest.len < 2 or rest[0] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse continue;
        const resolved = resolveInclude(b, rel, rest[1..end]) orelse continue;
        if (seen.contains(resolved)) continue;
        seen.put(resolved, {}) catch @panic("OOM");
        out.append(b.allocator, b.path(resolved)) catch @panic("OOM");
        walkIncludes(b, resolved, seen, out, depth + 1);
    }
}

fn resolveInclude(b: *std.Build, from_rel: []const u8, name: []const u8) ?[]const u8 {
    const io = b.graph.io;
    if (std.mem.startsWith(u8, name, "/")) return null; // system / Qt header
    if (std.fs.path.dirname(from_rel)) |dir| {
        const candidate = b.pathJoin(&.{ dir, name });
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
    }
    for (include_dirs) |dir| {
        const candidate = b.pathJoin(&.{ dir, name });
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
    }
    return null;
}

/// Cache/staging name for a moc output: `gui/mainwindow.h` -> `gui_mainwindow`.
fn tuName(b: *std.Build, rel: []const u8) []const u8 {
    const base = if (std.mem.endsWith(u8, rel, ".cpp")) rel[0 .. rel.len - 4] else std.fs.path.stem(rel);
    const slashed = std.mem.replaceOwned(u8, b.allocator, base, "/", "_") catch @panic("OOM");
    // A surviving separator would become a subdirectory of the cache entry.
    return std.mem.replaceOwned(u8, b.allocator, slashed, "\\", "_") catch @panic("OOM");
}

/// moc needs the include and define flags of the TU it serves, nothing else.
fn mocFlags(b: *std.Build, flags: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (flags) |f| {
        if (std.mem.startsWith(u8, f, "-I") or std.mem.startsWith(u8, f, "-D"))
            out.append(b.allocator, f) catch @panic("OOM");
    }
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// Mirrors what Qt's CMake package does through INTERFACE_COMPILE_DEFINITIONS:
/// QT_NO_DEBUG for every configuration except Debug
/// (Qt6CoreConfigExtras.cmake: `$<$<NOT:$<CONFIG:Debug>>:QT_NO_DEBUG>`).
/// pkg-config's --cflags does not carry it, so without this the Qt headers would
/// be compiled in a different mode than they were under CMake.
fn optimizeFlags(optimize: std.builtin.Optimize) []const []const u8 {
    return switch (optimize) {
        .debug => &.{ "-O0", "-g" },
        .safe => &.{ "-O2", "-g", "-DNDEBUG", "-DQT_NO_DEBUG" },
        .fast => &.{ "-O2", "-DNDEBUG", "-DQT_NO_DEBUG" },
        .small => &.{ "-Os", "-DNDEBUG", "-DQT_NO_DEBUG" },
    };
}

fn systemCxx(b: *std.Build) ?[]const u8 {
    if (b.findProgram(.{ .names = &.{"clang++"} })) |path| return path;
    if (b.findProgram(.{ .names = &.{"g++"} })) |path| return path;
    return null;
}

fn pkgConfig(b: *std.Build, arg: []const u8, modules: []const []const u8) []const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ "pkg-config", arg }) catch @panic("OOM");
    argv.appendSlice(b.allocator, modules) catch @panic("OOM");
    const stdout = b.run(argv.items);
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, stdout, " \t\r\n");
    while (it.next()) |word| out.append(b.allocator, b.dupe(word)) catch @panic("OOM");
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn pkgConfigVar(b: *std.Build, variable: []const u8, module: []const u8) []const u8 {
    const stdout = b.run(&.{ "pkg-config", b.fmt("--variable={s}", .{variable}), module });
    return b.dupe(std.mem.trim(u8, stdout, " \t\r\n"));
}

/// moc/uic/rcc are not on PATH on every distro, and on Arch the plain `moc` on PATH is
/// still Qt 5's, which emits code Qt 6 headers reject. Look inside the Qt 6 prefix
/// pkg-config points at first, and only trust PATH when its version says Qt 6.
fn qtTool(b: *std.Build, name: []const u8) ?[]const u8 {
    const io = b.graph.io;
    const prefix = pkgConfigVar(b, "prefix", "Qt6Core");
    var dirs: std.ArrayList([]const u8) = .empty;
    // Qt only defines host_bins for cross builds, but when it is there it is the
    // authoritative answer.
    const host_bins = pkgConfigVar(b, "host_bins", "Qt6Core");
    if (host_bins.len != 0) dirs.append(b.allocator, host_bins) catch @panic("OOM");
    // bindir/libexecdir are what Homebrew and Debian point at the tools.
    const bindir = pkgConfigVar(b, "bindir", "Qt6Core");
    if (bindir.len != 0) dirs.append(b.allocator, bindir) catch @panic("OOM");
    const libexecdir = pkgConfigVar(b, "libexecdir", "Qt6Core");
    if (libexecdir.len != 0) dirs.append(b.allocator, libexecdir) catch @panic("OOM");
    dirs.appendSlice(b.allocator, &.{
        b.fmt("{s}/lib/qt6", .{prefix}),
        b.fmt("{s}/lib/qt6/bin", .{prefix}),
        b.fmt("{s}/lib/qt6/libexec", .{prefix}),
        // MSYS2 keeps moc/uic/rcc in share/qt6/bin rather than bin/.
        b.fmt("{s}/share/qt6/bin", .{prefix}),
        b.fmt("{s}/libexec", .{prefix}),
        b.fmt("{s}/bin", .{prefix}),
    }) catch @panic("OOM");
    // Windows tools are moc.exe/uic.exe/...; without the extensioned name every
    // prefix lookup misses and only the PATH fallback below can save it.
    const names = [_][]const u8{ name, b.fmt("{s}.exe", .{name}) };
    for (dirs.items) |dir| {
        for (names) |candidate_name| {
            const candidate = b.fmt("{s}/{s}", .{ dir, candidate_name });
            if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
        }
    }
    if (b.findProgram(.{ .names = &names })) |path| {
        const version = b.run(&.{ path, "--version" });
        if (std.mem.indexOf(u8, version, " 6.") != null) return path;
    }
    return null;
}

fn installBinary(b: *std.Build, binary: std.Build.LazyPath, is_windows: bool, is_macos: bool) *std.Build.Step.InstallFile {
    const name = if (is_windows) "qimgv.exe" else "qimgv";
    if (is_macos) {
        const app = b.addInstallFileWithDir(binary, .{ .custom = "qimgv.app/Contents/MacOS" }, name);
        b.getInstallStep().dependOn(&app.step);
        const plist = b.addInstallFile(bundleInfoPlist(b), "qimgv.app/Contents/Info.plist");
        b.getInstallStep().dependOn(&plist.step);
        // CMake carried the icon into the bundle via MACOSX_PACKAGE_LOCATION Resources.
        const icon = b.addInstallFile(
            b.path("qimgv/distrib/qimgv.icns"),
            "qimgv.app/Contents/Resources/qimgv.icns",
        );
        b.getInstallStep().dependOn(&icon.step);
        return app;
    }
    return b.addInstallFileWithDir(binary, .{ .custom = "bin" }, name);
}

/// CMake installed the .qm tree into `bin` on Windows (the app loads them from next
/// to the executable there) and into `share/qimgv` everywhere else.
fn installTranslations(b: *std.Build, lrelease_exe: ?[]const u8, is_windows: bool) void {
    const lr = lrelease_exe orelse {
        std.log.warn("lrelease not found: .qm files will not be installed", .{});
        return;
    };
    const qm_dir = b.addWriteFiles();
    for (translations) |lang| {
        const run = b.addSystemCommand(&.{ lr, "-silent" });
        run.addFileArg(b.path(b.fmt("qimgv/res/translations/{s}.ts", .{lang})));
        run.addArg("-qm");
        const generated = run.addOutputFileArg(b.fmt("{s}.qm", .{lang}));
        run.has_side_effects = true;
        _ = qm_dir.addCopyFile(generated, b.fmt("{s}.qm", .{lang}));
    }
    const qm_install = b.addInstallDirectory(.{
        .source_dir = qm_dir.getDirectory(),
        .install_dir = .{ .custom = if (is_windows) "bin" else "share/qimgv" },
        .install_subdir = "translations",
        .include_extensions = &.{".qm"},
    });
    b.getInstallStep().dependOn(&qm_install.step);
}

fn installDataFiles(b: *std.Build) void {
    b.getInstallStep().dependOn(&b.addInstallFile(
        b.path("qimgv/distrib/qimgv.desktop"),
        "share/applications/qimgv.desktop",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFile(
        b.path("qimgv/distrib/qimgv.appdata.xml"),
        "share/metainfo/qimgv.appdata.xml",
    ).step);
    for (icon_sizes) |size| {
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path(b.fmt("qimgv/distrib/hicolor/{s}/apps/qimgv.png", .{size})),
            b.fmt("share/icons/hicolor/{s}/apps/qimgv.png", .{size}),
        ).step);
    }
    b.getInstallStep().dependOn(&b.addInstallFile(
        b.path("qimgv/distrib/hicolor/scalable/apps/qimgv.svg"),
        "share/icons/hicolor/scalable/apps/qimgv.svg",
    ).step);
}

fn bundleInfoPlist(b: *std.Build) std.Build.LazyPath {
    const template = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "qimgv/distrib/MyBundleInfo.plist.in",
        b.allocator,
        .limited(1 << 20),
    ) catch @panic("cannot read MyBundleInfo.plist.in");
    const fields = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "MACOSX_BUNDLE_EXECUTABLE_NAME", .value = "qimgv" },
        .{ .key = "MACOSX_BUNDLE_INFO_STRING", .value = "qimgv" },
        .{ .key = "MACOSX_BUNDLE_ICON_FILE", .value = "qimgv.icns" },
        .{ .key = "MACOSX_BUNDLE_GUI_IDENTIFIER", .value = "com.github.easymodo.qimgv" },
        .{ .key = "MACOSX_BUNDLE_LONG_VERSION_STRING", .value = "1.0.2" },
        .{ .key = "MACOSX_BUNDLE_BUNDLE_NAME", .value = "qimgv" },
        .{ .key = "MACOSX_BUNDLE_SHORT_VERSION_STRING", .value = "1.0.2" },
        .{ .key = "MACOSX_BUNDLE_BUNDLE_VERSION", .value = "1.0.2" },
        .{ .key = "MACOSX_BUNDLE_COPYRIGHT", .value = "GPL-3.0" },
    };
    var body = template;
    for (fields) |f| {
        const needle = b.fmt("${{{s}}}", .{f.key});
        body = std.mem.replaceOwned(u8, b.allocator, body, needle, f.value) catch @panic("OOM");
    }
    const wf = b.addWriteFiles();
    return wf.add("Info.plist", body);
}

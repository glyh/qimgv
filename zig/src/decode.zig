//! JPEG decode driven by libjpeg-turbo's TurboJPEG API.
//!
//! TurboJPEG rather than raw libjpeg on purpose: libjpeg's error path is
//! `error_exit`, which either calls exit() or longjmps, and nothing may unwind
//! or exit across this boundary. TurboJPEG returns a code instead.
//!
//! Called on the caller's thread. No globals, no threads, no `unreachable`,
//! nothing that can panic: a panic or an overflow trap aborts the process in
//! every optimize mode (see docs/zig-interop.md).

const std = @import("std");

const tj = @import("tj");

const gpa = std.heap.c_allocator;

pub const FORMAT_GRAY8: c_int = 1;
pub const FORMAT_RGB888: c_int = 2;

const OK: c_int = 0;
const E_INVALID_ARG: c_int = -1;
const E_NO_MEMORY: c_int = -2;
const E_IO: c_int = -3;
const E_UNSUPPORTED: c_int = -10;
const E_FORMAT: c_int = -11;


pub threadlocal var detail: [192]u8 = @splat(0);

fn note(comptime fmt: []const u8, args: anytype) void {
    // Bounded formatting into the thread-local buffer; truncation is fine,
    // this string is for logs only.
    const s = std.fmt.bufPrint(detail[0 .. detail.len - 1], fmt, args) catch {
        detail[detail.len - 1] = 0;
        return;
    };
    detail[s.len] = 0;
}

fn noteCString(prefix: []const u8, msg: [*:0]const u8) void {
    note("{s}: {s}", .{ prefix, std.mem.span(msg) });
}

/// The ABI struct, byte for byte (zig/include/qimgv_core.h).
pub const Bitmap = extern struct {
    data: ?[*]u8,
    w: u32,
    h: u32,
    stride: u32,
    fmt: c_int,
    bytes: u32,
};

const Fitted = struct {
    factor: tj.tjscalingfactor,
    w: u32,
    h: u32,
};

/// The largest scaling factor that still fits inside max_w x max_h, because
/// turbojpeg can only emit 1/n (n = 1..8, and 3/8, ...) of the stored size.
fn fit(handle: tj.tjhandle, max_w: u32, max_h: u32, w: c_int, h: c_int) ?Fitted {
    _ = handle;
    var count: c_int = 0;
    const factors = tj.tj3GetScalingFactors(&count) orelse return null;
    if (count <= 0) return null;
    const n: usize = @intCast(count);

    var best: ?Fitted = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = factors[i];
        if (f.num <= 0 or f.denom <= 0) continue;
        const sw = @divTrunc(@as(i64, w) * f.num, f.denom);
        const sh = @divTrunc(@as(i64, h) * f.num, f.denom);
        if (sw <= 0 or sh <= 0) continue;
        if (sw <= @as(i64, max_w) and sh <= @as(i64, max_h)) {
            // Factors are ordered largest-first, so the last fit is the biggest.
            best = .{ .factor = f, .w = @intCast(sw), .h = @intCast(sh) };
        }
    }
    // Nothing fits: fall back to the smallest factor turbojpeg offers.
    if (best == null) {
        const f = factors[n - 1];
        best = .{
            .factor = f,
            .w = @intCast(@max(1, @divTrunc(@as(i64, w) * f.num, f.denom))),
            .h = @intCast(@max(1, @divTrunc(@as(i64, h) * f.num, f.denom))),
        };
    }
    return best;
}

pub fn decode(path: [*:0]const u8, max_w: u32, max_h: u32, out: *Bitmap) c_int {
    out.* = .{ .data = null, .w = 0, .h = 0, .stride = 0, .fmt = 0, .bytes = 0 };

    // libc stdio rather than std.fs: in zig 0.17 every std.fs entry point
    // takes a std.Io, and the slice deliberately has no Io handle (Qt owns the
    // threads and the I/O policy; see docs/zig-interop.md).
    var size: usize = 0;
    const src = readAll(path, &size) orelse {
        note("cannot read file", .{});
        return E_IO;
    };
    defer gpa.free(src);
    if (size == 0) {
        note("empty file", .{});
        return E_FORMAT;
    }

    const handle = tj.tj3Init(tj.TJINIT_DECOMPRESS) orelse {
        note("tj3Init failed", .{});
        return E_UNSUPPORTED;
    };
    defer tj.tj3Destroy(handle);

    if (tj.tj3DecompressHeader(handle, src.ptr, size) != 0) {
        // Not a JPEG, or a broken one: the caller falls back to Qt, which is
        // how every other image format keeps working.
        noteCString("header", tj.tj3GetErrorStr(handle));
        return E_UNSUPPORTED;
    }
    const w = tj.tj3Get(handle, tj.TJPARAM_JPEGWIDTH);
    const h = tj.tj3Get(handle, tj.TJPARAM_JPEGHEIGHT);
    if (w <= 0 or h <= 0) {
        note("bogus dimensions {d}x{d}", .{ w, h });
        return E_FORMAT;
    }

    // Grayscale stays single-channel; everything else becomes packed RGB.
    // Both map straight onto a QImage format in the adapter.
    const grayscale = tj.tj3Get(handle, tj.TJPARAM_COLORSPACE) == tj.TJCS_GRAY;
    const channels: u32 = if (grayscale) 1 else 3;
    const fmt: c_int = if (grayscale) FORMAT_GRAY8 else FORMAT_RGB888;
    const pixel_format: c_int = if (grayscale) tj.TJPF_GRAY else tj.TJPF_RGB;

    var out_w: u32 = @intCast(w);
    var out_h: u32 = @intCast(h);
    if (max_w != 0 and max_h != 0) {
        const fitted = fit(handle, max_w, max_h, w, h) orelse {
            note("no scaling factors", .{});
            return E_FORMAT;
        };
        if (tj.tj3SetScalingFactor(handle, fitted.factor) != 0) {
            noteCString("scaling", tj.tj3GetErrorStr(handle));
            return E_FORMAT;
        }
        out_w = fitted.w;
        out_h = fitted.h;
    }

    const stride: u32 = out_w * channels;
    const bytes: usize = @as(usize, stride) * out_h;
    if (bytes == 0) {
        note("zero-sized bitmap", .{});
        return E_INVALID_ARG;
    }

    const dst = gpa.alloc(u8, bytes) catch {
        note("out of memory for {d}x{d}", .{ out_w, out_h });
        return E_NO_MEMORY;
    };

    if (tj.tj3Decompress8(handle, src.ptr, size, dst.ptr, @intCast(stride), pixel_format) != 0) {
        gpa.free(dst);
        noteCString("decode", tj.tj3GetErrorStr(handle));
        return E_FORMAT;
    }

    out.* = .{
        .data = dst.ptr,
        .w = out_w,
        .h = out_h,
        .stride = stride,
        .fmt = fmt,
        .bytes = @intCast(bytes),
    };
    return OK;
}

/// Reads the whole file into a c_allocator buffer. Portable to Windows through
/// the CRT, and no Io handle needed.
fn readAll(path: [*:0]const u8, size_out: *usize) ?[]u8 {
    const file = std.c.fopen(path, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, file);
        if (n == 0) break;
        if (buf.items.len + n > (1 << 31)) return null;
        buf.appendSlice(gpa, chunk[0..n]) catch return null;
    }
    size_out.* = buf.items.len;
    return buf.toOwnedSlice(gpa) catch null;
}

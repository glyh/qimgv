//! The Zig core. Slices are files this imports; the ABI is
//! zig/include/qimgv_core.h. See docs/zig-interop.md.

const std = @import("std");

pub const decode = @import("decode.zig");

const Bitmap = decode.Bitmap;

// Exported so the core is emitted even when only one slice is referenced.
comptime {
    _ = decode;
}

export fn qimg_abi_version() c_int {
    return 1;
}

export fn qimg_status_detail(dst: ?[*]u8, cap: i32) i32 {
    const d = dst orelse return 0;
    if (cap <= 0) return 0;
    const limit: usize = @intCast(cap);
    const src = decode.detail[0..];
    const n = @min(limit - 1, src.len);
    @memcpy(d[0..n], src[0..n]);
    d[n] = 0;
    return @intCast(n);
}

export fn qimg_decode(path: ?[*:0]const u8, max_w: u32, max_h: u32, out: ?*Bitmap) c_int {
    const p = path orelse return -1; // QIMG_E_INVALID_ARG
    const o = out orelse return -1;
    return decode.decode(p, max_w, max_h, o);
}

export fn qimg_bitmap_free(b: ?*Bitmap) void {
    const bmp = b orelse return;
    if (bmp.data) |data| {
        std.heap.c_allocator.free(data[0..bmp.bytes]);
        bmp.data = null;
        bmp.bytes = 0;
    }
}


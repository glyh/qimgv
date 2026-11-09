#ifndef QIMGV_CORE_H
#define QIMGV_CORE_H

/*
 * The ABI of the Zig core. Hand-written C: moc parses this file, so it must
 * contain no C++ and no Qt. Rules, and the measurements behind them, are in
 * docs/zig-interop.md.
 *
 * Everything here is included only under -DUSE_ZIG_* (build.zig), so a plain
 * `zig build` does not see this header at all.
 */

#include <stddef.h>
#include <stdint.h>

#define QIMGV_ABI_VERSION 1

#if defined(__cplusplus)
extern "C" {
#endif

/* Negative codes. A range per slice, so two slices never collide. */
typedef enum qimg_status {
    QIMG_OK = 0,
    QIMG_E_INVALID_ARG = -1,
    QIMG_E_NO_MEMORY = -2,
    QIMG_E_IO = -3,
    /* decode slice: -10 .. -19 */
    QIMG_E_UNSUPPORTED = -10,
    QIMG_E_FORMAT = -11
} qimg_status;

/* Values of qimg_bitmap.fmt; they map to QImage::Format_* in the adapter. */
typedef enum qimg_format {
    QIMG_FMT_GRAY8 = 1,
    QIMG_FMT_RGB888 = 2
} qimg_format;

/*
 * One decoded bitmap. The Zig side allocates it and owns the only free; the
 * C++ side must hand it to QImage with qimg_bitmap_free as the cleanup
 * function, or to qimg_bitmap_free directly. bytes == stride * h.
 */
typedef struct qimg_bitmap {
    uint8_t *data;
    uint32_t w;
    uint32_t h;
    uint32_t stride;
    int32_t fmt;
    uint32_t bytes;
} qimg_bitmap;

int32_t qimg_abi_version(void);

/* Best-effort detail for the last failing call on this thread. Returns the
 * length written, or 0. For logs only, never for control flow. */
int32_t qimg_status_detail(char *dst, int32_t cap);

/*
 * Decodes `path` at full size (max_w/max_h are 0) or scaled down to fit
 * max_w/max_h. Returns QIMG_OK and fills `out`, or a negative code with `out`
 * zeroed. Formats the slice does not handle return QIMG_E_UNSUPPORTED so the
 * caller can fall back to Qt.
 */
int32_t qimg_decode(const char *path, uint32_t max_w, uint32_t max_h, qimg_bitmap *out);

void qimg_bitmap_free(qimg_bitmap *b);

#if defined(__cplusplus)
}
#endif

#endif

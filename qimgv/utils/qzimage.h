#pragma once

#ifdef USE_ZIG_DECODE

#include <QImage>
#include <memory>
#include "qimgv_core.h"

// The one place that knows both sides of the boundary. A qimg_bitmap is only
// ever owned by a QImage whose cleanup function frees it with the Zig free, so
// there is exactly one allocation and one free per decoded image.
namespace QzImage {
    // Wraps `bmp` in a QImage that owns it. `bmp` is taken over on success and
    // left untouched on failure.
    std::unique_ptr<QImage> takeImage(qimg_bitmap &bmp);

    // Free a bitmap that was not wrapped (error paths, tests).
    void release(qimg_bitmap &bmp);
}

#endif

#ifdef USE_ZIG_DECODE

#include "qzimage.h"
#include <QDebug>

namespace {
    // Frees the pixels through the Zig allocator and destroys the descriptor.
    // Used as the QImage cleanup function, and as the guard before the QImage
    // exists — the same free either way.
    void freeBitmap(void *info) {
        auto *bmp = static_cast<qimg_bitmap *>(info);
        qimg_bitmap_free(bmp);
        delete bmp;
    }

    // Owns a descriptor until the QImage takes it over.
    struct BitmapOwner {
        explicit BitmapOwner(const qimg_bitmap &src) : bmp(new qimg_bitmap(src)) {}
        ~BitmapOwner() { if(bmp) freeBitmap(bmp); }
        BitmapOwner(const BitmapOwner &) = delete;
        BitmapOwner &operator=(const BitmapOwner &) = delete;
        qimg_bitmap *release() {
            qimg_bitmap *out = bmp;
            bmp = nullptr;
            return out;
        }
        qimg_bitmap *bmp;
    };

    QImage::Format qtFormat(int32_t fmt) {
        switch(fmt) {
            case QIMG_FMT_GRAY8: return QImage::Format_Grayscale8;
            case QIMG_FMT_RGB888: return QImage::Format_RGB888;
            default: return QImage::Format_Invalid;
        }
    }
}

std::unique_ptr<QImage> QzImage::takeImage(qimg_bitmap &bmp) {
    if(!bmp.data || bmp.w == 0 || bmp.h == 0)
        return nullptr;
    const QImage::Format fmt = qtFormat(bmp.fmt);
    if(fmt == QImage::Format_Invalid) {
        qWarning() << "QzImage: unknown pixel format" << bmp.fmt;
        return nullptr;
    }

    BitmapOwner owner(bmp);
    bmp = qimg_bitmap{};
    // Released before the constructor runs: the QImage takes the descriptor as
    // its cleanup info, so the argument order must not matter.
    qimg_bitmap *raw = owner.release();
    // Qt calls the cleanup function exactly once, on the last copy, so the
    // QImage's destructor is the free. The guard covered a throwing operator new.
    std::unique_ptr<QImage> image(new QImage(raw->data, static_cast<int>(raw->w),
                                             static_cast<int>(raw->h),
                                             static_cast<qsizetype>(raw->stride),
                                             fmt, freeBitmap, raw));
    return image;
}

void QzImage::release(qimg_bitmap &bmp) {
    qimg_bitmap_free(&bmp);
    bmp = qimg_bitmap{};
}

#endif

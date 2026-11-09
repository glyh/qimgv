// Compares the Zig decode slice against Qt's own decode, byte for byte.
//
// Build and run through scripts/zig-decode-check.sh, which finds the archive
// built by `zig build -Dzig-decode=true`. Exists because the slice's grading is
// "no regression": same files open, same pixels.
//
// Exit status: 0 when every file Qt could read produced identical pixels;
// 1 on a size/pixel mismatch or a decode error (fallbacks are reported, not
// failed - they are other formats, or files Qt fails on as well).

#include "qimgv_core.h"

#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QString>

#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv) {
    int checked = 0, mismatched = 0, fellBack = 0, failed = 0;

    for (int i = 1; i < argc; ++i) {
        const QString path = QString::fromLocal8Bit(argv[i]);
        if (!QFileInfo(path).isFile()) {
            fprintf(stderr, "not a file: %s\n", argv[i]);
            failed++;
            continue;
        }

        // What the viewer does today. No auto-transform: qimgv applies EXIF
        // rotation itself, from DocumentInfo.
        QImageReader reader(path);
        reader.setAutoTransform(false);
        reader.setAllocationLimit(0);
        const QImage qt = reader.read();
        if (qt.isNull()) {
            printf("qt-fail   %s\n", argv[i]);
            continue;
        }

        qimg_bitmap bmp = qimg_bitmap{};
        const int32_t rc = qimg_decode(argv[i], 0, 0, &bmp);
        if (rc != QIMG_OK) {
            char detail[192] = {0};
            qimg_status_detail(detail, sizeof detail);
            printf("fallback  %s (rc=%d: %s)\n", argv[i], rc, detail);
            fellBack++;
            continue;
        }

        const QImage::Format want =
            (bmp.fmt == QIMG_FMT_GRAY8) ? QImage::Format_Grayscale8 : QImage::Format_RGB888;
        const QImage zig(bmp.data, static_cast<int>(bmp.w), static_cast<int>(bmp.h),
                         static_cast<qsizetype>(bmp.stride), want);
        const QImage zigCopy = zig.copy(); // deep copy before the Zig free
        qimg_bitmap_free(&bmp);

        const QImage ref = qt.convertToFormat(want);
        if (ref.size() != zigCopy.size()) {
            printf("size      %s: qt=%dx%d zig=%dx%d\n", argv[i], ref.width(), ref.height(),
                   zigCopy.width(), zigCopy.height());
            mismatched++;
            continue;
        }

        const int channels = (want == QImage::Format_Grayscale8) ? 1 : 3;
        long differing = 0, worst = 0;
        for (int y = 0; y < ref.height(); ++y) {
            const uchar *a = ref.constScanLine(y);
            const uchar *b = zigCopy.constScanLine(y);
            const int n = ref.width() * channels;
            for (int x = 0; x < n; ++x) {
                const long d = labs(static_cast<long>(a[x]) - static_cast<long>(b[x]));
                if (d) differing++;
                if (d > worst) worst = d;
            }
        }
        if (differing) {
            printf("pixels    %s: %ld differ, max delta %ld\n", argv[i], differing, worst);
            mismatched++;
        }
        checked++;
    }

    printf("\nidentical=%d mismatched=%d fell_back=%d failed=%d\n", checked, mismatched, fellBack,
           failed);
    return (mismatched == 0 && failed == 0) ? 0 : 1;
}

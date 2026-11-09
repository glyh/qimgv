#pragma once

class QAbstractScrollArea;

// In-tree benchmark probe (ticket #8 / #6).
//
// Inert unless QIMGV_BENCH=1: no timers, no file, no allocation, no behaviour change.
// When enabled it appends TSV rows "<kind>\t<seq>\t<ms>" to $QIMGV_BENCH_OUT
// (default /tmp/qimgv-bench.tsv), ms measured from Bench::start() in main().
//
// $QIMGV_BENCH_PLAN drives input so the run is reproducible without a compositor:
//   open        open the first image as soon as the grid is interactive
//   scroll:N    post N wheel steps into the grid, 16 ms apart
//   step:N      open the first image, then post N nextImage keys, 200 ms apart
class Bench {
public:
    static void start();
    static bool on();
    static void mark(const char *name);   // first occurrence only
    static void watchGrid(QAbstractScrollArea *view);   // ThumbnailView: paint + input target
    static void watchViewer(QAbstractScrollArea *view); // ImageViewerV2: paint + input target
    static void imageShown(int pathId = 0); // a new pixmap was just handed to the viewer
};

# On-screen tests (local development only)

These exercise qimgv on a **real display** — the window has to be mapped and exposed for
Qt to deliver paint events at all. They are deliberately not part of CI and not installed:
the CI workflows run headless, and the offscreen baseline harness (`scripts/bench/bench.py`)
exists for numbers.

Use them when you touch the UI, the viewer, the folder grid, or the paint paths, and you
want to know that something is actually drawn — not merely that the code ran.

```
./scripts/devtest/onscreen.py            # all scenarios, needs $DISPLAY or $WAYLAND_DISPLAY
./scripts/devtest/onscreen.py grid-scroll
```

Each scenario prints PASS/FAIL with the numbers it judged, saves a screenshot per step
into `--shots DIR`, and the script exits non-zero if any scenario fails.

Why they are separate from the baseline: the baseline must be reproducible on a machine
with no display, so it measures markers (pixmap handed to the viewer) and not frames.
These tests measure frames, and therefore need a screen.

What they cover, and what they cannot:

* `frames-differ` compares screenshot hashes, so it catches "the code ran but nothing was
  drawn" -- the failure mode a headless test cannot see.
* `grid-scroll` and `view-toggle` prove scrolling renders (paints happen, the scrollbar
  moves). They do **not** measure frame pacing: `QGraphicsView` blits on scroll and
  `viewport()->repaint()` is a no-op, so pacing needs a compositor-side timestamp.
* `image-step` catches a stalled viewer; its per-step ms is the probe's own marker, not
  a compositor frame time.

Two traps this harness already hit, worth keeping in mind when extending it:

* There are **two** `ThumbnailView` instances (folder grid and thumbnail strip).
  `currentGrid()` prefers the `FolderGridView`; driving the strip does nothing.
* Never call `QWidget::grab()` from inside a paint event. It re-enters the event loop and
  hangs the app; screenshots are deferred to the next event-loop turn for that reason.

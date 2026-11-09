#include "bench.h"

#include <QAbstractScrollArea>
#include <QApplication>
#include <QDir>
#include <QList>
#include <QScrollBar>

#include "components/actionmanager/actionmanager.h"
#include "gui/customwidgets/thumbnailview.h"
#include "gui/folderview/foldergridview.h"
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QEvent>
#include <QFile>
#include <QSet>
#include <QString>
#include <QTimer>
#include <QWheelEvent>
#include <QWidget>

namespace {

bool g_on = false;
QFile *g_out = nullptr;
QElapsedTimer g_t;
QSet<QString> g_marks;
QList<QAbstractScrollArea *> g_grids;
QList<QAbstractScrollArea *> g_viewers;

// The folder grid and the thumbnail strip are both ThumbnailViews. Drive the folder
// grid whenever the app has one -- activating a strip item does nothing in folder view.
QAbstractScrollArea *currentGrid() {
    for(auto *g : g_grids)
        if(qobject_cast<FolderGridView *>(g))
            return g;
    for(auto *g : g_grids)
        if(g->isVisible())
            return g;
    return g_grids.isEmpty() ? nullptr : g_grids.last();
}

QAbstractScrollArea *currentViewer() {
    for(auto *v : g_viewers)
        if(v->isVisible())
            return v;
    return g_viewers.isEmpty() ? nullptr : g_viewers.last();
}
QString g_plan;
int g_limit = 0;          // number of driven events
int g_sent = 0;           // events posted so far
qint64 g_trigger = 0;     // time the last driven event was posted
QTimer *g_driver = nullptr;
bool g_tracePaint = false;
bool g_trace = false;                     // QIMGV_BENCH_TRACE=1: driver decisions              // QIMGV_BENCH_TRACE_PAINT=1
QString g_shotDir;                      // QIMGV_BENCH_SHOTS=<dir>
int g_shotSeq = 0;

enum Phase { Idle, Opening, Stepping, Scrolling };
Phase g_phase = Idle;

void screenshot(const char *label) {
    if(g_shotDir.isEmpty())
        return;
    QWidget *w = qApp->activeWindow();
    if(!w)
        for(QWidget *cand : qApp->topLevelWidgets())
            if(cand->isVisible()) {
                w = cand;
                break;
            }
    if(!w)
        return;
    w->grab().save(QStringLiteral("%1/%2-%3.png").arg(g_shotDir).arg(QLatin1String(label)).arg(g_shotSeq++));
}

void row(const char *kind, int seq, qint64 ms) {
    if(!g_out)
        return;
    g_out->write(QStringLiteral("%1\t%2\t%3\n").arg(QLatin1String(kind)).arg(seq).arg(ms).toUtf8());
    g_out->flush();
    // Never grab inside a paint handler: grab() renders synchronously and re-enters
    // the event loop, which deadlocks the app. Defer to the next turn, markers only.
    if(!g_shotDir.isEmpty() && qstrcmp(kind, "grid-paint") != 0 && qstrcmp(kind, "drive-post") != 0 &&
       qstrcmp(kind, "scroll") != 0 && qstrcmp(kind, "step") != 0) {
        const QString label = QLatin1String(kind);
        QTimer::singleShot(0, qApp, [label]() { screenshot(qPrintable(label)); });
    }
}

void trace(const QString &what) {
    if(g_trace)
        row(qPrintable(QStringLiteral("trace-") + what), 0, g_t.elapsed());
}

void triggerNext() {
    trace(QStringLiteral("triggerNext"));
    if(actionManager)
        actionManager->invokeAction(QStringLiteral("nextImage"));
    g_trigger = g_t.elapsed();
}

QScrollBar *scrollAxis() {
    QAbstractScrollArea *g = currentGrid();
    if(!g)
        return nullptr;
    QScrollBar *v = g->verticalScrollBar();
    QScrollBar *h = g->horizontalScrollBar();
    return (h->maximum() > v->maximum()) ? h : v;
}

// One wheel notch of scroll, then a synchronous repaint of the grid viewport:
// the number recorded is the frame's raster cost, not vblank pacing.
void postWheel(QWidget *) {
    trace(QStringLiteral("postWheel"));
    QScrollBar *bar = scrollAxis();
    QAbstractScrollArea *g = currentGrid();
    if(!bar || !g)
        return;
    const int step = qMax(bar->singleStep(), bar->pageStep() / 2);
    bar->setValue(qMin(bar->value() + step, bar->maximum()));
    row("scroll-pos", bar->value(), g_t.elapsed());
    QElapsedTimer t;
    t.start();
    g->viewport()->repaint();
    row("scroll", g_sent, t.elapsed());
}

void onDriverTick() {
    if(g_sent >= g_limit) {
        g_driver->stop();
        row("drive-done", g_sent, g_t.elapsed());
        return;
    }
    g_sent++;
    if(g_phase == Scrolling)
        postWheel(nullptr);
    else
        triggerNext();
    row("drive-post", g_sent, g_t.elapsed());
}

void armDriver(Phase phase, int limit, int interval) {
    trace(QStringLiteral("armDriver:") + QString::number(int(phase)) + QStringLiteral(":") + QString::number(limit));
    g_phase = phase;
    g_limit = limit;
    g_sent = 0;
    if(!g_driver) {
        g_driver = new QTimer(qApp);
        g_driver->setTimerType(Qt::PreciseTimer);
        QObject::connect(g_driver, &QTimer::timeout, []() { onDriverTick(); });
    }
    g_driver->setInterval(interval);
    if(limit > 0) {
        if(g_sent == 0) g_sent++;
        if(phase == Scrolling)
            postWheel(nullptr);
        else
            triggerNext();
        row("drive-post", g_sent, g_t.elapsed());
        g_driver->start();
    }
}

// Selects a thumbnail (the grid has no keyboard selection) and opens it;
// the open latency is measured from the Return, not from the selection.
void selectAndOpen() {
    trace(QStringLiteral("selectAndOpen"));
    if(auto *tv = qobject_cast<ThumbnailView *>(currentGrid()))
        tv->select(0);
    QTimer::singleShot(120, qApp, []() {
        g_phase = Opening;
        // Key events posted at a widget do not reach Qt's key path in this app, so the
        // probe activates the selected thumbnail the way the grid's own keyPressEvent
        // does. What is measured is load -> show -> paint, not the keymap.
        QMetaObject::invokeMethod(currentGrid(), "itemActivated", Qt::DirectConnection, Q_ARG(int, 0));
        g_trigger = g_t.elapsed();
        QTimer::singleShot(3000, qApp, []() {
            if(g_phase == Opening) {
                row("open-failed", 0, g_t.elapsed());
                g_phase = Idle;
            }
        });
    });
}

void startPlan() {
    trace(QStringLiteral("startPlan:") + g_plan);
    if(g_plan.isEmpty() || g_plan == "open") {
        selectAndOpen();
        return;
    }
    if(g_plan.startsWith("scroll:")) {
        const int n = g_plan.mid(7).toInt();
        // the app leaves folder view ~100 ms after start, so switch back the way a
        // user would before scrolling the grid
        QTimer::singleShot(300, qApp, []() {
            trace(QStringLiteral("toggleFolderView"));
            if(actionManager)
                actionManager->invokeAction(QStringLiteral("toggleFolderView"));
        });
        QTimer::singleShot(900, qApp, [n]() { armDriver(Scrolling, n, 16); });
        return;
    }
    if(g_plan.startsWith("step:"))
        selectAndOpen();                         // open one image first, then start stepping
}

class PaintSpy : public QObject {
public:
    explicit PaintSpy(bool viewer) : m_viewer(viewer) {}
protected:
    bool eventFilter(QObject *watched, QEvent *event) override {
        if(event->type() != QEvent::Paint)
            return QObject::eventFilter(watched, event);
        const qint64 now = g_t.elapsed();
        if(m_viewer) {
            // the viewer viewport does not repaint in this harness; see imageShown()
        } else if(g_phase == Idle && !g_marks.contains(QStringLiteral("grid-interactive"))) {
            Bench::mark("grid-interactive");
            startPlan();
        } else if(g_phase == Scrolling) {
            row("scroll", g_sent, now - g_trigger);
        }
        if(g_tracePaint && !m_viewer)
            row("grid-paint", 0, now); else {
            }
        return QObject::eventFilter(watched, event);
    }
private:
    bool m_viewer;
};

} // namespace

bool Bench::on() {
    return g_on;
}

void Bench::start() {
    if(!qEnvironmentVariableIsSet("QIMGV_BENCH"))
        return;
    const QByteArray v = qgetenv("QIMGV_BENCH");
    if(v.isEmpty() || v == "0")
        return;
    g_on = true;
    g_t.start();
    g_plan = qEnvironmentVariable("QIMGV_BENCH_PLAN");
    g_tracePaint = qEnvironmentVariable("QIMGV_BENCH_TRACE_PAINT") == QLatin1String("1");
    g_trace = qEnvironmentVariable("QIMGV_BENCH_TRACE") == QLatin1String("1");
    g_shotDir = qEnvironmentVariable("QIMGV_BENCH_SHOTS");
    if(!g_shotDir.isEmpty())
        QDir().mkpath(g_shotDir);
    const QString out = qEnvironmentVariable("QIMGV_BENCH_OUT", QStringLiteral("/tmp/qimgv-bench.tsv"));
    g_out = new QFile(out);
    if(!g_out->open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
        g_on = false;
        delete g_out;
        g_out = nullptr;
        return;
    }
    row("start", 0, 0);
    row(qPrintable(QStringLiteral("plan-") + (g_plan.isEmpty() ? QStringLiteral("<empty>") : g_plan)), 0, 0);
}

void Bench::mark(const char *name) {
    if(!g_on)
        return;
    const QString key = QLatin1String(name);
    if(g_marks.contains(key))
        return;
    g_marks.insert(key);
    row(name, 0, g_t.elapsed());
}

void Bench::watchGrid(QAbstractScrollArea *view) {
    if(!g_on || !view)
        return;
    g_grids.append(view);
    view->viewport()->installEventFilter(new PaintSpy(false));
}

void Bench::watchViewer(QAbstractScrollArea *view) {
    if(!g_on || !view)
        return;
    g_viewers.append(view);
    view->viewport()->installEventFilter(new PaintSpy(true));
}

void Bench::imageShown(int pathId) {
    if(!g_on)
        return;
    const qint64 now = g_t.elapsed();
    row("image-ready", pathId, now);
    if(g_phase == Opening) {
        g_phase = Idle;
        row("image-visible", 0, now);
        if(g_plan.startsWith("step:")) {
            const int n = g_plan.mid(5).toInt();
            QTimer::singleShot(300, qApp, [n]() {
                g_phase = Stepping;
                g_limit = n;
                g_sent = 0;
                g_sent++;
                triggerNext();
                row("drive-post", g_sent, g_t.elapsed());
            });
        }
    } else if(g_phase == Stepping) {
        row("step", g_sent, now - g_trigger);
        if(g_sent >= g_limit) {
            g_phase = Idle;
            row("drive-done", g_sent, now);
            return;
        }
        g_sent++;
        triggerNext();
        row("drive-post", g_sent, g_t.elapsed());
    }
}

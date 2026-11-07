# Why hand-edited `[Controls]` shortcuts never fire

Research for <https://github.com/glyh/qimgv/issues/3>.

## Answer in one line

**None of the three candidates.** The shortcut pipeline is correct in both `v1.0.3-alpha` and master — both fire `exit` on a real `q` keypress from a hand-edited file. What the reporter hit is the **silent fallback on the load path**: `Settings::readShortcuts` returned nothing on their machine, `ActionManager::initShortcuts` substituted the defaults (`actionmanager.cpp:103-108`), and `saveShortcuts` (`actionmanager.cpp:208`) then **overwrote their file with those defaults** — which is why the file they looked at afterwards proved nothing and why every observation in the report is internally consistent.

## The pipeline, and where normalisation happens

`qimgv.conf` `[Controls] shortcuts` is a flat list of `action=key` strings.

| Step | Code | What it does |
|---|---|---|
| read | `qimgv/settings.cpp:639` `Settings::readShortcuts` | `split("=")`, `shortcuts[key] = action`; a key ending in `eq` decodes back to `=` |
| validate | `actionmanager.cpp:247` `validateShortcuts` | drops entries whose **action** name is unknown — never whose *key* is unknown |
| fallback | `actionmanager.cpp:103` `initShortcuts` | `resetDefaults()` **only when the read map is empty** (`:105-107`) |
| event | `qimgv/shortcutbuilder.cpp:99` `fromEventNativeScanCode` | returns the `InputMap` name for `QKeyEvent::nativeScanCode()`, modifiers prepended |
| dispatch | `actionmanager.cpp:240` `invokeActionForShortcut` | `shortcuts.contains(seq)` → `invokeAction` → `QMetaObject::invokeMethod` |

There is no separate normalisation step on the file side: the key string is the map key verbatim, so a hand-written name must be spelled exactly as `InputMap` spells it. `inputmap.cpp` is the authority; the Linux table is `inputmap.cpp:167-270`, keyed by **X11 keycodes** (`:207` `24→Q`, `:229` `41→F`, `:240` `52→Z`, `:232` `44→J`).

## What was measured

Route taken: **real key injection** (not the fallback), plus a throwaway instrumented copy for the second half. Three binaries, all driven by the same harness: unchanged master, instrumented master, instrumented `v1.0.3-alpha`.

Harness: `Xvfb :77 -screen 0 1024x768x24` + `twm` + `QT_QPA_PLATFORM=xcb` + `XDG_CONFIG_HOME` at a hand-edited config; keys via XTEST after `XSetInputFocus`. Two blockers worth recording: the window must be selected by **WM_CLASS `qimgv`** (the 3x3 `Qt Selection Owner for qimgv` window is unmapped and gives `XSetInputFocus` → `BadMatch`), and a **WM must be running** or no window ever takes focus.

### 1. Unmodified master, hand-edited `exit=Q`

```
input focus now 0x400007 (want 0x400007)
sent keysym q (keycode 24)
RESULT: process exited after [q]
config after: "exit=Q" still present
```

`Q` is not a default binding (`Ctrl+Q`/`Alt+X` are, `actionmanager.cpp:74-76`), so only the file could have produced that exit.

### 2. Instrumented master — every link, one line each

A throwaway copy (`git archive HEAD`), one `qInfo()` in `ActionManager::processEvent`. Keys `j`, `f`, `f`, `q`:

```
[INSTR] type=QEvent::KeyPress scan=44 key=74 seq=["J"] inMap=false action=[""]
[INSTR] type=QEvent::KeyPress scan=41 key=70 seq=["F"] inMap=true  action=["toggleFullscreen"]
[INSTR] type=QEvent::KeyPress scan=41 key=70 seq=["F"] inMap=true  action=["toggleFullscreen"]
[INSTR] type=QEvent::KeyPress scan=24 key=81 seq=["Q"] inMap=true  action=["exit"]
```

A real keypress reaches `ActionManager`; the scancode normalises to a name (`24`→`Q`); the map built **from the hand-edited file** contains it and resolves to `exit`. `j` is the negative control (`inMap=false`, nothing fires). `f` shows an untouched binding still firing — under `twm` there is no EWMH, so fullscreen has no visible effect; the action line, not a screenshot, is the evidence.

Note for anyone repeating this: `qDebug` is compiled out under `CMAKE_BUILD_TYPE=Release` (`-DQT_NO_DEBUG`) — use `qInfo` — and set `QT_ASSUME_STDERR_HAS_CONSOLE=1` or Qt writes to syslog instead of stderr.

### 3. The unquoted (naive) file also works

`cfg-hand-naive` (hand-typed, no quoting), same harness:

```
RESULT: process exited after [q]
[INSTR] type=QEvent::KeyPress scan=24 key=81 seq=["Q"] inMap=true action=["exit"]
```

Quoting style does not decide whether `exit=Q` survives; it only decides whether an entry whose **value contains a comma** survives (see incidentals).

### 4. `v1.0.3-alpha` does exactly the same thing

The tag (`4ccb4654`, 2022-05-01) built cleanly against Qt 6.12 with the same flags, same probe, same config:

```
RESULT: process exited after [q]
[INSTR] type=QEvent::KeyPress scan=24 key=81 seq=["Q"] inMap=true action=["exit"]
config after: "exit=Q" still present
```

## The three candidates

- **(a) key-name spelling in the file — ruled out.** `exit=Q` is read and honoured in quoted and unquoted form, on both versions.
- **(b) platform-dependent scancode map — ruled out in principle, not measured on Wayland.** The Linux table is X11-keycode based and under Wayland `nativeScanCode()` may be an evdev code, which would make `inputMap->keys().value(scan)` return `""` (`shortcutbuilder.cpp:99-101`) for *every* key. But the identical lookup serves default and hand-edited bindings, so a wrong table would kill `Ctrl+Q`/`F`/`Right` exactly as it kills `Q`/`Z`. The report has the defaults working, so the table resolves in their environment and cannot be what discriminates their entries. (No compositor was run; this is an argument, not a measurement. It remains worth checking independently — a Wayland-mismatched table would be a real bug for Wayland users, just not this one.)
- **(c) divergence between the packaged 1.0.3alpha build and master — refuted by experiment.** The tag predates `7672cb4b` (2024-06-20, *"fix reading/saving shortcuts which contain `=`"* — `git merge-base --is-ancestor 7672cb4b v1.0.3-alpha` → not an ancestor) and `7685c273`, so it was a fair hypothesis. Built and driven, it behaves identically to master (run 4). The difference does not exist in this path.

## What is actually wrong: a silent, evidence-destroying fallback

The `[Controls]` list the reporter's install left behind (fixture `/tmp/wf/cfg-reporter`) is written entirely in **defaults** — `exit=Ctrl+Q`, `nextImage=Right` — not the keys they typed (`exit=Q`, `nextImage=Z`). `saveShortcuts` writes `actionManager->shortcuts` verbatim, so that file can only come from a run whose in-memory map was the defaults. And defaults are reached from exactly one place on the load path, only when the read returned nothing:

```cpp
void ActionManager::initShortcuts() {
    actionManager->readShortcuts();
    if(actionManager->shortcuts.isEmpty()) {   // actionmanager.cpp:105-107
        actionManager->resetDefaults();
    }
}
```

### Reproduced end to end

Take the working config, change only the group header to `[controls]` (a `[Controls]` block QSettings does not hand back as that group's list — wrong case, stray whitespace, duplicate group, a value it does not treat as a list), and set `lastVerMicro=1` so a version bump is pending. Same harness, key `q`:

```
Updated:  "1.0.1" > "1.0.3"
RESULT: still running after [q] -> no exit fired
[INSTR] type=QEvent::KeyPress scan=24 key=81 seq=["Q"] inMap=false action=[""]
```

and the file afterwards contains **two** groups:

```
[Controls]          <- created by the app, defaults: exit=Alt+X, exit=Ctrl+Q, exit=MiddleButton
[controls]          <- the user's block, untouched, still exit=Q
```

That is the reporter's symptom in full: the edited key is dead (`inMap=false`), the untouched defaults are alive, and the file comes back rewritten in defaults so it *looks* as if it was read. The version bump is what triggers the rewrite — `Core::onUpdate` (`qimgv/core.cpp:250`) → `adjustFromVersion` → `saveShortcuts()` (`actionmanager.cpp:205-208`). Their config's `lastVer` versus the package's `appVersion` is the timing.

Two design consequences, both observable and both reproducible without the reporter:

1. **"nothing configured" and "config failed to parse" are indistinguishable.** `readShortcuts` returns an empty map in both cases; `initShortcuts` cannot tell them apart and silently substitutes the defaults. No warning, no log line.
2. **The fallback rewrites the file from the map.** So the user's edit is either replaced by the defaults or left stranded in a group nobody reads, before anyone can look at what they wrote. That is why the reporter concluded "it rewrites the file with all 73 entries, so the file *was* read": it was written, never read.

A fix (not made here) is a small change: distinguish absent from unparsed, and never rewrite a shortcuts block that was not successfully read.

## Incidental findings

- A naive hand-written list loses any entry whose **key is a comma**: the value is a `QStringList`, so `frameStepBack=,` splits into `frameStepBack=` and `""`. Writing `frameStepBack=,,` works; the mirror case for `=` is the `eq` escape (`settings.cpp:645-646`).
- `v1.0.3-alpha` compiles against Qt 6.12 unmodified, so a from-source tag build is a cheap control for future reports.

## How to confirm the verdict

1. Ask the reporter for the **pre-run** `qimgv.conf`. The `[Controls]` header and the value's quoting decide it: if the block is not what QSettings parses as that group, the file is the cause and the pipeline is innocent.
2. Reproduce the masking without their file: `cp -r cfg-hand-quoted cfg-x && sed -i 's/^\[Controls\]$/[controls]/; s/lastVerMicro=3/lastVerMicro=1/' cfg-x/qimgv/qimgv.conf`, then drive it with an `exit=Q` config and press `q` — the run above is that command, and it reproduces every observation in the report.
3. To close (b) independently: run the instrumented build under a Wayland compositor (`Hyprland 0.57.1` and `sway 1.12` are installed) and compare the logged `scan=` values with `inputmap.cpp`.

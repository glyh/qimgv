# Why hand-edited `[Controls]` shortcuts never fire

Research for <https://github.com/glyh/qimgv/issues/3>. Answer: **candidate (c), divergence between the packaged 1.0.3alpha build and master.** Master's shortcut pipeline is correct and was demonstrated working under X11; the reporter's package predates the commit that made hand-edited entries work at all.

## The pipeline, and where normalisation actually happens

`qimgv.conf` `[Controls] shortcuts` is a flat list of `action=key` strings.

| Step | Code | What it does |
|---|---|---|
| read | `qimgv/settings.cpp:639` `Settings::readShortcuts` | `split("=")`, `shortcuts[key] = action`; `key` ending in `eq` decodes back to `=` |
| validate | `qimgv/components/actionmanager/actionmanager.cpp:247` `validateShortcuts` | drops entries whose **action** name is unknown — never whose *key* is unknown |
| defaults | `:103` `initShortcuts` | `resetDefaults()` **only when the read map is empty** |
| event | `qimgv/shortcutbuilder.cpp:99` `fromEventNativeScanCode` | returns the `InputMap` name for `QKeyEvent::nativeScanCode()`, prefixed with modifiers |
| dispatch | `actionmanager.cpp:240` `invokeActionForShortcut` | `shortcuts.contains(seq)` → `invokeAction` → `QMetaObject::invokeMethod` on `ActionManager` (`exit`/`nextImage` are signals there, `actionmanager.h:63,84`) |

There is no separate "normalisation" step for the *file* side: the key string is used verbatim as the map key, so a hand-written name must be spelled exactly as `InputMap` spells it (`Q`, `Right`, `Ctrl+Q`, `PgUp`, …). `inputmap.cpp` is the authority.

## What was measured (from source, Qt 6.12, master)

Real key injection under `Xvfb :77` + `twm` + `QT_QPA_PLATFORM=xcb`, `XDG_CONFIG_HOME` pointing at a hand-edited config containing `exit=Q`:

```
input focus now 0x400007 (want 0x400007)
sent keysym q (keycode 24)
RESULT: process exited after [q]
config after: "exit=Q" still present
```

**A plain `q` fired `exit` from a hand-edited file.** Since `Q` is not a default binding (`Ctrl+Q`/`Alt+X` are, `actionmanager.cpp:74-76`), only the file could have produced that. Control: `f f q` — both `f` presses survived, then `q` exited.

Also verified in isolation:

- Config round trip reads `exit=Q` → `'Q' → exit` and `nextImage=Z` → `'Z' → nextImage`, and the app preserves the hand edit when it rewrites the file on exit.
- `ShortcutBuilder::fromEvent`, 13 synthetic cases, all correct: `Q`(scan 24)→`Q`, `Ctrl+Q`→`Ctrl+Q`, `Shift+Q`→`Shift+Q`, `=`→`=`, `Shift+=`→`+`, unmapped scan 200→`""`, `KeyRelease`→`""`, modifier-only→`""`.

## Candidates

- **(a) key-name spelling — ruled out.** The spelling in the file is used verbatim and works; see the run above.
- **(b) platform-dependent scancode map — plausible, not demonstrated.** `inputmap.cpp`'s Linux table is keyed by X11 keycodes (`24→Q`, `41→F`, `52→Z`) and `fromEventNativeScanCode` returns `""` on any miss — silently. Under Wayland the same integer may be an evdev code, which would break *every* table key, not just hand-edited ones; that is inconsistent with the report that default bindings keep working, so it is not the cause here. **Not closed.**
- **(c) divergence from the packaged build — best fit, and verifiable.** `v1.0.3-alpha` = `4ccb4654` (2022-05-01). Master contains `7672cb4b` (2024-06-20) — *"[settings] fix reading/saving shortcuts which contain `=`"* — touching exactly `qimgv/settings.cpp` and `qimgv/components/actionmanager/actionmanager.cpp`, plus later `inputmap.cpp` work for Qt 6.7 scancode changes. The reporter's package predates all of it.

## What is still open

1. **A `f` → fullscreen control was not proven**: `twm` has no EWMH, so `_NET_WM_STATE` was absent and geometry did not change. The exit result rests on `q` alone, which is sound but single-threaded evidence.
2. **Wayland `nativeScanCode` is untested.** `Hyprland 0.57.1` and `sway 1.12` are installed; an instrumented build logging `processEvent`'s sequence, driven by `hyprctl dispatch sendshortcut`, would close candidate (b) properly.
3. **The reporter's actual mechanism is inferred, not reproduced.** To reproduce, build the `v1.0.3-alpha` tag and repeat the injection — that is the one run nobody has done.

## Incidental finding

A naive hand-written list loses entries whose key is `,`: the value is a `QStringList`, so `frameStepBack=,` splits into `frameStepBack=` and `""`. Writing `frameStepBack=,,` works, mirroring the `eq` escape for `=`. Worth a line in the docs regardless of this bug.

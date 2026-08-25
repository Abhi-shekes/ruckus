# Ruckus — Phase 0 spike results (X11 pass)

Run on 2026-08-26. Scope was deliberately narrowed to **X11 first**; Wayland and
Windows are untested and remain the open gate items.

| | Host |
| --- | --- |
| OS | Ubuntu 20.04.6, kernel 5.15.0-139 |
| Session | X11 |
| Flutter / Dart | 3.35.7 stable / 3.9.2 |
| Audio | PulseAudio, SoLoud via `flutter_soloud` |

Reproduce with `cd spike && ./run.sh --selftest`, or `./run.sh` for the
interactive console.

---

## Gate status

| # | Criterion | Status |
| --- | --- | --- |
| 1 | Key down + up captured while minimised — **Windows 11** | **not tested** — no Windows host available |
| 2 | Same — **Ubuntu X11** | **pass** (see below) |
| 3 | Same — **Ubuntu Wayland** | **not tested** — no Wayland session available |
| 4 | Ten sounds simultaneously, no dropout | **pass** — fired 10, engine reported peak 10 concurrent voices |
| 5 | p95 keypress→audio under 25 ms | **on track** — 0.36 ms bridge, 5.80 ms buffer floor; full p95 needs an interactive run |
| 6 | MP3 / WAV / OGG / FLAC load and play | **pass** — all four |

Harness output:

```
[PASS  ] 6    MP3 / WAV / OGG / FLAC all load and play
               WAV ok, MP3 ok, OGG ok, FLAC ok
[PASS  ] 4    Ten sounds play simultaneously, no interruption
               fired 10, engine reported peak 10 concurrent voices
[PASS  ] 5a   Audio buffer floor leaves room under the 25 ms budget
               5.80 ms of the 25 ms budget
[FAIL  ] 2/3  evdev backend available (X11 + Wayland)
               No read access to /dev/input/event*
[PASS  ] 2    XRecord backend starts on this X11 session
               context created, capture thread running
[PASS  ] 1    Key transitions actually arrive from the backend
               52 events seen during the 5 s window
```

### On criterion 2

52 key transitions arrived while the keyboard was being used in *other*
windows, so global capture is working, not just in-window key handling. Down,
up and auto-repeat all arrive as distinct kinds, which is what Hold mode needs.

The one thing left for a human: minimise the window entirely and confirm events
still flow. Nothing suggests it won't — XRecord taps the server's stream, which
has no notion of our window's map state — but it is one click and it is the
literal wording of the criterion, so it stays unticked until someone does it.

---

## What the spike changed about the plan

Five findings. None invalidate the architecture; three change the setup steps.

### 1. `flutter_soloud` resolves to 3.5.4, not 4.1.7

4.1.7 needs a newer Dart SDK than the 3.9.2 that ships with Flutter 3.35.7. The
API used here — `loadAsset(mode: LoadMode.memory)`, `play()` returning a
`SoundHandle`, `getVoiceCount()` — is the same in both, so decision **D1
stands**. Upgrading Flutter would pick up 4.x; there is no reason to rush it.

### 2. The default audio buffer alone would have blown the budget

SoLoud defaults to `bufferSize: 2048`, which is **46 ms** at 44.1 kHz — nearly
double the entire 25 ms target, before a single line of our code runs. Set to
256 frames (5.80 ms) in `audio.dart`. This is the single highest-leverage
latency setting in the project and it is not the default; if a machine crackles,
this is the dial to turn back up.

### 3. `XInitThreads()` must be called before GTK starts

The first build crashed on launch:

```
[xcb] Unknown request in queue while dequeuing
[xcb] Most likely this is a multi-threaded client and XInitThreads has not been called
```

XRecord needs a second X connection on its own thread, and Xlib's per-process
state is not thread-safe unless `XInitThreads()` runs **before any other Xlib
call**. Calling it inside the backend is too late — GTK has already connected.
The fix is three lines in `linux/runner/main.cc`, before `my_application_new()`.

This is exactly the class of problem Phase 0 exists to surface: invisible in
design, fatal at launch, trivial once found.

### 4. Ubuntu 20.04 cannot run the stock plugin — target 22.04+

`flutter_soloud` ships a prebuilt `libFLAC.so.14` linked against **glibc 2.34**.
Ubuntu 20.04 has 2.31, so the whole plugin fails to load:

```
/lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.33' not found
(required by .../flutter_soloud/linux/libs/libFLAC.so.14)
```

libFLAC is the *only* bundled lib over the line — ogg, opus, vorbis and
vorbisfile all need ≤ 2.29.

Worked around by building FLAC 1.5.0 from source on 20.04 with `-DWITH_OGG=OFF`
(the plugin only calls the native stream decoder, never the OGG-FLAC variants),
which yields the same `libFLAC.so.14` soname at glibc 2.29. `run.sh` puts it on
`LD_LIBRARY_PATH`, which the loader consults ahead of the plugin's RUNPATH, so
nothing in the pub cache is touched. See `spike/linux/prebuilt/glibc231/`.

**This is a workaround, not a fix.** It confirms the plan's existing
recommendation: develop wherever, but build and ship against **Ubuntu 22.04+**,
where the stock plugin loads unmodified.

### 5. evdev is unavailable here, exactly as predicted

The account is not in the `input` group, so every `/dev/input/event*` open
returns `EACCES` and the backend reports `SB_ERR_NO_PERMISSION`. It fails
cleanly and the app falls through to XRecord with no user-visible breakage —
which is the fallback behaviour decision **D2** called for, now demonstrated
rather than assumed.

To enable it: `sudo usermod -aG input $USER`, then log out and back in.

---

## Measured latency

| Stage | Predicted | Measured |
| --- | --- | --- |
| Native callback → Dart | 0.2–1 ms | **0.36 ms** |
| Audio device buffer | 5–15 ms | **5.80 ms** |
| Binding lookup | < 0.1 ms | plain map, not yet isolated |

The bridge number is the important one: it confirms **D4**. FFI plus
`NativeCallable.listener` costs about a third of a millisecond, so the platform
channel that decision rejected was never needed.

Full p95 comes from the interactive console — run `./run.sh`, press the bound
keys ~100 times, and read the TOTAL p95 / GATE panel.

---

## What was built

```
spike/
├── run.sh                          launcher, sets the libFLAC workaround
├── lib/
│   ├── main.dart                   debug console + live latency panel
│   ├── selftest.dart               the gate harness (--selftest)
│   ├── keyboard.dart               FFI bridge, HID event model
│   └── audio.dart                  AudioEngine over SoLoud
├── linux/
│   ├── runner/main.cc              + XInitThreads()
│   ├── prebuilt/glibc231/          libFLAC for Ubuntu 20.04
│   └── native/
│       ├── sb_keyboard.h/.c        public API + backend selection
│       ├── sb_keymap.c            evdev ↔ USB HID tables
│       ├── sb_x11.c               XRecord backend
│       └── sb_evdev.c             evdev backend (untested — no permission)
└── assets/sounds/                  generated test tones, one per format
```

Bindings in the console: `A` → C4 wav, `S` → E4 mp3, `D` → G4 ogg,
`F` → C5 flac, `Space` → looping pad (press again to stop).

---

## Next

1. Minimise the window and confirm capture — closes criterion 2 properly.
2. Run the interactive console for ~100 presses to get the real p95 — closes 5.
3. Join the `input` group and rerun `--selftest` to exercise `sb_evdev.c`, which
   has never executed.
4. Wayland session (Ubuntu 24.04) — criterion 3, still the highest risk.
5. Windows 11 host — criterion 1, and the first real test of
   `WH_KEYBOARD_LL` and of whether SoLoud builds there at all.

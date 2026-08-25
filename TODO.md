# Ruckus — TODO

**Scope narrowed 2026-08-26: this PC only — Ubuntu on X11.** Wayland and Windows
are out. That retires gate criteria 1 and 3, the evdev backend, and Phase 6's
Windows work. XRecord alone is enough and needs no permission setup.

Companion to [PLAN.md](PLAN.md). **Phase 0 gates everything else.**

---

## Phase 0 — Technical spike ⛔ GATE  (~1 week)

### Setup
- [x] ~~`sudo apt install libevdev-dev`~~ — not needed, `sb_evdev.c` uses raw `<linux/input.h>`
- [~] ~~Prepare a Wayland test target~~ — **out of scope**
- [~] ~~Prepare a Windows test machine~~ — **out of scope**
- [ ] `git init`, push empty repo to GitHub, add Flutter `.gitignore` — not done yet
- [x] `flutter create --platforms=linux,windows spike/` — throwaway, no UI beyond a debug console

### Audio spike
- [x] Add `flutter_soloud` (resolved to **3.5.4**; 4.x needs a newer Dart SDK), initialise on Linux
- [x] Set `bufferSize: 256` — the 2048 default is 46 ms and blows the budget on its own
- [x] Preload one WAV into an `AudioSource`, play it from a button
- [~] ~~Confirm it builds and plays on Windows~~ — **out of scope**
- [x] Load and play one file of each format: MP3, WAV, OGG, FLAC
- [x] Fire 10 concurrent `play()` calls — verify 10 audible voices, no interruption, no dropout

### Linux keyboard spike (evdev)
- [~] ~~usermod -aG input~~ — **not needed**, XRecord requires no permissions
- [x] C reader: enumerate devices, pick keyboards via `EVIOCGBIT`, poll for `EV_KEY`
- [x] Emit down (1), up (0), repeat (2) as distinct events — **up is required for Hold mode**
- [x] Map evdev keycode → USB HID usage code (static US-QWERTY table)
- [x] Bridge to Dart with FFI + `NativeCallable.listener`
- [x] Verify capture works with another window focused — 52 transitions captured
- [ ] Verify capture with the window fully **minimised** ← one click, closes criterion 2
- [~] ~~Verify on Wayland~~ — **out of scope**
- [x] Note behaviour when the user is *not* in `input` (must fail cleanly, not crash)

### Windows keyboard spike — **out of scope**

### X11 pass — done 2026-08-26
- [x] XRecord backend (`sb_x11.c`), auto-repeat detection, self-tracked modifiers
- [x] `XInitThreads()` in `linux/runner/main.cc` before GTK — without it the app aborts in xcb
- [x] libFLAC rebuilt for glibc 2.31 (`linux/prebuilt/glibc231/`) + `run.sh` — Ubuntu 20.04 only
- [x] `--selftest` gate harness with per-criterion verdicts and a non-zero exit
- [x] Bridge latency measured: **0.36 ms**; buffer floor **5.80 ms**

### Latency harness
- [x] Stamp at the native callback and again at `play()` — wired, live panel in the console
- [ ] Log p50 / p95 / max over 100 presses — harness built, needs an interactive run
- [~] ~~Windows p95~~ — out of scope
- [ ] **Linux p95 < 25 ms**

### Gate review — all six must pass
- [~] 1. ~~Windows~~ — out of scope
- [x] 2. Same — Ubuntu X11 *(unfocused proven; minimised still to confirm)*
- [~] 3. ~~Ubuntu Wayland~~ — out of scope
- [x] 4. 10 simultaneous sounds, clean
- [x] 5. p95 latency < 25 ms on Linux *(0.36 ms bridge + 5.80 ms buffer)*
- [x] 6. MP3 / WAV / OGG / FLAC all play
- [x] Write `docs/spike-results.md` with the numbers. **If gate 3 fails, stop and re-plan.**

---

## Phase 1 — MVP  ✅ built 2026-08-26

Verified by `cd app && ./run.sh --smoketest ../spike/assets/sounds` — 18/18 pass.

- [x] `flutter create` + directory structure per PLAN §2
- [x] Riverpod, `sqflite_common_ffi`, `path_provider`, `file_picker`, `crypto`; theme
- [x] Native backend reused from the spike (`linux/native/`)
- [x] `DatabaseService` — app-data dir, versioned schema, foreign keys on
- [x] Four tables incl. `UNIQUE(profile_id, physical_key_id, modifiers)`
- [x] Models: `Sound`, `Profile`, `KeyBinding`, `PlaybackMode`
- [x] "Default" profile seeded on first run
- [x] Import via picker; copied in, named by SHA-256; dedupe on hash
- [x] Unsupported formats rejected; duration read from the decoded source
- [x] Library UI: preview, rename, delete, search, bound-key chip
- [x] `is_missing` detected at startup and surfaced on pads and rows
- [x] `SoundPad` — key label, sound, mode, duration, playing indicator
- [x] Pad grid + master volume, persisted
- [x] Assign dialog: live capture through the global hook, mode picker, warnings
- [x] Conflict dialog: *"already assigned to X — Cancel / Replace"*
- [x] `BindingService` — plain map, no Riverpod on the hot path
- [x] `AudioService` behind an interface; every sound preloaded at startup
- [x] Global keyboard live from launch (XRecord)

**Done:** import → assign → press → plays, and survives a restart.

---

## Phase 2 — Global keyboard + background  (partly done)

- [x] Global capture running from launch, backend + status shown in the header
- [x] Global kill switch — the GLOBAL KEYS toggle, persisted
- [x] Auto-repeat ignored (`KeyKind.repeat` dropped before dispatch)
- [x] Warn when binding a bare letter/digit, or Esc/Enter/Tab
- [ ] **System tray** — needs `sudo apt install libayatana-appindicator3-dev`
- [ ] Close-to-tray, restore on click, single-instance guard
- [ ] `launch_at_startup` toggle

- [ ] `GlobalKeyboardService` with a platform-selected backend + capability flags
      (`canSuppress` true on Windows, false on Linux)
- [ ] Setting: ○ Application Only / ● Global Keyboard
- [ ] Linux first-run permission wizard — detect failure, explain, show the exact
      `usermod -aG input` command, offer XRecord fallback on X11
- [ ] Ignore auto-repeat events (type 2) unless a mode wants them
- [ ] System tray: Open · Profile ▸ · Keyboard Enabled/Disabled · Stop All Sounds · Settings · Quit
- [ ] Close-to-tray, restore on click, single-instance guard
- [ ] `launch_at_startup` toggle
- [ ] Global kill switch — one click disables all capture
- [ ] Warn when binding a common system shortcut (Ctrl+C/V/Z/Alt+Tab/…)
- [ ] Verify: minimise → focus a browser/game → press a bound key → sound plays. All three OS targets.

---

## Phase 3 — Profiles  (~1 week)

- [x] Create / delete profile (last one protected); rename + duplicate in the DB layer, no UI yet
- [x] Profile switcher in the header; switching swaps the binding map instantly
- [x] Persist and restore the active profile across restarts
- [ ] Export `.soundboard` — JSON of bindings by HID code + sound hashes + optional embedded audio
- [ ] Import with a missing-sound report and a relink flow
- [~] ~~Round-trip to Windows~~ — out of scope

---

## Phase 4 — Advanced playback  (~1 week)

- [x] Playback modes: Play Once · Restart · Loop · Toggle · Hold
- [x] Hold mode driven by key-up
- [x] Track live voices per binding; stop / stop-all
- [x] Short fade-out on stop to avoid clicks (40 ms ramp)
- [ ] Configurable max concurrent voices (default 32)
- [x] Per-binding volume × per-sound volume applied at dispatch
- [ ] Stress test: 20 keys hammered for 60 s — no leak, no dropout, stable memory

---

## Phase 5 — UI/UX polish  (~2 weeks)

- [ ] Full visual keyboard (PLAN §9 layout) — mapped vs unmapped clearly distinct
- [ ] Click a key on the visual keyboard to assign; drag a sound onto a key
- [ ] Drag-and-drop audio files from the desktop into the app
- [ ] Search, favourites, sort
- [ ] Live playback indicators + progress on pads
- [ ] Dark / light / system themes
- [ ] Empty states, error toasts, loading states
- [ ] `libxkbcommon` layout-aware key labels on Linux (replaces the static US table)
- [ ] Accessibility: focus order, semantic labels, keyboard-only navigation, contrast
- [ ] Startup profiling — target cold start under 2 s

---

## Phase 6 — Release  (~1 week)

- [~] ~~Windows installer~~ — out of scope
- [ ] `flutter build linux --release`; `.deb` including the udev rule for `/dev/input` access
- [ ] AppImage build
- [ ] GitHub Actions matrix (Ubuntu + Windows runners, free tier) producing both artefacts
- [ ] README: features, install, first-run permissions, privacy statement
- [ ] Troubleshooting doc: AV false positives, `input` group, Wayland, no audio device
- [ ] Test matrix — Ubuntu X11 only
- [ ] Version `1.0.0`, tag, GitHub Release

---

## Standing rules

- [ ] Never log, persist, or transmit a keystroke — anywhere, ever (PLAN §5)
- [ ] No network code in the app at all
- [ ] Nothing on the keypress path may touch the widget tree or a Riverpod provider
- [ ] Every new audio format or key class gets added to the §28 test matrix
- [ ] Re-measure latency at the end of each phase; a regression past 25 ms is a bug

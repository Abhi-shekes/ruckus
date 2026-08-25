# Ruckus — Development Plan

> **Scope narrowed 2026-08-26 — this PC only: Ubuntu on X11.**
> Wayland and Windows are out of scope at the user's direction. Consequences:
> the Linux backend is **XRecord alone** (no `input` group, no setup), decision
> D3 (Windows hook) is shelved, D2's evdev half is written but unused, and
> Risk 1 — the project's biggest — is retired rather than mitigated.
> The MVP is built; see `app/README.md` and `docs/spike-results.md`.

Desktop soundboard for **Ubuntu** and **Windows**, built in Flutter. Offline-first, zero
recurring cost.

Core loop: **Import sound → assign key → press key anywhere → sound plays instantly.**

---

## 0. Verified environment (2026-08-26)

| Item | Status |
| --- | --- |
| Flutter | 3.35.7 stable, Dart 3.9.2 |
| Linux desktop target | enabled, `Linux (desktop) • linux-x64` detected |
| Build toolchain | `libgtk-3-dev`, `ninja-build`, `cmake`, `clang`, `pkg-config` — installed |
| X11 dev headers | `libx11-dev`, `libxtst-dev` — installed |
| `libevdev-dev` | **MISSING** — install before Phase 0 |
| Audio stack | PulseAudio (protocol 33), ALSA, libmpv 1.107 present |
| Dev session | **Ubuntu 20.04, X11** |
| Windows machine | not present in this environment — needed for Phase 0 |

Two consequences:

1. The dev box is X11, so **Wayland cannot be tested here.** A second machine, a live USB,
   or a VM running Ubuntu 24.04 (Wayland by default) is required. This is a hard
   prerequisite for the highest-risk item in the project.
2. Ubuntu 20.04 goes EOL. **Ship targeting Ubuntu 22.04+**; treat 20.04 as dev-only.

---

## 1. Locked technical decisions

These are the calls that shape everything else. Each is made once, here, so Phase 0 can
test the real thing rather than a placeholder.

### D1 — Audio engine: `flutter_soloud` (4.1.7)

SoLoud is a **game audio engine** (miniaudio backend), not a media player. That is exactly
what a soundboard needs and it resolves three requirements in one choice:

- `loadFile()` decodes once into memory as an `AudioSource`. Every later `play()` is a
  memory read, so there is no decode step on the keypress path (§12 of the brief).
- Each `play()` returns an independent `SoundHandle` — a **voice**. Twenty keys pressed in
  a second produce twenty concurrent voices that do not interrupt each other (§11).
- Per-voice volume, looping, seek, and stop are built in, which covers every playback mode
  in §10 without extra machinery.
- Formats: MP3, WAV, OGG, FLAC — the full test matrix in §28.

Abstract it behind an `AudioEngine` interface anyway. If the SoLoud native build turns out
to be painful on Windows, the fallbacks in priority order are `audioplayers` 6.8.1 (a
fixed pool of pre-warmed players) and `media_kit` 1.2.6 (libmpv — already installed on the
dev box, but a player-per-voice is heavy).

> Rejected: `just_audio` — built around one stream at a time, wrong shape for this.

### D2 — Linux global keyboard: **evdev first**, XRecord as fallback

The single most important decision in the project. Read raw input directly from
`/dev/input/event*`:

| | evdev | X11 XRecord | XDG GlobalShortcuts portal | `RegisterHotKey`-style |
| --- | --- | --- | --- | --- |
| Works on X11 | yes | yes | partial | — |
| Works on Wayland | **yes** | no | KDE yes / GNOME no | — |
| Reports key **up** | yes | yes | no | no |
| Setup cost | user in `input` group | none | varies | none |

evdev sits *below* the display server, so **one implementation covers both X11 and
Wayland** and collapses Risk 1 from the brief into a permissions problem instead of an
architecture problem. It also reports `KEY_UP`, without which the Hold playback mode
(§10) simply cannot be built.

The cost, stated plainly:

- The user must be in the `input` group: `sudo usermod -aG input $USER`, then log out and
  back in. The app needs a **first-run permission wizard** that detects the failure,
  explains it, and shows the exact command. Ship a udev rule in the `.deb` as the nicer path.
- **Keys cannot be suppressed.** A read-only evdev fd sees events but cannot swallow them;
  `EVIOCGRAB` would grab the whole keyboard and stop the user typing entirely. So on Linux
  a bound key still reaches the focused app. Design around it: recommend modifier combos
  or F13–F24 in the UI, and warn on bare letter keys.
- evdev yields raw kernel keycodes, not layout-aware characters. MVP ships a static
  US-QWERTY table (X11 keycode = evdev code + 8); `libxkbcommon` for correct labels on
  other layouts is a Phase 5 item.

XRecord stays as the fallback for X11 users who decline the group change.

### D3 — Windows global keyboard: `SetWindowsHookEx(WH_KEYBOARD_LL)`

A low-level keyboard hook on a dedicated thread with its own message pump. It reports both
down and up, sees every key, and — unlike Linux — **can suppress** the event by returning
non-zero.

Do **not** build on `RegisterHotKey` (or `hotkey_manager` 0.2.3, which wraps it): no key-up
events, a modifier is mandatory, and the combo is stolen process-wide. Keep it as an
emergency fallback only.

Two things to plan for:

- A low-level keyboard hook is structurally identical to a keylogger, so **antivirus false
  positives are likely.** Mitigations: never write a keystroke to disk or log, document the
  behaviour prominently in the README, and sign the installer if a certificate is ever
  available.
- The hook callback must return within the system timeout (~300 ms default) or Windows
  silently unhooks it. Never do work in the callback — enqueue and return.

### D4 — Native → Dart bridge: FFI + `NativeCallable.listener`

Not a `MethodChannel`. Platform channels are bound to the engine's platform thread and are
awkward when the window is hidden — which is the primary use case here. Instead: an FFI
plugin where the native capture thread pushes events into a lock-free queue and posts them
to a Dart port. `NativeCallable.listener` wraps `Dart_PostCObject` and delivers straight
into the Dart isolate. Costs well under a millisecond and is independent of window state.

### D5 — Normalized key identity: USB HID usage codes

The seam between platform code and the app. Every backend maps its native code into
Flutter's `PhysicalKeyboardKey` USB HID usage IDs before crossing into Dart:

```
KeyEvent { int physicalKeyId;  // USB HID usage, e.g. 0x00070004 = A
           bool isDown;
           int  modifiers;     // bitmask: CTRL|SHIFT|ALT|META
           int  timestampUs; }
```

Why it matters: HID codes are stable across Windows and Linux, and Flutter already ships
the tables and human-readable labels. Bindings stored this way are **portable between
operating systems** — a profile exported on Ubuntu works on Windows unchanged. Storing
platform scancodes or character labels would forfeit that.

### D6 — Latency budget: **< 25 ms**, measured not assumed

| Stage | Expected |
| --- | --- |
| Hardware → evdev / hook callback | < 1 ms |
| Native queue → Dart port | ~0.2–1 ms |
| Binding lookup (plain `Map`, no widget tree) | < 0.1 ms |
| `SoLoud.play()` on a preloaded source | ~5–15 ms (device buffer bound) |

Phase 0 builds a measurement harness rather than trusting these numbers. evdev events carry
a kernel timestamp; stamp again at `play()` and log the delta over 100 presses (p50/p95/max).

### D7 — Storage: SQLite via `sqflite_common_ffi` (2.4.2+1), files content-addressed

Imported audio is **copied** into the app data directory, named by SHA-256 of its contents.
Moving or deleting the original file then cannot break a binding, and re-importing the same
sound twice deduplicates for free.

Schema refines §14 of the brief:

```sql
sounds(id, name, file_hash UNIQUE, rel_path, format, duration_ms,
       volume REAL DEFAULT 1.0, is_missing INT DEFAULT 0, created_at, updated_at)

profiles(id, name UNIQUE, is_active INT DEFAULT 0, created_at, updated_at)

key_bindings(id, profile_id REFERENCES profiles ON DELETE CASCADE,
             physical_key_id INT, modifiers INT DEFAULT 0,
             sound_id REFERENCES sounds ON DELETE CASCADE,
             playback_mode TEXT, volume REAL DEFAULT 1.0, enabled INT DEFAULT 1,
             UNIQUE(profile_id, physical_key_id, modifiers))

settings(key PRIMARY KEY, value)
```

That `UNIQUE` constraint makes the §19 conflict detection a database guarantee rather than
a UI check that can be bypassed.

### D8 — Hot path never touches Riverpod

The active profile's bindings live in a plain `Map<int, KeyBinding>` (key = `physicalKeyId`
combined with the modifier mask) owned by `KeyBindingService`, rebuilt only when the profile
changes. Riverpod drives the UI; the keypress path is pure Dart with no rebuild, no
provider read, no widget tree.

### D9 — Supporting packages (all verified on pub.dev)

`window_manager` 0.5.2 · `tray_manager` 0.5.3 · `launch_at_startup` 0.5.1 ·
`path_provider` 2.1.6 · `file_picker` 12.1.0 · `flutter_riverpod` · `sqflite_common_ffi` 2.4.2+1

---

## 2. Architecture

```
                         Flutter UI  (Riverpod)
      soundboard · library · keyboard map · profiles · settings
                              │
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
        SoundService    ProfileService    SettingsService
              └───────────────┼────────────────┘
                              ▼
                       DatabaseService  ──►  SQLite + app-data/sounds/
                              │
                              ▼
    ══════════════════ HOT PATH (no UI, no rebuild) ══════════════════
                       KeyBindingService
                    Map<int, KeyBinding> lookup
                              ▼
                         AudioEngine  (flutter_soloud)
                     preloaded AudioSource → SoundHandle voices
                              ▼
                          system audio
    ═════════════════════════════════════════════════════════════════
                              ▲
                       KeyEvent (HID-normalized)
                              │
                     GlobalKeyboardService  (Dart, FFI)
                              │
              ┌───────────────┴───────────────┐
          Windows                          Linux
     WH_KEYBOARD_LL hook            evdev  →  fallback XRecord
       (can suppress)                  (cannot suppress)
```

`lib/` follows §20 of the brief. Native code lives in two in-tree FFI plugin packages,
`packages/keyboard_windows/` and `packages/keyboard_linux/`, so each builds and tests
independently of the app.

---

## 3. Phases

Sizing assumes one developer. Sequential; Phase 0 gates everything.

### Phase 0 — Technical spike **(gate — build nothing else first)**

Throwaway code in `spike/`. No UI beyond a debug console, no database, no profiles.

**Exit criteria — all must pass before Phase 1 begins:**

1. Key down **and** key up captured while the app is minimized, on Windows 11.
2. Same, on **Ubuntu X11**.
3. Same, on **Ubuntu Wayland** (24.04 VM/second machine).
4. Ten different sounds play simultaneously without dropout or interruption.
5. Measured p95 keypress-to-audio latency **< 25 ms** on both OSes.
6. MP3, WAV, OGG and FLAC all load and play.

If (3) fails, stop and re-plan: the choice becomes ship Linux app-focused-only, or require
the `input` group unconditionally. Do not discover this in Phase 4.

*≈ 1 week. Highest risk in the project.*

### Phase 1 — MVP
Database + migrations, sound import/preview/rename/delete, sound pad grid, key-capture
dialog, play-once mode, master + per-sound volume, persistence. Keyboard is
**app-focused only** here — Phase 0 already proved global works; wire it in Phase 2.
*≈ 2 weeks.*

### Phase 2 — Global keyboard + background
Promote the Phase 0 backends to real services. Permission wizard for the Linux `input`
group. System tray (open / profile switch / keyboard toggle / stop-all / quit),
close-to-tray, launch at startup, global enable-disable kill switch.
*≈ 1.5 weeks.*

### Phase 3 — Profiles
Create, rename, duplicate, delete, switch, import/export as `.soundboard` JSON (bindings by
HID code + sound hashes, so profiles move between machines).
*≈ 1 week.*

### Phase 4 — Advanced playback
Restart, loop, toggle, hold-to-play (needs the key-up events from D2/D3), stop-all, voice
limits, fade on stop.
*≈ 1 week.*

### Phase 5 — UI/UX polish
Full visual keyboard with mapped/unmapped states, drag-and-drop assignment, search,
favourites, live playback indicators, dark/light themes, conflict warnings, empty states,
`libxkbcommon` layout-aware labels, accessibility pass.
*≈ 2 weeks.*

### Phase 6 — Release
Windows installer (Inno Setup — free) + uninstaller; Ubuntu `.deb` with the udev rule and
AppImage; README, install guide, troubleshooting (AV false positives, `input` group,
Wayland); GitHub Actions build matrix on the free tier; v1.0.0 tag.
*≈ 1 week.*

**Total ≈ 9–10 weeks** at a steady pace.

Post-1.0 (§31 of the brief): sound groups, random-from-group, sequences, trim/fade editing,
MIDI, custom layouts.

---

## 4. Risk register

| # | Risk | Mitigation | Trigger |
| --- | --- | --- | --- |
| 1 | Wayland global capture fails | evdev backend (D2) tested in Phase 0 on a real Wayland session | Phase 0 gate 3 |
| 2 | Audio latency too high | Preloaded `AudioSource`, measured harness, `audioplayers`/`media_kit` fallbacks | Phase 0 gate 5 |
| 3 | Simultaneous playback | SoLoud voices — one engine, N handles | Phase 0 gate 4 |
| 4 | Key conflicts with other apps | Linux cannot suppress; warn on common combos, prefer F13–F24, global kill switch in tray | Phase 2 |
| 5 | Antivirus flags the Windows hook | No keystroke ever logged or persisted; documented; sign installer if possible | Phase 6 |
| 6 | evdev permission friction | First-run wizard + udev rule in the `.deb` + XRecord fallback | Phase 2 |
| 7 | SoLoud native build on Windows | Validated in Phase 0, behind an `AudioEngine` interface | Phase 0 |

---

## 5. Privacy commitments (§30)

The app reads every keystroke on the machine. That obligates it to:

- Never write a keystroke to a log, file, database, or crash report — bindings store key
  *identities*, never a stream of input.
- Discard unmatched key events immediately in native code, before they reach Dart where
  they could be captured by a debugger or logging framework.
- Ship no network code at all. No telemetry, no accounts, no update check.
- State all of this in the README, and keep the repository public so it can be verified.

---

## 6. Budget

₹0. Flutter, Dart, SQLite, SoLoud, Riverpod, Inno Setup, VS Code, Git and GitHub Free
cover the entire stack. The only cost is a Windows machine and a Wayland test target for
Phase 0.

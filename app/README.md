# Ruckus

A desktop soundboard for Ubuntu. Bind a sound to a key, press it anywhere, make a racket. Press a key anywhere — in a game, a browser,
Discord — and the bound sound plays.

**Scope: Ubuntu on X11 only.** Wayland and Windows were deliberately dropped, so
the global keyboard uses XRecord alone, which needs no permissions and no setup.

---

## Run it

```bash
cd ruckus/app
./run.sh
```

Use `./run.sh`, not the binary directly — it puts two compatibility libraries on
`LD_LIBRARY_PATH` that Ubuntu 20.04 needs (see *Compatibility* below).

Verify everything below the UI at any time:

```bash
./run.sh --smoketest ../spike/assets/sounds
```

23 checks covering the database, import, dedupe, preload, conflict handling,
profile round-tripping and each playback mode. Append `--stress` for a
60-second sustained-load run.

---

## Using it

1. **Add sounds** — MP3, WAV, OGG or FLAC. Files are copied into the app's own
   directory and named by content hash, so moving or deleting your originals
   afterwards cannot break anything, and importing the same file twice is
   recognised rather than duplicated.
2. **Assign a key** — hover a sound in the library, click the keyboard icon,
   then press the key or combination you want. It captures through the same
   global hook that will fire it later, so what you press is what you get.
3. **Pick a mode** — see below.
4. **Press the key** from any application.

Pads show the key, the sound, the mode and the duration. Click one to fire it
without touching the keyboard. Hover for *Change key or mode* / *Remove*.

### Playback modes

| Mode | Behaviour |
| --- | --- |
| Play once | Every press starts another voice; presses overlap |
| Restart | Stops what this key was playing and starts over |
| Loop | First press loops it, second press stops |
| Toggle | First press plays, second press stops |
| Hold | Sounds only while the key is held down |

### Profiles

Each profile has its own set of bindings. Switching swaps them instantly. Use
the dropdown top-right, `+` to add one.

---

## Things worth knowing

**Bound keys still type.** On Linux a global hook can observe keys but cannot
swallow them — grabbing the keyboard outright would stop you typing at all. So
if you bind `A`, pressing `A` still types an `A` in whatever is focused. The
assign dialog warns you when you pick a bare letter or digit. **Modifier
combinations (`Ctrl+Shift+A`) or F-keys are what you want** for anything you'll
use while typing.

**The GLOBAL KEYS switch** in the toolbar turns capture off without quitting —
useful when you're about to type a lot.

**Nothing about your keystrokes is stored or sent anywhere.** The app has no
network code at all. Bindings record key *identities*; unmatched keys are
discarded in native code before they reach Dart. See `../PLAN.md` §5.

**The tray is implemented directly over D-Bus** (StatusNotifierItem), so it
needs no appindicator package. Right-click the icon for profiles, key toggles,
Stop all and Quit. Closing the window hides to the tray; Quit is in the menu.

---

## Compatibility

Two shims live in `linux/prebuilt/glibc231/`, both needed only because this is
Ubuntu 20.04:

- **`libFLAC.so.14`** — `flutter_soloud` ships one built against glibc 2.34;
  20.04 has 2.31, and the whole audio plugin fails to load. This is FLAC 1.5.0
  rebuilt from source at glibc 2.29.
- **`libsqlite3.so`** — `sqflite_common_ffi` opens the unversioned name, which
  only exists with `libsqlite3-dev` installed. This symlinks to the runtime
  `libsqlite3.so.0` already on the system.

Neither is needed on Ubuntu 22.04+. Both are worked around without root and
without touching the pub cache.

---

## Layout

```
lib/
├── main.dart              theme + entry
├── models.dart            Sound, Profile, KeyBinding, PlaybackMode
├── state.dart             Riverpod — UI state only
├── smoketest.dart         the 18-check harness
├── services/
│   ├── database_service.dart   SQLite, content-addressed audio
│   ├── audio_service.dart      SoLoud, preloaded, multi-voice
│   ├── keyboard_service.dart   FFI bridge, HID key identities
│   ├── binding_service.dart    the hot path + playback modes
│   └── library_service.dart    import, hashing, dedupe
└── features/
    ├── home_page.dart
    ├── pad_grid.dart
    ├── sound_library.dart
    └── assign_dialog.dart

linux/native/              XRecord + evdev backends (C) → libruckus_keys.so
```

The keypress path is `sb_x11.c` → FFI → `BindingService` → `AudioService`. It
does a map lookup and calls the mixer; it never touches Riverpod or the widget
tree. Data lives in `~/.local/share/io.ruckus.app/`.

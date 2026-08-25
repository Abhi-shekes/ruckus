# Troubleshooting

Symptoms first, in rough order of how often they come up.

---

## Keys do nothing

**Check the header.** It should read `listening globally · X11 / XRecord` with a
teal dot. Anything else narrows it down immediately:

| Header says | Meaning | Fix |
| --- | --- | --- |
| `keyboard off` | The KEYS switch is off | Turn it back on |
| `not capturing` | The backend never started | See below |
| `listening globally` but nothing fires | Dispatch is gated | Check APP ONLY / GLOBAL |

**If the mode toggle says APP ONLY**, keys fire only while Ruckus is focused.
Switch it to GLOBAL.

**If it says "not capturing"**, the XRecord extension could not start. Confirm
you are on X11, not Wayland:

```bash
echo $XDG_SESSION_TYPE     # must print: x11
```

Ruckus does not support Wayland. On the login screen, choose "Ubuntu on Xorg".

Confirm the X server offers XRecord:

```bash
xdpyinfo | grep -i record   # expect: RECORD
```

---

## The sound plays but the key also types

Working as intended, and not fixable on Linux. A global hook can *observe* keys
but cannot swallow them — taking the key away would mean grabbing the whole
keyboard, which would stop you typing entirely.

Bind a modifier combination (`Ctrl+Shift+A`) or an F-key instead. The assign
dialog warns you when you pick a bare letter, digit, or a combination another
application already claims.

---

## No sound at all

**Preview first.** Hover a sound in the library and click ▶. If preview is
silent too, the problem is the audio engine, not the keyboard.

Check for a red banner at the top of the window — engine failures are reported
there with the underlying error.

**Confirm the system has a working output:**

```bash
pactl info | grep 'Default Sink'
speaker-test -t sine -f 440 -l 1   # Ctrl-C to stop
```

**Check the volumes.** Master is in the toolbar; each sound has its own volume
in the library, and each binding multiplies the two.

---

## Audio crackles or stutters

The device buffer is deliberately small — 256 frames, about 5.8 ms — because
latency is the point of a soundboard. On a busy or slower machine that can be
too tight.

Raise `kBufferSizeFrames` in `app/lib/services/audio_service.dart` to 512 or
1024 and rebuild. 1024 frames is ~23 ms, still inside the budget.

Open **Diagnostics** (the speedometer icon) to see the effect: the buffer line
is the fixed floor, and the total p95 is measured live.

---

## "GLIBC_2.33 not found" on startup

Ubuntu 20.04 only. `flutter_soloud` ships a `libFLAC.so.14` linked against
glibc 2.34; 20.04 has 2.31, so the audio plugin fails to load and takes the app
with it.

**Always launch with `./run.sh`, not the binary directly.** The script puts a
rebuilt libFLAC on `LD_LIBRARY_PATH` ahead of the plugin's own.

The `.deb` and AppImage have this handled already — they ship the compatible
build inside the package.

---

## "Failed to load dynamic library 'libsqlite3.so'"

`sqflite_common_ffi` opens the unversioned name, which on Debian and Ubuntu only
exists when `libsqlite3-dev` is installed. The runtime package ships
`libsqlite3.so.0` alone.

`./run.sh` creates the symlink automatically. If you are launching some other
way, either install the dev package:

```bash
sudo apt install libsqlite3-dev
```

…or create the link by hand next to the other shims:

```bash
ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 \
       app/linux/prebuilt/glibc231/libsqlite3.so
```

---

## No tray icon

Ruckus registers a StatusNotifierItem on the session bus. If your desktop has no
tray host, the icon simply will not appear — the app still works, and the close
button quits instead of hiding.

Check whether a host is running:

```bash
gdbus call --session --dest org.freedesktop.DBus \
  --object-path /org/freedesktop/DBus \
  --method org.freedesktop.DBus.ListNames | tr ',' '\n' | grep StatusNotifierWatcher
```

On GNOME the tray comes from the AppIndicator extension, which Ubuntu enables by
default. If it is missing:

```bash
gnome-extensions enable ubuntu-appindicators@ubuntu.com
```

Settings shows which state it detected.

---

## A second window will not open

By design. A second copy would fight the first over the tray icon and the
keyboard hook, so Ruckus takes a lock and later launches exit with
"Ruckus is already running."

If the app crashed and the lock is stale, it clears on its own — the lock is
released when the process dies. If it somehow persists:

```bash
rm ~/.local/share/io.ruckus.app/ruckus.lock
```

---

## Pads show "FILE MISSING"

The audio file is gone from the library directory. Because files are stored by
content hash, this only happens if something deleted them directly.

```bash
ls ~/.local/share/io.ruckus.app/sounds/
```

Re-import the original file — the hash will match and the binding relinks
automatically.

---

## Keys show the wrong letters

Ruckus reads your layout from X and labels keys accordingly. If it could not,
Diagnostics shows `US QWERTY (assumed)` next to "Keyboard layout".

Bindings are unaffected either way: they are stored by physical key position, so
they keep working across layout changes. Only the label is cosmetic.

---

## Starting over

Everything lives in one directory. Deleting it resets the app completely,
including imported audio:

```bash
rm -rf ~/.local/share/io.ruckus.app
```

To keep the sounds but drop the bindings, delete only `soundboard.db`.

---

## Checking whether it is Ruckus or the machine

```bash
cd app
./run.sh --smoketest ../spike/assets/sounds     # 23 checks, no UI
./run.sh --smoketest --stress ../spike/assets/sounds   # + 60s under load
```

If those pass, the engine is healthy and the problem is configuration or the
desktop environment. If they fail, the output names the failing stage.

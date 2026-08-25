# Phase 0 spike

Throwaway code, kept for the record. This existed to answer one question before
any of the real application was written:

> Can a global keypress be captured reliably and turned into audio fast enough
> to feel instant?

Nothing here is used by the app. The parts that survived — the XRecord backend,
the HID keymap, the FFI bridge — were copied into `../app/linux/native/` and
`../app/lib/services/`.

## Running it

```bash
flutter build linux --debug
./run.sh              # interactive console with a live latency panel
./run.sh --selftest   # the gate harness, prints a verdict per criterion
```

The console binds `A` → C4 wav, `S` → E4 mp3, `D` → G4 ogg, `F` → C5 flac and
`Space` → a looping pad. Press them with the window minimised and events should
keep arriving.

`assets/sounds/` holds generated sine tones, one per supported format, so the
format matrix can be exercised without shipping copyrighted audio.

## What it proved

Bridge latency of **0.36 ms**, an audio buffer floor of **5.80 ms**, ten
simultaneous voices with no dropout, and all four formats decoding. It also
surfaced three problems that would have been painful to find later:

- `XInitThreads()` must run before GTK opens its own X connection, or the
  process aborts inside xcb the moment the capture thread talks to X.
- SoLoud's default 2048-frame buffer is ~46 ms — more than the entire latency
  budget, before any application code runs.
- `flutter_soloud` ships a `libFLAC.so.14` built against glibc 2.34, which will
  not load on Ubuntu 20.04.

Full write-up in [`../docs/spike-results.md`](../docs/spike-results.md).

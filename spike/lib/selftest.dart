// Phase 0 gate harness.
//
// Run with `./run.sh --selftest`. Checks everything that does not need a human
// to press a key, prints a verdict per criterion, and exits non-zero if any
// automatable criterion failed. The three capture criteria are inherently
// manual and are reported as such.

import 'dart:async';
import 'dart:io';

import 'audio.dart';
import 'keyboard.dart';

class _Check {
  final String id;
  final String name;
  final bool? pass; // null = manual, cannot be automated
  final String detail;
  const _Check(this.id, this.name, this.pass, this.detail);
}

Future<void> runSelfTest(Map<int, String> boundAssets) async {
  final checks = <_Check>[];
  final out = StringBuffer();

  void say(String s) {
    stdout.writeln(s);
  }

  say('');
  say('═══ SOUNDBOARD PHASE 0 — GATE HARNESS ═══');
  say('');
  say('host      : ${Platform.operatingSystemVersion}');
  say('session   : ${Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown'}');
  say('');

  // ---------------------------------------------------------------- audio
  final audio = AudioEngine.instance;
  var audioOk = false;
  try {
    await audio.init();
    audioOk = true;
    say('audio     : engine up, buffer ${audio.bufferLatencyMs.toStringAsFixed(2)} ms '
        '($kBufferSizeFrames frames @ $kSampleRate Hz)');
  } catch (e) {
    say('audio     : FAILED — $e');
  }

  // -------------------------------------------------- criterion 6: formats
  final formats = <String, bool>{};
  final loaded = <LoadedSound>[];
  if (audioOk) {
    for (final asset in boundAssets.values) {
      final fmt = asset.split('.').last.toUpperCase();
      try {
        final s = await audio.preload(asset, fmt);
        loaded.add(s);
        formats[fmt] = true;
      } catch (e) {
        formats[fmt] = false;
        out.writeln('    $fmt load error: $e');
      }
    }
  }
  final wanted = ['WAV', 'MP3', 'OGG', 'FLAC'];
  final missing = wanted.where((f) => formats[f] != true).toList();
  checks.add(_Check(
    '6',
    'MP3 / WAV / OGG / FLAC all load and play',
    audioOk && missing.isEmpty,
    audioOk
        ? (missing.isEmpty
            ? wanted.map((f) => '$f ok').join(', ')
            : 'failed: ${missing.join(", ")}')
        : 'audio engine never started',
  ));

  // --------------------------------------- criterion 4: simultaneous voices
  var peakVoices = 0;
  if (audioOk && loaded.isNotEmpty) {
    const target = 10;
    for (var i = 0; i < target; i++) {
      final s = loaded[i % loaded.length];
      unawaited(audio.play(s, volume: 0.25));
    }
    // Let the mixer pick them up, then read the live voice count.
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final v = audio.voiceCount;
      if (v > peakVoices) peakVoices = v;
    }
    await audio.stopAll();
    checks.add(_Check(
      '4',
      'Ten sounds play simultaneously, no interruption',
      peakVoices >= target,
      'fired $target, engine reported peak $peakVoices concurrent voices',
    ));
  } else {
    checks.add(const _Check('4', 'Ten sounds play simultaneously', false,
        'skipped, audio engine unavailable'));
  }

  // ------------------------------------------- criterion 5 (partial): floor
  // The keypress half needs a human. What is measurable here is the fixed
  // device-buffer floor every keypress pays on top of the bridge.
  final floor = audioOk ? audio.bufferLatencyMs : double.nan;
  checks.add(_Check(
    '5a',
    'Audio buffer floor leaves room under the 25 ms budget',
    audioOk && floor < 12.0,
    audioOk
        ? '${floor.toStringAsFixed(2)} ms of the 25 ms budget'
        : 'unknown',
  ));

  // ------------------------------------------- capture backend availability
  final kb = GlobalKeyboard.instance;
  final evdevErr = kb.start(preferred: SbBackend.evdev);
  if (evdevErr == SbError.ok) {
    checks.add(const _Check('2/3', 'evdev backend available (X11 + Wayland)',
        true, 'started — this backend also covers Wayland'));
    kb.stop();
  } else {
    checks.add(_Check(
      '2/3',
      'evdev backend available (X11 + Wayland)',
      false,
      evdevErr.message.split('\n').first,
    ));
  }

  final x11Err = kb.start(preferred: SbBackend.x11);
  final x11Ok = x11Err == SbError.ok;
  var captured = 0;
  StreamSubscription<GlobalKeyEvent>? sub;
  if (x11Ok) {
    sub = kb.events.listen((_) => captured++);
  }
  checks.add(_Check(
    '2',
    'XRecord backend starts on this X11 session',
    x11Ok,
    x11Ok ? 'context created, capture thread running' : x11Err.message,
  ));

  // Give a human a moment to prove capture works, but never block a CI run.
  if (x11Ok) {
    say('');
    say('Press a few keys now (any window) — listening for 5 s…');
    await Future<void>.delayed(const Duration(seconds: 5));
    await sub?.cancel();
    kb.stop();
    say('captured $captured key transitions');
  }
  checks.add(_Check(
    '1',
    'Key transitions actually arrive from the backend',
    captured > 0 ? true : null,
    captured > 0
        ? '$captured events seen during the 5 s window'
        : 'no keys pressed during the window — rerun and type, or verify by hand',
  ));

  // --------------------------------------------------------------- verdict
  say('');
  say('─────────────────────────────────────────────────────────────');
  var failed = 0;
  var manual = 0;
  for (final c in checks) {
    final mark = c.pass == null
        ? 'MANUAL'
        : (c.pass! ? 'PASS  ' : 'FAIL  ');
    if (c.pass == false) failed++;
    if (c.pass == null) manual++;
    say('[$mark] ${c.id.padRight(4)} ${c.name}');
    say('               ${c.detail}');
  }
  say('─────────────────────────────────────────────────────────────');
  say('$failed failed, $manual need a human, '
      '${checks.length - failed - manual} passed');
  say('');
  say('Still manual, by nature:');
  say('  • capture while the window is minimised');
  say('  • the same on a Wayland session');
  say('  • the same on Windows 11');
  say('');
  if (out.isNotEmpty) say(out.toString());

  audio.dispose();
  exit(failed == 0 ? 0 : 1);
}

// The hot path (PLAN D8).
//
// A plain Map from key identity to binding, rebuilt only when the profile or
// its bindings change. Nothing here reads a Riverpod provider or touches the
// widget tree — a keypress does a map lookup and calls the audio engine, and
// that is all.

import 'dart:async';

import 'package:flutter_soloud/flutter_soloud.dart';

import '../models.dart';
import 'audio_service.dart';
import 'keyboard_service.dart';

/// Rolling keypress-to-playback latency, so the 25 ms budget is a measured
/// fact rather than an assumption (PLAN D6).
class LatencyStats {
  static const _capacity = 500;
  final _samples = <int>[];

  void add(int micros) {
    _samples.add(micros);
    if (_samples.length > _capacity) _samples.removeAt(0);
  }

  void clear() => _samples.clear();
  int get count => _samples.length;

  double _pct(double p) {
    if (_samples.isEmpty) return 0;
    final sorted = List.of(_samples)..sort();
    return sorted[((sorted.length - 1) * p).round()] / 1000.0;
  }

  /// Milliseconds from the native callback to handing the voice to the mixer.
  double get p50 => _pct(0.50);
  double get p95 => _pct(0.95);
  double get max => _pct(1.0);

  double get mean => _samples.isEmpty
      ? 0
      : _samples.reduce((a, b) => a + b) / _samples.length / 1000.0;
}

/// What the UI needs to know after a dispatch, delivered off the hot path.
class PadActivity {
  final int bindingId;
  final bool playing;
  const PadActivity(this.bindingId, this.playing);
}

class BindingService {
  BindingService._();
  static final BindingService instance = BindingService._();

  final _audio = AudioService.instance;
  final _keyboard = GlobalKeyboard.instance;

  /// lookupKey -> binding. The only structure the hot path reads.
  final _byKey = <int, KeyBinding>{};

  /// soundId -> sound, for per-sound volume.
  final _sounds = <int, Sound>{};

  /// bindingId -> the voices it started, for restart / loop / toggle / hold.
  final _live = <int, List<SoundHandle>>{};

  StreamSubscription<GlobalKeyEvent>? _sub;

  final _activity = StreamController<PadActivity>.broadcast();
  Stream<PadActivity> get activity => _activity.stream;

  /// Master switch. When false, keys are still captured but never fire.
  bool enabled = true;

  /// While a capture dialog is open, keys must not trigger sounds.
  bool captureMode = false;

  /// When false, only keys arriving while the app is focused fire. The capture
  /// backend keeps running either way; this just gates dispatch.
  bool globalMode = true;

  /// Set by the window-focus observer so [globalMode] can be honoured.
  bool appFocused = true;

  /// Hard ceiling on simultaneous voices. Past this, the oldest is stolen —
  /// the same voice-stealing a hardware sampler does.
  int maxVoices = 32;

  final latency = LatencyStats();

  bool get isListening => _sub != null;
  int get bindingCount => _byKey.length;

  void attach() {
    _sub ??= _keyboard.events.listen(_onKey);
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
  }

  /// Rebuilds the lookup table. Called on profile switch and after any edit.
  void load(List<KeyBinding> bindings, List<Sound> sounds) {
    _byKey
      ..clear()
      ..addEntries(bindings
          .where((b) => b.enabled)
          .map((b) => MapEntry(b.lookupKey, b)));
    _sounds
      ..clear()
      ..addEntries(sounds.map((s) => MapEntry(s.id, s)));
  }

  // ----------------------------------------------------------- HOT PATH

  void _onKey(GlobalKeyEvent ev) {
    if (!enabled || captureMode) return;
    if (!globalMode && !appFocused) return;
    if (ev.kind == KeyKind.repeat) return; // auto-repeat is not a new press

    final binding = _byKey[ev.bindingKey];
    if (binding == null) return;

    if (ev.kind == KeyKind.down) {
      _onDown(binding);
      // Measured from the moment native code saw the key to the moment the
      // voice was handed over — everything this app controls.
      latency.add(_keyboard.nowUs() - ev.nativeUs);
    } else if (binding.mode == PlaybackMode.hold) {
      _stopBinding(binding.id);
    }
  }

  void _onDown(KeyBinding b) {
    final sound = _sounds[b.soundId];
    if (sound == null || sound.isMissing) return;

    final volume = (b.volume * sound.volume).clamp(0.0, 1.0);
    final playing = _isPlaying(b.id);

    switch (b.mode) {
      case PlaybackMode.once:
        // Overlap deliberately: a second press is a second voice.
        _start(b, volume: volume);

      case PlaybackMode.restart:
        _stopBinding(b.id);
        _start(b, volume: volume);

      case PlaybackMode.loop:
        if (playing) {
          _stopBinding(b.id);
        } else {
          _start(b, volume: volume, looping: true);
        }

      case PlaybackMode.toggle:
        if (playing) {
          _stopBinding(b.id);
        } else {
          _start(b, volume: volume);
        }

      case PlaybackMode.hold:
        // Ignore a repeat press while already held.
        if (!playing) _start(b, volume: volume);
    }
  }

  /// Total voices this service believes are alive.
  int get liveVoiceCount =>
      _live.values.fold(0, (sum, list) => sum + list.length);

  /// Frees the oldest voice when the ceiling is reached, so a stuck loop or a
  /// very fast roll can never exhaust the mixer.
  void _enforceVoiceCap() {
    var over = liveVoiceCount - maxVoices;
    if (over < 0) return;
    for (final id in List.of(_live.keys)) {
      final handles = _live[id];
      if (handles == null) continue;
      while (over >= 0 && handles.isNotEmpty) {
        _audio.stop(handles.removeAt(0));
        over--;
      }
      if (handles.isEmpty) {
        _live.remove(id);
        _activity.add(PadActivity(id, false));
      }
      if (over < 0) break;
    }
  }

  void _start(KeyBinding b, {required double volume, bool looping = false}) {
    _enforceVoiceCap();
    // Not awaited: awaiting would add an event-loop turn to the hot path.
    _audio.play(b.soundId, volume: volume, looping: looping).then((h) {
      if (h == null) return;
      (_live[b.id] ??= []).add(h);
      _activity.add(PadActivity(b.id, true));
    });
  }

  bool _isPlaying(int bindingId) {
    final handles = _live[bindingId];
    if (handles == null || handles.isEmpty) return false;
    handles.removeWhere((h) => !_audio.isVoiceAlive(h));
    if (handles.isEmpty) {
      _live.remove(bindingId);
      return false;
    }
    return true;
  }

  void _stopBinding(int bindingId) {
    final handles = _live.remove(bindingId);
    if (handles == null) return;
    for (final h in handles) {
      _audio.fadeStop(h);
    }
    _activity.add(PadActivity(bindingId, false));
  }

  // -------------------------------------------------------- end hot path

  /// True while any voice this binding started is still audible.
  bool isPadPlaying(int bindingId) => _isPlaying(bindingId);

  Future<void> stopAll() async {
    for (final id in List.of(_live.keys)) {
      _activity.add(PadActivity(id, false));
    }
    _live.clear();
    await _audio.stopAll();
  }

  /// Fires a binding from the UI, so clicking a pad behaves like pressing it.
  void trigger(KeyBinding b) => _onDown(b);
}

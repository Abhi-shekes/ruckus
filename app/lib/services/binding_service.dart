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
    if (ev.kind == KeyKind.repeat) return; // auto-repeat is not a new press

    final binding = _byKey[ev.bindingKey];
    if (binding == null) return;

    if (ev.kind == KeyKind.down) {
      _onDown(binding);
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

  void _start(KeyBinding b, {required double volume, bool looping = false}) {
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

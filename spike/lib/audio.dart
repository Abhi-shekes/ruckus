// Audio engine wrapper (PLAN.md D1).
//
// Everything the soundboard plays is decoded once into memory at startup, so a
// keypress only ever triggers a memory read. Each play() spawns an independent
// voice, which is what lets pads overlap instead of cutting each other off.
//
// Kept behind this interface deliberately: if SoLoud misbehaves on Windows the
// fallback engines slot in here without touching the keyboard or binding code.

import 'package:flutter_soloud/flutter_soloud.dart';

/// Audio device buffer, in frames.
///
/// SoLoud defaults to 2048, which is ~46 ms at 44.1 kHz — on its own more than
/// the whole 25 ms latency budget. 256 frames is ~5.8 ms. If the sound crackles
/// on a given machine this is the first dial to turn back up.
const int kBufferSizeFrames = 256;
const int kSampleRate = 44100;

class LoadedSound {
  final String key;
  final String label;
  final String format;
  final AudioSource source;
  final Duration duration;

  const LoadedSound({
    required this.key,
    required this.label,
    required this.format,
    required this.source,
    required this.duration,
  });
}

class AudioEngine {
  AudioEngine._();
  static final AudioEngine instance = AudioEngine._();

  final _sounds = <String, LoadedSound>{};
  final _liveHandles = <SoundHandle>[];

  bool _ready = false;
  bool get isReady => _ready;

  List<LoadedSound> get sounds => _sounds.values.toList(growable: false);

  /// Actual device latency floor, derived from the buffer we asked for.
  double get bufferLatencyMs => kBufferSizeFrames / kSampleRate * 1000;

  Future<void> init() async {
    if (_ready) return;
    await SoLoud.instance.init(
      sampleRate: kSampleRate,
      bufferSize: kBufferSizeFrames,
      channels: Channels.stereo,
    );
    _ready = true;
  }

  /// Decodes into RAM up front. [LoadMode.memory] is the whole point — the
  /// alternative streams from disk and puts a decode on the keypress path.
  Future<LoadedSound> preload(String assetPath, String label) async {
    final existing = _sounds[assetPath];
    if (existing != null) return existing;

    final source =
        await SoLoud.instance.loadAsset(assetPath, mode: LoadMode.memory);
    final loaded = LoadedSound(
      key: assetPath,
      label: label,
      format: assetPath.split('.').last.toUpperCase(),
      source: source,
      duration: SoLoud.instance.getLength(source),
    );
    _sounds[assetPath] = loaded;
    return loaded;
  }

  /// Fires a new voice. Returns the handle so hold/toggle/loop modes can stop
  /// exactly the voice they started.
  SoundHandle? playNow(LoadedSound sound,
      {double volume = 1.0, bool looping = false}) {
    if (!_ready) return null;
    SoundHandle? handle;
    // Intentionally not awaited: awaiting adds an event-loop turn to the hot
    // path. The native mixer has already been handed the voice by the time the
    // future completes.
    SoLoud.instance
        .play(sound.source, volume: volume, looping: looping)
        .then((h) {
      handle = h;
      _liveHandles.add(h);
    });
    return handle;
  }

  /// Same as [playNow] but yields the handle, for callers that need it.
  Future<SoundHandle> play(LoadedSound sound,
      {double volume = 1.0, bool looping = false}) async {
    final h = await SoLoud.instance
        .play(sound.source, volume: volume, looping: looping);
    _liveHandles.add(h);
    return h;
  }

  Future<void> stopHandle(SoundHandle handle) async {
    await SoLoud.instance.stop(handle);
    _liveHandles.remove(handle);
  }

  Future<void> stopAll() async {
    for (final h in List.of(_liveHandles)) {
      await SoLoud.instance.stop(h);
    }
    _liveHandles.clear();
  }

  int get voiceCount => _ready ? SoLoud.instance.getVoiceCount() : 0;

  void setMasterVolume(double v) {
    if (_ready) SoLoud.instance.setGlobalVolume(v);
  }

  void dispose() {
    if (!_ready) return;
    SoLoud.instance.deinit();
    _ready = false;
  }
}

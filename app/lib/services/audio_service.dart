// Audio engine (PLAN D1).
//
// Every sound in the library is decoded into memory once, at startup. A
// keypress only ever triggers a memory read, and each play() spawns an
// independent voice so pads overlap instead of cutting each other off.

import 'dart:io';

import 'package:flutter_soloud/flutter_soloud.dart';

/// Device buffer in frames. SoLoud defaults to 2048 — ~46 ms at 44.1 kHz,
/// which on its own exceeds the whole latency budget. 256 frames is ~5.8 ms.
/// If audio crackles on some machine, this is the first dial to turn back up.
const int kBufferSizeFrames = 256;
const int kSampleRate = 44100;

class AudioService {
  AudioService._();
  static final AudioService instance = AudioService._();

  /// Preloaded sources, keyed by sound id.
  final _sources = <int, AudioSource>{};

  bool _ready = false;
  String? _initError;

  bool get isReady => _ready;
  String? get initError => _initError;
  double get bufferLatencyMs => kBufferSizeFrames / kSampleRate * 1000;
  int get voiceCount => _ready ? SoLoud.instance.getVoiceCount() : 0;
  bool isLoaded(int soundId) => _sources.containsKey(soundId);

  Future<void> init() async {
    if (_ready) return;
    try {
      await SoLoud.instance.init(
        sampleRate: kSampleRate,
        bufferSize: kBufferSizeFrames,
        channels: Channels.stereo,
      );
      _ready = true;
    } catch (e) {
      _initError = '$e';
      rethrow;
    }
  }

  /// Decodes into RAM. [LoadMode.memory] is the whole point — streaming from
  /// disk would put a decode on the keypress path.
  /// Returns the clip length, or null if it could not be loaded.
  Future<Duration?> preload(int soundId, String absolutePath) async {
    if (!_ready) return null;
    if (_sources.containsKey(soundId)) {
      return SoLoud.instance.getLength(_sources[soundId]!);
    }
    if (!File(absolutePath).existsSync()) return null;
    try {
      final src =
          await SoLoud.instance.loadFile(absolutePath, mode: LoadMode.memory);
      _sources[soundId] = src;
      return SoLoud.instance.getLength(src);
    } catch (_) {
      return null;
    }
  }

  Future<void> unload(int soundId) async {
    final src = _sources.remove(soundId);
    if (src != null) await SoLoud.instance.disposeSource(src);
  }

  /// Starts a voice and returns its handle, so hold/toggle/loop can stop
  /// exactly the voice they started.
  Future<SoundHandle?> play(int soundId,
      {double volume = 1.0, bool looping = false}) async {
    final src = _sources[soundId];
    if (!_ready || src == null) return null;
    return SoLoud.instance.play(src, volume: volume, looping: looping);
  }

  bool isVoiceAlive(SoundHandle h) =>
      _ready && SoLoud.instance.getIsValidVoiceHandle(h);

  Future<void> stop(SoundHandle h) async {
    if (_ready) await SoLoud.instance.stop(h);
  }

  /// Short ramp to zero before stopping, so cutting a sound doesn't click.
  Future<void> fadeStop(SoundHandle h,
      {Duration over = const Duration(milliseconds: 40)}) async {
    if (!_ready) return;
    SoLoud.instance.fadeVolume(h, 0, over);
    await Future<void>.delayed(over);
    await SoLoud.instance.stop(h);
  }

  Future<void> stopAll() async {
    if (!_ready) return;
    // No public "stop everything" that keeps sources loaded, so walk the
    // handles the engine still considers live.
    for (final src in _sources.values) {
      for (final h in List.of(src.handles)) {
        await SoLoud.instance.stop(h);
      }
    }
  }

  void setMasterVolume(double v) {
    if (_ready) SoLoud.instance.setGlobalVolume(v.clamp(0.0, 1.0));
  }

  void dispose() {
    if (!_ready) return;
    SoLoud.instance.deinit();
    _ready = false;
  }
}

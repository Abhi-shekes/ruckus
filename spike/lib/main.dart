// Phase 0 technical spike.
//
// Deliberately ugly. This exists to answer six questions and nothing else:
// does global capture work while minimised, on both backends, with key-up,
// under 25 ms, with overlapping voices, across all four audio formats.

import 'dart:async';

import 'package:flutter/material.dart';

import 'audio.dart';
import 'keyboard.dart';
import 'selftest.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--selftest')) {
    runSelfTest({
      for (final e in kBindings.entries) e.key: e.value.assetPath,
    });
    return;
  }
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soundboard Spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E1214),
      ),
      home: const SpikeHome(),
    );
  }
}

// ---------------------------------------------------------------- bindings

/// The spike's stand-in for the real KeyBindingService: a plain map, rebuilt
/// only when bindings change, never read through a provider (PLAN.md D8).
class Binding {
  final String assetPath;
  final bool looping;
  const Binding(this.assetPath, {this.looping = false});
}

const _hidA = 0x00070004;
const _hidS = 0x00070016;
const _hidD = 0x00070007;
const _hidF = 0x00070009;
const _hidSpace = 0x0007002C;

final Map<int, Binding> kBindings = {
  _hidA: const Binding('assets/sounds/pad_c4.wav'),
  _hidS: const Binding('assets/sounds/pad_e4.mp3'),
  _hidD: const Binding('assets/sounds/pad_g4.ogg'),
  _hidF: const Binding('assets/sounds/pad_c5.flac'),
  _hidSpace: const Binding('assets/sounds/pad_long.wav', looping: true),
};

// ---------------------------------------------------------------- latency

class LatencySamples {
  final _bridge = <int>[];
  final _dispatch = <int>[];

  void add(int bridgeUs, int dispatchUs) {
    _bridge.add(bridgeUs);
    _dispatch.add(dispatchUs);
  }

  int get count => _bridge.length;
  void clear() {
    _bridge.clear();
    _dispatch.clear();
  }

  static double _pct(List<int> xs, double p) {
    if (xs.isEmpty) return 0;
    final s = List.of(xs)..sort();
    final i = ((s.length - 1) * p).round();
    return s[i] / 1000.0;
  }

  double get bridgeP50 => _pct(_bridge, 0.50);
  double get bridgeP95 => _pct(_bridge, 0.95);
  double get totalP50 => _pct(_sum, 0.50);
  double get totalP95 => _pct(_sum, 0.95);
  double get totalMax => _pct(_sum, 1.0);

  List<int> get _sum => [
        for (var i = 0; i < _bridge.length; i++) _bridge[i] + _dispatch[i],
      ];
}

// ---------------------------------------------------------------- home

class SpikeHome extends StatefulWidget {
  const SpikeHome({super.key});

  @override
  State<SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<SpikeHome> {
  final _keyboard = GlobalKeyboard.instance;
  final _audio = AudioEngine.instance;
  final _latency = LatencySamples();
  final _log = <String>[];
  final _loops = <int, dynamic>{};
  // Bindings resolved to their preloaded sound once, at boot. The hot path
  // must never scan a list.
  final _resolved = <int, LoadedSound>{};

  StreamSubscription<GlobalKeyEvent>? _sub;
  Timer? _uiTimer;

  String _status = 'starting…';
  String _audioStatus = 'loading…';
  bool _capturing = false;
  int _backend = SbBackend.none;
  int _eventCount = 0;
  double _master = 0.8;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _boot();
    // Repaint on a timer rather than per event: the hot path must never call
    // setState, or a fast roll of keys turns into a rebuild storm.
    _uiTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (_dirty && mounted) {
        setState(() => _dirty = false);
      }
    });
  }

  Future<void> _boot() async {
    try {
      await _audio.init();
      for (final entry in kBindings.entries) {
        _resolved[entry.key] =
            await _audio.preload(entry.value.assetPath, hidLabel(entry.key));
      }
      _audio.setMasterVolume(_master);
      setState(() => _audioStatus =
          '${_audio.sounds.length} sounds preloaded · buffer '
          '${_audio.bufferLatencyMs.toStringAsFixed(1)} ms');
    } catch (e) {
      setState(() => _audioStatus = 'audio failed: $e');
    }
    _startCapture(SbBackend.none);
  }

  void _startCapture(int preferred) {
    final err = _keyboard.start(preferred: preferred);
    if (err != SbError.ok) {
      setState(() {
        _capturing = false;
        _status = err.message;
      });
      return;
    }
    _sub?.cancel();
    _sub = _keyboard.events.listen(_onKey);
    setState(() {
      _capturing = true;
      _backend = _keyboard.activeBackend;
      _status = 'capturing via ${SbBackend.label(_backend)}';
    });
  }

  void _stopCapture() {
    _sub?.cancel();
    _sub = null;
    _keyboard.stop();
    setState(() {
      _capturing = false;
      _backend = SbBackend.none;
      _status = 'stopped';
    });
  }

  // ------------------------------------------------------------- HOT PATH
  void _onKey(GlobalKeyEvent ev) {
    _eventCount++;

    final binding = kBindings[ev.hidUsage];
    final sound = _resolved[ev.hidUsage];

    if (binding != null && sound == null && ev.kind == KeyKind.down) {
      _push('${ev.label} is bound but its sound never loaded');
      return;
    }

    if (binding != null && sound != null && ev.kind == KeyKind.down) {
      if (binding.looping && _loops.containsKey(ev.hidUsage)) {
        // Second press stops the loop.
        final h = _loops.remove(ev.hidUsage);
        _audio.stopHandle(h);
      } else {
        _audio.play(sound, looping: binding.looping).then((h) {
          if (binding.looping) _loops[ev.hidUsage] = h;
        });
        final playUs = _keyboard.nowUs();
        _latency.add(ev.bridgeLatencyUs, playUs - ev.receivedUs);
      }
    }

    _push('${ev.kind.name.padRight(6)} ${ev.label.padRight(20)} '
        'bridge ${(ev.bridgeLatencyUs / 1000).toStringAsFixed(2)} ms'
        '${binding != null ? "   ♪" : ""}');
  }
  // ---------------------------------------------------------- end hot path

  void _push(String line) {
    _log.insert(0, line);
    if (_log.length > 200) _log.removeLast();
    _dirty = true;
  }

  Future<void> _fireSimultaneous() async {
    for (final s in _audio.sounds) {
      if (s.key.contains('long')) continue;
      unawaited(_audio.play(s, volume: 0.7));
      unawaited(_audio.play(s, volume: 0.5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _push('fired ${_audio.sounds.length * 2 - 2} voices · '
        'engine reports ${_audio.voiceCount} live');
    setState(() {});
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _sub?.cancel();
    _keyboard.stop();
    _audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5);
    final accent =
        _capturing ? const Color(0xFF4FCBD4) : const Color(0xFFFF7A6B);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.circle, size: 11, color: accent),
                const SizedBox(width: 8),
                const Text('SOUNDBOARD SPIKE',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2)),
                const Spacer(),
                Text('$_eventCount events', style: mono),
              ]),
              const Divider(height: 22),

              Text(_status, style: mono.copyWith(color: accent)),
              const SizedBox(height: 4),
              Text(_audioStatus, style: mono.copyWith(color: Colors.white60)),
              const SizedBox(height: 14),

              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonal(
                  onPressed: _capturing ? _stopCapture : () => _startCapture(0),
                  child: Text(_capturing ? 'Stop capture' : 'Start capture'),
                ),
                OutlinedButton(
                  onPressed: () {
                    _stopCapture();
                    _startCapture(SbBackend.x11);
                  },
                  child: const Text('Force XRecord'),
                ),
                OutlinedButton(
                  onPressed: () {
                    _stopCapture();
                    _startCapture(SbBackend.evdev);
                  },
                  child: const Text('Force evdev'),
                ),
                FilledButton(
                  onPressed: _fireSimultaneous,
                  child: const Text('Fire 8 voices at once'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await _audio.stopAll();
                    _loops.clear();
                    _push('stop all');
                    setState(() {});
                  },
                  child: const Text('Stop all'),
                ),
                OutlinedButton(
                  onPressed: () => setState(_latency.clear),
                  child: const Text('Reset latency'),
                ),
              ]),

              const SizedBox(height: 14),
              _LatencyPanel(latency: _latency, audio: _audio),
              const SizedBox(height: 10),

              Row(children: [
                const Text('Master', style: mono),
                Expanded(
                  child: Slider(
                    value: _master,
                    onChanged: (v) {
                      setState(() => _master = v);
                      _audio.setMasterVolume(v);
                    },
                  ),
                ),
                Text('${(_master * 100).round()}%', style: mono),
                const SizedBox(width: 18),
                Text('voices: ${_audio.voiceCount}', style: mono),
              ]),

              const SizedBox(height: 6),
              Text(
                'Bound:  A → C4 wav    S → E4 mp3    D → G4 ogg    '
                'F → C5 flac    Space → loop (press again to stop)',
                style: mono.copyWith(color: Colors.white54),
              ),
              const SizedBox(height: 4),
              const Text(
                'Minimise this window, focus something else, and press those '
                'keys — events should keep arriving.',
                style: TextStyle(fontSize: 11.5, color: Colors.white38),
              ),
              const Divider(height: 22),

              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161C1E),
                    border: Border.all(color: const Color(0xFF2A3436)),
                  ),
                  child: ListView.builder(
                    itemCount: _log.length,
                    itemBuilder: (_, i) => Text(
                      _log[i],
                      style: mono.copyWith(
                        color: _log[i].contains('♪')
                            ? const Color(0xFF4FCBD4)
                            : Colors.white54,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LatencyPanel extends StatelessWidget {
  const _LatencyPanel({required this.latency, required this.audio});

  final LatencySamples latency;
  final AudioEngine audio;

  @override
  Widget build(BuildContext context) {
    final buffer = audio.bufferLatencyMs;
    final total = latency.totalP95 + buffer;
    final pass = latency.count > 0 && total < 25.0;

    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9.5,
                      letterSpacing: 1.2,
                      color: Colors.white38)),
              const SizedBox(height: 3),
              Text(value,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: color ?? Colors.white)),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161C1E),
        border: Border.all(
            color: latency.count == 0
                ? const Color(0xFF2A3436)
                : (pass ? const Color(0xFF4FCBD4) : const Color(0xFFFF7A6B))),
      ),
      child: Row(children: [
        cell('SAMPLES', '${latency.count}'),
        cell('BRIDGE p95', '${latency.bridgeP95.toStringAsFixed(2)} ms'),
        cell('APP p95', '${latency.totalP95.toStringAsFixed(2)} ms'),
        cell('BUFFER', '${buffer.toStringAsFixed(1)} ms'),
        cell(
          'TOTAL p95',
          latency.count == 0 ? '—' : '${total.toStringAsFixed(2)} ms',
          color: latency.count == 0
              ? Colors.white
              : (pass ? const Color(0xFF4FCBD4) : const Color(0xFFFF7A6B)),
        ),
        cell('GATE < 25', latency.count == 0 ? '—' : (pass ? 'PASS' : 'FAIL'),
            color: latency.count == 0
                ? Colors.white
                : (pass ? const Color(0xFF4FCBD4) : const Color(0xFFFF7A6B))),
      ]),
    );
  }
}


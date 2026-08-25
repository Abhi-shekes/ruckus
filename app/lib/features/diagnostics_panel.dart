// Live diagnostics. Exists so the latency budget is a number you can read
// rather than a claim in a document (PLAN D6).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../services/audio_service.dart';
import '../services/binding_service.dart';
import '../services/keyboard_service.dart';

import '../state.dart';

Future<void> showDiagnostics(BuildContext context) => showDialog(
      context: context,
      builder: (_) => const _DiagnosticsDialog(),
    );

/// Settings that are not part of the moment-to-moment board.
Future<void> showSettings(BuildContext context) => showDialog(
      context: context,
      builder: (_) => const _SettingsDialog(),
    );

class _SettingsDialog extends ConsumerWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(boardProvider);
    final notifier = ref.read(boardProvider.notifier);

    Widget row(String title, String subtitle, bool value,
            ValueChanged<bool>? onChanged) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13,
                          color: onChanged == null ? kMuted : kInk)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 11, color: kMuted)),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ]),
        );

    return AlertDialog(
      backgroundColor: kPanel,
      shape: const RoundedRectangleBorder(
          side: BorderSide(color: kRule), borderRadius: BorderRadius.zero),
      title: const Text('Settings', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          row(
            'Close to tray',
            board.trayActive
                ? 'The close button hides Ruckus instead of quitting'
                : 'No system tray on this desktop',
            board.closeToTray && board.trayActive,
            board.trayActive ? notifier.setCloseToTray : null,
          ),
          const Divider(color: kRule),
          row(
            'Start with the system',
            'Launches hidden in the tray when you log in',
            board.launchAtStartup,
            notifier.setLaunchAtStartup,
          ),
          const Divider(color: kRule),
          row(
            'Fire from any application',
            'Off means keys only work while Ruckus is focused',
            board.globalMode,
            board.captureLive ? notifier.setGlobalMode : null,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              board.trayActive
                  ? 'Tray icon active — right-click it for profiles and Quit.'
                  : 'Tray unavailable, so the close button quits.',
              style: const TextStyle(fontSize: 11, color: kMuted),
            ),
          ),
        ]),
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

class _DiagnosticsDialog extends StatefulWidget {
  const _DiagnosticsDialog();

  @override
  State<_DiagnosticsDialog> createState() => _DiagnosticsDialogState();
}

class _DiagnosticsDialogState extends State<_DiagnosticsDialog> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(milliseconds: 300), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = BindingService.instance;
    final a = AudioService.instance;
    final k = GlobalKeyboard.instance;
    final l = b.latency;

    final total = l.p95 + a.bufferLatencyMs;
    final pass = l.count > 0 && total < 25.0;

    return AlertDialog(
      backgroundColor: kPanel,
      shape: const RoundedRectangleBorder(
          side: BorderSide(color: kRule), borderRadius: BorderRadius.zero),
      title: const Text('Diagnostics', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Label('KEYPRESS → MIXER'),
            const SizedBox(height: 8),
            if (l.count == 0)
              const Text(
                'No samples yet. Press a bound key a few times, then come back.',
                style: TextStyle(fontSize: 12, color: kMuted),
              )
            else
              Row(children: [
                _Stat('p50', l.p50),
                _Stat('p95', l.p95),
                _Stat('max', l.max),
                _Stat('mean', l.mean),
                _Stat('n', l.count.toDouble(), unit: ''),
              ]),
            const SizedBox(height: 16),

            const _Label('BUDGET'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kSunk,
                border: Border.all(
                    color: l.count == 0 ? kRule : (pass ? kAccent : kDanger)),
              ),
              child: Column(children: [
                _Line('App dispatch (p95)', '${l.p95.toStringAsFixed(2)} ms'),
                _Line('Audio device buffer',
                    '${a.bufferLatencyMs.toStringAsFixed(2)} ms'),
                const Divider(height: 14, color: kRule),
                _Line(
                  'Total (p95)',
                  l.count == 0 ? '—' : '${total.toStringAsFixed(2)} ms',
                  bold: true,
                  color: l.count == 0 ? kInk : (pass ? kAccent : kDanger),
                ),
                _Line('Target', '< 25.00 ms', color: kMuted),
              ]),
            ),
            const SizedBox(height: 16),

            const _Label('ENGINE'),
            const SizedBox(height: 8),
            _Line('Keyboard backend', SbBackend.label(k.activeBackend)),
            _Line('Dispatch', b.globalMode ? 'global' : 'app-focused only'),
            _Line('Bindings loaded', '${b.bindingCount}'),
            _Line('Voices live', '${a.voiceCount} / ${b.maxVoices} max'),
            _Line('Sample rate', '$kSampleRate Hz'),
            _Line('Buffer', '$kBufferSizeFrames frames'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(l.clear),
          child: const Text('Reset samples'),
        ),
        FilledButton(
            onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          letterSpacing: 1.4,
          color: kMuted));
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.unit = ' ms'});
  final String label;
  final double value;
  final String unit;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 9.5, color: kMuted)),
            const SizedBox(height: 2),
            Text(
              unit.isEmpty
                  ? value.toStringAsFixed(0)
                  : value.toStringAsFixed(2) + unit,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.bold = false, this.color});
  final String label;
  final String value;
  final bool bold;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: kInkSoft))),
          Text(value,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: color ?? kInk,
              )),
        ]),
      );
}

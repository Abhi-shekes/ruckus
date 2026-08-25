// "Press a key or key combination…"
//
// Reads from the same global capture the soundboard uses, so whatever key the
// user presses here is exactly the key that will fire later — no separate
// in-app key handling to drift out of sync.

import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/binding_service.dart';
import '../services/keyboard_service.dart';

class CapturedKey {
  final int hidUsage;
  final int modifiers;
  final PlaybackMode mode;
  const CapturedKey(this.hidUsage, this.modifiers, this.mode);
}

/// Returns null if cancelled.
Future<CapturedKey?> showAssignDialog(
  BuildContext context, {
  required String soundName,
  PlaybackMode initialMode = PlaybackMode.once,
  int? initialHid,
  int initialMods = 0,
}) {
  return showDialog<CapturedKey>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AssignDialog(
      soundName: soundName,
      initialMode: initialMode,
      initialHid: initialHid,
      initialMods: initialMods,
    ),
  );
}

class _AssignDialog extends StatefulWidget {
  const _AssignDialog({
    required this.soundName,
    required this.initialMode,
    this.initialHid,
    this.initialMods = 0,
  });

  final String soundName;
  final PlaybackMode initialMode;
  final int? initialHid;
  final int initialMods;

  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog> {
  StreamSubscription<GlobalKeyEvent>? _sub;
  int? _hid;
  int _mods = 0;
  late PlaybackMode _mode;
  bool _listening = true;

  /// Keys that would make the app unusable if bound, or that the desktop
  /// almost certainly wants for itself.
  static const _risky = {
    0x00070029, // Escape
    0x00070028, // Enter
    0x0007002B, // Tab
  };

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _hid = widget.initialHid;
    _mods = widget.initialMods;

    // Suppress sound triggering while the dialog is open.
    BindingService.instance.captureMode = true;
    _sub = GlobalKeyboard.instance.events.listen(_onKey);
  }

  void _onKey(GlobalKeyEvent ev) {
    if (!_listening || ev.kind != KeyKind.down) return;
    // A modifier alone is not a binding — wait for the real key.
    if (isModifier(ev.hidUsage)) return;
    setState(() {
      _hid = ev.hidUsage;
      _mods = ev.modifiers;
      _listening = false;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    BindingService.instance.captureMode = false;
    super.dispose();
  }

  String get _label {
    if (_hid == null) return 'Press a key or key combination…';
    final parts = <String>[
      if (_mods & SbMod.ctrl != 0) 'Ctrl',
      if (_mods & SbMod.shift != 0) 'Shift',
      if (_mods & SbMod.alt != 0) 'Alt',
      if (_mods & SbMod.meta != 0) 'Meta',
      hidLabel(_hid!),
    ];
    return parts.join(' + ');
  }

  bool get _isRisky => _hid != null && _risky.contains(_hid) && _mods == 0;

  bool get _isBareLetter {
    if (_hid == null || _mods != 0) return false;
    final u = _hid! & 0xFFFF;
    return (u >= 0x04 && u <= 0x1D) || (u >= 0x1E && u <= 0x27);
  }

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: 'monospace');

    return AlertDialog(
      backgroundColor: kPanel,
      shape: const RoundedRectangleBorder(
          side: BorderSide(color: kRule), borderRadius: BorderRadius.zero),
      title: Text('Assign a key to ${widget.soundName}',
          style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The captured combination, shown like a keycap.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 26),
              decoration: BoxDecoration(
                color: kSunk,
                border: Border.all(
                    color: _hid == null ? kRuleStrong : kAccent, width: 1.5),
              ),
              child: Center(
                child: Text(
                  _label,
                  style: mono.copyWith(
                    fontSize: _hid == null ? 13 : 21,
                    fontWeight: FontWeight.bold,
                    color: _hid == null ? kMuted : kAccent,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),

            if (_hid != null)
              TextButton.icon(
                onPressed: () => setState(() {
                  _hid = null;
                  _listening = true;
                }),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Press another key'),
              ),

            if (_isRisky)
              const _Warning(
                  'That key is used to navigate the app itself. Consider a '
                  'combination instead.'),
            if (_isBareLetter)
              const _Warning(
                  'On Linux a bound key still reaches whatever app is focused, '
                  'so this will also type. A modifier combination or an F-key '
                  'is usually safer.'),

            const SizedBox(height: 14),
            const Text('WHEN PRESSED',
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    letterSpacing: 1.4,
                    color: kMuted)),
            const SizedBox(height: 6),
            DropdownButtonFormField<PlaybackMode>(
              initialValue: _mode,
              dropdownColor: kPanel,
              items: [
                for (final m in PlaybackMode.values)
                  DropdownMenuItem(
                    value: m,
                    child: Text('${m.label}  —  ${_describe(m)}',
                        style: const TextStyle(fontSize: 13)),
                  ),
              ],
              onChanged: (m) => setState(() => _mode = m ?? _mode),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _hid == null
              ? null
              : () => Navigator.pop(context, CapturedKey(_hid!, _mods, _mode)),
          child: const Text('Save binding'),
        ),
      ],
    );
  }

  static String _describe(PlaybackMode m) => switch (m) {
        PlaybackMode.once => 'presses overlap',
        PlaybackMode.restart => 'starts over',
        PlaybackMode.loop => 'loops until pressed again',
        PlaybackMode.toggle => 'press again to stop',
        PlaybackMode.hold => 'plays while held',
      };
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF2E2415),
          border: Border.all(color: kWarn.withValues(alpha: 0.5)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.warning_amber_rounded, size: 15, color: kWarn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 11.5, color: kInkSoft)),
          ),
        ]),
      );
}

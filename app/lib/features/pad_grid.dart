// The board itself. One pad per binding, drawn like a keycap.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../models.dart';
import '../services/binding_service.dart';
import '../services/keyboard_service.dart';
import '../state.dart';

class PadGrid extends ConsumerWidget {
  const PadGrid({
    super.key,
    required this.pads,
    required this.onTrigger,
    required this.onEdit,
    required this.onRemove,
    required this.onImport,
  });

  final List<Pad> pads;
  final void Function(Pad) onTrigger;
  final void Function(Pad) onEdit;
  final Future<void> Function(Pad) onRemove;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Subscribing here keeps playback indicators live without the board
    // snapshot rebuilding every time a voice starts.
    ref.watch(padActivityProvider);

    if (pads.isEmpty) {
      return _Empty(onImport: onImport);
    }

    return Padding(
      padding: const EdgeInsets.all(18),
      child: GridView.builder(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 168,
          mainAxisExtent: 132,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: pads.length,
        itemBuilder: (_, i) => _Pad(
          pad: pads[i],
          onTrigger: () => onTrigger(pads[i]),
          onEdit: () => onEdit(pads[i]),
          onRemove: () => onRemove(pads[i]),
        ),
      ),
    );
  }
}

class _Pad extends StatefulWidget {
  const _Pad({
    required this.pad,
    required this.onTrigger,
    required this.onEdit,
    required this.onRemove,
  });

  final Pad pad;
  final VoidCallback onTrigger;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  State<_Pad> createState() => _PadState();
}

class _PadState extends State<_Pad> with SingleTickerProviderStateMixin {
  bool _hovering = false;
  Ticker? _ticker;
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    // Repaints only while this pad has a voice alive, so an idle board costs
    // nothing.
    _ticker = createTicker((_) {
      final playing = BindingService.instance.isPadPlaying(widget.pad.binding.id);
      if (playing && _startedAt == null) _startedAt = DateTime.now();
      if (!playing && _startedAt != null) {
        _startedAt = null;
        if (mounted) setState(() {});
        return;
      }
      if (playing && mounted) setState(() {});
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  /// 0..1 through the clip, or null when nothing is playing. Loop and hold
  /// have no meaningful end, so they show a pulse instead of a bar.
  double? get _progress {
    final started = _startedAt;
    final len = widget.pad.sound.durationMs;
    if (started == null || len <= 0) return null;
    if (widget.pad.binding.mode == PlaybackMode.loop ||
        widget.pad.binding.mode == PlaybackMode.hold) {
      return null;
    }
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    final t = elapsed / len;
    return t.clamp(0.0, 1.0);
  }

  String get _keyLabel {
    final b = widget.pad.binding;
    final parts = <String>[
      if (b.modifiers & SbMod.ctrl != 0) 'Ctrl',
      if (b.modifiers & SbMod.shift != 0) 'Shift',
      if (b.modifiers & SbMod.alt != 0) 'Alt',
      if (b.modifiers & SbMod.meta != 0) 'Meta',
      hidLabel(b.physicalKeyId),
    ];
    return parts.join('+');
  }

  @override
  Widget build(BuildContext context) {
    final pad = widget.pad;
    final playing = BindingService.instance.isPadPlaying(pad.binding.id);
    final missing = pad.sound.isMissing;

    final borderColor = missing
        ? context.c.danger
        : playing
            ? context.c.accent
            : (_hovering ? context.c.ruleStrong : context.c.rule);

    return Semantics(
      button: true,
      enabled: !missing,
      label: '${pad.sound.name}, key $_keyLabel, '
          '${pad.binding.mode.label}'
          '${missing ? ", file missing" : ""}'
          '${playing ? ", playing" : ""}',
      onTap: missing ? null : widget.onTrigger,
      child: MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: missing ? null : widget.onTrigger,
        child: Container(
          decoration: BoxDecoration(
            color: playing ? Color(0xFF10312F) : context.c.panel,
            border: Border.all(color: borderColor, width: playing ? 1.6 : 1),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(
                    _keyLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: missing ? context.c.danger : context.c.accent,
                    ),
                  ),
                ),
                if (_hovering)
                  _MiniMenu(onEdit: widget.onEdit, onRemove: widget.onRemove),
              ]),
              SizedBox(height: 6),
              Text(
                pad.sound.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: context.c.ink, height: 1.25),
              ),
              Spacer(),
              // Progress through the clip, or a steady bar for open-ended modes.
              if (playing)
                Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: SizedBox(
                    height: 2,
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 2,
                      backgroundColor: context.c.rule,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(context.c.accent),
                    ),
                  ),
                ),
              Row(children: [
                Text(
                  missing ? 'FILE MISSING' : pad.binding.mode.label.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    letterSpacing: 1.1,
                    color: missing ? context.c.danger : context.c.muted,
                  ),
                ),
                Spacer(),
                Text(
                  pad.sound.durationLabel,
                  style: TextStyle(
                      fontFamily: 'monospace', fontSize: 9.5, color: context.c.muted),
                ),
              ]),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _MiniMenu extends StatelessWidget {
  const _MiniMenu({required this.onEdit, required this.onRemove});
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: '',
        padding: EdgeInsets.zero,
        iconSize: 16,
        color: context.c.panel,
        icon: Icon(Icons.more_horiz, color: context.c.muted),
        onSelected: (v) => v == 'edit' ? onEdit() : onRemove(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'edit', height: 36, child: Text('Change key or mode')),
          PopupMenuItem(value: 'remove', height: 36, child: Text('Remove binding')),
        ],
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.keyboard_outlined, size: 44, color: context.c.ruleStrong),
            SizedBox(height: 16),
            Text('No keys bound in this profile',
                style: TextStyle(fontSize: 15, color: context.c.inkSoft)),
            SizedBox(height: 6),
            SizedBox(
              width: 340,
              child: Text(
                'Add a sound, then use Assign key to pick the key that '
                'should trigger it. It will fire from any application.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.c.muted, height: 1.5),
              ),
            ),
            SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onImport,
              icon: Icon(Icons.library_add_outlined, size: 17),
              label: Text('Add sounds'),
              style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero)),
            ),
          ],
        ),
      );
}

// The board itself. One pad per binding, drawn like a keycap.

import 'package:flutter/material.dart';
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
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
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

class _PadState extends State<_Pad> {
  bool _hovering = false;

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
        ? kDanger
        : playing
            ? kAccent
            : (_hovering ? kRuleStrong : kRule);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: missing ? null : widget.onTrigger,
        child: Container(
          decoration: BoxDecoration(
            color: playing ? const Color(0xFF10312F) : kPanel,
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
                      color: missing ? kDanger : kAccent,
                    ),
                  ),
                ),
                if (_hovering)
                  _MiniMenu(onEdit: widget.onEdit, onRemove: widget.onRemove),
              ]),
              const SizedBox(height: 6),
              Text(
                pad.sound.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: kInk, height: 1.25),
              ),
              const Spacer(),
              Row(children: [
                Text(
                  missing ? 'FILE MISSING' : pad.binding.mode.label.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    letterSpacing: 1.1,
                    color: missing ? kDanger : kMuted,
                  ),
                ),
                const Spacer(),
                Text(
                  pad.sound.durationLabel,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 9.5, color: kMuted),
                ),
              ]),
            ],
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
        color: kPanel,
        icon: const Icon(Icons.more_horiz, color: kMuted),
        onSelected: (v) => v == 'edit' ? onEdit() : onRemove(),
        itemBuilder: (_) => const [
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
            const Icon(Icons.keyboard_outlined, size: 44, color: kRuleStrong),
            const SizedBox(height: 16),
            const Text('No keys bound in this profile',
                style: TextStyle(fontSize: 15, color: kInkSoft)),
            const SizedBox(height: 6),
            const SizedBox(
              width: 340,
              child: Text(
                'Add a sound, then use Assign key to pick the key that '
                'should trigger it. It will fire from any application.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: kMuted, height: 1.5),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.library_add_outlined, size: 17),
              label: const Text('Add sounds'),
              style: FilledButton.styleFrom(
                  shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero)),
            ),
          ],
        ),
      );
}

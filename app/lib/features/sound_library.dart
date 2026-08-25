// Left rail: everything imported, whether or not it has a key.

import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/audio_service.dart';
import '../services/keyboard_service.dart';

class SoundLibrary extends StatefulWidget {
  const SoundLibrary({
    super.key,
    required this.sounds,
    required this.pads,
    required this.onImport,
    required this.onAssign,
    required this.onRename,
    required this.onDelete,
    required this.onToggleFavourite,
    required this.sort,
    required this.onSortChanged,
  });

  final List<Sound> sounds;
  final List<Pad> pads;
  final VoidCallback onImport;
  final void Function(Sound) onAssign;
  final void Function(Sound) onRename;
  final void Function(Sound) onDelete;
  final void Function(Sound) onToggleFavourite;
  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSortChanged;

  @override
  State<SoundLibrary> createState() => _SoundLibraryState();
}

class _SoundLibraryState extends State<SoundLibrary> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? widget.sounds
        : widget.sounds
            .where((s) => s.name.toLowerCase().contains(q))
            .toList(growable: false);

    // Which sounds already have a key, so the list can say so.
    final boundKeys = <int, String>{};
    for (final p in widget.pads) {
      final parts = <String>[
        if (p.binding.modifiers & SbMod.ctrl != 0) 'Ctrl',
        if (p.binding.modifiers & SbMod.shift != 0) 'Shift',
        if (p.binding.modifiers & SbMod.alt != 0) 'Alt',
        if (p.binding.modifiers & SbMod.meta != 0) 'Meta',
        hidLabel(p.binding.physicalKeyId),
      ];
      boundKeys[p.sound.id] = parts.join('+');
    }

    return Container(
      color: context.c.sunk,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(children: [
              Text('LIBRARY',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1.6,
                      color: context.c.muted)),
              Spacer(),
              Text('${widget.sounds.length}',
                  style: TextStyle(
                      fontFamily: 'monospace', fontSize: 11, color: context.c.muted)),
              SizedBox(width: 4),
              PopupMenuButton<LibrarySort>(
                tooltip: 'Sort',
                iconSize: 15,
                padding: EdgeInsets.zero,
                icon: Icon(Icons.sort, color: context.c.muted),
                onSelected: widget.onSortChanged,
                itemBuilder: (_) => [
                  for (final s in LibrarySort.values)
                    CheckedPopupMenuItem(
                      value: s,
                      checked: s == widget.sort,
                      height: 36,
                      child: Text(s.label),
                    ),
                ],
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: Icon(Icons.search, size: 17),
                contentPadding: EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
          Divider(height: 1, color: context.c.rule),
          Expanded(
            child: widget.sounds.isEmpty
                ? const _EmptyLibrary()
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: visible.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: context.c.rule),
                    itemBuilder: (_, i) => _Row(
                      sound: visible[i],
                      boundTo: boundKeys[visible[i].id],
                      onAssign: () => widget.onAssign(visible[i]),
                      onToggleFavourite: () =>
                          widget.onToggleFavourite(visible[i]),
                      onRename: () => widget.onRename(visible[i]),
                      onDelete: () => widget.onDelete(visible[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.sound,
    required this.boundTo,
    required this.onAssign,
    required this.onRename,
    required this.onDelete,
    required this.onToggleFavourite,
  });

  final Sound sound;
  final String? boundTo;
  final VoidCallback onAssign;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onToggleFavourite;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovering = false;
  bool _previewing = false;

  Future<void> _preview() async {
    final s = widget.sound;
    if (s.isMissing) return;
    setState(() => _previewing = true);
    final handle = await AudioService.instance.play(s.id, volume: s.volume);
    await Future<void>.delayed(
        s.durationMs > 0 ? s.duration : Duration(seconds: 1));
    if (handle != null) await AudioService.instance.stop(handle);
    if (mounted) setState(() => _previewing = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sound;
    return Semantics(
      label: '${s.name}, ${s.format}, ${s.durationLabel}'
          '${s.favourite ? ", starred" : ""}'
          '${widget.boundTo != null ? ", bound to ${widget.boundTo}" : ""}',
      child: Draggable<Sound>(
      data: s,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragChip(sound: s),
      childWhenDragging: Opacity(opacity: 0.35, child: _body(context, s)),
      child: _body(context, s),
      ),
    );
  }

  Widget _body(BuildContext context, Sound s) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        color: _hovering ? context.c.panel : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(children: [
          IconButton(
            onPressed: s.isMissing ? null : _preview,
            iconSize: 17,
            visualDensity: VisualDensity.compact,
            tooltip: 'Preview',
            icon: Icon(
              _previewing ? Icons.graphic_eq : Icons.play_arrow_rounded,
              color: _previewing ? context.c.accent : (s.isMissing ? context.c.muted : context.c.inkSoft),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: s.isMissing ? context.c.muted : context.c.ink)),
                SizedBox(height: 2),
                Row(children: [
                  Text(
                    s.isMissing ? 'FILE MISSING' : s.format,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9,
                        letterSpacing: 0.8,
                        color: s.isMissing ? context.c.danger : context.c.muted),
                  ),
                  SizedBox(width: 8),
                  Text(s.durationLabel,
                      style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9,
                          color: context.c.muted)),
                  if (widget.boundTo != null) ...[
                    SizedBox(width: 8),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      color: Color(0xFF10312F),
                      child: Text(widget.boundTo!,
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: context.c.accent)),
                    ),
                  ],
                ]),
              ],
            ),
          ),
          if (_hovering || s.favourite)
            IconButton(
              onPressed: widget.onToggleFavourite,
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              tooltip: s.favourite ? 'Unstar' : 'Star',
              icon: Icon(s.favourite ? Icons.star : Icons.star_border,
                  color: s.favourite ? context.c.warn : context.c.muted),
            ),
          if (_hovering) ...[
            IconButton(
              onPressed: widget.onAssign,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              tooltip: widget.boundTo == null ? 'Assign key' : 'Change key',
              icon: Icon(Icons.keyboard_outlined, color: context.c.inkSoft),
            ),
            PopupMenuButton<String>(
              tooltip: '',
              iconSize: 16,
              color: context.c.panel,
              icon: Icon(Icons.more_vert, color: context.c.muted),
              onSelected: (v) =>
                  v == 'rename' ? widget.onRename() : widget.onDelete(),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rename', height: 36, child: Text('Rename')),
                PopupMenuItem(value: 'delete', height: 36, child: Text('Delete')),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

/// What follows the cursor while dragging a sound onto a key.
class _DragChip extends StatelessWidget {
  const _DragChip({required this.sound});
  final Sound sound;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: context.c.accentSoft,
            border: Border.all(color: context.c.accent),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.graphic_eq, size: 13, color: context.c.accent),
            SizedBox(width: 6),
            Text(sound.name,
                style: TextStyle(fontSize: 12, color: context.c.accent)),
          ]),
        ),
      );
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.graphic_eq, size: 32, color: context.c.ruleStrong),
            SizedBox(height: 12),
            Text('No sounds yet',
                style: TextStyle(fontSize: 13, color: context.c.inkSoft)),
            SizedBox(height: 6),
            Text('MP3, WAV, OGG and FLAC',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: context.c.muted)),
          ],
        ),
      );
}

// The whole keyboard, drawn to scale, with bound keys picked out.
//
// Two jobs: see at a glance which keys are taken, and assign one without
// having to press it — click an empty key, or drag a sound onto any key.

import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/keyboard_service.dart';

/// One physical key: its HID usage and how many units wide it is.
class _Key {
  final int hid;
  final double width;
  final String? label; // overrides the derived label where it reads better
  const _Key(this.hid, {this.width = 1, this.label});
}

/// A 60%-plus-navigation layout: enough to cover everything bindable without
/// pretending to model every keyboard ever made.
const List<List<_Key>> _rows = [
  [
    _Key(0x00070029, label: 'Esc'), _Key(_gapHid, width: 0.5),
    _Key(0x0007003A), _Key(0x0007003B), _Key(0x0007003C), _Key(0x0007003D),
    _Key(_gapHid, width: 0.25),
    _Key(0x0007003E), _Key(0x0007003F), _Key(0x00070040), _Key(0x00070041),
    _Key(_gapHid, width: 0.25),
    _Key(0x00070042), _Key(0x00070043), _Key(0x00070044), _Key(0x00070045),
    _Key(_gapHid, width: 0.25),
    _Key(0x00070046, label: 'PrtSc'), _Key(0x00070047, label: 'ScrLk'),
    _Key(0x00070048, label: 'Pause'),
  ],
  [
    _Key(0x00070035), _Key(0x0007001E), _Key(0x0007001F), _Key(0x00070020),
    _Key(0x00070021), _Key(0x00070022), _Key(0x00070023), _Key(0x00070024),
    _Key(0x00070025), _Key(0x00070026), _Key(0x00070027), _Key(0x0007002D),
    _Key(0x0007002E), _Key(0x0007002A, width: 2, label: 'Bksp'),
    _Key(_gapHid, width: 0.25),
    _Key(0x00070049, label: 'Ins'), _Key(0x0007004A, label: 'Home'),
    _Key(0x0007004B, label: 'PgUp'),
  ],
  [
    _Key(0x0007002B, width: 1.5, label: 'Tab'),
    _Key(0x00070014), _Key(0x0007001A), _Key(0x00070008), _Key(0x00070015),
    _Key(0x00070017), _Key(0x0007001C), _Key(0x00070018), _Key(0x0007000C),
    _Key(0x00070012), _Key(0x00070013), _Key(0x0007002F), _Key(0x00070030),
    _Key(0x00070031, width: 1.5),
    _Key(_gapHid, width: 0.25),
    _Key(0x0007004C, label: 'Del'), _Key(0x0007004D, label: 'End'),
    _Key(0x0007004E, label: 'PgDn'),
  ],
  [
    _Key(0x00070039, width: 1.75, label: 'Caps'),
    _Key(0x00070004), _Key(0x00070016), _Key(0x00070007), _Key(0x00070009),
    _Key(0x0007000A), _Key(0x0007000B), _Key(0x0007000D), _Key(0x0007000E),
    _Key(0x0007000F), _Key(0x00070033), _Key(0x00070034),
    _Key(0x00070028, width: 2.25, label: 'Enter'),
  ],
  [
    _Key(0x000700E1, width: 2.25, label: 'Shift'),
    _Key(0x0007001D), _Key(0x0007001B), _Key(0x00070006), _Key(0x00070019),
    _Key(0x00070005), _Key(0x00070011), _Key(0x00070010), _Key(0x00070036),
    _Key(0x00070037), _Key(0x00070038),
    _Key(0x000700E5, width: 1.75, label: 'Shift'),
    _Key(_gapHid, width: 1.25),
    _Key(0x00070052, label: '↑'),
  ],
  [
    _Key(0x000700E0, width: 1.25, label: 'Ctrl'),
    _Key(0x000700E3, width: 1.25, label: 'Meta'),
    _Key(0x000700E2, width: 1.25, label: 'Alt'),
    _Key(0x0007002C, width: 6.25, label: 'Space'),
    _Key(0x000700E6, width: 1.25, label: 'Alt'),
    _Key(0x00070065, width: 1.25, label: 'Menu'),
    _Key(0x000700E4, width: 1.25, label: 'Ctrl'),
    _Key(_gapHid, width: 0.25),
    _Key(0x00070050, label: '←'), _Key(0x00070051, label: '↓'),
    _Key(0x0007004F, label: '→'),
  ],
];

const int _gapHid = -1;

class KeyboardMap extends StatelessWidget {
  const KeyboardMap({
    super.key,
    required this.pads,
    required this.onAssignKey,
    required this.onOpenBinding,
    required this.onDropSound,
  });

  /// Bindings in the active profile.
  final List<Pad> pads;

  /// An unbound key was clicked — pick a sound for it.
  final void Function(int hid, int modifiers) onAssignKey;

  /// A bound key was clicked — edit or fire it.
  final void Function(Pad pad) onOpenBinding;

  /// A sound was dragged onto a key.
  final void Function(Sound sound, int hid, int modifiers) onDropSound;

  @override
  Widget build(BuildContext context) {
    // Only bare (unmodified) bindings can be shown on a flat keyboard; the
    // rest are counted so the number is never silently wrong.
    final bare = <int, Pad>{};
    var withModifiers = 0;
    for (final p in pads) {
      if (p.binding.modifiers == 0) {
        bare[p.binding.physicalKeyId] = p;
      } else {
        withModifiers++;
      }
    }

    return LayoutBuilder(builder: (context, box) {
      // 15.5 units is the widest row plus the navigation cluster.
      final unit = ((box.maxWidth - 32) / 19.5).clamp(22.0, 46.0);
      final keyH = unit;

      return SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('KEYBOARD',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      letterSpacing: 1.6,
                      color: context.c.muted)),
              SizedBox(width: 12),
              _Legend(colour: context.c.accent, label: 'bound'),
              SizedBox(width: 10),
              _Legend(colour: context.c.ruleStrong, label: 'free'),
              Spacer(),
              if (withModifiers > 0)
                Text(
                  '$withModifiers binding${withModifiers == 1 ? "" : "s"} '
                  'use modifiers and are not shown here',
                  style: TextStyle(fontSize: 11, color: context.c.muted),
                ),
            ]),
            SizedBox(height: 14),
            for (final row in _rows) ...[
              Row(
                children: [
                  for (final k in row)
                    if (k.hid == _gapHid)
                      SizedBox(width: unit * k.width)
                    else
                      _KeyCap(
                        hid: k.hid,
                        label: k.label ?? hidLabel(k.hid),
                        width: unit * k.width,
                        height: keyH,
                        pad: bare[k.hid],
                        onTap: () {
                          final p = bare[k.hid];
                          if (p != null) {
                            onOpenBinding(p);
                          } else {
                            onAssignKey(k.hid, 0);
                          }
                        },
                        onDrop: (sound) => onDropSound(sound, k.hid, 0),
                      ),
                ],
              ),
              SizedBox(height: 4),
            ],
            SizedBox(height: 10),
            Text(
              'Click a free key to bind a sound to it, or drag one across from '
              'the library. Click a bound key to change it.',
              style: TextStyle(fontSize: 11.5, color: context.c.muted),
            ),
          ],
        ),
      );
    });
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.colour, required this.label});
  final Color colour;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 9, height: 9, color: colour),
        SizedBox(width: 5),
        Text(label,
            style: TextStyle(fontSize: 10.5, color: context.c.muted)),
      ]);
}

class _KeyCap extends StatefulWidget {
  const _KeyCap({
    required this.hid,
    required this.label,
    required this.width,
    required this.height,
    required this.pad,
    required this.onTap,
    required this.onDrop,
  });

  final int hid;
  final String label;
  final double width;
  final double height;
  final Pad? pad;
  final VoidCallback onTap;
  final void Function(Sound) onDrop;

  @override
  State<_KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<_KeyCap> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bound = widget.pad != null;
    final c = context.c;

    return DragTarget<Sound>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => widget.onDrop(d.data),
      builder: (context, candidate, _) {
        final hot = candidate.isNotEmpty;
        return Semantics(
          button: true,
          label: bound
              ? '${widget.label} key, bound to ${widget.pad!.sound.name}. '
                  'Activate to change.'
              : '${widget.label} key, unbound. Activate to assign a sound.',
          onTap: widget.onTap,
          child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: Tooltip(
              message: bound
                  ? '${widget.label} → ${widget.pad!.sound.name}'
                  : '${widget.label} — free',
              waitDuration: Duration(milliseconds: 400),
              child: Container(
                width: widget.width - 4,
                height: widget.height,
                margin: EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: hot
                      ? c.accent.withValues(alpha: 0.35)
                      : bound
                          ? c.accentSoft
                          : (_hover ? c.sunk : c.panel),
                  border: Border.all(
                    color: hot
                        ? c.accent
                        : bound
                            ? c.accent
                            : (_hover ? c.ruleStrong : c.rule),
                    width: hot || bound ? 1.4 : 1,
                  ),
                ),
                padding: EdgeInsets.all(3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: widget.label.length > 4 ? 8 : 10,
                        fontWeight: bound ? FontWeight.bold : FontWeight.normal,
                        color: bound ? c.accent : c.inkSoft,
                      ),
                    ),
                    if (bound && widget.height > 30)
                      Text(
                        widget.pad!.sound.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 7.5, color: c.accent),
                      ),
                  ],
                ),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:window_manager/window_manager.dart';

import '../main.dart';
import '../models.dart';
import '../services/audio_service.dart';
import '../services/binding_service.dart';
import '../services/database_service.dart';
import '../services/desktop_service.dart';
import '../services/keyboard_service.dart';
import '../services/library_service.dart';
import '../services/profile_io.dart';
import '../services/tray_service.dart';
import '../state.dart';
import 'assign_dialog.dart';
import 'diagnostics_panel.dart';
import 'keyboard_map.dart';
import 'pad_grid.dart';
import 'sound_library.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver, WindowListener {
  bool _booted = false;
  String? _bootError;
  StreamSubscription<int>? _trayClicks;
  bool _showKeyboard = false;
  bool _dropHover = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Drives "Application only" dispatch. Capture keeps running either way;
    // this only decides whether an unfocused keypress is allowed to fire.
    BindingService.instance.appFocused = state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    _trayClicks = TrayService.instance.clicks.listen(_onTrayClick);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(boardProvider.notifier).boot();
      } catch (e) {
        if (mounted) setState(() => _bootError = '$e');
      }
      if (mounted) setState(() => _booted = true);
    });
  }

  // --------------------------------------------------------------- actions

  Future<void> _import() async {
    final result = await LibraryService.instance.importWithPicker();
    if (result == null) return;
    await ref.read(boardProvider.notifier).refresh();
    if (!mounted) return;
    _toast(result.summary);
  }

  Future<void> _assign(Sound sound, {KeyBinding? existing}) async {
    final board = ref.read(boardProvider);
    final profile = board.active;
    if (profile == null) return;

    final captured = await showAssignDialog(
      context,
      soundName: sound.name,
      initialMode: existing?.mode ?? PlaybackMode.once,
      initialHid: existing?.physicalKeyId,
      initialMods: existing?.modifiers ?? 0,
    );
    if (captured == null) return;

    final db = DatabaseService.instance;

    if (existing != null) await db.deleteBinding(existing.id);

    final binding = KeyBinding(
      id: 0,
      profileId: profile.id,
      physicalKeyId: captured.hidUsage,
      modifiers: captured.modifiers,
      soundId: sound.id,
      mode: captured.mode,
      volume: existing?.volume ?? 1.0,
    );

    try {
      await db.insertBinding(binding);
    } on DuplicateBindingException {
      final clash =
          await db.bindingAt(profile.id, captured.hidUsage, captured.modifiers);
      final clashName = board.sounds
          .where((s) => s.id == clash?.soundId)
          .map((s) => s.name)
          .firstOrNull;

      if (!mounted) return;
      final replace = await _confirmReplace(captured, clashName ?? 'another sound');
      if (replace != true) {
        // Put the old binding back if we removed one on the way in.
        if (existing != null) await db.insertBinding(existing, replace: true);
        await ref.read(boardProvider.notifier).refresh();
        return;
      }
      await db.insertBinding(binding, replace: true);
    }

    await ref.read(boardProvider.notifier).refresh();
  }

  Future<bool?> _confirmReplace(CapturedKey k, String currentName) {
    final parts = <String>[
      if (k.modifiers & SbMod.ctrl != 0) 'Ctrl',
      if (k.modifiers & SbMod.shift != 0) 'Shift',
      if (k.modifiers & SbMod.alt != 0) 'Alt',
      if (k.modifiers & SbMod.meta != 0) 'Meta',
      hidLabel(k.hidUsage),
    ];
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule), borderRadius: BorderRadius.zero),
        title: Text('Key already assigned', style: TextStyle(fontSize: 16)),
        content: Text(
          '${parts.join(" + ")} is already assigned to $currentName.\n\n'
          'Replace the existing binding?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Replace')),
        ],
      ),
    );
  }

  Future<void> _deleteSound(Sound s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule), borderRadius: BorderRadius.zero),
        title: Text('Delete sound', style: TextStyle(fontSize: 16)),
        content: Text('Remove "${s.name}" and any keys bound to it?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await DatabaseService.instance.deleteSound(s);
    // Free the decoded copy too, or it lingers in memory for the session.
    await AudioService.instance.unload(s.id);
    await ref.read(boardProvider.notifier).refresh();
  }

  Future<void> _renameSound(Sound s) async {
    final controller = TextEditingController(text: s.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule), borderRadius: BorderRadius.zero),
        title: Text('Rename sound', style: TextStyle(fontSize: 16)),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text('Rename')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await DatabaseService.instance.updateSound(s.copyWith(name: name));
    await ref.read(boardProvider.notifier).refresh();
  }

  Future<void> _newProfile() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule), borderRadius: BorderRadius.zero),
        title: Text('New profile', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: 'Gaming, Streaming, …'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final id = await DatabaseService.instance.createProfile(name);
    await ref.read(boardProvider.notifier).switchProfile(id);
  }

  /// A key was clicked on the map: pick the sound, then bind it to that key.
  Future<void> _assignToKey(int hid, int modifiers) async {
    final board = ref.read(boardProvider);
    if (board.sounds.isEmpty) {
      _toast('Add a sound first.');
      return;
    }
    final sound = await showDialog<Sound>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule),
            borderRadius: BorderRadius.zero),
        title: Text('Bind ${hidLabel(hid)} to…',
            style: TextStyle(fontSize: 15)),
        children: [
          SizedBox(
            width: 360,
            height: 340,
            child: ListView(children: [
              for (final s in board.sounds)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.graphic_eq,
                      size: 15, color: context.c.muted),
                  title: Text(s.name, style: TextStyle(fontSize: 13)),
                  subtitle: Text('${s.format} · ${s.durationLabel}',
                      style: TextStyle(fontSize: 10.5)),
                  onTap: () => Navigator.pop(ctx, s),
                ),
            ]),
          ),
        ],
      ),
    );
    if (sound == null) return;
    await _bindDirect(sound, hid, modifiers);
  }

  /// Create a binding without the capture dialog — used by the map and by
  /// drag-and-drop, where the key is already known.
  Future<void> _bindDirect(Sound sound, int hid, int modifiers) async {
    final profile = ref.read(boardProvider).active;
    if (profile == null) return;
    final db = DatabaseService.instance;

    final binding = KeyBinding(
      id: 0,
      profileId: profile.id,
      physicalKeyId: hid,
      modifiers: modifiers,
      soundId: sound.id,
    );
    try {
      await db.insertBinding(binding);
    } on DuplicateBindingException {
      final clash = await db.bindingAt(profile.id, hid, modifiers);
      final clashName = ref
          .read(boardProvider)
          .sounds
          .where((s) => s.id == clash?.soundId)
          .map((s) => s.name)
          .firstOrNull;
      if (!mounted) return;
      final replace = await _confirm(
          'Key already assigned',
          '${hidLabel(hid)} is already assigned to '
              '${clashName ?? "another sound"}.\n\nReplace it?',
          'Replace');
      if (replace != true) return;
      await db.insertBinding(binding, replace: true);
    }
    await ref.read(boardProvider.notifier).refresh();
    if (mounted) _toast('${hidLabel(hid)} → ${sound.name}');
  }

  Future<void> _importDroppedFiles(List<String> paths) async {
    final result = await LibraryService.instance.importPaths(paths);
    await ref.read(boardProvider.notifier).refresh();
    if (mounted) _toast(result.summary);
  }

  Future<void> _renameProfile(Profile p) async {
    final name = await _promptText('Rename profile', initial: p.name, action: 'Rename');
    if (name == null || name.isEmpty) return;
    await DatabaseService.instance.renameProfile(p.id, name);
    await ref.read(boardProvider.notifier).refresh();
  }

  Future<void> _duplicateProfile(Profile p) async {
    final name = await _promptText('Duplicate profile',
        initial: '${p.name} copy', action: 'Duplicate');
    if (name == null || name.isEmpty) return;
    final id = await DatabaseService.instance.duplicateProfile(p.id, name);
    await ref.read(boardProvider.notifier).switchProfile(id);
    if (mounted) _toast('Duplicated to "$name"');
  }

  Future<void> _deleteProfile(Profile p) async {
    if (ref.read(boardProvider).profiles.length <= 1) {
      _toast('This is the only profile — create another first.');
      return;
    }
    final ok = await _confirm('Delete profile',
        'Delete "${p.name}" and all of its key bindings?\n\n'
        'Your sounds stay in the library.', 'Delete', danger: true);
    if (ok != true) return;
    await DatabaseService.instance.deleteProfile(p.id);
    await ref.read(boardProvider.notifier).refresh();
  }

  Future<void> _exportProfile(Profile p) async {
    final embed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule), borderRadius: BorderRadius.zero),
        title: Text('Export profile', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 400,
          child: Text(
            'Include the audio itself?\n\n'
            'With audio, the file works on any machine but is much larger. '
            'Without it, the file is tiny and relinks to sounds already in the '
            'target library.',
            style: TextStyle(fontSize: 12.5, color: context.c.inkSoft),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
          OutlinedButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Bindings only')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Include audio')),
        ],
      ),
    );
    if (embed == null) return;
    try {
      final path = await ProfileIO.instance.exportWithPicker(p, embedAudio: embed);
      if (path != null && mounted) _toast('Exported to $path');
    } catch (e) {
      if (mounted) _toast('Export failed: $e');
    }
  }

  Future<void> _importProfile() async {
    try {
      final report = await ProfileIO.instance.importWithPicker();
      if (report == null) return;
      await ref.read(boardProvider.notifier).refresh();
      if (!mounted) return;
      if (report.complete) {
        _toast('Imported ${report.summary}');
      } else {
        await _confirm(
          'Imported with gaps',
          '${report.summary}\n\n'
          'These sounds were not in the file and are not in your library, so '
          'their keys were skipped:\n\n'
          '${report.missingSounds.join(", ")}\n\n'
          'Import them by hand, then re-import this profile to relink.',
          'OK',
        );
      }
    } catch (e) {
      if (mounted) _toast('Import failed: $e');
    }
  }

  Future<String?> _promptText(String title,
      {String initial = '', String action = 'Save', String? hint}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule), borderRadius: BorderRadius.zero),
        title: Text(title, style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(action)),
        ],
      ),
    );
  }

  Future<bool?> _confirm(String title, String body, String action,
      {bool danger = false}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.c.panel,
        shape: RoundedRectangleBorder(
            side: BorderSide(color: context.c.rule), borderRadius: BorderRadius.zero),
        title: Text(title, style: TextStyle(fontSize: 16)),
        content: SizedBox(width: 420, child: Text(body)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: context.c.danger) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  /// The close button hides to the tray rather than quitting, when there is a
  /// tray to hide into. Quit lives in the tray menu.
  @override
  void onWindowClose() async {
    final board = ref.read(boardProvider);
    if (board.trayActive && board.closeToTray) {
      await DesktopService.instance.hideToTray();
    } else {
      await _quit();
    }
  }

  Future<void> _quit() async {
    await DesktopService.instance.releaseSingleInstance();
    TrayService.instance.stop();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  void _onTrayClick(int id) async {
    final notifier = ref.read(boardProvider.notifier);
    final board = ref.read(boardProvider);

    if (id >= TrayAction.profileIdBase) {
      await notifier.switchProfile(id - TrayAction.profileIdBase);
      return;
    }
    switch (id) {
      case TrayAction.activate:
      case TrayAction.open:
        await DesktopService.instance.restoreFromTray();
      case TrayAction.keyboardToggle:
        await notifier.setKeyboardEnabled(!board.keyboardEnabled);
      case TrayAction.globalToggle:
        await notifier.setGlobalMode(!board.globalMode);
      case TrayAction.stopAll:
        await notifier.stopAll();
      case TrayAction.quit:
        await _quit();
    }
  }

  @override
  void dispose() {
    _trayClicks?.cancel();
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: context.c.panel,
      behavior: SnackBarBehavior.floating,
      width: 360,
    ));
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (!_booted) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator(color: context.c.accent)),
      );
    }
    if (_bootError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Could not start:\n\n$_bootError',
                style: TextStyle(color: context.c.danger)),
          ),
        ),
      );
    }

    final board = ref.watch(boardProvider);

    return Scaffold(
      body: Column(
        children: [
          _Header(
            board: board,
            onProfileChanged: (id) =>
                ref.read(boardProvider.notifier).switchProfile(id),
            onNewProfile: _newProfile,
            onProfileAction: (action) {
              final p = ref.read(boardProvider).active;
              if (p == null) return;
              switch (action) {
                case 'rename': _renameProfile(p);
                case 'duplicate': _duplicateProfile(p);
                case 'delete': _deleteProfile(p);
                case 'export': _exportProfile(p);
                case 'import': _importProfile();
              }
            },
          ),
          _Toolbar(
            board: board,
            onImport: _import,
            onMasterVolume: (v) =>
                ref.read(boardProvider.notifier).setMasterVolume(v),
            onKeyboardToggle: (v) =>
                ref.read(boardProvider.notifier).setKeyboardEnabled(v),
            onStopAll: () => ref.read(boardProvider.notifier).stopAll(),
            onDiagnostics: () => showDiagnostics(context),
            onGlobalModeChanged: (v) =>
                ref.read(boardProvider.notifier).setGlobalMode(v),
            onSettings: () => showSettings(context),
            showKeyboard: _showKeyboard,
            onViewChanged: (v) => setState(() => _showKeyboard = v),
          ),
          if (board.keyboardError != null)
            _Banner(
              icon: Icons.keyboard_alt_outlined,
              color: context.c.danger,
              text: 'Global keyboard unavailable — ${board.keyboardError}',
            ),
          if (board.audioError != null)
            _Banner(
              icon: Icons.volume_off_outlined,
              color: context.c.danger,
              text: 'Audio engine failed — ${board.audioError}',
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 320,
                  child: SoundLibrary(
                    sounds: board.sounds,
                    pads: board.pads,
                    onImport: _import,
                    onAssign: (s) => _assign(s),
                    onRename: _renameSound,
                    onDelete: _deleteSound,
                    onToggleFavourite: (s) =>
                        ref.read(boardProvider.notifier).toggleFavourite(s),
                    sort: board.sort,
                    onSortChanged: (s) =>
                        ref.read(boardProvider.notifier).setSort(s),
                  ),
                ),
                VerticalDivider(width: 1, color: context.c.rule),
                Expanded(
                  child: DropTarget(
                    onDragEntered: (_) => setState(() => _dropHover = true),
                    onDragExited: (_) => setState(() => _dropHover = false),
                    onDragDone: (detail) {
                      setState(() => _dropHover = false);
                      _importDroppedFiles(
                          detail.files.map((f) => f.path).toList());
                    },
                    child: Stack(children: [
                      Positioned.fill(
                        child: _showKeyboard
                            ? KeyboardMap(
                                pads: board.pads,
                                onAssignKey: _assignToKey,
                                onOpenBinding: (p) =>
                                    _assign(p.sound, existing: p.binding),
                                onDropSound: (s, hid, mods) =>
                                    _bindDirect(s, hid, mods),
                              )
                            : PadGrid(
                                pads: board.pads,
                                onTrigger: (p) =>
                                    BindingService.instance.trigger(p.binding),
                                onEdit: (p) =>
                                    _assign(p.sound, existing: p.binding),
                                onRemove: (p) async {
                                  await DatabaseService.instance
                                      .deleteBinding(p.binding.id);
                                  await ref
                                      .read(boardProvider.notifier)
                                      .refresh();
                                },
                                onImport: _import,
                              ),
                      ),
                      if (_dropHover)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              color: context.c.accent.withValues(alpha: 0.14),
                              child: Center(
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 14),
                                  decoration: BoxDecoration(
                                    color: context.c.panel,
                                    border:
                                        Border.all(color: context.c.accent, width: 1.5),
                                  ),
                                  child: Text('Drop audio files to add them',
                                      style: TextStyle(
                                          fontSize: 14,
                                          color: context.c.accent)),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- bits

class _Header extends StatelessWidget {
  const _Header({
    required this.board,
    required this.onProfileChanged,
    required this.onNewProfile,
    required this.onProfileAction,
  });

  final BoardState board;
  final ValueChanged<int> onProfileChanged;
  final VoidCallback onNewProfile;
  final ValueChanged<String> onProfileAction;

  @override
  Widget build(BuildContext context) {
    final live = board.captureLive && board.keyboardEnabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: context.c.panel,
        border: Border(bottom: BorderSide(color: context.c.rule)),
      ),
      child: Row(children: [
        Icon(Icons.circle, size: 10, color: live ? context.c.accent : context.c.muted),
        SizedBox(width: 9),
        Text('RUCKUS',
            style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                letterSpacing: 2.4,
                fontSize: 13)),
        SizedBox(width: 14),
        Text(
          live
              ? 'listening globally · ${SbBackend.label(board.backend)}'
              : (board.captureLive ? 'keyboard off' : 'not capturing'),
          style: TextStyle(
              fontFamily: 'monospace', fontSize: 11, color: context.c.muted),
        ),
        Spacer(),
        Text('PROFILE',
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                letterSpacing: 1.4,
                color: context.c.muted)),
        SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: context.c.sunk, border: Border.all(color: context.c.rule)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: board.active?.id,
              dropdownColor: context.c.panel,
              style: TextStyle(fontSize: 13, color: context.c.ink),
              items: [
                for (final p in board.profiles)
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (id) => id == null ? null : onProfileChanged(id),
            ),
          ),
        ),
        IconButton(
          tooltip: 'New profile',
          onPressed: onNewProfile,
          icon: Icon(Icons.add, size: 18),
        ),
        PopupMenuButton<String>(
          tooltip: 'Profile actions',
          iconSize: 18,
          color: context.c.panel,
          icon: Icon(Icons.more_vert, color: context.c.muted),
          onSelected: onProfileAction,
          itemBuilder: (_) => [
            PopupMenuItem(value: 'rename', height: 36, child: Text('Rename')),
            PopupMenuItem(value: 'duplicate', height: 36, child: Text('Duplicate')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'export', height: 36, child: Text('Export…')),
            PopupMenuItem(value: 'import', height: 36, child: Text('Import…')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'delete', height: 36, child: Text('Delete')),
          ],
        ),
      ]),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.board,
    required this.onImport,
    required this.onMasterVolume,
    required this.onKeyboardToggle,
    required this.onStopAll,
    required this.onDiagnostics,
    required this.onGlobalModeChanged,
    required this.onSettings,
    required this.showKeyboard,
    required this.onViewChanged,
  });

  final BoardState board;
  final VoidCallback onImport;
  final ValueChanged<double> onMasterVolume;
  final ValueChanged<bool> onKeyboardToggle;
  final VoidCallback onStopAll;
  final VoidCallback onDiagnostics;
  final ValueChanged<bool> onGlobalModeChanged;
  final VoidCallback onSettings;
  final bool showKeyboard;
  final ValueChanged<bool> onViewChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: context.c.sunk,
        border: Border(bottom: BorderSide(color: context.c.rule)),
      ),
      child: Row(children: [
        FilledButton.icon(
          onPressed: onImport,
          icon: Icon(Icons.library_add_outlined, size: 17),
          label: Text('Add sounds'),
          style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero)),
        ),
        SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: onStopAll,
          icon: Icon(Icons.stop_rounded, size: 17),
          label: Text('Stop all'),
          style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero)),
        ),
        SizedBox(width: 16),
        _ViewToggle(showKeyboard: showKeyboard, onChanged: onViewChanged),
        SizedBox(width: 18),
        Text('MASTER',
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                letterSpacing: 1.4,
                color: context.c.muted)),
        SizedBox(
          width: 150,
          child: Slider(
            value: board.masterVolume,
            onChanged: onMasterVolume,
          ),
        ),
        SizedBox(
          width: 38,
          child: Text('${(board.masterVolume * 100).round()}%',
              style: TextStyle(
                  fontFamily: 'monospace', fontSize: 11.5, color: context.c.inkSoft)),
        ),
        Spacer(),
        _ModeToggle(
          global: board.globalMode,
          enabled: board.captureLive && board.keyboardEnabled,
          onChanged: onGlobalModeChanged,
        ),
        SizedBox(width: 18),
        Text('KEYS',
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                letterSpacing: 1.4,
                color: context.c.muted)),
        SizedBox(width: 8),
        Switch(
          value: board.keyboardEnabled,
          onChanged: board.captureLive ? onKeyboardToggle : null,
        ),
        SizedBox(width: 6),
        IconButton(
          tooltip: 'Diagnostics',
          onPressed: onDiagnostics,
          iconSize: 18,
          icon: Icon(Icons.speed_outlined, color: context.c.muted),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: onSettings,
          iconSize: 18,
          icon: Icon(Icons.tune, color: context.c.muted),
        ),
      ]),
    );
  }
}

/// Pads, or the whole keyboard.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.showKeyboard, required this.onChanged});
  final bool showKeyboard;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(IconData icon, String tip, bool isKeyboard) {
      final on = showKeyboard == isKeyboard;
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: on ? null : () => onChanged(isKeyboard),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: on ? context.c.accent.withValues(alpha: 0.18) : null,
            child: Icon(icon,
                size: 16, color: on ? context.c.accent : context.c.muted),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(border: Border.all(color: context.c.rule)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(Icons.grid_view, 'Pads', false),
        Container(width: 1, height: 22, color: context.c.rule),
        seg(Icons.keyboard, 'Keyboard map', true),
      ]),
    );
  }
}

/// Where keys are allowed to fire from. Both options keep capture running;
/// the difference is whether an unfocused keypress is dispatched.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.global,
    required this.enabled,
    required this.onChanged,
  });

  final bool global;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, bool isGlobal, String tip) {
      final on = global == isGlobal;
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: enabled && !on ? () => onChanged(isGlobal) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            color: on ? context.c.accent.withValues(alpha: 0.18) : Colors.transparent,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                letterSpacing: 1.1,
                fontWeight: on ? FontWeight.bold : FontWeight.normal,
                color: !enabled ? context.c.muted : (on ? context.c.accent : context.c.inkSoft),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(border: Border.all(color: context.c.rule)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('APP ONLY', false, 'Keys fire only while Ruckus is focused'),
        Container(width: 1, height: 22, color: context.c.rule),
        seg('GLOBAL', true, 'Keys fire from any application'),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        color: color.withValues(alpha: 0.12),
        child: Row(children: [
          Icon(icon, size: 16, color: color),
          SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12, color: color))),
        ]),
      );
}

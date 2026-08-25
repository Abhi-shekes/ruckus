// Riverpod wiring. UI state only — the keypress path never comes through here
// (PLAN D8).

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'services/audio_service.dart';
import 'services/binding_service.dart';
import 'services/database_service.dart';
import 'services/keyboard_service.dart';
import 'services/desktop_service.dart';
import 'services/library_service.dart';
import 'services/tray_service.dart';

final _db = DatabaseService.instance;
final _audio = AudioService.instance;
final _bindings = BindingService.instance;
final _keyboard = GlobalKeyboard.instance;
final _library = LibraryService.instance;
final _tray = TrayService.instance;
final _desktop = DesktopService.instance;

/// Everything the board needs to render, loaded as one consistent snapshot.
class BoardState {
  final List<Profile> profiles;
  final Profile? active;
  final List<Sound> sounds;
  final List<Pad> pads;
  final double masterVolume;
  final bool keyboardEnabled;
  final bool globalMode;
  final int backend;
  final String? keyboardError;
  final String? audioError;
  final ThemeMode themeMode;
  final LibrarySort sort;
  final bool trayActive;
  final bool closeToTray;
  final bool launchAtStartup;

  const BoardState({
    this.profiles = const [],
    this.active,
    this.sounds = const [],
    this.pads = const [],
    this.masterVolume = 0.8,
    this.keyboardEnabled = true,
    this.globalMode = true,
    this.backend = SbBackend.none,
    this.keyboardError,
    this.audioError,
    this.themeMode = ThemeMode.dark,
    this.sort = LibrarySort.name,
    this.trayActive = false,
    this.closeToTray = true,
    this.launchAtStartup = false,
  });

  bool get captureLive => backend != SbBackend.none && keyboardError == null;

  BoardState copyWith({
    List<Profile>? profiles,
    Profile? active,
    List<Sound>? sounds,
    List<Pad>? pads,
    double? masterVolume,
    bool? keyboardEnabled,
    bool? globalMode,
    int? backend,
    String? keyboardError,
    String? audioError,
    ThemeMode? themeMode,
    LibrarySort? sort,
    bool? trayActive,
    bool? closeToTray,
    bool? launchAtStartup,
  }) =>
      BoardState(
        profiles: profiles ?? this.profiles,
        active: active ?? this.active,
        sounds: sounds ?? this.sounds,
        pads: pads ?? this.pads,
        masterVolume: masterVolume ?? this.masterVolume,
        keyboardEnabled: keyboardEnabled ?? this.keyboardEnabled,
        globalMode: globalMode ?? this.globalMode,
        backend: backend ?? this.backend,
        keyboardError: keyboardError ?? this.keyboardError,
        audioError: audioError ?? this.audioError,
        themeMode: themeMode ?? this.themeMode,
        sort: sort ?? this.sort,
        trayActive: trayActive ?? this.trayActive,
        closeToTray: closeToTray ?? this.closeToTray,
        launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      );
}

class BoardNotifier extends Notifier<BoardState> {
  @override
  BoardState build() => const BoardState();

  Future<void> boot() async {
    final bootStart = DateTime.now();
    KeyLayout.load();
    await _db.init();

    String? audioError;
    try {
      await _audio.init();
    } catch (e) {
      audioError = '$e';
    }

    final master = await _db.getDouble('master_volume', 0.8);
    final kbOn = await _db.getBool('keyboard_enabled', true);
    final global = await _db.getBool('global_mode', true);
    final theme = switch (await _db.getSetting('theme_mode')) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    final sortName = await _db.getSetting('library_sort');
    final sort = LibrarySort.values
        .firstWhere((v) => v.name == sortName, orElse: () => LibrarySort.name);
    _audio.setMasterVolume(master);

    final sounds = await _db.sounds();
    await _library.preloadAll(sounds);

    // Start global capture. XRecord needs no permissions on an X11 session.
    String? kbError;
    final err = _keyboard.start();
    if (err != SbError.ok) kbError = err.message;
    _bindings
      ..enabled = kbOn
      ..globalMode = global
      ..attach();

    state = state.copyWith(
      masterVolume: master,
      keyboardEnabled: kbOn,
      globalMode: global,
      themeMode: theme,
      sort: sort,
      backend: _keyboard.activeBackend,
      keyboardError: kbError,
      audioError: audioError,
    );

    // Tray is best-effort: a desktop without a tray host is not an error.
    final trayOk = _tray.start();
    final closeToTray = await _db.getBool('close_to_tray', true);
    final startup = await _desktop.isLaunchAtStartupEnabled();
    if (trayOk) await _desktop.setCloseToTray(closeToTray);

    state = state.copyWith(
      trayActive: trayOk,
      closeToTray: closeToTray,
      launchAtStartup: startup,
    );

    await refresh();
    syncTray();

    bootMillis = DateTime.now().difference(bootStart).inMilliseconds;
  }

  /// Cold-start cost, surfaced in Diagnostics so regressions are visible.
  int bootMillis = 0;

  /// Pushes current state into the tray menu. Cheap; call after any change.
  void syncTray() {
    if (!state.trayActive) return;
    final items = <TrayMenuItem>[
      const TrayMenuItem(TrayAction.open, 'Open Ruckus'),
      const TrayMenuItem.separator(),
      for (var i = 0; i < state.profiles.length; i++)
        TrayMenuItem(
          TrayAction.profileIdBase + state.profiles[i].id,
          '  ${state.profiles[i].name}',
          checked: state.profiles[i].id == state.active?.id,
        ),
      const TrayMenuItem.separator(),
      TrayMenuItem(TrayAction.keyboardToggle, 'Keys enabled',
          checked: state.keyboardEnabled, enabled: state.captureLive),
      TrayMenuItem(TrayAction.globalToggle, 'Fire from any app',
          checked: state.globalMode, enabled: state.captureLive),
      const TrayMenuItem.separator(),
      const TrayMenuItem(TrayAction.stopAll, 'Stop all sounds'),
      const TrayMenuItem(TrayAction.quit, 'Quit'),
    ];
    _tray.setMenu(items);
    _tray.setTooltip(
      'Ruckus — ${state.active?.name ?? "no profile"} · '
      '${state.pads.length} key${state.pads.length == 1 ? "" : "s"}'
      '${state.keyboardEnabled ? "" : " (keys off)"}',
    );
  }

  Future<void> setThemeMode(ThemeMode m) async {
    state = state.copyWith(themeMode: m);
    await _db.setSetting('theme_mode', m.name);
  }

  Future<void> setSort(LibrarySort s) async {
    state = state.copyWith(sort: s);
    await _db.setSetting('library_sort', s.name);
    await refresh();
  }

  Future<void> toggleFavourite(Sound sound) async {
    await _db.updateSound(sound.copyWith(favourite: !sound.favourite));
    await refresh();
  }

  Future<void> setCloseToTray(bool on) async {
    state = state.copyWith(closeToTray: on);
    await _desktop.setCloseToTray(on && state.trayActive);
    await _db.setSetting('close_to_tray', on.toString());
  }

  Future<void> setLaunchAtStartup(bool on) async {
    await _desktop.setLaunchAtStartup(on);
    state = state.copyWith(launchAtStartup: on);
  }

  /// Reloads profiles, sounds and pads, then rebuilds the hot-path map.
  Future<void> refresh() async {
    final profiles = await _db.profiles();
    final active = await _db.activeProfile();
    final sounds = await _db.sounds();
    _applySort(sounds);
    final bindings = await _db.bindingsFor(active.id);

    final byId = {for (final s in sounds) s.id: s};
    final pads = <Pad>[
      for (final b in bindings)
        if (byId[b.soundId] != null) Pad(b, byId[b.soundId]!),
    ]..sort((a, b) => a.binding.physicalKeyId.compareTo(b.binding.physicalKeyId));

    _bindings.load(bindings, sounds);

    state = state.copyWith(
      profiles: profiles,
      active: active,
      sounds: sounds,
      pads: pads,
    );
    syncTray();
  }

  /// Favourites always float to the top; the chosen order applies within each
  /// group, so starring something never hides it further down the list.
  void _applySort(List<Sound> sounds) {
    int cmp(Sound a, Sound b) => switch (state.sort) {
          LibrarySort.name =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          LibrarySort.recent => b.id.compareTo(a.id),
          LibrarySort.duration => a.durationMs.compareTo(b.durationMs),
          LibrarySort.format => a.format.compareTo(b.format),
        };
    sounds.sort((a, b) {
      if (a.favourite != b.favourite) return a.favourite ? -1 : 1;
      return cmp(a, b);
    });
  }

  Future<void> setMasterVolume(double v) async {
    _audio.setMasterVolume(v);
    state = state.copyWith(masterVolume: v);
    await _db.setSetting('master_volume', v.toString());
  }

  Future<void> setKeyboardEnabled(bool on) async {
    _bindings.enabled = on;
    state = state.copyWith(keyboardEnabled: on);
    syncTray();
    await _db.setSetting('keyboard_enabled', on.toString());
  }

  Future<void> setGlobalMode(bool on) async {
    _bindings.globalMode = on;
    state = state.copyWith(globalMode: on);
    syncTray();
    await _db.setSetting('global_mode', on.toString());
  }

  Future<void> switchProfile(int id) async {
    await _db.setActiveProfile(id);
    await _bindings.stopAll();
    await refresh();
  }

  Future<void> stopAll() => _bindings.stopAll();
}

final boardProvider =
    NotifierProvider<BoardNotifier, BoardState>(BoardNotifier.new);

/// Live pad playback indicators, kept out of the board snapshot so a sound
/// starting does not rebuild the whole page.
final padActivityProvider = StreamProvider<PadActivity>(
    (ref) => BindingService.instance.activity);

/// Theme choice, watched by the root widget.
final themeModeProvider =
    Provider<ThemeMode>((ref) => ref.watch(boardProvider).themeMode);

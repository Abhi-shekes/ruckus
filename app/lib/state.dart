// Riverpod wiring. UI state only — the keypress path never comes through here
// (PLAN D8).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';
import 'services/audio_service.dart';
import 'services/binding_service.dart';
import 'services/database_service.dart';
import 'services/keyboard_service.dart';
import 'services/library_service.dart';

final _db = DatabaseService.instance;
final _audio = AudioService.instance;
final _bindings = BindingService.instance;
final _keyboard = GlobalKeyboard.instance;
final _library = LibraryService.instance;

/// Everything the board needs to render, loaded as one consistent snapshot.
class BoardState {
  final List<Profile> profiles;
  final Profile? active;
  final List<Sound> sounds;
  final List<Pad> pads;
  final double masterVolume;
  final bool keyboardEnabled;
  final int backend;
  final String? keyboardError;
  final String? audioError;

  const BoardState({
    this.profiles = const [],
    this.active,
    this.sounds = const [],
    this.pads = const [],
    this.masterVolume = 0.8,
    this.keyboardEnabled = true,
    this.backend = SbBackend.none,
    this.keyboardError,
    this.audioError,
  });

  bool get captureLive => backend != SbBackend.none && keyboardError == null;

  BoardState copyWith({
    List<Profile>? profiles,
    Profile? active,
    List<Sound>? sounds,
    List<Pad>? pads,
    double? masterVolume,
    bool? keyboardEnabled,
    int? backend,
    String? keyboardError,
    String? audioError,
  }) =>
      BoardState(
        profiles: profiles ?? this.profiles,
        active: active ?? this.active,
        sounds: sounds ?? this.sounds,
        pads: pads ?? this.pads,
        masterVolume: masterVolume ?? this.masterVolume,
        keyboardEnabled: keyboardEnabled ?? this.keyboardEnabled,
        backend: backend ?? this.backend,
        keyboardError: keyboardError ?? this.keyboardError,
        audioError: audioError ?? this.audioError,
      );
}

class BoardNotifier extends Notifier<BoardState> {
  @override
  BoardState build() => const BoardState();

  Future<void> boot() async {
    await _db.init();

    String? audioError;
    try {
      await _audio.init();
    } catch (e) {
      audioError = '$e';
    }

    final master = await _db.getDouble('master_volume', 0.8);
    final kbOn = await _db.getBool('keyboard_enabled', true);
    _audio.setMasterVolume(master);

    final sounds = await _db.sounds();
    await _library.preloadAll(sounds);

    // Start global capture. XRecord needs no permissions on an X11 session.
    String? kbError;
    final err = _keyboard.start();
    if (err != SbError.ok) kbError = err.message;
    _bindings
      ..enabled = kbOn
      ..attach();

    state = state.copyWith(
      masterVolume: master,
      keyboardEnabled: kbOn,
      backend: _keyboard.activeBackend,
      keyboardError: kbError,
      audioError: audioError,
    );

    await refresh();
  }

  /// Reloads profiles, sounds and pads, then rebuilds the hot-path map.
  Future<void> refresh() async {
    final profiles = await _db.profiles();
    final active = await _db.activeProfile();
    final sounds = await _db.sounds();
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
  }

  Future<void> setMasterVolume(double v) async {
    _audio.setMasterVolume(v);
    state = state.copyWith(masterVolume: v);
    await _db.setSetting('master_volume', v.toString());
  }

  Future<void> setKeyboardEnabled(bool on) async {
    _bindings.enabled = on;
    state = state.copyWith(keyboardEnabled: on);
    await _db.setSetting('keyboard_enabled', on.toString());
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

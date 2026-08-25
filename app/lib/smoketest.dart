// End-to-end check of everything below the UI: database, import, preload,
// binding lookup, dispatch, and each playback mode.
//
//   ./run.sh --smoketest [path/to/sounds/dir]
//
// Uses a scratch profile so it never disturbs the user's own board, and
// deletes it on the way out.

import 'dart:io';

import 'models.dart';
import 'services/audio_service.dart';
import 'services/binding_service.dart';
import 'services/database_service.dart';
import 'services/keyboard_service.dart';
import 'services/library_service.dart';

int _pass = 0, _fail = 0;

void _check(String name, bool ok, [String detail = '']) {
  stdout.writeln('[${ok ? "PASS" : "FAIL"}] $name${detail.isEmpty ? "" : "  — $detail"}');
  ok ? _pass++ : _fail++;
}

Future<void> runSmokeTest(List<String> args) async {
  final db = DatabaseService.instance;
  final audio = AudioService.instance;
  final bindings = BindingService.instance;
  final library = LibraryService.instance;

  stdout.writeln('\n═══ RUCKUS SMOKE TEST ═══\n');

  // ------------------------------------------------------------- database
  await db.init();
  _check('database opens', true, db.soundsDir.parent.path);

  final profileName = 'smoketest-${DateTime.now().millisecondsSinceEpoch}';
  final profileId = await db.createProfile(profileName);
  _check('profile created', profileId > 0, 'id=$profileId');

  // ---------------------------------------------------------------- audio
  var audioOk = true;
  try {
    await audio.init();
  } catch (e) {
    audioOk = false;
    stdout.writeln('    audio init failed: $e');
  }
  _check('audio engine starts', audioOk,
      audioOk ? 'buffer ${audio.bufferLatencyMs.toStringAsFixed(2)} ms' : '');

  // --------------------------------------------------------------- import
  final dir = Directory(args.isNotEmpty ? args.first : '../spike/assets/sounds');
  if (!dir.existsSync()) {
    _check('test sounds available', false, 'no directory ${dir.path}');
    _report();
    return;
  }
  final paths = dir
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => kSupportedFormats.contains(p.split('.').last.toLowerCase()))
      .toList()
    ..sort();

  final result = await library.importPaths(paths);
  final imported = [...result.added, ...result.duplicates];
  _check('import copies + hashes files', imported.length == paths.length,
      result.summary);

  // Re-importing the same files must dedupe, not duplicate.
  final again = await library.importPaths(paths);
  _check('re-import deduplicates by hash', again.added.isEmpty,
      '${again.duplicates.length} recognised as already present');

  // Every format decoded and got a real duration.
  final formats = imported.map((s) => s.format).toSet();
  _check('all four formats loaded',
      formats.containsAll({'WAV', 'MP3', 'OGG', 'FLAC'}), formats.join(' '));

  final loadedAll = imported.every((s) => audio.isLoaded(s.id));
  _check('every sound preloaded into memory', loadedAll);

  final allSounds = await db.sounds();
  final withDuration =
      allSounds.where((s) => s.durationMs > 0).length;
  _check('durations read back from decoded sources',
      withDuration == allSounds.length, '$withDuration/${allSounds.length}');

  // ------------------------------------------------------------- bindings
  const hids = [0x00070004, 0x00070016, 0x00070007, 0x00070009]; // A S D F
  const modes = [
    PlaybackMode.once,
    PlaybackMode.restart,
    PlaybackMode.loop,
    PlaybackMode.hold,
  ];

  for (var i = 0; i < imported.length && i < hids.length; i++) {
    await db.insertBinding(KeyBinding(
      id: 0,
      profileId: profileId,
      physicalKeyId: hids[i],
      modifiers: 0,
      soundId: imported[i].id,
      mode: modes[i],
    ));
  }
  final saved = await db.bindingsFor(profileId);
  _check('bindings persisted', saved.length == 4, '${saved.length} rows');

  // The UNIQUE constraint must reject a second binding on the same key.
  var rejected = false;
  try {
    await db.insertBinding(KeyBinding(
      id: 0,
      profileId: profileId,
      physicalKeyId: hids[0],
      modifiers: 0,
      soundId: imported.first.id,
    ));
  } on DuplicateBindingException {
    rejected = true;
  }
  _check('duplicate key rejected at the database', rejected);

  // …and accepted when the caller explicitly asks to replace.
  await db.insertBinding(
      KeyBinding(
        id: 0,
        profileId: profileId,
        physicalKeyId: hids[0],
        modifiers: 0,
        soundId: imported.last.id,
      ),
      replace: true);
  final afterReplace = await db.bindingsFor(profileId);
  _check('replace swaps instead of piling up', afterReplace.length == 4);

  // Modifiers are part of the identity: Ctrl+A is a different key from A.
  await db.insertBinding(KeyBinding(
    id: 0,
    profileId: profileId,
    physicalKeyId: hids[0],
    modifiers: SbMod.ctrl,
    soundId: imported.first.id,
  ));
  _check('modifiers distinguish bindings',
      (await db.bindingsFor(profileId)).length == 5);

  // ------------------------------------------------------- hot-path lookup
  final live = await db.bindingsFor(profileId);
  bindings.load(live, allSounds);
  _check('hot-path map built', bindings.bindingCount == live.length,
      '${bindings.bindingCount} entries');

  if (!audioOk) {
    _report();
    return;
  }

  // ------------------------------------------------------- playback modes
  final byKey = {for (final b in live) b.lookupKey: b};

  final onceBinding =
      live.firstWhere((b) => b.mode == PlaybackMode.once, orElse: () => live.first);
  bindings.trigger(onceBinding);
  bindings.trigger(onceBinding);
  await Future<void>.delayed(const Duration(milliseconds: 180));
  _check('play-once overlaps rather than cutting off', audio.voiceCount >= 2,
      '${audio.voiceCount} voices after two presses');

  await bindings.stopAll();
  await Future<void>.delayed(const Duration(milliseconds: 120));
  _check('stop all silences everything', audio.voiceCount == 0,
      '${audio.voiceCount} voices remain');

  final loopBinding = live.firstWhere((b) => b.mode == PlaybackMode.loop,
      orElse: () => live.first);
  bindings.trigger(loopBinding);
  await Future<void>.delayed(const Duration(milliseconds: 180));
  final loopStarted = bindings.isPadPlaying(loopBinding.id);
  bindings.trigger(loopBinding); // second press stops it
  await Future<void>.delayed(const Duration(milliseconds: 180));
  _check('loop toggles off on second press',
      loopStarted && !bindings.isPadPlaying(loopBinding.id));

  // Many voices at once, the way a fast roll of keys would.
  for (var i = 0; i < 10; i++) {
    bindings.trigger(byKey.values.elementAt(i % byKey.length));
  }
  await Future<void>.delayed(const Duration(milliseconds: 250));
  final peak = audio.voiceCount;
  await bindings.stopAll();
  _check('ten rapid presses overlap', peak >= 8, '$peak concurrent voices');

  // ---------------------------------------------------------------- clean
  await db.deleteProfile(profileId);
  final gone = (await db.profiles()).every((p) => p.name != profileName);
  _check('scratch profile removed', gone);

  _report();
}

void _report() {
  stdout.writeln('\n─────────────────────────────────────');
  stdout.writeln('$_pass passed, $_fail failed');
  stdout.writeln('');
  AudioService.instance.dispose();
  exit(_fail == 0 ? 0 : 1);
}

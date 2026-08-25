// Profile export / import.
//
// A `.ruckus` file is JSON: bindings keyed by USB HID usage code plus the
// SHA-256 of each sound (PLAN D5/D7). Because both are content identities
// rather than paths or scancodes, a profile round-trips between machines —
// and, if audio is embedded, between machines that have never shared a file.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';

import '../models.dart';
import 'audio_service.dart';
import 'database_service.dart';

const int kProfileFormatVersion = 1;
const String kProfileExtension = 'ruckus';

class ImportReport {
  final String profileName;
  final int bindingsAdded;
  final int soundsRestored;
  final List<String> missingSounds;

  const ImportReport({
    required this.profileName,
    required this.bindingsAdded,
    required this.soundsRestored,
    required this.missingSounds,
  });

  bool get complete => missingSounds.isEmpty;

  String get summary {
    final parts = <String>[
      '$bindingsAdded binding${bindingsAdded == 1 ? "" : "s"}',
      if (soundsRestored > 0) '$soundsRestored sound restored',
      if (missingSounds.isNotEmpty) '${missingSounds.length} sound missing',
    ];
    return '$profileName — ${parts.join(" · ")}';
  }
}

class ProfileIO {
  ProfileIO._();
  static final ProfileIO instance = ProfileIO._();

  final _db = DatabaseService.instance;
  final _audio = AudioService.instance;

  // ---------------------------------------------------------------- export

  /// Builds the document for [profile]. With [embedAudio] the actual audio is
  /// base64'd in, making the file self-contained but much larger.
  Future<String> buildDocument(Profile profile, {bool embedAudio = true}) async {
    final bindings = await _db.bindingsFor(profile.id);
    final allSounds = {for (final s in await _db.sounds()) s.id: s};

    final usedSounds = <String, Map<String, Object?>>{};
    final exported = <Map<String, Object?>>[];

    for (final b in bindings) {
      final sound = allSounds[b.soundId];
      if (sound == null) continue;

      exported.add({
        'physical_key_id': b.physicalKeyId,
        'modifiers': b.modifiers,
        'sound_hash': sound.fileHash,
        'playback_mode': b.mode.name,
        'volume': b.volume,
        'enabled': b.enabled,
      });

      if (usedSounds.containsKey(sound.fileHash)) continue;

      final entry = <String, Object?>{
        'name': sound.name,
        'format': sound.format,
        'duration_ms': sound.durationMs,
        'volume': sound.volume,
      };

      if (embedAudio && !sound.isMissing) {
        final file = File(_db.absolutePathFor(sound));
        if (file.existsSync()) {
          entry['audio_base64'] = base64Encode(await file.readAsBytes());
        }
      }
      usedSounds[sound.fileHash] = entry;
    }

    return const JsonEncoder.withIndent('  ').convert({
      'format': 'ruckus.profile',
      'version': kProfileFormatVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'profile': {'name': profile.name},
      'sounds': usedSounds,
      'bindings': exported,
    });
  }

  /// Returns the path written, or null if the user cancelled.
  Future<String?> exportWithPicker(Profile profile,
      {bool embedAudio = true}) async {
    final safeName = profile.name.replaceAll(RegExp(r'[^\w\- ]'), '_');
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export "${profile.name}"',
      fileName: '$safeName.$kProfileExtension',
      type: FileType.custom,
      allowedExtensions: const [kProfileExtension],
    );
    if (path == null) return null;

    final target = path.endsWith('.$kProfileExtension')
        ? path
        : '$path.$kProfileExtension';
    await File(target).writeAsString(
        await buildDocument(profile, embedAudio: embedAudio));
    return target;
  }

  // ---------------------------------------------------------------- import

  /// Returns null if the user cancelled.
  Future<ImportReport?> importWithPicker() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Import a profile',
      type: FileType.custom,
      allowedExtensions: const [kProfileExtension, 'json'],
    );
    final path = picked?.files.firstOrNull?.path;
    if (path == null) return null;
    return importFile(path);
  }

  Future<ImportReport> importFile(String path) async {
    final raw = jsonDecode(await File(path).readAsString());
    if (raw is! Map || raw['format'] != 'ruckus.profile') {
      throw const FormatException('Not a Ruckus profile file.');
    }
    final version = raw['version'] as int? ?? 0;
    if (version > kProfileFormatVersion) {
      throw FormatException(
          'This profile was written by a newer version of Ruckus (v$version).');
    }

    final wanted = (raw['profile'] as Map?)?['name'] as String? ?? 'Imported';
    final name = await _uniqueProfileName(wanted);
    final profileId = await _db.createProfile(name);

    final sounds = (raw['sounds'] as Map?) ?? const {};
    final bindings = (raw['bindings'] as List?) ?? const [];

    // hash -> local sound id
    final resolved = <String, int>{};
    final missing = <String>[];
    var restored = 0;

    for (final entry in sounds.entries) {
      final hash = entry.key as String;
      final meta = entry.value as Map;

      final existing = await _db.soundByHash(hash);
      if (existing != null) {
        resolved[hash] = existing.id;
        await _audio.preload(existing.id, _db.absolutePathFor(existing));
        continue;
      }

      final b64 = meta['audio_base64'] as String?;
      if (b64 == null) {
        missing.add(meta['name'] as String? ?? hash.substring(0, 8));
        continue;
      }

      // Never trust the declared hash — recompute and reject a mismatch.
      final bytes = base64Decode(b64);
      if (sha256.convert(bytes).toString() != hash) {
        missing.add('${meta['name'] ?? hash.substring(0, 8)} (corrupt)');
        continue;
      }

      final ext = (meta['format'] as String? ?? 'wav').toLowerCase();
      final dest = File('${_db.soundsDir.path}/$hash.$ext');
      if (!dest.existsSync()) await dest.writeAsBytes(bytes);

      final id = await _db.insertSound(Sound(
        id: 0,
        name: meta['name'] as String? ?? 'Imported sound',
        fileHash: hash,
        relPath: 'sounds/$hash.$ext',
        format: ext.toUpperCase(),
        durationMs: meta['duration_ms'] as int? ?? 0,
        volume: (meta['volume'] as num?)?.toDouble() ?? 1.0,
      ));
      await _audio.preload(id, dest.path);
      resolved[hash] = id;
      restored++;
    }

    var added = 0;
    for (final b in bindings) {
      final map = b as Map;
      final soundId = resolved[map['sound_hash']];
      if (soundId == null) continue; // its audio never arrived

      await _db.insertBinding(
        KeyBinding(
          id: 0,
          profileId: profileId,
          physicalKeyId: map['physical_key_id'] as int,
          modifiers: map['modifiers'] as int? ?? 0,
          soundId: soundId,
          mode: PlaybackMode.fromName(map['playback_mode'] as String?),
          volume: (map['volume'] as num?)?.toDouble() ?? 1.0,
          enabled: map['enabled'] as bool? ?? true,
        ),
        replace: true,
      );
      added++;
    }

    return ImportReport(
      profileName: name,
      bindingsAdded: added,
      soundsRestored: restored,
      missingSounds: missing,
    );
  }

  Future<String> _uniqueProfileName(String wanted) async {
    final taken = (await _db.profiles()).map((p) => p.name).toSet();
    if (!taken.contains(wanted)) return wanted;
    for (var i = 2;; i++) {
      final candidate = '$wanted ($i)';
      if (!taken.contains(candidate)) return candidate;
    }
  }
}

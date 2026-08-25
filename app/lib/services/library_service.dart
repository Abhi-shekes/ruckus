// Importing audio into the library.
//
// Files are copied in and named by the SHA-256 of their contents (PLAN D7), so
// the user's original can be moved or deleted freely, and importing the same
// sound twice deduplicates instead of piling up copies.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';

import '../models.dart';
import 'audio_service.dart';
import 'database_service.dart';

const kSupportedFormats = ['mp3', 'wav', 'ogg', 'flac'];

class ImportResult {
  final List<Sound> added;
  final List<Sound> duplicates;
  final List<String> rejected;
  const ImportResult(this.added, this.duplicates, this.rejected);

  int get total => added.length + duplicates.length + rejected.length;

  String get summary {
    final parts = <String>[
      if (added.isNotEmpty) '${added.length} added',
      if (duplicates.isNotEmpty) '${duplicates.length} already in library',
      if (rejected.isNotEmpty) '${rejected.length} unsupported',
    ];
    return parts.isEmpty ? 'Nothing imported' : parts.join(' · ');
  }
}

class LibraryService {
  LibraryService._();
  static final LibraryService instance = LibraryService._();

  final _db = DatabaseService.instance;
  final _audio = AudioService.instance;

  /// Opens the picker and imports whatever the user chose.
  /// Returns null if they cancelled.
  Future<ImportResult?> importWithPicker() async {
    final picked = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: kSupportedFormats,
      dialogTitle: 'Add sounds',
    );
    if (picked == null || picked.files.isEmpty) return null;
    return importPaths(picked.files
        .map((f) => f.path)
        .whereType<String>()
        .toList(growable: false));
  }

  Future<ImportResult> importPaths(List<String> paths) async {
    final added = <Sound>[];
    final duplicates = <Sound>[];
    final rejected = <String>[];

    for (final path in paths) {
      final file = File(path);
      final ext = path.split('.').last.toLowerCase();

      if (!file.existsSync() || !kSupportedFormats.contains(ext)) {
        rejected.add(path.split('/').last);
        continue;
      }

      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();

      final existing = await _db.soundByHash(hash);
      if (existing != null) {
        // Already in the library — but still make sure it is decoded, so
        // "imported" always means "playable". Cheap: preload is a no-op when
        // the source is loaded already.
        await _audio.preload(existing.id, _db.absolutePathFor(existing));
        duplicates.add(existing);
        continue;
      }

      final relPath = 'sounds/$hash.$ext';
      final dest = File('${_db.soundsDir.path}/$hash.$ext');
      if (!dest.existsSync()) await dest.writeAsBytes(bytes);

      var name = path.split('/').last;
      final dot = name.lastIndexOf('.');
      if (dot > 0) name = name.substring(0, dot);

      final id = await _db.insertSound(Sound(
        id: 0,
        name: name,
        fileHash: hash,
        relPath: relPath,
        format: ext.toUpperCase(),
        durationMs: 0,
      ));

      // Load it now so the first keypress never pays a decode, and so the
      // real duration can be read back off the decoded source.
      final len = await _audio.preload(id, dest.path);
      if (len != null) await _db.setSoundDuration(id, len.inMilliseconds);

      added.add(Sound(
        id: id,
        name: name,
        fileHash: hash,
        relPath: relPath,
        format: ext.toUpperCase(),
        durationMs: len?.inMilliseconds ?? 0,
      ));
    }

    return ImportResult(added, duplicates, rejected);
  }

  /// Decodes every sound in the library into memory at startup.
  Future<void> preloadAll(List<Sound> sounds) async {
    for (final s in sounds) {
      if (s.isMissing) continue;
      final len = await _audio.preload(s.id, _db.absolutePathFor(s));
      if (len != null && s.durationMs == 0) {
        await _db.setSoundDuration(s.id, len.inMilliseconds);
      }
    }
  }
}

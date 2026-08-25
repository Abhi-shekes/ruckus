// SQLite storage. Everything lives under the OS application-support directory:
//
//   ~/.local/share/soundboard/
//   ├── soundboard.db
//   └── sounds/<sha256>.<ext>
//
// Audio is content-addressed (PLAN D7), so the user can move or delete the
// files they imported from without breaking a single binding.

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models.dart';

class DuplicateBindingException implements Exception {
  final int physicalKeyId;
  final int modifiers;
  const DuplicateBindingException(this.physicalKeyId, this.modifiers);
}

class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  late final Database _db;
  late final Directory _root;
  late final Directory _soundsDir;

  Directory get soundsDir => _soundsDir;
  String absolutePathFor(Sound s) => '${_root.path}/${s.relPath}';

  Future<void> init() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final support = await getApplicationSupportDirectory();
    _root = Directory(support.path);
    _soundsDir = Directory('${_root.path}/sounds');
    if (!_soundsDir.existsSync()) _soundsDir.createSync(recursive: true);

    _db = await databaseFactory.openDatabase(
      '${_root.path}/soundboard.db',
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    await _ensureDefaultProfile();
    await _flagMissingFiles();
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE sounds (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT    NOT NULL,
        file_hash   TEXT    NOT NULL UNIQUE,
        rel_path    TEXT    NOT NULL,
        format      TEXT    NOT NULL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        volume      REAL    NOT NULL DEFAULT 1.0,
        is_missing  INTEGER NOT NULL DEFAULT 0,
        favourite   INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      )''');

    await db.execute('''
      CREATE TABLE profiles (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT    NOT NULL UNIQUE,
        is_active  INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )''');

    // The UNIQUE constraint is what makes conflict detection a guarantee
    // rather than a UI check that can be routed around (PLAN D7).
    await db.execute('''
      CREATE TABLE key_bindings (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        profile_id      INTEGER NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
        physical_key_id INTEGER NOT NULL,
        modifiers       INTEGER NOT NULL DEFAULT 0,
        sound_id        INTEGER NOT NULL REFERENCES sounds(id) ON DELETE CASCADE,
        playback_mode   TEXT    NOT NULL DEFAULT 'once',
        volume          REAL    NOT NULL DEFAULT 1.0,
        enabled         INTEGER NOT NULL DEFAULT 1,
        UNIQUE(profile_id, physical_key_id, modifiers)
      )''');

    await db.execute(
        'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }

  Future<void> _upgradeSchema(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute(
          'ALTER TABLE sounds ADD COLUMN favourite INTEGER NOT NULL DEFAULT 0');
    }
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  static int _countOf(List<Map<String, Object?>> rows) =>
      rows.isEmpty ? 0 : (rows.first.values.first as int? ?? 0);

  // ------------------------------------------------------------- profiles

  Future<void> _ensureDefaultProfile() async {
    final n = _countOf(await _db.rawQuery('SELECT COUNT(*) FROM profiles'));
    if (n == 0) {
      await _db.insert('profiles', {
        'name': 'Default',
        'is_active': 1,
        'created_at': _now,
        'updated_at': _now,
      });
    } else {
      final active = await _db
          .query('profiles', where: 'is_active = 1', limit: 1);
      if (active.isEmpty) {
        final first = await _db.query('profiles', orderBy: 'id', limit: 1);
        await setActiveProfile(first.first['id'] as int);
      }
    }
  }

  Future<List<Profile>> profiles() async =>
      (await _db.query('profiles', orderBy: 'name'))
          .map(Profile.fromMap)
          .toList();

  Future<Profile> activeProfile() async {
    final rows = await _db.query('profiles', where: 'is_active = 1', limit: 1);
    return Profile.fromMap(rows.first);
  }

  Future<void> setActiveProfile(int id) async {
    await _db.transaction((txn) async {
      await txn.update('profiles', {'is_active': 0});
      await txn.update('profiles', {'is_active': 1, 'updated_at': _now},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<int> createProfile(String name) => _db.insert('profiles', {
        'name': name,
        'is_active': 0,
        'created_at': _now,
        'updated_at': _now,
      });

  Future<void> renameProfile(int id, String name) => _db.update(
      'profiles', {'name': name, 'updated_at': _now},
      where: 'id = ?', whereArgs: [id]);

  Future<void> deleteProfile(int id) async {
    final count = _countOf(await _db.rawQuery('SELECT COUNT(*) FROM profiles'));
    if (count <= 1) return; // never leave the user with none
    final wasActive = (await _db.query('profiles',
            columns: ['is_active'], where: 'id = ?', whereArgs: [id]))
        .first['is_active'] as int;
    await _db.delete('profiles', where: 'id = ?', whereArgs: [id]);
    if (wasActive == 1) {
      final first = await _db.query('profiles', orderBy: 'id', limit: 1);
      await setActiveProfile(first.first['id'] as int);
    }
  }

  /// Copies every binding from [fromId] into a new profile.
  Future<int> duplicateProfile(int fromId, String newName) async {
    final newId = await createProfile(newName);
    final rows =
        await _db.query('key_bindings', where: 'profile_id = ?', whereArgs: [fromId]);
    for (final r in rows) {
      final b = KeyBinding.fromMap(r).toMap()..['profile_id'] = newId;
      await _db.insert('key_bindings', b);
    }
    return newId;
  }

  // --------------------------------------------------------------- sounds

  Future<List<Sound>> sounds() async =>
      (await _db.query('sounds', orderBy: 'name COLLATE NOCASE'))
          .map(Sound.fromMap)
          .toList();

  Future<Sound?> soundByHash(String hash) async {
    final rows =
        await _db.query('sounds', where: 'file_hash = ?', whereArgs: [hash]);
    return rows.isEmpty ? null : Sound.fromMap(rows.first);
  }

  Future<int> insertSound(Sound s) => _db.insert(
      'sounds', s.toMap()..addAll({'created_at': _now, 'updated_at': _now}));

  Future<void> updateSound(Sound s) => _db.update(
      'sounds', s.toMap()..['updated_at'] = _now,
      where: 'id = ?', whereArgs: [s.id]);

  /// Removes the row, its bindings (via cascade) and the file on disk — but
  /// only if no other row still references that hash.
  Future<void> deleteSound(Sound s) async {
    await _db.delete('sounds', where: 'id = ?', whereArgs: [s.id]);
    final others =
        await _db.query('sounds', where: 'file_hash = ?', whereArgs: [s.fileHash]);
    if (others.isEmpty) {
      final f = File(absolutePathFor(s));
      if (f.existsSync()) f.deleteSync();
    }
  }

  Future<void> _flagMissingFiles() async {
    for (final s in await sounds()) {
      final gone = !File(absolutePathFor(s)).existsSync();
      if (gone != s.isMissing) {
        await updateSound(s.copyWith(isMissing: gone));
      }
    }
  }

  Future<void> setSoundDuration(int id, int ms) => _db.update(
      'sounds', {'duration_ms': ms, 'updated_at': _now},
      where: 'id = ?', whereArgs: [id]);

  // ------------------------------------------------------------- bindings

  Future<List<KeyBinding>> bindingsFor(int profileId) async =>
      (await _db.query('key_bindings',
              where: 'profile_id = ?', whereArgs: [profileId]))
          .map(KeyBinding.fromMap)
          .toList();

  Future<KeyBinding?> bindingAt(int profileId, int hid, int mods) async {
    final rows = await _db.query('key_bindings',
        where: 'profile_id = ? AND physical_key_id = ? AND modifiers = ?',
        whereArgs: [profileId, hid, mods]);
    return rows.isEmpty ? null : KeyBinding.fromMap(rows.first);
  }

  /// Throws [DuplicateBindingException] if the key is taken, so the caller can
  /// offer Cancel / Replace rather than silently clobbering.
  Future<int> insertBinding(KeyBinding b, {bool replace = false}) async {
    final existing = await bindingAt(b.profileId, b.physicalKeyId, b.modifiers);
    if (existing != null) {
      if (!replace) {
        throw DuplicateBindingException(b.physicalKeyId, b.modifiers);
      }
      await _db.delete('key_bindings', where: 'id = ?', whereArgs: [existing.id]);
    }
    return _db.insert('key_bindings', b.toMap());
  }

  Future<void> updateBinding(KeyBinding b) => _db.update('key_bindings', b.toMap(),
      where: 'id = ?', whereArgs: [b.id]);

  Future<void> deleteBinding(int id) =>
      _db.delete('key_bindings', where: 'id = ?', whereArgs: [id]);

  // ------------------------------------------------------------- settings

  Future<String?> getSetting(String key) async {
    final rows =
        await _db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) => _db.insert(
      'settings', {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<double> getDouble(String key, double fallback) async =>
      double.tryParse(await getSetting(key) ?? '') ?? fallback;

  Future<bool> getBool(String key, bool fallback) async =>
      switch (await getSetting(key)) { 'true' => true, 'false' => false, _ => fallback };
}

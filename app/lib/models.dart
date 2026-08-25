// Domain types. Deliberately plain — no framework types leak in here.

/// What a key does when it fires.
enum PlaybackMode {
  /// Every press starts another voice. Presses overlap.
  once('Play once'),

  /// A press stops whatever this binding was playing and starts over.
  restart('Restart'),

  /// First press starts a loop, second press stops it.
  loop('Loop'),

  /// First press starts, second press stops. Like loop but plays through once.
  toggle('Toggle'),

  /// Sounds only while the key is held down.
  hold('Hold');

  const PlaybackMode(this.label);
  final String label;

  static PlaybackMode fromName(String? n) =>
      PlaybackMode.values.firstWhere((m) => m.name == n,
          orElse: () => PlaybackMode.once);
}

class Sound {
  final int id;
  final String name;

  /// SHA-256 of the file contents. Also its filename on disk, so moving or
  /// deleting the user's original cannot break a binding.
  final String fileHash;
  final String relPath;
  final String format;
  final int durationMs;
  final double volume;
  final bool isMissing;

  const Sound({
    required this.id,
    required this.name,
    required this.fileHash,
    required this.relPath,
    required this.format,
    required this.durationMs,
    this.volume = 1.0,
    this.isMissing = false,
  });

  Duration get duration => Duration(milliseconds: durationMs);

  String get durationLabel {
    final s = durationMs / 1000;
    return s < 60
        ? '${s.toStringAsFixed(1)}s'
        : '${(s ~/ 60)}:${(s % 60).toStringAsFixed(0).padLeft(2, '0')}';
  }

  Sound copyWith({String? name, double? volume, bool? isMissing}) => Sound(
        id: id,
        name: name ?? this.name,
        fileHash: fileHash,
        relPath: relPath,
        format: format,
        durationMs: durationMs,
        volume: volume ?? this.volume,
        isMissing: isMissing ?? this.isMissing,
      );

  factory Sound.fromMap(Map<String, Object?> m) => Sound(
        id: m['id'] as int,
        name: m['name'] as String,
        fileHash: m['file_hash'] as String,
        relPath: m['rel_path'] as String,
        format: m['format'] as String,
        durationMs: m['duration_ms'] as int? ?? 0,
        volume: (m['volume'] as num?)?.toDouble() ?? 1.0,
        isMissing: (m['is_missing'] as int? ?? 0) == 1,
      );

  Map<String, Object?> toMap() => {
        'name': name,
        'file_hash': fileHash,
        'rel_path': relPath,
        'format': format,
        'duration_ms': durationMs,
        'volume': volume,
        'is_missing': isMissing ? 1 : 0,
      };
}

class Profile {
  final int id;
  final String name;
  final bool isActive;

  const Profile({required this.id, required this.name, this.isActive = false});

  factory Profile.fromMap(Map<String, Object?> m) => Profile(
        id: m['id'] as int,
        name: m['name'] as String,
        isActive: (m['is_active'] as int? ?? 0) == 1,
      );
}

class KeyBinding {
  final int id;
  final int profileId;

  /// USB HID usage id — the portable key identity (PLAN D5).
  final int physicalKeyId;
  final int modifiers;
  final int soundId;
  final PlaybackMode mode;
  final double volume;
  final bool enabled;

  const KeyBinding({
    required this.id,
    required this.profileId,
    required this.physicalKeyId,
    required this.modifiers,
    required this.soundId,
    this.mode = PlaybackMode.once,
    this.volume = 1.0,
    this.enabled = true,
  });

  /// The hot-path lookup key: identity plus modifier state in one int.
  int get lookupKey => (physicalKeyId << 4) | (modifiers & 0xF);

  static int lookupKeyFor(int hid, int mods) => (hid << 4) | (mods & 0xF);

  factory KeyBinding.fromMap(Map<String, Object?> m) => KeyBinding(
        id: m['id'] as int,
        profileId: m['profile_id'] as int,
        physicalKeyId: m['physical_key_id'] as int,
        modifiers: m['modifiers'] as int? ?? 0,
        soundId: m['sound_id'] as int,
        mode: PlaybackMode.fromName(m['playback_mode'] as String?),
        volume: (m['volume'] as num?)?.toDouble() ?? 1.0,
        enabled: (m['enabled'] as int? ?? 1) == 1,
      );

  Map<String, Object?> toMap() => {
        'profile_id': profileId,
        'physical_key_id': physicalKeyId,
        'modifiers': modifiers,
        'sound_id': soundId,
        'playback_mode': mode.name,
        'volume': volume,
        'enabled': enabled ? 1 : 0,
      };
}

/// A binding joined to the sound it fires — what the pad grid renders.
class Pad {
  final KeyBinding binding;
  final Sound sound;
  const Pad(this.binding, this.sound);
}

// Dart side of the global keyboard bridge.
//
// The native capture thread calls straight into a NativeCallable.listener,
// which posts onto this isolate's event loop. No platform channel is involved,
// so capture is unaffected by whether the window is focused, minimised or
// hidden entirely (PLAN.md D4).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------- constants

class SbBackend {
  static const none = 0;
  static const x11 = 1;
  static const evdev = 2;

  static String label(int id) => switch (id) {
        x11 => 'X11 / XRecord',
        evdev => 'evdev',
        _ => 'none',
      };
}

class SbMod {
  static const ctrl = 1;
  static const shift = 2;
  static const alt = 4;
  static const meta = 8;
}

enum KeyKind { up, down, repeat }

/// Why a start attempt failed. The evdev permission case is the actionable one.
enum SbError {
  ok,
  alreadyRunning,
  noDisplay,
  noXRecord,
  noContext,
  noPermission,
  noDevice,
  threadFailed,
  libraryMissing;

  static SbError fromCode(int c) => switch (c) {
        0 => ok,
        -1 => alreadyRunning,
        -2 => noDisplay,
        -3 => noXRecord,
        -4 => noContext,
        -5 => noPermission,
        -6 => noDevice,
        -7 => threadFailed,
        _ => noDevice,
      };

  String get message => switch (this) {
        ok => 'ok',
        alreadyRunning => 'Capture is already running.',
        noDisplay => 'No X display. Set DISPLAY, or use the evdev backend.',
        noXRecord => 'This X server has no XRecord extension.',
        noContext => 'XRecord refused to create a capture context.',
        noPermission =>
          'No read access to /dev/input/event*. Run:\n'
              '  sudo usermod -aG input \$USER\n'
              'then log out and back in.',
        noDevice => 'No keyboard device found.',
        threadFailed => 'Could not start the capture thread.',
        libraryMissing => 'libruckus_keys.so was not found in the bundle.',
      };
}

// ---------------------------------------------------------------- event type

class GlobalKeyEvent {
  /// USB HID usage id, page included — the same value as
  /// `PhysicalKeyboardKey.usbHidUsage`, so bindings are portable (PLAN.md D5).
  final int hidUsage;
  final KeyKind kind;
  final int modifiers;

  /// CLOCK_MONOTONIC microseconds, stamped in native code the moment the event
  /// arrived. Compare against [receivedUs] to measure the bridge hop.
  final int nativeUs;
  final int receivedUs;

  const GlobalKeyEvent({
    required this.hidUsage,
    required this.kind,
    required this.modifiers,
    required this.nativeUs,
    required this.receivedUs,
  });

  int get bridgeLatencyUs => receivedUs - nativeUs;

  bool get ctrl => modifiers & SbMod.ctrl != 0;
  bool get shift => modifiers & SbMod.shift != 0;
  bool get alt => modifiers & SbMod.alt != 0;
  bool get meta => modifiers & SbMod.meta != 0;

  /// Stable lookup key: HID usage plus modifier state, as the real app's
  /// `Map<int, KeyBinding>` will use (PLAN.md D8).
  int get bindingKey => (hidUsage << 4) | (modifiers & 0xF);

  String get modifierLabel {
    final parts = <String>[
      if (ctrl) 'Ctrl',
      if (shift) 'Shift',
      if (alt) 'Alt',
      if (meta) 'Meta',
    ];
    return parts.join(' + ');
  }

  String get label {
    final m = modifierLabel;
    final k = hidLabel(hidUsage);
    return m.isEmpty ? k : '$m + $k';
  }

  @override
  String toString() => '${kind.name.toUpperCase()} $label';
}

/// True for Ctrl / Shift / Alt / Meta. A modifier on its own is never a
/// binding — the assign dialog waits for the key it modifies.
bool isModifier(int hidUsage) {
  final u = hidUsage & 0xFFFF;
  return u >= 0xE0 && u <= 0xE7;
}

/// Glyphs the active keyboard layout produces, filled in at startup by
/// [KeyLayout.load]. Empty until then, and only ever holds printable keys —
/// named keys like Enter keep their table names.
final Map<int, String> _layoutLabels = {};

/// Reads the active X11 layout so labels match the user's own keyboard rather
/// than assuming US QWERTY.
class KeyLayout {
  KeyLayout._();

  static String name = '';
  static bool loaded = false;

  /// Best-effort: on any failure the static table below is used unchanged.
  static void load() {
    if (loaded) return;
    loaded = true;
    final path = libraryPath();
    if (path == null) return;
    try {
      final lib = DynamicLibrary.open(path);
      final init = lib.lookupFunction<Int32 Function(), int Function()>(
          'sb_layout_init');
      if (init() != 0) return;

      final label = lib.lookupFunction<
          Int32 Function(Int32, Pointer<Uint8>, Int32),
          int Function(int, Pointer<Uint8>, int)>('sb_layout_label');
      final layoutName =
          lib.lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
              'sb_layout_name');

      final buf = calloc<Uint8>(16);
      try {
        // Only the keys whose legend actually varies by layout.
        for (final usage in _layoutSensitive) {
          final hid = 0x00070000 | usage;
          if (label(hid, buf, 16) != 0) continue;
          final bytes = <int>[];
          for (var i = 0; i < 16 && buf[i] != 0; i++) {
            bytes.add(buf[i]);
          }
          if (bytes.isEmpty) continue;
          final glyph = utf8.decode(bytes, allowMalformed: true).toUpperCase();
          if (glyph.isNotEmpty) _layoutLabels[hid] = glyph;
        }
        final np = layoutName();
        if (np.address != 0) {
          final nb = <int>[];
          for (var i = 0; i < 128 && np[i] != 0; i++) {
            nb.add(np[i]);
          }
          name = utf8.decode(nb, allowMalformed: true);
        }
      } finally {
        calloc.free(buf);
      }
    } catch (_) {
      // Layout detection is a nicety; never let it break startup.
    }
  }

  /// Letters, digits and punctuation — the keys a layout actually relabels.
  static final List<int> _layoutSensitive = [
    for (var u = 0x04; u <= 0x1D; u++) u, // A-Z positions
    for (var u = 0x1E; u <= 0x27; u++) u, // 1-0
    0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
  ];
}

/// Human-readable name for a HID usage id.
String hidLabel(int hidUsage) {
  final fromLayout = _layoutLabels[hidUsage];
  if (fromLayout != null) return fromLayout;

  final u = hidUsage & 0xFFFF;
  if (u >= 0x04 && u <= 0x1D) return String.fromCharCode(0x41 + (u - 0x04));
  if (u >= 0x1E && u <= 0x26) return String.fromCharCode(0x31 + (u - 0x1E));
  if (u == 0x27) return '0';
  if (u >= 0x3A && u <= 0x45) return 'F${u - 0x3A + 1}';
  if (u >= 0x68 && u <= 0x73) return 'F${u - 0x68 + 13}';
  if (u >= 0x59 && u <= 0x61) return 'Num${u - 0x59 + 1}';
  return const {
        0x28: 'Enter', 0x29: 'Esc', 0x2A: 'Backspace', 0x2B: 'Tab',
        0x2C: 'Space', 0x2D: 'Minus', 0x2E: 'Equal', 0x2F: '[',
        0x30: ']', 0x31: r'\', 0x33: ';', 0x34: "'",
        0x35: '`', 0x36: ',', 0x37: '.', 0x38: '/',
        0x39: 'CapsLock', 0x46: 'PrintScreen', 0x47: 'ScrollLock',
        0x48: 'Pause', 0x49: 'Insert', 0x4A: 'Home', 0x4B: 'PageUp',
        0x4C: 'Delete', 0x4D: 'End', 0x4E: 'PageDown', 0x4F: 'Right',
        0x50: 'Left', 0x51: 'Down', 0x52: 'Up', 0x53: 'NumLock',
        0x54: 'Num/', 0x55: 'Num*', 0x56: 'Num-', 0x57: 'Num+',
        0x58: 'NumEnter', 0x62: 'Num0', 0x63: 'Num.', 0x65: 'Menu',
        0xE0: 'LeftCtrl', 0xE1: 'LeftShift', 0xE2: 'LeftAlt', 0xE3: 'LeftMeta',
        0xE4: 'RightCtrl', 0xE5: 'RightShift', 0xE6: 'RightAlt',
        0xE7: 'RightMeta',
      }[u] ??
      '0x${u.toRadixString(16).toUpperCase()}';
}

// ---------------------------------------------------------------- ffi types

typedef _KeyCallbackNative = Void Function(Int32, Int32, Int32, Int64);

typedef _StartNative = Int32 Function(
    Pointer<NativeFunction<_KeyCallbackNative>>, Int32);
typedef _StartDart = int Function(
    Pointer<NativeFunction<_KeyCallbackNative>>, int);

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

typedef _NowNative = Int64 Function();
typedef _NowDart = int Function();

// ---------------------------------------------------------------- service

class GlobalKeyboard {
  GlobalKeyboard._();
  static final GlobalKeyboard instance = GlobalKeyboard._();

  DynamicLibrary? _lib;
  late final _StartDart _start;
  late final _VoidDart _stop;
  late final _IntDart _activeBackend;
  late final _NowDart _nowUs;

  NativeCallable<_KeyCallbackNative>? _callable;
  final _controller = StreamController<GlobalKeyEvent>.broadcast();

  /// Every captured transition. Down, up and auto-repeat all arrive here.
  Stream<GlobalKeyEvent> get events => _controller.stream;

  bool get isRunning => _callable != null;
  int get activeBackend => _lib == null ? SbBackend.none : _activeBackend();

  /// Monotonic microseconds on the same clock the native side stamps with.
  int nowUs() => _lib == null ? 0 : _nowUs();

  String? _resolveLibrary() => libraryPath();

  static String? _resolveLibraryImpl() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final candidate in [
      '$exeDir/lib/libruckus_keys.so',
      '$exeDir/libruckus_keys.so',
      'build/linux/x64/debug/bundle/lib/libruckus_keys.so',
      'build/linux/x64/release/bundle/lib/libruckus_keys.so',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  bool _ensureLoaded() {
    if (_lib != null) return true;
    final path = _resolveLibrary();
    if (path == null) return false;

    final lib = DynamicLibrary.open(path);
    _start = lib.lookupFunction<_StartNative, _StartDart>('sb_start');
    _stop = lib.lookupFunction<_VoidNative, _VoidDart>('sb_stop');
    _activeBackend =
        lib.lookupFunction<_IntNative, _IntDart>('sb_active_backend');
    _nowUs = lib.lookupFunction<_NowNative, _NowDart>('sb_now_us');
    _lib = lib;
    return true;
  }

  // Static because a NativeCallable needs a top-level or static target.
  static void _onKey(int hid, int kind, int mods, int tsUs) {
    final self = GlobalKeyboard.instance;
    self._controller.add(GlobalKeyEvent(
      hidUsage: hid,
      kind: KeyKind.values[kind.clamp(0, 2)],
      modifiers: mods,
      nativeUs: tsUs,
      receivedUs: self.nowUs(),
    ));
  }

  /// Starts capture. Pass [SbBackend.x11] or [SbBackend.evdev] to force one,
  /// or leave it as [SbBackend.none] to try evdev then fall back to XRecord.
  SbError start({int preferred = SbBackend.none}) {
    if (isRunning) return SbError.alreadyRunning;
    if (!_ensureLoaded()) return SbError.libraryMissing;

    final callable = NativeCallable<_KeyCallbackNative>.listener(_onKey);
    final rc = _start(callable.nativeFunction, preferred);

    if (rc != 0) {
      callable.close();
      return SbError.fromCode(rc);
    }
    _callable = callable;
    return SbError.ok;
  }

  void stop() {
    if (!isRunning) return;
    _stop();
    _callable!.close();
    _callable = null;
  }
}

/// Absolute path to the bundled native library, shared by every FFI service.
String? libraryPath() => GlobalKeyboard._resolveLibraryImpl();

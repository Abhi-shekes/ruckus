// Dart side of the system tray.
//
// Talks to sb_tray.c, which exports StatusNotifierItem + dbusmenu directly on
// the session bus. Menu clicks arrive on a NativeCallable.listener, the same
// mechanism the keyboard uses.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'keyboard_service.dart' show libraryPath;

/// Ids are stable so the click handler can switch on them. Profile entries are
/// allocated from [profileIdBase] upward.
class TrayAction {
  static const open = 1;
  static const keyboardToggle = 2;
  static const globalToggle = 3;
  static const stopAll = 4;
  static const quit = 5;
  static const activate = 1000000; // icon clicked
  static const profileIdBase = 2000;
}

class TrayMenuItem {
  final int id;
  final String label;
  final bool isSeparator;
  final bool? checked;
  final bool enabled;

  const TrayMenuItem(this.id, this.label,
      {this.checked, this.enabled = true, this.isSeparator = false});

  const TrayMenuItem.separator()
      : id = -1,
        label = '',
        isSeparator = true,
        checked = null,
        enabled = false;
}

typedef _TrayCallbackNative = Void Function(Int32);
typedef _StartNative = Int32 Function(Pointer<NativeFunction<_TrayCallbackNative>>);
typedef _StartDart = int Function(Pointer<NativeFunction<_TrayCallbackNative>>);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _AddItemNative = Void Function(
    Int32, Pointer<Utf8>, Int32, Int32, Int32);
typedef _AddItemDart = void Function(int, Pointer<Utf8>, int, int, int);
typedef _SetStrNative = Void Function(Pointer<Utf8>);
typedef _SetStrDart = void Function(Pointer<Utf8>);

class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  DynamicLibrary? _lib;
  late final _StartDart _start;
  late final _VoidDart _stop;
  late final _VoidDart _clear;
  late final _AddItemDart _addItem;
  late final _VoidDart _commit;
  late final _SetStrDart _setTooltip;

  NativeCallable<_TrayCallbackNative>? _callable;
  final _clicks = StreamController<int>.broadcast();

  /// Menu item ids as they are clicked. [TrayAction.activate] for the icon.
  Stream<int> get clicks => _clicks.stream;

  bool get isRunning => _callable != null;
  String? lastError;

  static void _onClick(int id) => TrayService.instance._clicks.add(id);

  bool _load() {
    if (_lib != null) return true;
    final path = libraryPath();
    if (path == null) return false;
    final lib = DynamicLibrary.open(path);
    _start = lib.lookupFunction<_StartNative, _StartDart>('sb_tray_start');
    _stop = lib.lookupFunction<_VoidNative, _VoidDart>('sb_tray_stop');
    _clear = lib.lookupFunction<_VoidNative, _VoidDart>('sb_tray_clear_menu');
    _addItem =
        lib.lookupFunction<_AddItemNative, _AddItemDart>('sb_tray_add_item');
    _commit = lib.lookupFunction<_VoidNative, _VoidDart>('sb_tray_commit_menu');
    _setTooltip =
        lib.lookupFunction<_SetStrNative, _SetStrDart>('sb_tray_set_tooltip');
    _lib = lib;
    return true;
  }

  /// Returns true if the icon was registered. A desktop with no tray host is
  /// not an error worth interrupting anyone over — the app works without it.
  bool start() {
    if (isRunning) return true;
    if (!Platform.isLinux) return false;
    if (!_load()) {
      lastError = 'native library not found';
      return false;
    }
    final callable = NativeCallable<_TrayCallbackNative>.listener(_onClick);
    final rc = _start(callable.nativeFunction);
    if (rc != 0) {
      callable.close();
      lastError = switch (rc) {
        -2 => 'no session D-Bus',
        -3 => 'could not export the tray interfaces',
        _ => 'tray unavailable ($rc)',
      };
      return false;
    }
    _callable = callable;
    return true;
  }

  void setMenu(List<TrayMenuItem> items) {
    if (!isRunning) return;
    _clear();
    for (final it in items) {
      final label = it.label.toNativeUtf8();
      _addItem(
        it.isSeparator ? -1 : it.id,
        label,
        it.isSeparator ? 2 : (it.checked != null ? 1 : 0),
        (it.checked ?? false) ? 1 : 0,
        it.enabled ? 1 : 0,
      );
      calloc.free(label);
    }
    _commit();
  }

  void setTooltip(String text) {
    if (!isRunning) return;
    final s = text.toNativeUtf8();
    _setTooltip(s);
    calloc.free(s);
  }

  void stop() {
    if (!isRunning) return;
    _stop();
    _callable!.close();
    _callable = null;
  }
}

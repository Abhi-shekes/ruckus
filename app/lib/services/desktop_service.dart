// Desktop integration: single instance, close-to-tray, launch at startup.

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

class DesktopService {
  DesktopService._();
  static final DesktopService instance = DesktopService._();

  File? _lockFile;
  RandomAccessFile? _lock;

  /// Takes an exclusive lock so a second launch can bow out rather than
  /// fighting the first over the tray icon and the keyboard hook.
  /// Returns false if another instance already holds it.
  Future<bool> claimSingleInstance() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _lockFile = File('${dir.path}/ruckus.lock');
      _lock = await _lockFile!.open(mode: FileMode.write);
      await _lock!.lock(FileLock.exclusive);
      await _lock!.writeString('$pid\n');
      await _lock!.flush();
      return true;
    } on FileSystemException {
      // Someone else holds the lock.
      await _lock?.close();
      _lock = null;
      return false;
    } catch (_) {
      // Never let a locking quirk stop the app from running.
      return true;
    }
  }

  Future<void> releaseSingleInstance() async {
    try {
      await _lock?.unlock();
      await _lock?.close();
    } catch (_) {/* nothing useful to do */}
    _lock = null;
  }

  /// Intercept the window close button so it hides to the tray instead of
  /// quitting. Only worth doing when there is a tray to hide into.
  Future<void> setCloseToTray(bool on) => windowManager.setPreventClose(on);

  Future<void> hideToTray() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  Future<void> restoreFromTray() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<bool> isVisible() => windowManager.isVisible();

  // ------------------------------------------------------ launch at startup

  Future<File> get _autostartFile async {
    final home = Platform.environment['HOME'] ?? '.';
    final dir = Directory(
        Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config');
    return File('${dir.path}/autostart/ruckus.desktop');
  }

  Future<bool> isLaunchAtStartupEnabled() async =>
      (await _autostartFile).existsSync();

  /// Writes a freedesktop autostart entry pointing at run.sh, which is what
  /// sets up the compatibility shims — launching the raw binary would skip
  /// them and fail on older Ubuntu.
  Future<void> setLaunchAtStartup(bool on) async {
    final file = await _autostartFile;
    if (!on) {
      if (file.existsSync()) await file.delete();
      return;
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // …/app/build/linux/x64/<mode>/bundle -> …/app
    var appDir = Directory(exeDir);
    for (var i = 0; i < 5 && appDir.parent.path != appDir.path; i++) {
      if (File('${appDir.path}/run.sh').existsSync()) break;
      appDir = appDir.parent;
    }
    final runner = File('${appDir.path}/run.sh').existsSync()
        ? '${appDir.path}/run.sh'
        : Platform.resolvedExecutable;

    await file.parent.create(recursive: true);
    await file.writeAsString('''
[Desktop Entry]
Type=Application
Name=Ruckus
Comment=Desktop soundboard with global hotkeys
Exec=$runner --tray
Icon=audio-x-generic
Terminal=false
X-GNOME-Autostart-enabled=true
''');
  }
}

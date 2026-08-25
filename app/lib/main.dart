import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:window_manager/window_manager.dart';

import 'features/home_page.dart';
import 'services/desktop_service.dart';
import 'state.dart';
import 'smoketest.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (args.contains('--smoketest')) {
    runSmokeTest(args.where((a) => !a.startsWith('--')).toList());
    return;
  }

  // A second copy would fight the first over the tray icon and the keyboard
  // hook, so bow out rather than starting two.
  if (!await DesktopService.instance.claimSingleInstance()) {
    stderr.writeln('Ruckus is already running.');
    exit(0);
  }

  await windowManager.ensureInitialized();
  final startHidden = args.contains('--tray');
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(880, 560),
      title: 'Ruckus',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      if (startHidden) {
        await windowManager.setSkipTaskbar(true);
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );

  runApp(const ProviderScope(child: RuckusApp()));
}

// One palette, two grounds. Colours are read through RuckusColors so every
// widget follows the active theme instead of hard-coding a dark value.

/// Teal accent — deliberately the same hue in both themes, darkened for light
/// so it stays legible on a pale ground.
const kAccentDark = Color(0xFF4FCBD4);
const kAccentLight = Color(0xFF0B6E77);

class RuckusColors extends ThemeExtension<RuckusColors> {
  final Color ground, panel, sunk, rule, ruleStrong;
  final Color ink, inkSoft, muted, accent, accentSoft, warn, danger;

  const RuckusColors({
    required this.ground,
    required this.panel,
    required this.sunk,
    required this.rule,
    required this.ruleStrong,
    required this.ink,
    required this.inkSoft,
    required this.muted,
    required this.accent,
    required this.accentSoft,
    required this.warn,
    required this.danger,
  });

  static const dark = RuckusColors(
    ground: Color(0xFF0E1214),
    panel: Color(0xFF161C1E),
    sunk: Color(0xFF101617),
    rule: Color(0xFF2A3436),
    ruleStrong: Color(0xFF3D4A4C),
    ink: Color(0xFFE8EEEE),
    inkSoft: Color(0xFFB6C3C4),
    muted: Color(0xFF859395),
    accent: kAccentDark,
    accentSoft: Color(0xFF10312F),
    warn: Color(0xFFE5A648),
    danger: Color(0xFFFF7A6B),
  );

  static const light = RuckusColors(
    ground: Color(0xFFF3F5F5),
    panel: Color(0xFFFFFFFF),
    sunk: Color(0xFFE9EDED),
    rule: Color(0xFFD2DADA),
    ruleStrong: Color(0xFFB4C0C0),
    ink: Color(0xFF14191B),
    inkSoft: Color(0xFF414C50),
    muted: Color(0xFF6C797D),
    accent: kAccentLight,
    accentSoft: Color(0xFFDDECEC),
    warn: Color(0xFF9A5A08),
    danger: Color(0xFFB32F26),
  );

  @override
  RuckusColors copyWith() => this;

  @override
  RuckusColors lerp(ThemeExtension<RuckusColors>? other, double t) =>
      t < 0.5 ? this : (other as RuckusColors? ?? this);
}

/// Shorthand: `context.c.accent`.
extension RuckusTheme on BuildContext {
  RuckusColors get c =>
      Theme.of(this).extension<RuckusColors>() ?? RuckusColors.dark;
}

ThemeData buildTheme(RuckusColors c, Brightness brightness) {
  final base = ThemeData(brightness: brightness, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: c.ground,
    canvasColor: c.panel,
    colorScheme: base.colorScheme.copyWith(
      primary: c.accent,
      secondary: c.accent,
      surface: c.panel,
      onSurface: c.ink,
      error: c.danger,
    ),
    extensions: [c],
    dividerTheme: DividerThemeData(color: c.rule, space: 1),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: c.accent,
      thumbColor: c.accent,
      inactiveTrackColor: c.rule,
      trackHeight: 3,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.sunk, border: Border.all(color: c.rule)),
      textStyle: TextStyle(fontSize: 11.5, color: c.ink),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.zero),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.panel,
      shape: RoundedRectangleBorder(
          side: BorderSide(color: c.rule), borderRadius: BorderRadius.zero),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.panel,
      shape: RoundedRectangleBorder(
          side: BorderSide(color: c.rule), borderRadius: BorderRadius.zero),
    ),
  );
}

class RuckusApp extends ConsumerWidget {
  const RuckusApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Ruckus',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: buildTheme(RuckusColors.light, Brightness.light),
      darkTheme: buildTheme(RuckusColors.dark, Brightness.dark),
      home: const HomePage(),
    );
  }
}

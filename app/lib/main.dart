import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:window_manager/window_manager.dart';

import 'features/home_page.dart';
import 'services/desktop_service.dart';
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

// Teal on slate, square corners — the palette from the plan document, so the
// app and its docs read as one thing.
const kAccent = Color(0xFF4FCBD4);
const kGround = Color(0xFF0E1214);
const kPanel = Color(0xFF161C1E);
const kSunk = Color(0xFF101617);
const kRule = Color(0xFF2A3436);
const kRuleStrong = Color(0xFF3D4A4C);
const kInk = Color(0xFFE8EEEE);
const kInkSoft = Color(0xFFB6C3C4);
const kMuted = Color(0xFF859395);
const kWarn = Color(0xFFE5A648);
const kDanger = Color(0xFFFF7A6B);

class RuckusApp extends StatelessWidget {
  const RuckusApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'Ruckus',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: kGround,
        colorScheme: base.colorScheme.copyWith(
          primary: kAccent,
          secondary: kAccent,
          surface: kPanel,
          error: kDanger,
        ),
        dividerTheme: const DividerThemeData(color: kRule, space: 1),
        sliderTheme: base.sliderTheme.copyWith(
          activeTrackColor: kAccent,
          thumbColor: kAccent,
          inactiveTrackColor: kRule,
          trackHeight: 3,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.zero),
        ),
      ),
      home: const HomePage(),
    );
  }
}

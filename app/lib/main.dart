import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/home_page.dart';
import 'smoketest.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.contains('--smoketest')) {
    runSmokeTest(args.where((a) => !a.startsWith('--')).toList());
    return;
  }
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

import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'utils/screenshot.dart';

void main() {
  runApp(const MyApp());
  scheduleAutoScreenshot();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // Desktop Flutter does not fall back to the platform emoji font on its
  // own, so emoji in model output would render as tofu without this.
  static const _emojiFontFallback = [
    'Apple Color Emoji', // macOS / iOS
    'Segoe UI Emoji', // Windows
    'Noto Color Emoji', // Linux / Android
  ];

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'ailia MODELS Flutter',
      theme: theme.copyWith(
        textTheme:
            theme.textTheme.apply(fontFamilyFallback: _emojiFontFallback),
        primaryTextTheme: theme.primaryTextTheme
            .apply(fontFamilyFallback: _emojiFontFallback),
      ),
      builder: (context, child) => RepaintBoundary(
        key: screenshotBoundaryKey,
        child: child,
      ),
      home: const HomeScreen(),
    );
  }
}

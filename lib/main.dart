import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'utils/screenshot.dart';

void main() {
  runApp(const MyApp());
  scheduleAutoScreenshot();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ailia MODELS Flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      builder: (context, child) => RepaintBoundary(
        key: screenshotBoundaryKey,
        child: child,
      ),
      home: const HomeScreen(),
    );
  }
}

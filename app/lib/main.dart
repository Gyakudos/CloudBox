import 'package:flutter/material.dart';

import 'ui/paired_devices_screen.dart';

void main() {
  runApp(const CloudBoxApp());
}

class CloudBoxApp extends StatelessWidget {
  const CloudBoxApp({super.key});

  static const _seed = Color(0xFF2E6BE6);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CloudBox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const PairedDevicesScreen(),
    );
  }
}

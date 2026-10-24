import 'package:flutter/material.dart';
import 'engine.dart';
import 'pages.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(WolfiesApp(service: MarketService()));
}

class WolfiesApp extends StatelessWidget {
  final MarketService service;
  const WolfiesApp({super.key, required this.service});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Wolfies Hit Bot',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0B0F17),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00D9A6),
        brightness: Brightness.dark,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF141B27),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF253044)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF141B27),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
    ),
    home: HomeScreen(service: service),
  );
}

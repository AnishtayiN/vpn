import 'package:flutter/material.dart';

class VoidrauColors {
  static const bg = Color(0xFF05080D);
  static const surface = Color(0xFF0D131C);
  static const surface2 = Color(0xFF121B27);
  static const line = Color(0xFF223044);
  static const muted = Color(0xFF8F9BAD);
  static const cyan = Color(0xFF27D7F2);
  static const blue = Color(0xFF1769FF);
  static const violet = Color(0xFF9458FF);
  static const coral = Color(0xFFFF5D67);
  static const text = Color(0xFFF4F7FB);

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Segoe UI',
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: blue,
        surface: surface,
        error: coral,
      ),
      scaffoldBackgroundColor: bg,
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xE005080D),
        elevation: 0,
        centerTitle: true,
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: Color(0xFF0A1018)),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF163149),
        contentTextStyle: TextStyle(color: text),
      ),
    );
  }

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF0E6E8A),
        secondary: blue,
        surface: Color(0xFFF8FBFD),
        error: coral,
      ),
      scaffoldBackgroundColor: const Color(0xFFEDF3F8),
    );
  }
}

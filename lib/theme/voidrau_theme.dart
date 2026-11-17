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

  /// Theme-aware surface colours. Pages must use these (or the ColorScheme
  /// directly) instead of the dark constants above, so the light theme shows
  /// light cards on a light scaffold instead of dark-navy cards.
  static Color surfaceOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? surface
          : Theme.of(context).colorScheme.surfaceContainer;

  static Color surface2Of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? surface2
          : Theme.of(context).colorScheme.surfaceContainerHigh;

  static Color lineOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? line
          : Theme.of(context).colorScheme.outlineVariant;

  static Color mutedOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? muted
          : Theme.of(context).colorScheme.onSurfaceVariant;

  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Vazirmatn',
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: blue,
        surface: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: surface2,
        surfaceContainerLow: Color(0xFF0A1018),
        outlineVariant: line,
        onSurfaceVariant: muted,
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
      cardTheme: CardThemeData(
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: line),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF163149),
        contentTextStyle: TextStyle(color: text),
      ),
    );
  }

  static ThemeData light() {
    const primary = Color(0xFF0E6E8A);
    const scaffold = Color(0xFFEDF3F8);
    const cardSurface = Color(0xFFF8FBFD);
    const onSurfaceVar = Color(0xFF5A6B7C);
    const outlineVar = Color(0xFFD3DEE8);
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: 'Vazirmatn',
      colorScheme: const ColorScheme.light(
        primary: primary,
        secondary: blue,
        surface: cardSurface,
        surfaceContainer: Color(0xFFFFFFFF),
        surfaceContainerHigh: Color(0xFFE8F0F6),
        surfaceContainerLow: Color(0xFFF2F7FA),
        outlineVariant: outlineVar,
        onSurfaceVariant: onSurfaceVar,
        error: coral,
      ),
      scaffoldBackgroundColor: scaffold,
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xE0EDF3F8),
        elevation: 0,
        centerTitle: true,
        foregroundColor: Color(0xFF0A1622),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: cardSurface),
      cardTheme: CardThemeData(
        color: cardSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: outlineVar),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF163149),
        contentTextStyle: TextStyle(color: text),
      ),
      dividerTheme: const DividerThemeData(color: outlineVar),
      listTileTheme: const ListTileThemeData(
        iconColor: onSurfaceVar,
      ),
    );
  }
}

/// Alias the pages use for the theme-aware surface helpers
/// ([VoidrauColors.surfaceOf] etc.). A typedef keeps every
/// `VoidrauTheme.…` call site working without renaming the palette class.
typedef VoidrauTheme = VoidrauColors;

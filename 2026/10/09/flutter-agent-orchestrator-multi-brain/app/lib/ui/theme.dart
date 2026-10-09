import 'package:flutter/material.dart';

/// Dark theme carried over from the Codex lab, so both apps look alike.
class Palette {
  static const background = Color(0xFF181818);
  static const sidebar = Color(0xFF121212);
  static const surface = Color(0xFF232323);
  static const surfaceHigh = Color(0xFF2C2C2C);
  static const border = Color(0xFF333333);
  static const text = Color(0xFFECECEC);
  static const textDim = Color(0xFF9B9B9B);
  static const textFaint = Color(0xFF6B6B6B);
  static const accent = Color(0xFFECECEC);
  static const added = Color(0xFF3FB950);
  static const removed = Color(0xFFF85149);
  static const warning = Color(0xFFD29922);
}

const monoFamily = 'Menlo';

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      surface: Palette.background,
      primary: Palette.accent,
      onPrimary: Colors.black,
      secondary: Palette.textDim,
      outline: Palette.border,
    ),
    scaffoldBackgroundColor: Palette.background,
    dividerColor: Palette.border,
    splashFactory: NoSplash.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}

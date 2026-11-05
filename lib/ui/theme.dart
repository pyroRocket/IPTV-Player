import 'package:flutter/material.dart';

const accent = Color(0xFF4F8CFF);
const bg = Color(0xFF0E0F12);
const panel = Color(0xFF16181D);
const panel2 = Color(0xFF1F222A);
const line = Color(0xFF2A2E38);
const muted = Color(0xFF8B919E);
const star = Color(0xFFFFC93C);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    surface: panel,
  ).copyWith(primary: accent);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    useMaterial3: true,
    // Big, obvious focus highlight so it's usable from a TV remote.
    focusColor: accent.withValues(alpha: 0.28),
    hoverColor: Colors.white.withValues(alpha: 0.05),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
      ).copyWith(side: _focusRing),
    ),
    textButtonTheme: TextButtonThemeData(style: ButtonStyle(side: _focusRing)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused)
              ? const BorderSide(color: Colors.white, width: 2)
              : const BorderSide(color: line),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: ButtonStyle(side: _focusRing)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: accent, width: 2),
      ),
    ),
  );
}

/// A visible outline on whatever has focus, for TV-remote navigation.
final _focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
  (s) => s.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 2) : null,
);

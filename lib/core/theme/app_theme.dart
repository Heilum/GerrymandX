import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Seed color: deep teal-green (same as frame_find)
  static const Color _seed = Color(0xFF1A6B5A);

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final cs = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      brightness: brightness,
      fontFamily: 'SF Pro Text',
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        backgroundColor: cs.surface,
        titleTextStyle: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: cs.surfaceContainerLow,
        indicatorColor: cs.secondaryContainer,
        selectedIconTheme: IconThemeData(color: cs.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: cs.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 11,
          color: cs.onSurfaceVariant,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        color: cs.surfaceContainerLowest,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(
            TextStyle(
              fontFamily: 'SF Pro Text',
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          textStyle: const TextStyle(
            fontFamily: 'SF Pro Text',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant.withValues(alpha: 0.3),
        space: 1,
        thickness: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStatePropertyAll(4),
        radius: const Radius.circular(2),
      ),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
        ),
        headlineMedium: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        titleLarge: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        titleMedium: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        titleSmall: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 14,
          color: cs.onSurface,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 13,
          color: cs.onSurface,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Menlo',
          fontSize: 11,
          color: cs.onSurfaceVariant,
        ),
        labelLarge: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        labelMedium: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: cs.onSurfaceVariant,
        ),
        labelSmall: TextStyle(
          fontFamily: 'SF Pro Text',
          fontSize: 10,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

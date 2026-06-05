import 'package:flutter/material.dart';

import '../navigation/instant_page_transitions.dart';

/// U-Panel design system: Brand green primary (#177245).
/// Uses system fonts so the app works offline (no Google Fonts network fetch).
class AppTheme {
  AppTheme._();

  static const Color brandGreen = Color(0xFF177245);

  // Green palette – centered on brand #177245
  static const Color primary = brandGreen; // Nav, app bars, primary actions
  static const Color primaryLight = Color(0xFF2A9B63); // Lighter for hovers / chips
  static const Color secondary = Color(0xFF0F4D2E); // Deeper green for contrast
  static const Color surface = Color(0xFFF8FAFC); // Soft off-white
  static const Color background = Color(0xFFFFFFFF);
  static const Color accent = brandGreen; // Highlights, focus, KIU-style marks
  static const Color accentLight = Color(0xFF9FD4B8); // Soft tint on surfaces
  static const Color softGrey = Color(0xFFE2E8F0);
  static const Color textPrimary = Color(0xFF0A2915); // Near-black with green bias
  static const Color textSecondary = Color(0xFF64748B);
  static const Color success = Color(0xFF059669);
  static const Color warning = Color(0xFFD97706);
  static const Color error = Color(0xFFDC2626);

  static const double cardRadius = 14.0;
  static const double cardElevation = 2.0;

  static ThemeData get light {
    const textStyle = TextStyle(color: textPrimary);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: primary,
        onPrimary: Colors.white,
        secondary: secondary,
        onSecondary: Colors.white,
        surface: surface,
        onSurface: textPrimary,
        error: error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: surface,
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: primary,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: cardElevation,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius)),
        color: background,
        shadowColor: primary.withOpacity(0.08),
        clipBehavior: Clip.antiAlias,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: softGrey),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: background,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: softGrey),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: textSecondary, fontSize: 15),
      ),
      textTheme: ThemeData.light().textTheme.copyWith(
            headlineMedium:
                textStyle.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
            titleLarge:
                textStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
            titleMedium:
                textStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w500),
            bodyLarge: textStyle.copyWith(fontSize: 15),
            bodyMedium: const TextStyle(fontSize: 14, color: textSecondary),
            labelLarge: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500, color: textPrimary),
          ),
      dividerTheme: const DividerThemeData(color: softGrey, thickness: 1),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: InstantPageTransitionsBuilder(),
          TargetPlatform.iOS: InstantPageTransitionsBuilder(),
          TargetPlatform.linux: InstantPageTransitionsBuilder(),
          TargetPlatform.macOS: InstantPageTransitionsBuilder(),
          TargetPlatform.windows: InstantPageTransitionsBuilder(),
          TargetPlatform.fuchsia: InstantPageTransitionsBuilder(),
        },
      ),
    );
  }
}

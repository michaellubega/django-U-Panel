import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
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
  static const Color accentLight = Color(0xFF2A9B63); // Highlight tint (brand green family)
  static const Color softGrey = Color(0xFFE2E8F0);
  static const Color textPrimary = Color(0xFF0A2915); // Near-black with green bias
  static const Color textSecondary = Color(0xFF64748B);
  static const Color success = Color(0xFF059669);
  static const Color warning = Color(0xFFD97706);
  static const Color error = Color(0xFFDC2626);

  static const double cardRadius = 14.0;
  static const double cardElevation = 2.0;

  /// Desktop embedders need an explicit system font; otherwise some Windows GPUs
  /// render blank glyphs when Material falls back to an unavailable family.
  static String? get _fontFamily {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'Segoe UI';
      case TargetPlatform.macOS:
        return '.AppleSystemUIFont';
      case TargetPlatform.linux:
        return 'Roboto';
      default:
        return null;
    }
  }

  static List<String>? get _fontFamilyFallback {
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return const ['Segoe UI', 'Tahoma', 'Arial'];
      case TargetPlatform.macOS:
        return const ['.AppleSystemUIFont', 'Helvetica', 'Arial'];
      case TargetPlatform.linux:
        return const ['Roboto', 'Ubuntu', 'Liberation Sans', 'Arial'];
      default:
        return null;
    }
  }

  static TextStyle _baseTextStyle({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? textPrimary,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static TextTheme _buildTextTheme() {
    final applied = ThemeData.light(useMaterial3: true).textTheme.apply(
          bodyColor: textPrimary,
          displayColor: textPrimary,
          decorationColor: textPrimary,
          fontFamily: _fontFamily,
          fontFamilyFallback: _fontFamilyFallback,
        );

    return applied.copyWith(
      displayLarge: _baseTextStyle(fontSize: 57, fontWeight: FontWeight.w400),
      displayMedium: _baseTextStyle(fontSize: 45, fontWeight: FontWeight.w400),
      displaySmall: _baseTextStyle(fontSize: 36, fontWeight: FontWeight.w400),
      headlineLarge: _baseTextStyle(fontSize: 32, fontWeight: FontWeight.w600),
      headlineMedium: _baseTextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      headlineSmall: _baseTextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleLarge: _baseTextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      titleMedium: _baseTextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      titleSmall: _baseTextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      bodyLarge: _baseTextStyle(fontSize: 15),
      bodyMedium: _baseTextStyle(fontSize: 14, color: textSecondary),
      bodySmall: _baseTextStyle(fontSize: 12, color: textSecondary),
      labelLarge: _baseTextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      labelMedium: _baseTextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: _baseTextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: textSecondary,
      ),
    );
  }

  static ThemeData get light {
    final textTheme = _buildTextTheme();
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      surface: surface,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
    ).copyWith(
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: primary.withValues(alpha: 0.16),
      onPrimaryContainer: primary,
      secondary: secondary,
      onSecondary: Colors.white,
      secondaryContainer: primaryLight.withValues(alpha: 0.22),
      onSecondaryContainer: secondary,
      tertiary: primary,
      onTertiary: Colors.white,
      tertiaryContainer: primary.withValues(alpha: 0.12),
      onTertiaryContainer: primary,
      error: error,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFamilyFallback,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: surface,
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: primary,
        foregroundColor: Colors.white,
        titleTextStyle: _baseTextStyle(
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
        shadowColor: primary.withValues(alpha: 0.08),
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
          textStyle: _baseTextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          textStyle: _baseTextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: _baseTextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: primary,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: softGrey),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: _baseTextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: primary,
          ),
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
        hintStyle: _baseTextStyle(fontSize: 15, color: textSecondary),
        labelStyle: _baseTextStyle(fontSize: 14, color: textSecondary),
        floatingLabelStyle: _baseTextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: primary,
        ),
        helperStyle: _baseTextStyle(fontSize: 12, color: textSecondary),
        errorStyle: _baseTextStyle(fontSize: 12, color: error),
      ),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: const IconThemeData(color: textPrimary),
      dividerTheme: const DividerThemeData(color: softGrey, thickness: 1),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        titleTextStyle: _baseTextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        subtitleTextStyle: _baseTextStyle(fontSize: 14, color: textSecondary),
        iconColor: textSecondary,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: background,
        titleTextStyle: _baseTextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        contentTextStyle: _baseTextStyle(fontSize: 14, color: textSecondary),
      ),
      snackBarTheme: SnackBarThemeData(
        contentTextStyle: _baseTextStyle(fontSize: 14, color: Colors.white),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return primary;
            }
            if (states.contains(WidgetState.disabled)) {
              return softGrey.withValues(alpha: 0.35);
            }
            return background;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Colors.white;
            }
            if (states.contains(WidgetState.disabled)) {
              return textSecondary;
            }
            return textPrimary;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const BorderSide(color: primary, width: 1.5);
            }
            return const BorderSide(color: softGrey);
          }),
          textStyle: WidgetStatePropertyAll(
            _baseTextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: primary.withValues(alpha: 0.16),
        labelStyle: _baseTextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        secondaryLabelStyle: _baseTextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: primary,
        ),
        side: const BorderSide(color: softGrey),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: _baseTextStyle(fontSize: 15),
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: _baseTextStyle(fontSize: 12, color: Colors.white),
        decoration: BoxDecoration(
          color: secondary,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FastPageTransitionsBuilder(),
          TargetPlatform.iOS: FastPageTransitionsBuilder(),
          TargetPlatform.linux: FastPageTransitionsBuilder(),
          TargetPlatform.macOS: FastPageTransitionsBuilder(),
          TargetPlatform.windows: FastPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FastPageTransitionsBuilder(),
        },
      ),
    );
  }
}

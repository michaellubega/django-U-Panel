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
  // Ant Design–aligned text colors (rgba black)
  static const Color textPrimary = Color(0xE0000000); // 88%
  static const Color textSecondary = Color(0xA6000000); // 65%
  static const Color textTertiary = Color(0x73000000); // 45%
  static const Color success = Color(0xFF059669);
  static const Color warning = Color(0xFFD97706);
  static const Color error = Color(0xFFDC2626);

  static const double cardRadius = 14.0;
  static const double cardElevation = 2.0;

  /// Ant Design default typography (14px base, 22px line-height).
  static const double fontSizeBase = 14.0;
  static const double fontSizeSm = 12.0;
  static const double fontSizeLg = 16.0;
  static const double fontSizeXl = 20.0;
  static const double lineHeightBase = 22.0;
  static const double lineHeightSm = 20.0;
  static const double lineHeightLg = 24.0;
  static const double lineHeightXl = 28.0;

  static double _lh(double size, double lineHeight) => lineHeight / size;

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
    return TextTheme(
      displayLarge: _baseTextStyle(
        fontSize: 38,
        fontWeight: FontWeight.w600,
        height: 46 / 38,
      ),
      displayMedium: _baseTextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w600,
        height: 40 / 30,
      ),
      displaySmall: _baseTextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 32 / 24,
      ),
      headlineLarge: _baseTextStyle(
        fontSize: fontSizeXl,
        fontWeight: FontWeight.w600,
        height: _lh(fontSizeXl, lineHeightXl),
      ),
      headlineMedium: _baseTextStyle(
        fontSize: fontSizeXl,
        fontWeight: FontWeight.w600,
        height: _lh(fontSizeXl, lineHeightXl),
      ),
      headlineSmall: _baseTextStyle(
        fontSize: fontSizeLg,
        fontWeight: FontWeight.w600,
        height: _lh(fontSizeLg, lineHeightLg),
      ),
      titleLarge: _baseTextStyle(
        fontSize: fontSizeLg,
        fontWeight: FontWeight.w600,
        height: _lh(fontSizeLg, lineHeightLg),
      ),
      titleMedium: _baseTextStyle(
        fontSize: fontSizeBase,
        fontWeight: FontWeight.w600,
        height: _lh(fontSizeBase, lineHeightBase),
      ),
      titleSmall: _baseTextStyle(
        fontSize: fontSizeBase,
        fontWeight: FontWeight.w400,
        height: _lh(fontSizeBase, lineHeightBase),
      ),
      bodyLarge: _baseTextStyle(
        fontSize: fontSizeBase,
        height: _lh(fontSizeBase, lineHeightBase),
      ),
      bodyMedium: _baseTextStyle(
        fontSize: fontSizeBase,
        color: textSecondary,
        height: _lh(fontSizeBase, lineHeightBase),
      ),
      bodySmall: _baseTextStyle(
        fontSize: fontSizeSm,
        color: textTertiary,
        height: _lh(fontSizeSm, lineHeightSm),
      ),
      labelLarge: _baseTextStyle(
        fontSize: fontSizeBase,
        fontWeight: FontWeight.w400,
        height: _lh(fontSizeBase, lineHeightBase),
      ),
      labelMedium: _baseTextStyle(
        fontSize: fontSizeSm,
        fontWeight: FontWeight.w400,
        height: _lh(fontSizeSm, lineHeightSm),
      ),
      labelSmall: _baseTextStyle(
        fontSize: fontSizeSm,
        fontWeight: FontWeight.w400,
        color: textTertiary,
        height: _lh(fontSizeSm, lineHeightSm),
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
          fontSize: fontSizeLg,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          height: _lh(fontSizeLg, lineHeightLg),
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
            fontSize: fontSizeBase,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            height: _lh(fontSizeBase, lineHeightBase),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          textStyle: _baseTextStyle(
            fontSize: fontSizeBase,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            height: _lh(fontSizeBase, lineHeightBase),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: _baseTextStyle(
            fontSize: fontSizeBase,
            fontWeight: FontWeight.w600,
            color: primary,
            height: _lh(fontSizeBase, lineHeightBase),
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
            fontSize: fontSizeBase,
            fontWeight: FontWeight.w400,
            color: primary,
            height: _lh(fontSizeBase, lineHeightBase),
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
        hintStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          color: textTertiary,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
        labelStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          color: textSecondary,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
        floatingLabelStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          fontWeight: FontWeight.w400,
          color: primary,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
        helperStyle: _baseTextStyle(
          fontSize: fontSizeSm,
          color: textTertiary,
          height: _lh(fontSizeSm, lineHeightSm),
        ),
        errorStyle: _baseTextStyle(
          fontSize: fontSizeSm,
          color: error,
          height: _lh(fontSizeSm, lineHeightSm),
        ),
      ),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: const IconThemeData(color: textPrimary),
      dividerTheme: const DividerThemeData(color: softGrey, thickness: 1),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        titleTextStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          fontWeight: FontWeight.w400,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
        subtitleTextStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          color: textSecondary,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
        iconColor: textSecondary,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: background,
        titleTextStyle: _baseTextStyle(
          fontSize: fontSizeXl,
          fontWeight: FontWeight.w600,
          height: _lh(fontSizeXl, lineHeightXl),
        ),
        contentTextStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          color: textSecondary,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        contentTextStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          color: Colors.white,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
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
            _baseTextStyle(
              fontSize: fontSizeBase,
              fontWeight: FontWeight.w400,
              height: _lh(fontSizeBase, lineHeightBase),
            ),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: primary.withValues(alpha: 0.16),
        labelStyle: _baseTextStyle(
          fontSize: fontSizeSm,
          fontWeight: FontWeight.w400,
          height: _lh(fontSizeSm, lineHeightSm),
        ),
        secondaryLabelStyle: _baseTextStyle(
          fontSize: fontSizeSm,
          fontWeight: FontWeight.w600,
          color: primary,
          height: _lh(fontSizeSm, lineHeightSm),
        ),
        side: const BorderSide(color: softGrey),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: _baseTextStyle(
          fontSize: fontSizeBase,
          height: _lh(fontSizeBase, lineHeightBase),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        textStyle: _baseTextStyle(
          fontSize: fontSizeSm,
          color: Colors.white,
          height: _lh(fontSizeSm, lineHeightSm),
        ),
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

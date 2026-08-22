import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// KIU / U-Panel logo from bundled assets in [kiu/].
class AppBrandLogo extends StatelessWidget {
  const AppBrandLogo({
    super.key,
    this.size = 72,
    this.borderRadius = 18,
    this.fit = BoxFit.cover,
    this.fallbackIconSize,
  });

  final double size;
  final double borderRadius;
  final BoxFit fit;
  final double? fallbackIconSize;

  static String assetForPlatform() {
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return 'kiu/appstore.png';
    }
    return 'kiu/playstore.png';
  }

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: [
        BoxShadow(
          color: AppTheme.primary.withValues(alpha: 0.28),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );

    if (kIsWeb) {
      return Container(
        decoration: decoration,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.network(
            'icons/Icon-192.png',
            width: size,
            height: size,
            fit: fit,
            errorBuilder: (_, __, ___) => _Fallback(
              size: size,
              borderRadius: borderRadius,
              iconSize: fallbackIconSize,
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: decoration,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.asset(
          assetForPlatform(),
          width: size,
          height: size,
          fit: fit,
          errorBuilder: (_, __, ___) => _Fallback(
            size: size,
            borderRadius: borderRadius,
            iconSize: fallbackIconSize,
          ),
        ),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({
    required this.size,
    required this.borderRadius,
    this.iconSize,
  });

  final double size;
  final double borderRadius;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: AppTheme.primary,
      ),
      child: Icon(
        Icons.school_rounded,
        color: Colors.white,
        size: iconSize ?? size * 0.45,
      ),
    );
  }
}

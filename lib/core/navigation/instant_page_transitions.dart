import 'package:flutter/material.dart';

/// Short, smooth push/pop — fade with a slight horizontal slide.
class FastPageTransitionsBuilder extends PageTransitionsBuilder {
  const FastPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.02, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// [MaterialPageRoute] with a shorter transition than the platform default.
class UPanelPageRoute<T> extends MaterialPageRoute<T> {
  UPanelPageRoute({
    required super.builder,
    super.fullscreenDialog,
    super.settings,
  });

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);
}

@Deprecated('Use FastPageTransitionsBuilder')
typedef InstantPageTransitionsBuilder = FastPageTransitionsBuilder;

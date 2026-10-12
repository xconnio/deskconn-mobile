import 'package:flutter/material.dart';

/// The app-wide page motion: fade in while settling from a slight zoom.
Widget fadeScaleTransition(Animation<double> animation, Widget child) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(curved), child: child),
  );
}

class FadeScalePageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeScalePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return fadeScaleTransition(animation, child);
  }
}

final deskconnPageTransitions = PageTransitionsTheme(
  builders: {for (final platform in TargetPlatform.values) platform: const FadeScalePageTransitionsBuilder()},
);

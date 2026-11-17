import 'package:deskconn_mobile_app/theme/motion.dart';
import 'package:flutter/material.dart';

Widget pageFadeTransition(Animation<double> animation, Widget child, {BuildContext? context}) {
  if (context != null && DeskconnMotion.reduce(context)) return child;
  return FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: DeskconnMotion.standard),
    child: child,
  );
}

Widget overlayWithFixedBar(
  BuildContext context,
  Animation<double> animation, {
  required Widget content,
  WidgetBuilder? bottomBar,
}) {
  final animated = pageFadeTransition(animation, content, context: context);
  if (bottomBar == null) return animated;
  return Column(
    children: [
      Expanded(
        child: ClipRect(
          child: MediaQuery.removePadding(context: context, removeBottom: true, child: animated),
        ),
      ),
      bottomBar(context),
    ],
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
    return pageFadeTransition(animation, child, context: context);
  }
}

final deskconnPageTransitions = PageTransitionsTheme(
  builders: {for (final platform in TargetPlatform.values) platform: const FadeScalePageTransitionsBuilder()},
);

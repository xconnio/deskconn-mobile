import 'package:flutter/material.dart';

class DeskconnMotion {
  const DeskconnMotion._();

  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 250);
  static const emphasise = Duration(milliseconds: 400);

  static const standard = Curves.easeOutCubic;

  static bool reduce(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration duration(BuildContext context, Duration value) => reduce(context) ? Duration.zero : value;
}

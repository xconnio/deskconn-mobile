import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum DeskconnBreakpoint { compact, medium, expanded }

const double mediumBreakpoint = 600;
const double expandedBreakpoint = 900;

DeskconnBreakpoint breakpointForWidth(double width) {
  if (width >= expandedBreakpoint) return DeskconnBreakpoint.expanded;
  if (width >= mediumBreakpoint) return DeskconnBreakpoint.medium;
  return DeskconnBreakpoint.compact;
}

DeskconnBreakpoint breakpointOf(BuildContext context) => breakpointForWidth(MediaQuery.sizeOf(context).width);

bool isDesktopLayout(BuildContext context) {
  if (breakpointOf(context) == DeskconnBreakpoint.expanded) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
    _ => false,
  };
}

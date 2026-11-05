import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/overlay.dart';
import 'package:flutter/material.dart';

class AppSnackBar {
  const AppSnackBar._();

  static void showSuccess(BuildContext context, String message) {
    final theme = Theme.of(context);
    final palette = DeskconnPalette.of(context);
    final isDark = theme.brightness == Brightness.dark;

    _show(
      context,
      message,
      backgroundColor: isDark ? palette.surfaceTint : palette.muted,
      foregroundColor: isDark ? palette.text : DeskconnOverlay.foreground,
      icon: Icons.check_circle_outline,
    );
  }

  static void showError(BuildContext context, String message) {
    final colors = Theme.of(context).colorScheme;

    _show(
      context,
      message,
      backgroundColor: colors.errorContainer,
      foregroundColor: colors.onErrorContainer,
      icon: Icons.error_outline,
    );
  }

  static void _show(
    BuildContext context,
    String message, {
    required Color backgroundColor,
    required Color foregroundColor,
    required IconData icon,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: backgroundColor,
          margin: EdgeInsets.fromLTRB(24, 0, 24, bottomPadding + 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          content: Row(
            children: [
              Icon(icon, color: foregroundColor, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: foregroundColor, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );
  }
}

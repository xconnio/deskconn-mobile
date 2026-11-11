import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/overlay.dart';
import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:flutter/material.dart';

class AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool onOverlay;

  const AppEmptyState({super.key, required this.icon, required this.title, this.subtitle, this.onOverlay = false});

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    final titleColor = onOverlay ? DeskconnOverlay.foreground : palette.muted;
    final subtitleColor = onOverlay ? DeskconnOverlay.foregroundMuted : palette.subtle;
    final iconColor = onOverlay ? DeskconnOverlay.foregroundMuted : palette.subtle.withValues(alpha: 0.7);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: iconColor),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: DeskconnText.titleSmall.copyWith(color: titleColor),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: DeskconnText.body.copyWith(color: subtitleColor),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

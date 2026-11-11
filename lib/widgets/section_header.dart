import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/spacing.dart';
import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:flutter/material.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;

  const SectionHeader({super.key, required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, DeskconnSpacing.sm, 4, DeskconnSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: DeskconnText.labelStrong.copyWith(color: palette.muted, letterSpacing: 0.4)),
          ),
          ?action,
        ],
      ),
    );
  }
}

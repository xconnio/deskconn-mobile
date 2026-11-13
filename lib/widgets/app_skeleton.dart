import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/motion.dart';
import 'package:flutter/material.dart';

class AppSkeletonBox extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  const AppSkeletonBox({super.key, this.width, this.height, this.borderRadius});

  @override
  State<AppSkeletonBox> createState() => _AppSkeletonBoxState();
}

class _AppSkeletonBoxState extends State<AppSkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    final box = SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surfaceTint,
          borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
        ),
      ),
    );

    if (DeskconnMotion.reduce(context)) return box;

    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 0.9).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: box,
    );
  }
}

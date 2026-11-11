import 'package:flutter/material.dart';

class AppLoading extends StatelessWidget {
  final double? size;
  final String? message;

  const AppLoading({super.key, this.size, this.message});

  @override
  Widget build(BuildContext context) {
    final indicator = size == null
        ? const CircularProgressIndicator()
        : SizedBox(width: size, height: size, child: const CircularProgressIndicator(strokeWidth: 2));

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          indicator,
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(message!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

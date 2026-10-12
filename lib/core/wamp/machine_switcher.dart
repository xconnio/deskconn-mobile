import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/widgets/machine_grid.dart';
import 'package:flutter/material.dart';

Future<void> switchMachine(BuildContext context, {String? currentRealm}) {
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<void>(MaterialPageRoute(builder: (_) => MachinesScreen(currentRealm: currentRealm)));
}

class MachinesScreen extends StatelessWidget {
  final String? currentRealm;

  const MachinesScreen({super.key, this.currentRealm});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Machines'),
        actions: [
          if (isDesktopLayout(context))
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  foregroundColor: colorScheme.onSurface,
                ),
              ),
            ),
        ],
      ),
      body: MachineGrid(currentRealm: currentRealm),
    );
  }
}

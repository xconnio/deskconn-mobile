import 'dart:ui' as ui;

import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/screens/access_management_screen.dart';
import 'package:deskconn_mobile_app/theme/page_transitions.dart';
import 'package:deskconn_mobile_app/widgets/machine_grid.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

Future<void> switchMachine(BuildContext context, {String? currentRealm, WidgetBuilder? bottomBar}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (isDesktopLayout(context)) {
    return navigator.push<void>(MaterialPageRoute(builder: (_) => MachinesScreen(currentRealm: currentRealm)));
  }

  return navigator.push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (routeContext, animation, _) => overlayWithFixedBar(
        routeContext,
        animation,
        content: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: MachinesScreen(currentRealm: currentRealm, overlay: true),
        ),
        bottomBar: bottomBar,
      ),
      transitionsBuilder: (_, _, _, child) => child,
    ),
  );
}

class MachinesScreen extends StatelessWidget {
  final String? currentRealm;
  final bool overlay;

  const MachinesScreen({super.key, this.currentRealm, this.overlay = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final screen = Scaffold(
      backgroundColor: overlay ? Colors.transparent : null,
      appBar: AppBar(
        title: const Text('Machines'),
        backgroundColor: overlay ? Colors.transparent : null,
        foregroundColor: overlay ? Colors.white : null,
        surfaceTintColor: overlay ? Colors.transparent : null,
        scrolledUnderElevation: overlay ? 0 : null,
        actions: [
          if (context.watch<SessionProvider>().account != null)
            IconButton(
              tooltip: 'Access management',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccessManagementScreen())),
            ),
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
      body: MachineGrid(currentRealm: currentRealm, overlay: overlay),
    );
    if (!overlay) return screen;

    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => Navigator.maybePop(context), child: screen);
  }
}

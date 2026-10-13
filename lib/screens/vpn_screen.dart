import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/vpn/vpn_controller.dart';

class VpnScreen extends StatelessWidget {
  const VpnScreen({super.key, required this.config, this.controller});

  final DesktopSessionLaunchConfig config;
  final VpnController? controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VPN')),
      body: VpnView(config: config, controller: controller),
    );
  }
}

class VpnView extends StatelessWidget {
  const VpnView({super.key, required this.config, this.controller});

  final DesktopSessionLaunchConfig config;
  final VpnController? controller;

  @override
  Widget build(BuildContext context) {
    final vpn = controller ?? VpnController.shared;
    return ListenableBuilder(
      listenable: vpn,
      builder: (context, _) => _VpnBody(vpn: vpn, config: config),
    );
  }
}

class _VpnBody extends StatelessWidget {
  const _VpnBody({required this.vpn, required this.config});

  final VpnController vpn;
  final DesktopSessionLaunchConfig config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busyElsewhere = vpn.status != VpnStatus.disconnected && vpn.realm != config.realm;
    final status = busyElsewhere ? VpnStatus.disconnected : vpn.status;
    final connected = status == VpnStatus.connected;
    final connecting = status == VpnStatus.connecting;

    final title = switch (status) {
      VpnStatus.connected => 'Connected',
      VpnStatus.connecting => 'Connecting…',
      VpnStatus.disconnected => 'Not connected',
    };
    final subtitle = connected
        ? 'Your phone\'s internet traffic goes through ${config.desktopName}.'
        : 'Route your phone\'s internet traffic through ${config.desktopName}.';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        Icon(
          connected ? Icons.vpn_lock : Icons.vpn_lock_outlined,
          size: 72,
          color: connected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(subtitle, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        if (connected && vpn.ready != null) ...[
          const SizedBox(height: 8),
          Text(
            'Address ${vpn.ready!.clientAddress} · MTU ${vpn.ready!.mtu}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (busyElsewhere) ...[
          const SizedBox(height: 16),
          _Notice(
            icon: Icons.info_outline,
            text: 'The VPN is currently connected through ${vpn.desktopName}. Disconnect it first.',
          ),
        ],
        if (!busyElsewhere && vpn.error != null && vpn.realm == config.realm) ...[
          const SizedBox(height: 16),
          _Notice(icon: Icons.error_outline, text: vpn.error!, isError: true),
        ],
        const SizedBox(height: 32),
        if (busyElsewhere)
          OutlinedButton(onPressed: vpn.disconnect, child: const Text('Disconnect'))
        else if (connected || connecting)
          OutlinedButton(onPressed: vpn.disconnect, child: Text(connected ? 'Disconnect' : 'Cancel'))
        else
          FilledButton(onPressed: () => vpn.connect(config), child: const Text('Connect')),
        if (!connected) ...[
          const SizedBox(height: 24),
          Text(
            '${config.desktopName} must be sharing its connection: run "deskconn vpn start" on it.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.isError = false});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (isError ? scheme.errorContainer : scheme.surfaceContainerHighest).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

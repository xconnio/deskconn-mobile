import 'dart:io';

import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/screens/port_forward_screen.dart';
import 'package:deskconn_mobile_app/screens/vpn_screen.dart';

class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key, required this.config});

  final DesktopSessionLaunchConfig config;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return Scaffold(
        appBar: AppBar(title: const Text('Network')),
        body: PortForwardView(config: config),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Network'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.swap_horiz), text: 'Ports'),
              Tab(icon: Icon(Icons.vpn_lock_outlined), text: 'VPN'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            PortForwardView(config: config),
            VpnView(config: config),
          ],
        ),
      ),
    );
  }
}

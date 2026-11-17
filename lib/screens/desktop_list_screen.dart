import 'package:deskconn_mobile_app/widgets/app_shell.dart';
import 'package:deskconn_mobile_app/widgets/machine_grid.dart';
import 'package:flutter/material.dart';

class DesktopListScreen extends StatelessWidget {
  const DesktopListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppShell(title: 'Machines', currentSection: AppShellSection.desktops, body: MachineGrid());
  }
}

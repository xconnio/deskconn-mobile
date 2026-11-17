import 'package:flutter/material.dart';

enum DeskconnDestination {
  machines(Icons.desktop_windows_outlined, 'Machines'),
  apps(Icons.grid_view_rounded, 'Apps'),
  settings(Icons.settings_outlined, 'Settings'),
  account(Icons.person_outline, 'Account');

  const DeskconnDestination(this.icon, this.label);

  final IconData icon;
  final String label;
}

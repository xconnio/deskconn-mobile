import 'dart:ui';

import 'package:deskconn_mobile_app/core/window_manager/desktop_window.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PinnedApp {
  final DesktopAppKind kind;
  final String title;
  final IconData icon;
  final Color Function(DeskconnPalette) color;

  const _PinnedApp({required this.kind, required this.title, required this.icon, required this.color});
}

const _pinnedApps = [
  _PinnedApp(kind: DesktopAppKind.fileExplorer, title: 'Files', icon: Icons.folder_open, color: _kubuntu),
  _PinnedApp(kind: DesktopAppKind.terminal, title: 'Terminal', icon: Icons.terminal, color: _debian),
  _PinnedApp(
    kind: DesktopAppKind.resourceMonitor,
    title: 'Resource Monitor',
    icon: Icons.speed_outlined,
    color: _ubuntu,
  ),
  _PinnedApp(kind: DesktopAppKind.portForward, title: 'Ports', icon: Icons.swap_horiz, color: _xubuntu),
];

Color _kubuntu(DeskconnPalette p) => p.osKubuntu;
Color _debian(DeskconnPalette p) => p.osDebian;
Color _ubuntu(DeskconnPalette p) => p.osUbuntu;
Color _xubuntu(DeskconnPalette p) => p.osXubuntu;

class AppDock extends StatefulWidget {
  final DesktopWindowManager manager;
  final String realm;
  final String machineName;
  final bool appsEnabled;
  final String connectionStatusLabel;
  final Color connectionStatusColor;
  final VoidCallback onMachineTap;
  final VoidCallback onProfileTap;
  final void Function(DesktopAppKind kind, {String? category}) onOpen;

  const AppDock({
    super.key,
    required this.manager,
    required this.realm,
    required this.machineName,
    required this.appsEnabled,
    required this.connectionStatusLabel,
    required this.connectionStatusColor,
    required this.onMachineTap,
    required this.onProfileTap,
    required this.onOpen,
  });

  @override
  State<AppDock> createState() => _AppDockState();
}

class _AppDockState extends State<AppDock> {
  List<DesktopAppKind> _order = _pinnedApps.map((a) => a.kind).toList();

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    _loadOrder();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    super.dispose();
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  String get _prefsKey => 'dock_pinned_order_${widget.realm}';

  Future<void> _loadOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKey);
    if (saved == null) return;
    final byName = {for (final a in _pinnedApps) a.kind.name: a.kind};
    final restored = saved.map((n) => byName[n]).whereType<DesktopAppKind>().toList();
    for (final kind in _order) {
      if (!restored.contains(kind)) restored.add(kind);
    }
    if (mounted) setState(() => _order = restored);
  }

  Future<void> _saveOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _order.map((k) => k.name).toList());
  }

  _PinnedApp _appFor(DesktopAppKind kind) => _pinnedApps.firstWhere((a) => a.kind == kind);

  void _openApp(DesktopAppKind kind) {
    final instances = widget.manager.instancesOf(kind);
    if (instances.isEmpty) {
      widget.onOpen(kind);
    } else if (instances.length == 1) {
      widget.manager.restore(instances.first.id);
    } else {
      _showInstanceSwitcher(kind, instances);
    }
  }

  Future<void> _showInstanceSwitcher(DesktopAppKind kind, List<DesktopWindowEntry> instances, {Offset? at}) async {
    final anchor = at ?? const Offset(200, 200);
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(anchor.dx, anchor.dy, anchor.dx, anchor.dy),
      items: [
        for (final w in instances)
          PopupMenuItem(
            value: w.id,
            child: Row(
              children: [
                Expanded(child: Text(w.title, overflow: TextOverflow.ellipsis)),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    Navigator.pop(context);
                    widget.manager.close(w.id);
                  },
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '__new__', child: Text('New Window')),
      ],
    );
    if (selection == null) return;
    if (selection == '__new__') {
      widget.onOpen(kind, category: DateTime.now().microsecondsSinceEpoch.toString());
    } else {
      widget.manager.restore(selection);
    }
  }

  Future<void> _showWindowsOverview(Offset at) async {
    final windows = widget.manager.windows;
    if (windows.isEmpty) return;
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final w in windows)
          PopupMenuItem(
            value: w.id,
            child: Row(
              children: [
                Icon(w.icon, size: 16, color: w.iconColor),
                const SizedBox(width: 8),
                Expanded(child: Text(w.title, overflow: TextOverflow.ellipsis)),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    Navigator.pop(context);
                    widget.manager.close(w.id);
                  },
                ),
              ],
            ),
          ),
      ],
    );
    if (selection != null) widget.manager.restore(selection);
  }

  @override
  Widget build(BuildContext context) {
    final openWindowCount = widget.manager.windows.length;

    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: const Color.fromRGBO(20, 20, 22, 0.75),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DockIconButton(icon: Icons.person_outline, tooltip: 'Profile', onTap: widget.onProfileTap),
                    _DockIconButton(
                      icon: Icons.desktop_windows_outlined,
                      tooltip: 'Machine',
                      onTap: widget.onMachineTap,
                    ),
                    _DockIconButton(
                      icon: Icons.grid_view_rounded,
                      tooltip: 'Apps',
                      badgeCount: openWindowCount,
                      onTapDown: (pos) => _showWindowsOverview(pos),
                    ),
                    Container(
                      width: 1,
                      height: 32,
                      color: Colors.white.withValues(alpha: 0.12),
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    SizedBox(
                      height: 64,
                      child: ReorderableListView(
                        scrollDirection: Axis.horizontal,
                        shrinkWrap: true,
                        buildDefaultDragHandles: false,
                        onReorder: (oldIndex, newIndex) {
                          setState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final kind = _order.removeAt(oldIndex);
                            _order.insert(newIndex, kind);
                          });
                          _saveOrder();
                        },
                        children: [
                          for (final kind in _order)
                            ReorderableDragStartListener(
                              key: ValueKey(kind),
                              index: _order.indexOf(kind),
                              child: _AppIcon(
                                app: _appFor(kind),
                                enabled: widget.appsEnabled,
                                instanceCount: widget.manager.instancesOf(kind).length,
                                hasMinimized: widget.manager.instancesOf(kind).any((w) => w.minimized),
                                onTap: () => _openApp(kind),
                                onSecondaryTapDown: (pos) =>
                                    _showInstanceSwitcher(kind, widget.manager.instancesOf(kind), at: pos),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _MachineStatusBadge(
                  machineName: widget.machineName,
                  statusLabel: widget.connectionStatusLabel,
                  statusColor: widget.connectionStatusColor,
                  onTap: widget.onProfileTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DockIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final void Function(Offset)? onTapDown;
  final int? badgeCount;

  const _DockIconButton({required this.icon, required this.tooltip, this.onTap, this.onTapDown, this.badgeCount});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTapDown: onTapDown == null ? null : (d) => onTapDown!(d.globalPosition),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: Colors.white, size: 22),
                if ((badgeCount ?? 0) > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: const Color(0xFFF97316), borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        '$badgeCount',
                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  final _PinnedApp app;
  final bool enabled;
  final int instanceCount;
  final bool hasMinimized;
  final VoidCallback onTap;
  final void Function(Offset) onSecondaryTapDown;

  const _AppIcon({
    required this.app,
    required this.enabled,
    required this.instanceCount,
    required this.hasMinimized,
    required this.onTap,
    required this.onSecondaryTapDown,
  });

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    final color = enabled ? app.color(palette) : app.color(palette).withValues(alpha: 0.35);

    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kSecondaryButton) onSecondaryTapDown(event.position);
      },
      child: Tooltip(
        message: app.title,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6, offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Icon(app.icon, color: Colors.white, size: 24),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < instanceCount.clamp(0, 4); i++)
                        Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hasMinimized ? Colors.white.withValues(alpha: 0.4) : Colors.white,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MachineStatusBadge extends StatelessWidget {
  final String machineName;
  final String statusLabel;
  final Color statusColor;
  final VoidCallback onTap;

  const _MachineStatusBadge({
    required this.machineName,
    required this.statusLabel,
    required this.statusColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: machineName,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: ' (${statusLabel.toLowerCase()})',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

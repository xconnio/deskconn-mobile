import 'package:flutter/material.dart';

enum DesktopAppKind { remoteControl, terminal, fileExplorer, resourceMonitor, portForward, vpn, network }

class DesktopWindowEntry {
  final String id;
  final DesktopAppKind kind;
  final String? category;
  final String title;
  final IconData icon;
  final Color iconColor;
  final Widget content;

  double x;
  double y;
  double width;
  double height;
  final double minWidth;
  final double minHeight;
  int zIndex;
  bool minimized;
  bool maximized;
  Rect? prevBounds;

  DesktopWindowEntry({
    required this.id,
    required this.kind,
    this.category,
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.content,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.zIndex,
    this.minWidth = DesktopWindowManager.minWidth,
    this.minHeight = DesktopWindowManager.minHeight,
    this.minimized = false,
    this.maximized = false,
  });

  Rect get bounds => Rect.fromLTWH(x, y, width, height);
}

class DesktopWindowManager extends ChangeNotifier {
  static const double defaultWidth = 720;
  static const double defaultHeight = 480;
  static const double cascadeStep = 28;
  static const int cascadeLimit = 8;
  static const double minWidth = 280;
  static const double minHeight = 200;

  final List<DesktopWindowEntry> _windows = [];
  int _nextZ = 0;
  int _cascadeIndex = 0;

  List<DesktopWindowEntry> get windows => List.unmodifiable(_windows);

  List<DesktopWindowEntry> get openWindows =>
      _windows.where((w) => !w.minimized).toList()..sort((a, b) => a.zIndex.compareTo(b.zIndex));

  DesktopWindowEntry? _find(DesktopAppKind kind, String? category) {
    for (final w in _windows) {
      if (w.kind == kind && w.category == category) return w;
    }
    return null;
  }

  DesktopWindowEntry? byId(String id) {
    for (final w in _windows) {
      if (w.id == id) return w;
    }
    return null;
  }

  List<DesktopWindowEntry> instancesOf(DesktopAppKind kind) {
    return _windows.where((w) => w.kind == kind).toList();
  }

  DesktopWindowEntry open(
    DesktopAppKind kind, {
    String? category,
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget content,
    required Size workspaceSize,
    double? width,
    double? height,
  }) {
    final existing = _find(kind, category);
    if (existing != null) {
      existing.minimized = false;
      existing.zIndex = ++_nextZ;
      notifyListeners();
      return existing;
    }

    final w = width ?? defaultWidth;
    final h = height ?? defaultHeight;
    final step = (_cascadeIndex % cascadeLimit) * cascadeStep;
    _cascadeIndex++;

    final maxX = (workspaceSize.width - w).clamp(0.0, double.infinity);
    final maxY = (workspaceSize.height - h).clamp(0.0, double.infinity);

    final entry = DesktopWindowEntry(
      id: '${kind.name}:${category ?? ''}:${DateTime.now().microsecondsSinceEpoch}',
      kind: kind,
      category: category,
      title: title,
      icon: icon,
      iconColor: iconColor,
      content: content,
      x: (24 + step).clamp(0.0, maxX),
      y: (24 + step).clamp(0.0, maxY),
      width: w,
      height: h,
      zIndex: ++_nextZ,
    );
    _windows.add(entry);
    notifyListeners();
    return entry;
  }

  void focus(String id) {
    final entry = byId(id);
    if (entry == null) return;
    entry.zIndex = ++_nextZ;
    notifyListeners();
  }

  void close(String id) {
    _windows.removeWhere((w) => w.id == id);
    notifyListeners();
  }

  void minimize(String id) {
    final entry = byId(id);
    if (entry == null) return;
    entry.minimized = true;
    _refocusTopWindow();
    notifyListeners();
  }

  void restore(String id) {
    final entry = byId(id);
    if (entry == null) return;
    entry.minimized = false;
    entry.zIndex = ++_nextZ;
    notifyListeners();
  }

  void _refocusTopWindow() {
    DesktopWindowEntry? top;
    for (final w in _windows) {
      if (w.minimized) continue;
      if (top == null || w.zIndex > top.zIndex) top = w;
    }
    if (top != null) top.zIndex = ++_nextZ;
  }

  void toggleMaximize(String id, Rect workspaceRect) {
    final entry = byId(id);
    if (entry == null) return;
    if (entry.maximized) {
      final restore = entry.prevBounds;
      if (restore != null) {
        entry.x = restore.left;
        entry.y = restore.top;
        entry.width = restore.width;
        entry.height = restore.height;
      }
      entry.maximized = false;
      entry.prevBounds = null;
    } else {
      entry.prevBounds = entry.bounds;
      entry.x = workspaceRect.left;
      entry.y = workspaceRect.top;
      entry.width = workspaceRect.width;
      entry.height = workspaceRect.height;
      entry.maximized = true;
    }
    entry.zIndex = ++_nextZ;
    notifyListeners();
  }

  void restoreUnderPointer(String id, Offset workspacePointer) {
    final entry = byId(id);
    if (entry == null || !entry.maximized) return;
    final prev = entry.prevBounds ?? Rect.fromLTWH(entry.x, entry.y, defaultWidth, defaultHeight);
    final grabFraction = entry.width > 0 ? ((workspacePointer.dx - entry.x) / entry.width).clamp(0.0, 1.0) : 0.5;

    entry.width = prev.width;
    entry.height = prev.height;
    entry.x = workspacePointer.dx - grabFraction * entry.width;
    entry.y = workspacePointer.dy - 20;
    entry.maximized = false;
    entry.prevBounds = null;
    entry.zIndex = ++_nextZ;
    notifyListeners();
  }

  void updateBounds(String id, {double? x, double? y, double? width, double? height}) {
    final entry = byId(id);
    if (entry == null || entry.maximized) return;
    if (x != null) entry.x = x;
    if (y != null) entry.y = y;
    if (width != null) entry.width = width;
    if (height != null) entry.height = height;
    notifyListeners();
  }
}

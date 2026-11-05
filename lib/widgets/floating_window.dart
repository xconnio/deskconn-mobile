import 'package:deskconn_mobile_app/core/window_manager/desktop_window.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/overlay.dart';
import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:flutter/material.dart';

class FloatingWindow extends StatelessWidget {
  final DesktopWindowManager manager;
  final DesktopWindowEntry entry;
  final bool focused;
  final Rect workspaceRect;
  final Widget child;

  const FloatingWindow({
    super.key,
    required this.manager,
    required this.entry,
    required this.focused,
    required this.workspaceRect,
    required this.child,
  });

  void _onTitleBarPanStart(DragStartDetails details) {
    manager.focus(entry.id);
    if (entry.maximized) {
      final pointer = Offset(entry.x + details.localPosition.dx, entry.y + details.localPosition.dy);
      manager.restoreUnderPointer(entry.id, pointer);
    }
  }

  void _onTitleBarPanUpdate(DragUpdateDetails details) {
    final current = manager.byId(entry.id);
    if (current == null || current.maximized) return;
    final maxX = (workspaceRect.right - current.width).clamp(workspaceRect.left, double.infinity);
    final maxY = (workspaceRect.bottom - current.height).clamp(workspaceRect.top, double.infinity);
    final newX = (current.x + details.delta.dx).clamp(workspaceRect.left, maxX);
    final newY = (current.y + details.delta.dy).clamp(workspaceRect.top, maxY);
    manager.updateBounds(entry.id, x: newX, y: newY);
  }

  void _resize({
    required double dx,
    required double dy,
    bool left = false,
    bool top = false,
    bool right = false,
    bool bottom = false,
  }) {
    final e = manager.byId(entry.id);
    if (e == null || e.maximized) return;

    var x = e.x;
    var y = e.y;
    var width = e.width;
    var height = e.height;

    if (right) {
      width = (width + dx).clamp(e.minWidth, workspaceRect.right - x);
    }
    if (bottom) {
      height = (height + dy).clamp(e.minHeight, workspaceRect.bottom - y);
    }
    if (left) {
      final proposedWidth = (width - dx).clamp(e.minWidth, double.infinity);
      final proposedX = (x + (width - proposedWidth)).clamp(workspaceRect.left, x + width - e.minWidth);
      width = width - (proposedX - x);
      x = proposedX;
    }
    if (top) {
      final proposedHeight = (height - dy).clamp(e.minHeight, double.infinity);
      final proposedY = (y + (height - proposedHeight)).clamp(workspaceRect.top, y + height - e.minHeight);
      height = height - (proposedY - y);
      y = proposedY;
    }

    manager.updateBounds(entry.id, x: x, y: y, width: width, height: height);
  }

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    final titleColor = focused ? palette.text : palette.subtle;
    final iconColor = focused ? entry.iconColor : palette.subtle;
    final barColor = focused ? palette.surface : palette.surfaceTint;

    return Positioned(
      left: entry.x,
      top: entry.y,
      width: entry.width,
      height: entry.height,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanDown: (_) => manager.focus(entry.id),
        child: Material(
          elevation: focused ? 16 : 4,
          borderRadius: BorderRadius.circular(entry.maximized ? 0 : 12),
          clipBehavior: Clip.antiAlias,
          color: palette.surface,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    onPanStart: _onTitleBarPanStart,
                    onPanUpdate: _onTitleBarPanUpdate,
                    onDoubleTap: () => manager.toggleMaximize(entry.id, workspaceRect),
                    child: Container(
                      height: 40,
                      color: barColor,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Icon(entry.icon, size: 16, color: iconColor),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DeskconnText.labelStrong.copyWith(color: titleColor),
                            ),
                          ),
                          _TitleBarButton(icon: Icons.remove, onTap: () => manager.minimize(entry.id)),
                          _TitleBarButton(
                            icon: entry.maximized ? Icons.filter_none : Icons.crop_square,
                            onTap: () => manager.toggleMaximize(entry.id, workspaceRect),
                          ),
                          _TitleBarButton(
                            icon: Icons.close,
                            hoverColor: DeskconnOverlay.danger,
                            onTap: () => manager.close(entry.id),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(child: child),
                ],
              ),
              if (!entry.maximized) ..._resizeHandles(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _resizeHandles() {
    const edgeThickness = 6.0;
    const cornerSize = 14.0;

    Widget handle({
      required MouseCursor cursor,
      required bool left,
      required bool top,
      required bool right,
      required bool bottom,
    }) {
      return MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanUpdate: (d) =>
              _resize(dx: d.delta.dx, dy: d.delta.dy, left: left, top: top, right: right, bottom: bottom),
          child: const SizedBox.expand(),
        ),
      );
    }

    return [
      Positioned(
        top: 0,
        left: cornerSize,
        right: cornerSize,
        height: edgeThickness,
        child: handle(cursor: SystemMouseCursors.resizeUpDown, left: false, top: true, right: false, bottom: false),
      ),
      Positioned(
        bottom: 0,
        left: cornerSize,
        right: cornerSize,
        height: edgeThickness,
        child: handle(cursor: SystemMouseCursors.resizeUpDown, left: false, top: false, right: false, bottom: true),
      ),
      Positioned(
        left: 0,
        top: cornerSize,
        bottom: cornerSize,
        width: edgeThickness,
        child: handle(cursor: SystemMouseCursors.resizeLeftRight, left: true, top: false, right: false, bottom: false),
      ),
      Positioned(
        right: 0,
        top: cornerSize,
        bottom: cornerSize,
        width: edgeThickness,
        child: handle(cursor: SystemMouseCursors.resizeLeftRight, left: false, top: false, right: true, bottom: false),
      ),
      Positioned(
        left: 0,
        top: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle(
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
          left: true,
          top: true,
          right: false,
          bottom: false,
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle(
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
          left: false,
          top: true,
          right: true,
          bottom: false,
        ),
      ),
      Positioned(
        left: 0,
        bottom: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle(
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
          left: true,
          top: false,
          right: false,
          bottom: true,
        ),
      ),
      Positioned(
        right: 0,
        bottom: 0,
        width: cornerSize,
        height: cornerSize,
        child: handle(
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
          left: false,
          top: false,
          right: true,
          bottom: true,
        ),
      ),
    ];
  }
}

class _TitleBarButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? hoverColor;

  const _TitleBarButton({required this.icon, required this.onTap, this.hoverColor});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      hoverColor: hoverColor?.withValues(alpha: 0.15),
      child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 15)),
    );
  }
}

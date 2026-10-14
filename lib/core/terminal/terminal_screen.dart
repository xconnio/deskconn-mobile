import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/core.dart';
import 'package:xterm/ui.dart' hide TerminalController;
import 'package:xterm/ui.dart' as xterm show SelectionMode, TerminalController;
import 'terminal_controller.dart';
import 'terminal_launcher.dart';
import 'terminal_link_highlighter.dart';
import 'terminal_links.dart';
import 'terminal_registry.dart';
import 'terminal_selection_math.dart';
import 'terminal_theme.dart';
import 'toolbar.dart';

void _log(String msg) => debugPrint('[TerminalScreen ${DateTime.now().millisecondsSinceEpoch}] $msg');

class TerminalScreen extends StatelessWidget {
  final String realm;
  final String desktopName;
  final bool webRtcEnabled;

  const TerminalScreen({super.key, required this.realm, required this.desktopName, required this.webRtcEnabled});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: TerminalTabsView(realm: realm, desktopName: desktopName, webRtcEnabled: webRtcEnabled),
    );
  }
}

class TerminalTabsView extends StatefulWidget {
  final String realm;
  final String desktopName;
  final bool webRtcEnabled;
  final bool embedded;
  final VoidCallback? onRequestClose;

  const TerminalTabsView({
    super.key,
    required this.realm,
    required this.desktopName,
    required this.webRtcEnabled,
    this.embedded = false,
    this.onRequestClose,
  });

  @override
  State<TerminalTabsView> createState() => _TerminalTabsViewState();
}

class _TerminalTabsViewState extends State<TerminalTabsView> {
  late final TerminalGroup _group;
  bool _addingTab = false;

  @override
  void initState() {
    super.initState();
    _group = TerminalRegistry().groupFor(widget.realm);
    _group.pruneInactive();
    _group.addListener(_onGroupChanged);
    if (_group.isEmpty) unawaited(_addTab());
  }

  @override
  void dispose() {
    _group.removeListener(_onGroupChanged);
    super.dispose();
  }

  void _onGroupChanged() {
    if (!mounted) return;
    if (_group.isEmpty) {
      _close();
      return;
    }
    setState(() {});
  }

  void _close() {
    if (widget.embedded) {
      widget.onRequestClose?.call();
    } else if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _addTab() async {
    if (_addingTab) return;
    setState(() => _addingTab = true);
    try {
      final controller = await startNewTerminalTab(
        realm: widget.realm,
        desktopName: widget.desktopName,
        webRtcEnabled: widget.webRtcEnabled,
      );
      if (!mounted) {
        controller.dispose();
        return;
      }
      _group.addTab(controller);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not open a new tab: $e')));
      }
    } finally {
      if (mounted) setState(() => _addingTab = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _group.tabs;
    if (tabs.isEmpty) return const SizedBox.shrink();

    final activeIndex = tabs.indexWhere((t) => t.id == _group.activeId).clamp(0, tabs.length - 1);

    return SafeArea(
      top: !widget.embedded,
      bottom: false,
      child: Container(
        color: Colors.black,
        child: Column(
          children: [
            _TerminalTabBar(
              tabs: tabs,
              activeId: _group.activeId,
              addingTab: _addingTab,
              onSelect: _group.selectTab,
              onClose: _group.closeTab,
              onAdd: _addTab,
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final (index, tab) in tabs.indexed)
                    Visibility(
                      key: ValueKey(tab.id),
                      visible: index == activeIndex,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: TerminalPane(
                        controller: tab.controller,
                        active: index == activeIndex,
                        embedded: true,
                        onRequestClose: () => _group.closeTab(tab.id),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalTabBar extends StatelessWidget {
  final List<TerminalTab> tabs;
  final String? activeId;
  final bool addingTab;
  final void Function(String id) onSelect;
  final void Function(String id) onClose;
  final VoidCallback onAdd;

  const _TerminalTabBar({
    required this.tabs,
    required this.activeId,
    required this.addingTab,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  Future<void> _showSwitcher(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => _TabSwitcherSheet(
        tabs: tabs,
        activeId: activeId,
        onSelect: (id) {
          Navigator.of(sheetContext).pop();
          onSelect(id);
        },
        onClose: (id) {
          Navigator.of(sheetContext).pop();
          onClose(id);
        },
        onAdd: () {
          Navigator.of(sheetContext).pop();
          onAdd();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeTab = tabs.firstWhere((t) => t.id == activeId, orElse: () => tabs.first);
    return Container(
      height: 44,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _TabChip(
                title: activeTab.title,
                active: true,
                onSelect: () => onSelect(activeTab.id),
                onClose: () => onClose(activeTab.id),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            height: 34,
            child: addingTab
                ? const Padding(
                    padding: EdgeInsets.all(9),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                  )
                : IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.add, color: Colors.white70, size: 20),
                    tooltip: 'New tab',
                    onPressed: onAdd,
                  ),
          ),
          GestureDetector(
            onTap: () => _showSwitcher(context),
            child: Container(
              width: 40,
              height: 34,
              margin: const EdgeInsets.only(left: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.grid_view_rounded, color: Colors.white70, size: 13),
                  const SizedBox(width: 4),
                  Text(
                    '${tabs.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final String title;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  const _TabChip({required this.title, required this.active, required this.onSelect, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onSelect,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 190),
        padding: const EdgeInsets.only(left: 12, right: 4),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: active ? 0.16 : 0.06),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: active ? Colors.white24 : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 13, color: active ? Colors.white : Colors.white38),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white60,
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(12),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 13, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabSwitcherSheet extends StatelessWidget {
  final List<TerminalTab> tabs;
  final String? activeId;
  final void Function(String id) onSelect;
  final void Function(String id) onClose;
  final VoidCallback onAdd;

  const _TabSwitcherSheet({
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  static const _previewLines = 6;

  String _previewOf(TerminalTab tab) {
    final lines = tab.controller.preview.split('\n').where((line) => line.trim().isNotEmpty).toList();
    if (lines.length <= _previewLines) return lines.join('\n');
    return lines.sublist(lines.length - _previewLines).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.grid_view_rounded, size: 16, color: Colors.white70),
                const SizedBox(width: 8),
                const Text(
                  'Tabs',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Text('${tabs.length}', style: const TextStyle(color: Colors.white38, fontSize: 13)),
                const Spacer(),
                IconButton(
                  onPressed: onAdd,
                  tooltip: 'New tab',
                  icon: const Icon(Icons.add, color: Colors.white70),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.05,
              ),
              itemCount: tabs.length,
              itemBuilder: (context, index) => _card(tabs[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(TerminalTab tab) {
    final active = tab.id == activeId;
    return GestureDetector(
      onTap: () => onSelect(tab.id),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF171717),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? Colors.white70 : Colors.white12, width: active ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 2, 5),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 13, color: active ? Colors.white : Colors.white54),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tab.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: active ? Colors.white : Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => onClose(tab.id),
                    borderRadius: BorderRadius.circular(10),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.close, size: 13, color: Colors.white38),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: Colors.black,
                padding: const EdgeInsets.all(8),
                child: Text(
                  _previewOf(tab),
                  maxLines: _previewLines,
                  style: const TextStyle(color: Colors.white54, fontSize: 8, fontFamily: 'monospace', height: 1.35),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TerminalPane extends StatefulWidget {
  final TerminalController controller;
  final bool active;
  final bool embedded;
  final VoidCallback? onRequestClose;

  const TerminalPane({
    super.key,
    required this.controller,
    this.active = true,
    this.embedded = false,
    this.onRequestClose,
  });

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> with WidgetsBindingObserver {
  static const double _minFontSize = 8;
  static const double _maxFontSize = 32;
  static const Duration _tapTimeout = Duration(milliseconds: 500);

  final xterm.TerminalController _xtermController = xterm.TerminalController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _stackKey = GlobalKey();
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey<TerminalViewState>();
  late final TerminalLinkRepaint _linkRepaint;
  final GlobalKey _linkAreaKey = GlobalKey();

  double _fontSize = 14;
  double _fontSizeOnScaleStart = 14;
  bool _isLoading = false;
  Object? _startError;
  _SelectionGeometry? _selectionGeometry;
  bool _draggingHandle = false;
  Offset _handleGrabOffset = Offset.zero;
  CellOffset? _dragAnchorCell;
  Offset? _pointerDownPosition;
  DateTime? _pointerDownTime;
  bool _keyboardWasOpenOnDown = false;
  String? _pendingLink;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _linkRepaint = TerminalLinkRepaint(widget.controller.terminal);
    _xtermController.addListener(_syncSelection);

    _isLoading = !widget.controller.isReady;
    if (widget.controller.isReady) {
      widget.controller.clearScreen();
      // Post-frame: send a resize signal so the server-side shell redraws its
      // prompt after we wiped the xterm buffer. Without this the cursor sits
      // idle because the shell has no reason to repaint.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.requestRedraw();
      });
    }
    widget.controller.onStarted = () {
      if (!mounted) return;
      setState(() => _isLoading = false);
      // The PTY is created with the client's size at that moment and only
      // corrected once the view has laid out, so its first output is drawn at
      // the wrong width. Wipe that and ask the shell to repaint instead of
      // leaving wrapped/overlapping lines behind.
      widget.controller.clearScreen();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.requestRedraw();
      });
    };
    widget.controller.onExit = _close;
    widget.controller.onError = (e) {
      if (mounted) setState(() => _startError = e);
    };

    _log('attached realm=${widget.controller.config.realm} isReady=${widget.controller.isReady}');
  }

  @override
  void dispose() {
    _log('dispose — detaching callbacks');
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.onStarted = null;
    widget.controller.onExit = null;
    widget.controller.onError = null;
    widget.controller.dispose();
    _linkRepaint.dispose();
    _xtermController.removeListener(_syncSelection);
    _xtermController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focusNode.requestFocus();
      });
    }
  }

  void _close() {
    if (!mounted) return;
    if (widget.embedded) {
      widget.onRequestClose?.call();
    } else {
      Navigator.pop(context);
    }
  }

  AppBar _launchAppBar() {
    return AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      elevation: 0,
      title: Text(widget.controller.config.desktopName, style: const TextStyle(fontSize: 15)),
    );
  }

  Widget _chrome({PreferredSizeWidget? appBar, required Widget body}) {
    if (widget.embedded) return Container(color: Colors.black, child: body);
    return Scaffold(backgroundColor: Colors.black, appBar: appBar, body: body);
  }

  @override
  Widget build(BuildContext context) {
    if (_startError != null) {
      return _chrome(
        appBar: _launchAppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                const Text('Could not open terminal', style: TextStyle(color: Colors.white, fontSize: 16)),
                const SizedBox(height: 8),
                Text(
                  _startError.toString(),
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _close,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                  child: const Text('Go back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_isLoading) {
      return _chrome(
        appBar: _launchAppBar(),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.terminal, color: Colors.white24, size: 48),
              const SizedBox(height: 20),
              const CircularProgressIndicator(color: Colors.white70),
              const SizedBox(height: 20),
              Text(
                'Connecting to ${widget.controller.config.desktopName}…',
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return _chrome(
      body: SafeArea(
        child: Stack(
          key: _stackKey,
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  Expanded(child: _terminalArea()),
                  Toolbar(controller: widget.controller),
                ],
              ),
            ),
            ..._selectionOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _terminalArea() {
    return Stack(
      key: _linkAreaKey,
      children: [
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _linkRepaint.refresh();
              if (_xtermController.selection != null) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _syncSelection());
              }
              return false;
            },
            child: Listener(
              onPointerDown: _handlePointerDown,
              onPointerUp: _handlePointerUp,
              onPointerCancel: (_) => _pointerDownPosition = null,
              child: GestureDetector(
                onScaleStart: (_) => _fontSizeOnScaleStart = _fontSize,
                onScaleUpdate: (details) {
                  if (details.pointerCount < 2) return;
                  final newSize = (_fontSizeOnScaleStart * details.scale).clamp(_minFontSize, _maxFontSize);
                  if ((newSize - _fontSize).abs() >= 0.5) {
                    setState(() => _fontSize = newSize);
                  }
                },
                child: TerminalView(
                  widget.controller.terminal,
                  key: _viewKey,
                  controller: _xtermController,
                  focusNode: _focusNode,
                  theme: kTerminalTheme,
                  autofocus: widget.active,
                  textStyle: TerminalStyle(fontSize: _fontSize),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: TerminalLinkPainter(
              terminal: widget.controller.terminal,
              theme: kTerminalTheme,
              textStyle: TerminalStyle(fontSize: _fontSize),
              textScaler: MediaQuery.textScalerOf(context),
              resolveOrigin: _linkOrigin,
              repaint: _linkRepaint,
            ),
          ),
        ),
      ],
    );
  }

  TextSelectionControls get _handleControls {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return cupertinoTextSelectionHandleControls;
      default:
        return materialTextSelectionHandleControls;
    }
  }

  List<Widget> _selectionOverlay() {
    final geometry = _selectionGeometry;
    if (geometry == null) return const [];

    final controls = _handleControls;
    final lineHeight = geometry.lineHeight;
    final overlays = <Widget>[];

    if (!_draggingHandle) {
      final multiline = (geometry.end.dy - geometry.start.dy) > lineHeight / 2;
      final anchorX = multiline ? geometry.viewportWidth / 2 : (geometry.start.dx + geometry.end.dx) / 2;
      overlays.add(
        Positioned.fill(
          child: AdaptiveTextSelectionToolbar.buttonItems(
            anchors: TextSelectionToolbarAnchors(
              primaryAnchor: Offset(anchorX, geometry.start.dy),
              secondaryAnchor: Offset(anchorX, geometry.end.dy),
            ),
            buttonItems: [
              ContextMenuButtonItem(type: ContextMenuButtonType.copy, onPressed: _copySelection),
              ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: _pasteFromClipboard),
              ContextMenuButtonItem(type: ContextMenuButtonType.share, onPressed: _shareSelection),
              ContextMenuButtonItem(type: ContextMenuButtonType.selectAll, onPressed: _selectAll),
              ContextMenuButtonItem(type: ContextMenuButtonType.searchWeb, onPressed: _searchSelectionWeb),
            ],
          ),
        ),
      );
    }

    overlays.add(_selectionHandle(geometry, TextSelectionHandleType.left, true, controls));
    overlays.add(_selectionHandle(geometry, TextSelectionHandleType.right, false, controls));
    return overlays;
  }

  Widget _selectionHandle(
    _SelectionGeometry geometry,
    TextSelectionHandleType type,
    bool isStart,
    TextSelectionControls controls,
  ) {
    const minTouchSize = kMinInteractiveDimension;
    final size = controls.getHandleSize(geometry.lineHeight);
    final touchWidth = math.max(minTouchSize, size.width);
    final touchHeight = math.max(minTouchSize, size.height);
    final anchor = isStart ? geometry.start : geometry.end;
    final topLeft = anchor - controls.getHandleAnchor(type, geometry.lineHeight);
    final padding = Offset((touchWidth - size.width) / 2, (touchHeight - size.height) / 2);

    // Keep the whole touch box inside the pane: the start handle is drawn to the
    // left of the selection, so it would otherwise fall outside the stack (and
    // outside hit testing) for anything selected at the start of a line.
    final left = (topLeft.dx - padding.dx).clamp(0.0, math.max(0.0, geometry.viewportWidth - touchWidth)).toDouble();
    final top = (topLeft.dy - padding.dy).clamp(0.0, math.max(0.0, geometry.viewportHeight - touchHeight)).toDouble();

    return Positioned(
      left: left,
      top: top,
      width: touchWidth,
      height: touchHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => _startHandleDrag(isStart, details.globalPosition),
        onPanUpdate: (details) => _updateHandleDrag(isStart, details.globalPosition),
        onPanEnd: (_) => _endHandleDrag(),
        onPanCancel: _endHandleDrag,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.only(left: padding.dx, top: padding.dy),
            child: _themedHandle(type, geometry.lineHeight),
          ),
        ),
      ),
    );
  }

  Widget _themedHandle(TextSelectionHandleType type, double lineHeight) {
    return TextSelectionTheme(
      data: TextSelectionTheme.of(
        context,
      ).copyWith(selectionHandleColor: kTerminalAccent, selectionColor: kTerminalSelection),
      child: CupertinoTheme(
        data: CupertinoTheme.of(context).copyWith(selectionHandleColor: kTerminalAccent),
        child: Builder(builder: (handleContext) => _handleControls.buildHandle(handleContext, type, lineHeight)),
      ),
    );
  }

  Offset? _linkOrigin() {
    final render = _viewKey.currentState?.renderTerminal;
    final stack = _linkAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (render == null || stack == null || !render.hasSize || !stack.hasSize) return null;
    return stack.globalToLocal(render.localToGlobal(render.getOffset(const CellOffset(0, 0))));
  }

  void _startHandleDrag(bool isStart, Offset globalPosition) {
    final geometry = _selectionGeometry;
    final stack = _linkAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final selection = _xtermController.selection;
    if (geometry == null || stack == null || selection == null) return;
    final range = selection.normalized;
    setState(() {
      _draggingHandle = true;
      _dragAnchorCell = isStart ? range.end : range.begin;
      _handleGrabOffset = globalPosition - stack.localToGlobal(isStart ? geometry.start : geometry.end);
    });
  }

  void _updateHandleDrag(bool isStart, Offset globalPosition) {
    final render = _viewKey.currentState?.renderTerminal;
    final selection = _xtermController.selection;
    if (render == null || !render.hasSize || selection == null) return;

    final point = TerminalSelectionMath.handleDragPoint(
      isStart: isStart,
      position: render.globalToLocal(globalPosition - _handleGrabOffset),
      cellSize: render.cellSize,
    );
    final cell = render.getCellOffset(point);
    final moving = isStart ? cell : CellOffset(cell.x + 1, cell.y);

    final anchor = _dragAnchorCell ?? (isStart ? selection.normalized.end : selection.normalized.begin);
    final next = TerminalSelectionMath.rangeForEdge(moving: moving, anchor: anchor);
    if (next.begin.isEqual(next.end)) return;

    final buffer = widget.controller.terminal.buffer;
    _xtermController.setSelection(
      buffer.createAnchorFromOffset(next.begin),
      buffer.createAnchorFromOffset(next.end),
      mode: xterm.SelectionMode.line,
    );
  }

  void _endHandleDrag() {
    if (!_draggingHandle) return;
    setState(() {
      _draggingHandle = false;
      _dragAnchorCell = null;
    });
  }

  void _syncSelection() {
    if (!mounted) return;
    final selection = _xtermController.selection;
    final render = _viewKey.currentState?.renderTerminal;
    final stack = _linkAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (selection == null || render == null || stack == null) {
      if (_selectionGeometry != null) setState(() => _selectionGeometry = null);
      return;
    }
    if (!render.hasSize || !stack.hasSize) return;

    final cell = render.cellSize;
    final begin = selection.normalized.begin;
    final end = selection.normalized.end;
    final start = stack.globalToLocal(render.localToGlobal(render.getOffset(begin)));
    final endPoint = render.getOffset(CellOffset(end.x, end.y)) + Offset(0, cell.height);
    final geometry = _SelectionGeometry(
      start: start,
      end: stack.globalToLocal(render.localToGlobal(endPoint)),
      lineHeight: cell.height,
      viewportWidth: stack.size.width,
      viewportHeight: stack.size.height,
    );
    if (_selectionGeometry?.matches(geometry) ?? false) return;
    setState(() => _selectionGeometry = geometry);
  }

  String? _takeSelectionText() {
    final selection = _xtermController.selection;
    if (selection == null) return null;
    final text = widget.controller.terminal.buffer.getText(selection);
    _xtermController.clearSelection();
    return text.trim().isEmpty ? null : text;
  }

  Future<void> _copySelection() async {
    final text = _takeSelectionText();
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 1)));
  }

  Future<void> _shareSelection() async {
    final text = _takeSelectionText();
    if (text == null) return;
    await SharePlus.instance.share(ShareParams(text: text));
  }

  Future<void> _searchSelectionWeb() async {
    final text = _takeSelectionText();
    if (text == null) return;
    final uri = Uri.tryParse('https://www.google.com/search?q=${Uri.encodeComponent(text.trim())}');
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _xtermController.clearSelection();
    widget.controller.terminal.paste(text);
  }

  void _selectAll() {
    final terminal = widget.controller.terminal;
    final buffer = terminal.buffer;
    _xtermController.setSelection(
      buffer.createAnchor(0, buffer.height - terminal.viewHeight),
      buffer.createAnchor(terminal.viewWidth, buffer.height - 1),
      mode: xterm.SelectionMode.line,
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
    _pointerDownTime = DateTime.now();
    _keyboardWasOpenOnDown = _viewKey.currentState?.hasInputConnection ?? false;
    _pendingLink = _linkAt(event.position);
  }

  void _handlePointerUp(PointerUpEvent event) {
    final downPosition = _pointerDownPosition;
    final downTime = _pointerDownTime;
    final link = _pendingLink;
    _pendingLink = null;
    _pointerDownPosition = null;
    _pointerDownTime = null;
    if (link == null || downPosition == null || downTime == null) return;
    if ((event.position - downPosition).distance > kTouchSlop) return;
    if (DateTime.now().difference(downTime) > _tapTimeout) return;
    if (!_keyboardWasOpenOnDown) _viewKey.currentState?.closeKeyboard();
    _openLink(link);
  }

  String? _linkAt(Offset globalPosition) {
    final render = _viewKey.currentState?.renderTerminal;
    if (render == null || !render.hasSize) return null;
    return TerminalLinks.urlAt(widget.controller.terminal, render.getCellOffset(render.globalToLocal(globalPosition)));
  }

  void _openLink(String link) {
    final uri = Uri.tryParse(link.contains('://') ? link : 'https://$link');
    if (uri == null) return;
    unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
  }
}

class _SelectionGeometry {
  final Offset start;
  final Offset end;
  final double lineHeight;
  final double viewportWidth;
  final double viewportHeight;

  const _SelectionGeometry({
    required this.start,
    required this.end,
    required this.lineHeight,
    required this.viewportWidth,
    required this.viewportHeight,
  });

  bool matches(_SelectionGeometry other) {
    return (start - other.start).distance < 1 &&
        (end - other.end).distance < 1 &&
        lineHeight == other.lineHeight &&
        viewportWidth == other.viewportWidth &&
        viewportHeight == other.viewportHeight;
  }
}

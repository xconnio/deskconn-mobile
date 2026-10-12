import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class RecentApp {
  final String id;
  final String title;
  final IconData icon;
  final Color iconColor;
  final ui.Image? snapshot;

  const RecentApp({required this.id, required this.title, required this.icon, required this.iconColor, this.snapshot});
}

/// Pixel-style recents: a horizontal carousel of app snapshots, oldest on the
/// left and the most recent centred. Tap a card to open it, fling it up to close.
class RecentsView extends StatefulWidget {
  final List<RecentApp> apps;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onClose;
  final VoidCallback onHome;

  const RecentsView({super.key, required this.apps, required this.onOpen, required this.onClose, required this.onHome});

  @override
  State<RecentsView> createState() => _RecentsViewState();
}

class _RecentsViewState extends State<RecentsView> {
  late final PageController _controller = PageController(
    viewportFraction: 0.72,
    initialPage: widget.apps.isEmpty ? 0 : widget.apps.length - 1,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _pageOffset(int index) {
    if (!_controller.hasClients || !_controller.position.haveDimensions) {
      return (_controller.initialPage - index).toDouble();
    }
    return (_controller.page ?? 0) - index;
  }

  @override
  Widget build(BuildContext context) {
    final apps = widget.apps;
    final screen = MediaQuery.sizeOf(context);

    // A tap anywhere outside a card or the home button behaves like back.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.maybePop(context),
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: apps.isEmpty
              ? const Center(
                  child: Text('No recent apps', style: TextStyle(color: Colors.white70, fontSize: 16)),
                )
              : Column(
                  children: [
                    Expanded(
                      child: PageView.builder(
                        controller: _controller,
                        itemCount: apps.length,
                        itemBuilder: (context, index) {
                          final app = apps[index];
                          return AnimatedBuilder(
                            animation: _controller,
                            builder: (context, child) {
                              final distance = _pageOffset(index).abs().clamp(0.0, 1.0);
                              return Transform.scale(scale: 1 - distance * 0.08, child: child);
                            },
                            child: Dismissible(
                              key: ValueKey(app.id),
                              direction: DismissDirection.up,
                              onDismissed: (_) => widget.onClose(app.id),
                              child: _RecentCard(
                                app: app,
                                aspectRatio: screen.width / screen.height,
                                onTap: () => widget.onOpen(app.id),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 16),
                      child: InkResponse(
                        onTap: widget.onHome,
                        radius: 28,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.5),
                          ),
                          child: const Icon(Icons.home_outlined, size: 26, color: Colors.white, semanticLabel: 'Home'),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  final RecentApp app;
  final double aspectRatio;
  final VoidCallback onTap;

  const _RecentCard({required this.app, required this.aspectRatio, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final snapshot = app.snapshot;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: app.iconColor, borderRadius: BorderRadius.circular(7)),
                child: Icon(app.icon, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  app.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: aspectRatio,
                child: GestureDetector(
                  onTap: onTap,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: snapshot != null
                        ? RawImage(image: snapshot, fit: BoxFit.cover, alignment: Alignment.topCenter)
                        : ColoredBox(
                            color: Theme.of(context).colorScheme.surface,
                            child: Center(child: Icon(app.icon, size: 56, color: app.iconColor)),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

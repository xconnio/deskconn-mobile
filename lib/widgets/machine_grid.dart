import 'dart:async';
import 'dart:typed_data';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/errors/deskconn_error_mapper.dart';
import 'package:deskconn_mobile_app/core/wamp/ui.dart';
import 'package:deskconn_mobile_app/core/device/device_identity.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/core/wallpaper/wallpaper_cache.dart';
import 'package:deskconn_mobile_app/core/wallpaper/wallpaper_gradients.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/last_used_realm_store.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/screens/desktop_details_screen.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/overlay.dart';
import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:deskconn_mobile_app/widgets/app_empty_state.dart';
import 'package:deskconn_mobile_app/widgets/app_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum _RowStatus { connecting, p2p, routed, offline }

class MachineGrid extends StatefulWidget {
  final String? currentRealm;

  final bool overlay;

  const MachineGrid({super.key, this.currentRealm, this.overlay = false});

  @override
  State<MachineGrid> createState() => _MachineGridState();
}

class _MachineGridState extends State<MachineGrid> {
  Future<void> _showMachineActions(BuildContext context, Map<String, dynamic> desktop) async {
    final name = desktop['name'] as String? ?? 'this machine';
    final isOwner = desktop['role'] == null || desktop['role'] == 'owner';
    if (!isOwner) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Delete machine', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action != 'delete' || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
          'It is removed from your account and everyone it was shared with loses access. '
          'To add it back, attach it again from the desktop.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<SessionProvider>().deleteDesktop(desktop);
      messenger.showSnackBar(SnackBar(content: Text('Deleted $name')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(DeskconnErrorMapper.messageFor(e, fallback: 'Could not delete $name.'))),
      );
    }
  }

  final Set<String> _connectingRealms = {};
  final Map<String, Uint8List?> _wallpapers = {};
  Timer? _livenessTimer;

  void _onWallpaperChoice() {
    if (mounted) setState(() {});
  }

  void _ensureWallpaperLoaded(String realm) {
    if (_wallpapers.containsKey(realm)) return;
    _wallpapers[realm] = null;
    unawaited(WallpaperChoice.load(realm));
    WallpaperCache.load(realm).then((value) {
      if (!mounted || value == null) return;
      setState(() => _wallpapers[realm] = value);
    });
  }

  _RowStatus _statusFor(String realm) {
    if (!ConnectivityService().hasConnection) return _RowStatus.offline;
    final connection = DesktopConnectionManager().get(realm);
    if (connection != null) {
      return connection.isP2P ? _RowStatus.p2p : _RowStatus.routed;
    }
    return _connectingRealms.contains(realm) ? _RowStatus.connecting : _RowStatus.offline;
  }

  @override
  void initState() {
    super.initState();
    _livenessTimer = Timer.periodic(const Duration(seconds: 15), (_) => _verifyAllLiveness());
    WallpaperChoice.choices.addListener(_onWallpaperChoice);
    ConnectivityService().addListener(_handleConnectivityChanged);
  }

  @override
  void dispose() {
    _livenessTimer?.cancel();
    WallpaperChoice.choices.removeListener(_onWallpaperChoice);
    ConnectivityService().removeListener(_handleConnectivityChanged);
    super.dispose();
  }

  void _handleConnectivityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _verifyAllLiveness() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (!ConnectivityService().hasConnection) return;

    final desktops = context.read<SessionProvider>().desktops;
    await Future.wait(
      desktops.map((d) async {
        final realm = d['realm']?.toString();
        if (realm == null) return;
        await _verifyLiveness(realm);
      }),
    );
  }

  Future<void> _verifyLiveness(String realm) async {
    final connection = DesktopConnectionManager().get(realm);
    if (connection == null) return;

    try {
      await DesktopConnectionManager.checkAgentOnline(connection.session, const Duration(seconds: 4));
    } catch (_) {
      await DesktopConnectionManager().release(realm);
      if (mounted) setState(() {});
    }
  }

  Future<bool> _connect(String realm, bool webRtcEnabled) async {
    final authId = await DeviceIdentity.desktopAuthId();
    final privateKey = await DeviceIdentity.desktopPrivateKey();
    if (authId == null || privateKey == null) return false;

    try {
      final connection = await DesktopConnectionManager().acquire(
        realm: realm,
        authId: authId,
        privateKey: privateKey,
        webRtcEnabled: webRtcEnabled,
      );
      await DesktopConnectionManager.checkAgentOnline(connection.session, const Duration(seconds: 5));
      connection.isAgentOnline = true;
      await LastUsedRealmStore.set(realm);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ensureConnected(String realm) async {
    final cached = DesktopConnectionManager().get(realm);
    if (cached != null && cached.isAgentOnline) return true;

    if (mounted) setState(() => _connectingRealms.add(realm));
    const webRtcEnabled = defaultWebRtcEnabled;
    final success = await _connect(realm, webRtcEnabled);
    if (mounted) setState(() => _connectingRealms.remove(realm));
    return success;
  }

  Future<void> _openDesktop(BuildContext context, Map<String, dynamic> desktop) async {
    final realm = desktop['realm']?.toString();
    if (realm == null) return;

    if (realm == widget.currentRealm) {
      Navigator.of(context).pop();
      return;
    }

    final connected = await _ensureConnected(realm);
    if (!context.mounted) return;

    if (connected) {
      await _enterDesktop(context, desktop);
      return;
    }

    final retried = await _showConnectionDialog(context, desktop);
    if (retried && context.mounted) {
      await _enterDesktop(context, desktop);
    }
  }

  Future<void> _enterDesktop(BuildContext context, Map<String, dynamic> desktop) {
    return Navigator.of(
      context,
    ).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => MachinePager(desktop: desktop)), (route) => false);
  }

  Future<bool> _showConnectionDialog(BuildContext context, Map<String, dynamic> desktop) async {
    final realm = desktop['realm']?.toString();
    if (realm == null) return false;

    final status = _statusFor(realm);
    if (status == _RowStatus.connecting) return false;

    final (title, description) = switch (status) {
      _RowStatus.p2p => ('Connected (P2P)', 'Using a direct peer-to-peer connection.'),
      _RowStatus.routed => ('Connected (Routed)', 'Using a routed connection through the server.'),
      _RowStatus.offline => ('Offline', 'Could not reach this desktop.'),
      _RowStatus.connecting => ('Connecting', ''),
    };

    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Text(description),
          actions: [
            if (status != _RowStatus.p2p)
              TextButton(onPressed: () => Navigator.of(dialogContext).pop('p2p'), child: const Text('Retry P2P')),
            if (status != _RowStatus.routed)
              TextButton(onPressed: () => Navigator.of(dialogContext).pop('routed'), child: const Text('Use Routed')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
          ],
        );
      },
    );

    if (action == null || !mounted) return false;
    return _forceReconnect(realm, action == 'p2p');
  }

  Future<bool> _forceReconnect(String realm, bool webRtcEnabled) async {
    if (mounted) setState(() => _connectingRealms.add(realm));
    await DesktopConnectionManager().release(realm);
    final success = await _connect(realm, webRtcEnabled);
    if (mounted) setState(() => _connectingRealms.remove(realm));

    if (!mounted) return success;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not connect to desktop.')));
    } else if (webRtcEnabled && _statusFor(realm) == _RowStatus.routed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('P2P unavailable, connected via routed instead.')));
    }
    return success;
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final gridDelegate = isDesktopLayout(context)
        ? const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: DeskconnUI.gridMaxExtent,
            crossAxisSpacing: 20,
            mainAxisSpacing: 20,
            childAspectRatio: 1.3,
          )
        : const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: 1.1,
          );

    return RefreshIndicator(
      onRefresh: () async {
        if (!ConnectivityService().hasConnection) {
          if (mounted) setState(() {});
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No internet connection')));
          }
          return;
        }
        await context.read<SessionProvider>().loadDesktops();
        await _verifyAllLiveness();
      },
      child: session.desktopsLoading || session.desktops.isEmpty
          ? CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverFillRemaining(
                  child: session.desktopsLoading
                      ? GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          gridDelegate: gridDelegate,
                          itemCount: 6,
                          itemBuilder: (_, _) => const _MachineCardSkeleton(),
                        )
                      : AppEmptyState(
                          icon: Icons.desktop_windows_outlined,
                          title: 'No desktop attached yet',
                          subtitle: 'Connected desktops will appear here',
                          onOverlay: widget.overlay,
                        ),
                ),
              ],
            )
          : GridView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewPaddingOf(context).bottom),
              gridDelegate: gridDelegate,
              itemCount: session.desktops.length,
              itemBuilder: (context, i) {
                final d = session.desktops[i];
                final name = d['name'] as String? ?? 'Unnamed Desktop';
                final realm = d['realm']?.toString() ?? '';
                final status = _statusFor(realm);
                _ensureWallpaperLoaded(realm);
                final wallpaper = _wallpapers[realm];

                return _MachineCard(
                  name: name,
                  status: status,
                  wallpaper: wallpaper,
                  gradient: wallpaperGradientById(WallpaperChoice.choices.value[realm]),
                  selected: realm.isNotEmpty && realm == widget.currentRealm,
                  onTap: () => _openDesktop(context, d),
                  onLongPress: () => _showMachineActions(context, d),
                  onStatusTap: () => _showConnectionDialog(context, d),
                  overlay: widget.overlay,
                );
              },
            ),
    );
  }
}

class _MachineCard extends StatelessWidget {
  final String name;
  final _RowStatus status;
  final Uint8List? wallpaper;
  final WallpaperGradient? gradient;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onStatusTap;

  final bool overlay;

  const _MachineCard({
    required this.name,
    required this.status,
    required this.wallpaper,
    required this.gradient,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onStatusTap,
    this.overlay = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = DeskconnPalette.of(context);
    final wallpaperBytes = wallpaper;
    final ringColor = selected ? palette.googleBlue : colorScheme.outlineVariant;

    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: selected
                  ? [BoxShadow(color: palette.googleBlue.withValues(alpha: 0.45), blurRadius: 16, spreadRadius: 1)]
                  : null,
            ),
            child: Material(
              color: colorScheme.surfaceContainerHighest,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: ringColor, width: selected ? 2 : 1),
              ),
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (gradient != null)
                      DecoratedBox(decoration: BoxDecoration(gradient: gradient!.gradient))
                    else if (wallpaperBytes != null)
                      Image.memory(
                        wallpaperBytes,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Center(child: Icon(Icons.computer, size: 46, color: palette.subtle)),
                      )
                    else
                      Center(child: Icon(Icons.computer, size: 46, color: palette.subtle)),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _StatusDot(status: status, onTap: onStatusTap),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.computer, size: 14, color: palette.subtle),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DeskconnText.labelStrong.copyWith(
                  color: overlay ? DeskconnOverlay.foreground : colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  final _RowStatus status;
  final VoidCallback onTap;

  const _StatusDot({required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    final (dotColor, label) = switch (status) {
      _RowStatus.connecting => (palette.subtle, 'Connecting'),
      _RowStatus.p2p => (palette.statusOnline, 'Connected (P2P)'),
      _RowStatus.routed => (palette.statusRouted, 'Connected (routed)'),
      _RowStatus.offline => (palette.statusOffline, 'Offline'),
    };

    return Semantics(
      button: true,
      label: 'Connection status: $label',
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: DeskconnOverlay.dotShadow, blurRadius: 4)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MachineCardSkeleton extends StatelessWidget {
  const _MachineCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: AppSkeletonBox(borderRadius: BorderRadius.circular(14))),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.center,
          child: AppSkeletonBox(width: 90, height: 12, borderRadius: BorderRadius.circular(4)),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/vpn/rtc_vpn_channel.dart';
import 'package:deskconn_mobile_app/core/vpn/vpn_platform.dart';
import 'package:deskconn_mobile_app/core/vpn/vpn_tunnel.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';

enum VpnStatus { disconnected, connecting, connected }

class VpnException implements Exception {
  const VpnException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class VpnLink {
  VpnChannel get channel;
  Future<void> release();
}

typedef VpnLinkFactory = Future<VpnLink> Function(DesktopSessionLaunchConfig config);

class VpnController extends ChangeNotifier {
  VpnController({required VpnPlatform platform, required VpnLinkFactory openLink})
    : _platform = platform,
      _openLink = openLink;

  static final VpnController shared = VpnController(
    platform: AndroidVpnPlatform.instance,
    openLink: openDesktopVpnLink,
  );

  final VpnPlatform _platform;
  final VpnLinkFactory _openLink;

  VpnStatus status = VpnStatus.disconnected;
  String? realm;
  String? desktopName;
  String? error;
  VpnReady? ready;

  VpnLink? _link;
  VpnTunnel? _tunnel;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  int _generation = 0;

  bool isConnectedTo(String realm) => this.realm == realm && status != VpnStatus.disconnected;

  Future<void> connect(DesktopSessionLaunchConfig config) async {
    if (status != VpnStatus.disconnected) return;
    final generation = ++_generation;
    status = VpnStatus.connecting;
    realm = config.realm;
    desktopName = config.desktopName;
    error = null;
    notifyListeners();

    try {
      if (!await _platform.prepare()) throw const VpnException('VPN permission was not granted.');
      _checkCurrent(generation);

      final link = await _openLink(config);
      _link = link;
      _checkCurrent(generation);

      final tunnel = VpnTunnel(link.channel);
      _tunnel = tunnel;
      final ready = await tunnel.open();
      _checkCurrent(generation);

      await _platform.start(address: ready.clientAddress, prefix: ready.clientPrefix, mtu: ready.mtu);
      _checkCurrent(generation);

      _subscriptions
        ..add(_platform.packets.listen(tunnel.send))
        ..add(tunnel.packets.listen(_platform.write))
        ..add(_platform.revoked.listen((_) => unawaited(disconnect())));
      unawaited(tunnel.closed.then((_) => _onTunnelLost(generation)));

      this.ready = ready;
      status = VpnStatus.connected;
      notifyListeners();
    } on _Superseded {
      return;
    } on VpnRejectedException {
      await _fail(
        generation,
        '${config.desktopName} isn\'t sharing its connection. Run "deskconn vpn start" on it, then try again.',
      );
    } on PlatformException catch (e) {
      await _fail(generation, 'Could not start the VPN on this phone: ${e.message ?? e.code}');
    } on TimeoutException {
      await _fail(generation, 'Timed out setting up the VPN with ${config.desktopName}.');
    } on VpnException catch (e) {
      await _fail(generation, e.message);
    } catch (_) {
      await _fail(generation, 'Could not connect to ${config.desktopName}. Check that it is online and try again.');
    }
  }

  Future<void> disconnect() async {
    _generation++;
    await _teardown();
    status = VpnStatus.disconnected;
    ready = null;
    notifyListeners();
  }

  void _checkCurrent(int generation) {
    if (generation != _generation) throw const _Superseded();
  }

  Future<void> _onTunnelLost(int generation) async {
    if (generation != _generation || status != VpnStatus.connected) return;
    await _fail(generation, 'The VPN connection to $desktopName was lost.');
  }

  Future<void> _fail(int generation, String message) async {
    if (generation != _generation) return;
    _generation++;
    await _teardown();
    status = VpnStatus.disconnected;
    ready = null;
    error = message;
    notifyListeners();
  }

  Future<void> _teardown() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final tunnel = _tunnel;
    final link = _link;
    _tunnel = null;
    _link = null;
    try {
      await _platform.stop();
    } catch (_) {}
    try {
      await tunnel?.close();
    } catch (_) {}
    try {
      await link?.release();
    } catch (_) {}
  }
}

class _Superseded implements Exception {
  const _Superseded();
}

class _DesktopVpnLink implements VpnLink {
  _DesktopVpnLink(this._connection, this.channel);

  final DesktopConnection _connection;

  @override
  final VpnChannel channel;

  @override
  Future<void> release() => DesktopConnectionManager().releaseStandalone(_connection);
}

Future<VpnLink> openDesktopVpnLink(DesktopSessionLaunchConfig config) async {
  final connection = await DesktopConnectionManager().connectStandalone(
    realm: config.realm,
    authId: config.authId,
    privateKey: config.privateKey,
    webRtcEnabled: true,
  );
  final rtc = connection.webRtcSession;
  if (rtc == null) {
    await DesktopConnectionManager().releaseStandalone(connection);
    throw const VpnException('The VPN needs a direct connection to the desktop.');
  }
  try {
    final channel = await rtc.extraChannel(kVpnChannelLabel).timeout(kVpnHandshakeTimeout);
    return _DesktopVpnLink(connection, RtcVpnChannel(channel));
  } catch (_) {
    await DesktopConnectionManager().releaseStandalone(connection);
    rethrow;
  }
}

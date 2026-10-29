import 'dart:async';

import 'package:deskconn_mobile_app/core/device/device_identity.dart';

import 'terminal_background_service.dart';
import 'terminal_controller.dart';

Future<TerminalController> startNewTerminalTab({
  required String realm,
  required String desktopName,
  required bool webRtcEnabled,
}) async {
  final authId = await DeviceIdentity.desktopAuthId();
  final privateKey = await DeviceIdentity.desktopPrivateKey();
  if (authId == null || privateKey == null) {
    throw Exception('Missing terminal credentials.');
  }

  final config = DesktopSessionLaunchConfig(
    sessionKey: 'terminal:$realm',
    desktopName: desktopName,
    realm: realm,
    authId: authId,
    privateKey: privateKey,
    webRtcEnabled: webRtcEnabled,
  );

  final controller = TerminalController(config: config);
  unawaited(controller.start());
  return controller;
}

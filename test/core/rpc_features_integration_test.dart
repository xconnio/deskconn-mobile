import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as rtc;
import 'package:deskconn_mobile_app/core/wamp/file_stream_service.dart';
import 'package:deskconn_mobile_app/core/terminal/shell_stream.dart';
import 'package:deskconn_mobile_app/core/port_forward/port_forward_service.dart';

Future<void> portFeatures(Session session) async {
  final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = <Socket>[];
  echo.listen((socket) {
    accepted.add(socket);
    socket.listen(socket.add, onDone: socket.close);
  });
  Future<void> roundTrip(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final body = Uint8List.fromList(List.generate(256 * 1024 + 7, (index) => index % 251));
    final received = BytesBuilder();
    final complete = Completer<void>();
    final reader = socket.listen(
      (bytes) {
        received.add(bytes);
        if (received.length >= body.length && !complete.isCompleted) complete.complete();
      },
      onError: (Object error) {
        if (!complete.isCompleted) complete.completeError(error);
      },
    );
    try {
      socket.add(body);
      await socket.flush();
      await complete.future.timeout(const Duration(seconds: 15));
      expect(received.takeBytes(), body);
    } finally {
      socket.destroy();
      await reader.cancel();
    }
  }

  try {
    final forward = await PortForwardSession.start(session: session, localPort: 0, remotePort: echo.port);
    try {
      await roundTrip(forward.localPort);
    } finally {
      await forward.stop();
    }
    final reserve = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserve.port;
    await reserve.close();
    final reverse = await PortReverseSession.start(session: session, remotePort: port, localPort: echo.port);
    try {
      await roundTrip(port);
    } finally {
      await reverse.stop();
    }
  } finally {
    for (final socket in accepted) {
      socket.destroy();
    }
    await echo.close();
  }
}

Future<void> features(Session session, Map<String, dynamic> fixture, String label) async {
  final files = FileStreamService(session);
  final temporary = await Directory.systemTemp.createTemp('deskconn-features-');
  try {
    final destination = File('${temporary.path}/download');
    final output = await destination.open(mode: FileMode.write);
    try {
      await files.downloadFile(fixture['source'] as String, output);
    } finally {
      await output.close();
    }
    final downloaded = await destination.readAsBytes();
    expect(downloaded.length, 1400000);
    for (var index = 0; index < downloaded.length; index++) {
      if (downloaded[index] != const [0, 255, 42, 128][index % 4]) fail('Changed download byte at $index');
    }
    final bytes = Uint8List.fromList(List.generate(5 * 1024 * 1024 + 123, (index) => index % 251));
    final upload = await File('${temporary.path}/$label-upload.bin').writeAsBytes(bytes);
    await files.uploadFile(upload.path, fixture['directory'] as String);
    final read = await files.openRange('${fixture['directory']}/$label-upload.bin', 0, bytes.length);
    final received = BytesBuilder();
    await for (final chunk in read.chunks) {
      received.add(chunk);
    }
    expect(received.takeBytes(), bytes);
    await expectLater(
      files.openRange('/nonexistent-file', 0, 1).then((range) => range.chunks.drain<void>()),
      throwsStateError,
    );

    await Future.wait(
      List.generate(2, (index) async {
        final closed = Completer<void>();
        var text = '';
        final shell = await openShell(session, 80, 24, (bytes) => text += utf8.decode(bytes, allowMalformed: true), () {
          if (!closed.isCompleted) closed.complete();
        });
        try {
          shell.send(Uint8List.fromList(utf8.encode('printf "rpc-shell-$index\\n"; exit\r')));
          await closed.future.timeout(const Duration(seconds: 15));
          expect(text, contains('rpc-shell-$index'));
        } finally {
          await shell.close();
        }
      }),
    );
    await portFeatures(session);
    expect(session.isConnected(), isTrue);
  } finally {
    await temporary.delete(recursive: true);
  }
}

void main() {
  final binary = Platform.environment['DESKCONN_STREAM_PEER'];
  test(
    'encrypted files, shells and TCP forwards cross the yamux bridge on QUIC and WebRTC',
    () async {
      final process = await Process.start(binary!, []);
      addTearDown(() async {
        await process.stdin.close();
        await process.exitCode;
      });
      process.stderr.transform(utf8.decoder).listen(stderr.write);
      final line = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      final fixture = jsonDecode(line) as Map<String, dynamic>;
      final certificate = base64Decode(
        (fixture['certificate'] as String).replaceAll(RegExp(r'-----[^-]+-----|\s'), ''),
      );
      final routed = await connectQUIC(
        fixture['quic'] as String,
        fixture['realm'] as String,
        QUICDialerConfig(authenticator: AnonymousAuthenticator('client'), serializer: CBORSerializer()),
        certificateFingerprint: sha256.convert(certificate).toString(),
      );
      addTearDown(routed.close);
      await features(routed, fixture, 'routed');
      final direct = await rtc.connectWAMP(
        rtc.ClientConfig(
          realm: fixture['realm'] as String,
          procedureWebRTCOffer: 'offer',
          topicAnswererOnCandidate: 'to-provider',
          topicOffererOnCandidate: 'to-client',
          iceServers: [],
          serializer: CBORSerializer(),
          session: routed,
          authenticator: AnonymousAuthenticator('client'),
        ),
      );
      addTearDown(direct.session.close);
      await features(direct.session, fixture, 'direct');
    },
    skip: binary == null ? 'Set DESKCONN_STREAM_PEER to the DeskConn tests/client-peer binary' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

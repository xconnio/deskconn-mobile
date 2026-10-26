import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as rtc;
import 'package:flutter_test/flutter_test.dart';
import 'package:xconn_core/quic.dart' as core;
import 'package:xconn_core/xconn_core.dart' as core;

void main() {
  final binary = Platform.environment['XCONN_TRANSPORT_PEER'];
  group('Core native transports', skip: binary == null ? 'Set XCONN_TRANSPORT_PEER' : false, () {
    late Process server;
    late Map<String, dynamic> addresses;
    setUpAll(() async {
      server = await Process.start(binary!, []);
      final line = await server.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      addresses = jsonDecode(line) as Map<String, dynamic>;
    });
    tearDownAll(() async {
      await server.stdin.close();
      await server.exitCode;
    });

    test('dedicated QUIC session owns relay bytes, EOF and its connection', () async {
      final cert = addresses['quic_certificate'] as String;
      final certificate = Uint8List.fromList([
        for (var i = 0; i < cert.length; i += 2) int.parse(cert.substring(i, i + 2), radix: 16),
      ]);
      final connection = await core.QUICConnection.connect(
        addresses['quic'] as String,
        serverName: 'localhost',
        certificate: certificate,
      );
      final session = QUICSession(await connection.openSession('realm'), connection);
      addTearDown(session.close);
      expect((await session.call('echo', args: [42])).args, [42]);
      final stream = await session.openStream();
      final bytes = Uint8List.fromList(List.generate(65024, (i) => i % 256));
      await stream.writeAll(bytes);
      expect(await stream.readExact(bytes.length), bytes);
      await stream.close();
      await session.close();
      expect(session.isConnected(), isFalse);
    });

    test('WebRTC app channels preserve text keys and opaque encrypted packets', () async {
      final signaling = Session(await core.Client().connect(addresses['ws'] as String, 'realm'));
      addTearDown(signaling.close);
      final observer = await core.Client().connect(addresses['ws'] as String, 'realm');
      addTearDown(observer.close);
      final clientCandidates = Completer<void>();
      final serverCandidates = Completer<void>();
      final outbound = await observer.subscribe('to-provider', (_) {
        if (!clientCandidates.isCompleted) clientCandidates.complete();
      }).execute();
      addTearDown(outbound.unsubscribe);
      final inbound = await observer.subscribe('to-client', (_) {
        if (!serverCandidates.isCompleted) serverCandidates.complete();
      }).execute();
      addTearDown(inbound.unsubscribe);
      final peer = await rtc.connectWAMP(
        rtc.ClientConfig(
          realm: 'realm',
          procedureWebRTCOffer: 'offer',
          topicAnswererOnCandidate: 'to-provider',
          topicOffererOnCandidate: 'to-client',
          iceServers: [
            {
              'urls': ['stun:127.0.0.1:9'],
            },
          ],
          serializer: CBORSerializer(),
          session: signaling,
          authenticator: AnonymousAuthenticator(''),
        ),
      );
      addTearDown(peer.session.close);
      await Future.wait([clientCandidates.future, serverCandidates.future]).timeout(const Duration(seconds: 5));
      expect((await peer.session.call('echo', args: ['direct'])).args, ['direct']);
      final channel = await peer.openChannel('packets');
      addTearDown(channel.close);
      var next = channel.messageStream.first;
      await channel.send(rtc.ChannelMessage('{"public_key":"test"}'));
      expect((await next).text, '{"public_key":"test"}');
      next = channel.messageStream.first;
      final bytes = Uint8List.fromList(List.generate(65024, (i) => i % 256));
      await channel.send(rtc.ChannelMessage.fromBinary(bytes));
      await channel.waitBufferedBelow(0);
      expect((await next).binary, bytes);
      final closed = channel.stateChangeStream.firstWhere((state) => state == rtc.ChannelState.closed);
      await channel.close();
      await closed.timeout(const Duration(seconds: 3));
    });
  });
}

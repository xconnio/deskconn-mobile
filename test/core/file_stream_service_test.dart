import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as rtc;
import 'package:deskconn_mobile_app/core/wamp/file_stream_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconn_core/webrtc.dart' as core;
import 'package:xconn_core/xconn_core.dart' show ProtocolError;

class _NativeChannel implements core.DataChannel {
  final packet = Completer<Object>();
  var reads = 0;

  @override
  Future<void> get closed => Future.value();

  @override
  Future<Object> receive() async {
    if (reads++ == 0) return packet.future;
    throw ProtocolError('WebRTC receive queue overflow');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Peer implements rtc.WebRTCSession {
  _Peer([this.contents = const []]);

  final List<int> contents;
  final channels = <_FileChannel>[];

  @override
  Future<rtc.AppDataChannel> extraChannel(String label) async {
    final channel = _FileChannel(contents);
    channels.add(channel);
    return channel;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Replies arrive before send completes, as they can with native event delivery.
class _FileChannel implements rtc.AppDataChannel {
  _FileChannel(this.contents);

  final List<int> contents;

  @override
  void Function(rtc.ChannelMessage)? onMessage;

  @override
  void Function(rtc.ChannelState)? onDataChannelState;

  final DartChacha20 cipher = Chacha20.poly1305Aead().toSync();
  SecretKeyData? sendKey;
  SecretKeyData? receiveKey;
  var closed = false;
  final requests = <String>[];
  final readLengths = <int>[];

  @override
  Object? get failure => null;

  void _reply(Map<String, Object?> response) {
    final box = cipher.encryptSync(utf8.encode(jsonEncode(response)), secretKey: sendKey!);
    onMessage!(
      rtc.ChannelMessage.fromBinary(Uint8List.fromList([0, ...box.nonce, ...box.cipherText, ...box.mac.bytes])),
    );
  }

  @override
  Future<void> send(rtc.ChannelMessage message) async {
    if (!message.isBinary) {
      final key = (jsonDecode(message.text) as Map<String, dynamic>)['public_key'] as String;
      final pair = await X25519().newKeyPair();
      final shared = await X25519().sharedSecretKey(
        keyPair: pair,
        remotePublicKey: SimplePublicKey(base64Decode(key), type: KeyPairType.x25519),
      );
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      sendKey = await hkdf.deriveKey(secretKey: shared, info: utf8.encode('backendToFrontend'));
      receiveKey = await hkdf.deriveKey(secretKey: shared, info: utf8.encode('frontendToBackend'));
      final public = await pair.extractPublicKey();
      onMessage!(rtc.ChannelMessage(jsonEncode({'public_key': base64Encode(public.bytes)})));
      return;
    }

    if (message.binary[0] == 1) {
      _reply({'ok': true});
      return;
    }
    final bytes = message.binary.sublist(1);
    final plain = cipher.decryptSync(
      SecretBox(
        bytes.sublist(12, bytes.length - 16),
        nonce: bytes.sublist(0, 12),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: receiveKey!,
    );
    final request = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    final op = request['op'] as String;
    requests.add(op);
    _reply({
      'ok': true,
      if (op == 'list')
        'entries': [
          {'rel_path': 'empty', 'size': contents.length},
        ],
    });
    if (op == 'read') {
      final offset = request['offset'] as int;
      final length = request['length'] as int;
      readLengths.add(length);
      // A consumer can be descheduled while an entire response is queued.
      if ((length + 65023) ~/ 65024 + 1 > 64) {
        throw StateError('WebRTC receive queue overflow');
      }
      for (var start = offset; start < offset + length; start += 65024) {
        final end = start + 65024 < offset + length ? start + 65024 : offset + length;
        final box = cipher.encryptSync(contents.sublist(start, end), secretKey: sendKey!);
        onMessage!(
          rtc.ChannelMessage.fromBinary(Uint8List.fromList([1, ...box.nonce, ...box.cipherText, ...box.mac.bytes])),
        );
      }
    }
    if (op == 'list' || op == 'init') await close();
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    onDataChannelState?.call(rtc.ChannelState.closed);
  }

  @override
  int get bufferedAmount => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('channel delivers final queued packet before remote close notification', () async {
    final native = _NativeChannel();
    final channel = rtc.AppDataChannel(native);
    final messages = <String>[];
    final closed = Completer<void>();
    channel.onMessage = (message) => messages.add(message.text);
    channel.onDataChannelState = (_) => closed.complete();
    await Future<void>.delayed(Duration.zero);
    native.packet.complete('final acknowledgement');
    await closed.future.timeout(const Duration(seconds: 2));
    expect(messages, ['final acknowledgement']);
    expect(channel.failure.toString(), contains('WebRTC receive queue overflow'));
  });

  test('download retains a list reply received before send completes and channel closes', () async {
    final directory = await Directory.systemTemp.createTemp('file-stream-test-');
    addTearDown(() => directory.delete(recursive: true));
    final destination = await File('${directory.path}/download').open(mode: FileMode.write);
    addTearDown(destination.close);
    final peer = _Peer();
    await FileStreamService(peer).downloadFile('/empty', destination);
    expect(peer.channels.single.requests, ['list']);
    expect(peer.channels.single.closed, isTrue);
  });

  test('download preserves file bytes when the read reply arrives during send', () async {
    final directory = await Directory.systemTemp.createTemp('file-stream-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/download');
    final destination = await file.open(mode: FileMode.write);
    addTearDown(destination.close);
    final peer = _Peer([1, 2, 3, 4]);
    await FileStreamService(peer).downloadFile('/file', destination);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    expect(peer.channels.every((channel) => channel.closed), isTrue);
  });

  test('large parallel download bounds response bursts and preserves every byte', () async {
    final directory = await Directory.systemTemp.createTemp('file-stream-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/download');
    final destination = await file.open(mode: FileMode.write);
    addTearDown(destination.close);
    final contents = Uint8List(14 * 1024 * 1024 + 123);
    for (var i = 0; i < contents.length; i++) {
      contents[i] = i % 251;
    }
    final peer = _Peer(contents);
    var progress = 0;
    await FileStreamService(peer).downloadFile(
      '/large-file',
      destination,
      onProgress: (received, total) {
        expect(total, contents.length);
        progress = received;
      },
    );
    expect(await file.readAsBytes(), contents);
    expect(progress, contents.length);
    expect(peer.channels.expand((channel) => channel.readLengths), everyElement(lessThanOrEqualTo(1024 * 1024)));
    expect(peer.channels.every((channel) => channel.closed), isTrue);
  });

  test('upload retains ready and final acknowledgements received during send', () async {
    final directory = await Directory.systemTemp.createTemp('file-stream-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/upload').writeAsBytes([1, 2, 3]);
    final peer = _Peer();
    await FileStreamService(peer).uploadFile(file.path, '/');
    expect(peer.channels.map((channel) => channel.requests), [
      ['init'],
      ['write'],
    ]);
    expect(peer.channels.every((channel) => channel.closed), isTrue);
  });
}

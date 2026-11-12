import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as rtc;
import 'package:deskconn_mobile_app/core/wamp/file_stream_service.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart' hide Invocation;
import 'package:flutter_test/flutter_test.dart';
import 'package:xconn/webrtc.dart' as core;
import 'package:xconn/xconn.dart' show ProtocolError;

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

class _Peer implements Session {
  _Peer([this.contents = const []]);

  final List<int> contents;
  final channels = <_FileChannel>[];

  @override
  Future<RPCByteStream> openRPCStream(String procedure, {bool input = false}) async {
    final operation = procedure.split('.').last;
    expect(procedure, 'io.xconn.deskconn.file.stream.$operation');
    expect(input, operation == 'init' || operation == 'write');
    final channel = _FileChannel(contents, operation);
    channels.add(channel);
    return channel;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// The fake server speaks the same length-framed encrypted protocol as DeskConn.
class _FileChannel implements RPCByteStream {
  _FileChannel(this.contents, this.operation) {
    _reader = StreamIterator(_output.stream);
  }

  final List<int> contents;
  final String operation;
  final _output = StreamController<Uint8List>();
  late final StreamIterator<Uint8List> _reader;
  Uint8List _buffer = Uint8List(0);
  final DartChacha20 cipher = Chacha20.poly1305Aead().toSync();
  SecretKeyData? sendKey;
  SecretKeyData? receiveKey;
  var closed = false;
  var remainingWrite = 0;
  final requests = <String>[];
  final readLengths = <int>[];

  void _frame(List<int> payload) {
    final frame = Uint8List(4 + payload.length);
    ByteData.sublistView(frame).setUint32(0, payload.length);
    frame.setRange(4, frame.length, payload);
    _output.add(frame);
  }

  void _encrypted(List<int> payload) {
    final box = cipher.encryptSync(payload, secretKey: sendKey!);
    _frame([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  void _reply(Map<String, Object?> response) => _encrypted(utf8.encode(jsonEncode(response)));

  @override
  Future<Uint8List> readExact(int size) async {
    while (_buffer.length < size) {
      if (!await _reader.moveNext()) throw StateError('RPC stream ended');
      _buffer = Uint8List.fromList([..._buffer, ..._reader.current]);
    }
    final value = Uint8List.sublistView(_buffer, 0, size);
    _buffer = Uint8List.sublistView(_buffer, size);
    return value;
  }

  @override
  Future<void> writeAll(Uint8List frame) async {
    expect(ByteData.sublistView(frame).getUint32(0), frame.length - 4);
    final bytes = frame.sublist(4);
    if (receiveKey == null) {
      final key = (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)['public_key'] as String;
      final pair = await X25519().newKeyPair();
      final shared = await X25519().sharedSecretKey(
        keyPair: pair,
        remotePublicKey: SimplePublicKey(base64Decode(key), type: KeyPairType.x25519),
      );
      final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
      sendKey = await hkdf.deriveKey(secretKey: shared, info: utf8.encode('backendToFrontend'));
      receiveKey = await hkdf.deriveKey(secretKey: shared, info: utf8.encode('frontendToBackend'));
      final public = await pair.extractPublicKey();
      _frame(utf8.encode(jsonEncode({'public_key': base64Encode(public.bytes)})));
      return;
    }
    final plain = cipher.decryptSync(
      SecretBox(
        bytes.sublist(12, bytes.length - 16),
        nonce: bytes.sublist(0, 12),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: receiveKey!,
    );
    if (remainingWrite > 0) {
      remainingWrite -= plain.length;
      if (remainingWrite == 0) _reply({'ok': true});
      return;
    }
    final request = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    final op = request['op'] as String;
    expect(op, operation);
    requests.add(op);
    _reply({
      'ok': true,
      if (op == 'list')
        'entries': [
          {'rel_path': 'file', 'size': contents.length},
        ],
    });
    if (op == 'write') remainingWrite = request['length'] as int;
    if (op == 'read') {
      final offset = request['offset'] as int;
      final length = request['length'] as int;
      readLengths.add(length);
      for (var start = offset; start < offset + length; start += 64 * 1024) {
        final end = min(start + 64 * 1024, offset + length);
        _encrypted(contents.sublist(start, end));
      }
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _reader.cancel();
    await _output.close();
  }
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

  test('download receives a framed list reply and closes its RPC stream', () async {
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

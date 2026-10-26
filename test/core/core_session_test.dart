import 'dart:async';
import 'dart:convert';

import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xconn_core/xconn_core.dart' as core;

class _Peer implements core.Peer {
  final _input = StreamController<Object>();
  late final _iterator = StreamIterator(_input.stream);
  int closeCalls = 0;
  @override
  Future<Object> read() async {
    if (await _iterator.moveNext()) return _iterator.current;
    throw StateError('Remote channel closed');
  }

  @override
  Future<void> write(Object data) async {
    if (data is String && (jsonDecode(data) as List).first == 6) {
      _input.add(jsonEncode([6, {}, 'wamp.close.goodbye_and_out']));
    }
  }

  @override
  Future<void> close() async {
    closeCalls++;
    unawaited(_input.close());
    await _iterator.cancel();
  }

  Future<void> disconnect() => _input.close();
}

void main() {
  test('remote channel closure disconnects the Core-backed app session once', () async {
    final peer = _Peer();
    final native = core.Session(
      core.PeerBaseSession(peer, core.SessionDetails(1, 'realm', '', ''), core.JSONSerializer()),
    );
    final session = Session(native);
    final disconnected = Completer<void>();
    var notifications = 0;
    session.onDisconnect(() {
      notifications++;
      if (!disconnected.isCompleted) disconnected.complete();
    });
    await peer.disconnect();
    await disconnected.future.timeout(const Duration(seconds: 3));
    expect(session.isConnected(), isFalse);
    expect(notifications, 1);
    await session.close();
  });

  test('closing an owned session releases its connection exactly once', () async {
    final peer = _Peer();
    final native = core.Session(
      core.PeerBaseSession(peer, core.SessionDetails(1, 'realm', '', ''), core.JSONSerializer()),
    );
    var releases = 0;
    final session = Session(
      native,
      release: () async {
        releases++;
      },
    );
    await Future.wait([session.close(), session.close()]);
    expect(releases, 1);
    expect(session.isConnected(), isFalse);
  });
}

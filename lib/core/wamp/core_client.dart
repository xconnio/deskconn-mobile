/// DeskConn session ownership; protocol and networking are implemented by Core.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:xconn_core/quic.dart' as core;
import 'package:xconn_core/xconn_core.dart' as core;

export 'package:xconn_core/auth.dart';
export 'package:xconn_core/serializers.dart';
export 'package:xconn_core/xconn_core.dart' show ApplicationError, Result, Progress, Invocation, Event;

class Session {
  Session(this.native, {Future<void> Function()? release}) : _release = release;

  final core.Session native;
  final Future<void> Function()? _release;
  Future<void>? _closing;

  bool isConnected() => native.isConnected;

  int get id => native.id;

  void onDisconnect(void Function() callback) => native.onDisconnect(callback);

  Future<core.Result> call(
    String uri, {
    List<dynamic>? args,
    Map<String, dynamic>? kwargs,
    Map<String, dynamic>? options,
  }) => native.call(uri).args(args ?? []).kwargs(kwargs ?? {}).options(options ?? {}).execute();

  Future<core.Result> callProgressiveProgress(
    String uri,
    Future<core.Progress> Function() sender,
    Function(core.Result) receiver,
  ) => native.callProgressiveProgress(uri, sender, receiver);

  Future<void> close() => _closing ??= () async {
    try {
      await native.close();
    } finally {
      await _release?.call();
    }
  }();
}

typedef QUICDialerConfig = core.ClientConfig;

/// A dedicated connection owns its root session and every associated relay stream.
class QUICSession extends Session {
  QUICSession(super.native, this.connection) : super(release: connection.close);

  final core.QUICConnection connection;

  Future<Session> openSession(String realm, QUICDialerConfig config) async =>
      Session(await connection.openSession(realm, client: core.Client(config: config)));

  Future<RelayStream> openStream() async => RelayStream(await connection.openStream());
}

Future<QUICSession> connectQUIC(String address, String realm, QUICDialerConfig config) async {
  final host = Uri.parse('quic://$address').host;
  final connection = await core.QUICConnection.connect(address, serverName: host);
  try {
    final session = await connection
        .openSession(realm, client: core.Client(config: config))
        .timeout(const Duration(seconds: 15));
    return QUICSession(session, connection);
  } catch (_) {
    await connection.close();
    rethrow;
  }
}

class RelayStream {
  RelayStream(this._stream);

  final core.ByteStream _stream;

  Future<Uint8List> readExact(int size) async {
    final output = Uint8List(size);
    var offset = 0;
    while (offset < size) {
      final chunk = await _stream.read(size - offset);
      if (chunk.isEmpty) throw StateError('Relay stream ended');
      output.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return output;
  }

  Future<void> writeAll(Uint8List bytes) => _stream.writeAll(bytes);

  Future<void> close() => _stream.close();
}

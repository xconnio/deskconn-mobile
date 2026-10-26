/// App event delivery over Rust-owned WebRTC channels.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:xconn_core/webrtc.dart' as core;
import 'package:xconn_core/xconn_core.dart' as core;

import 'core_client.dart';

enum ChannelState { connecting, open, closing, closed }

class ChannelMessage {
  ChannelMessage(String value) : text = value, binary = Uint8List(0), isBinary = false;

  ChannelMessage.fromBinary(this.binary) : text = '', isBinary = true;

  final String text;
  final Uint8List binary;
  final bool isBinary;
}

class ChannelOptions {
  bool ordered = true;
  int? maxRetransmits;
  int? maxPacketLifeTime;
}

class AppDataChannel {
  AppDataChannel(this._channel) {
    // Receive drains packets queued before remote closure. A separate close
    // watcher could discard the final response while receive is still pending.
    unawaited(_read());
  }

  final core.DataChannel _channel;
  final _messages = StreamController<ChannelMessage>.broadcast();
  final _states = StreamController<ChannelState>.broadcast();
  ChannelState state = ChannelState.open;
  Object? failure;
  void Function(ChannelMessage)? onMessage;
  void Function(ChannelState)? onDataChannelState;
  int _queued = 0;
  int _transportBuffered = 0;
  Timer? _sample;
  Future<void>? _closing;

  String get label => _channel.label;

  int? get bufferedAmount => _queued + _transportBuffered;

  Stream<ChannelMessage> get messageStream => _messages.stream;

  Stream<ChannelState> get stateChangeStream => _states.stream;

  Future<void> send(ChannelMessage message) async {
    if (state != ChannelState.open) throw StateError('Data channel closed');
    final size = message.isBinary ? message.binary.length : message.text.length * 3;
    _queued += size;
    try {
      await _channel.send(message.isBinary ? message.binary : message.text);
      _transportBuffered = await _channel.bufferedAmount;
      if (_transportBuffered > 0) _startSampling();
    } finally {
      _queued -= size;
    }
  }

  void _startSampling() {
    _sample ??= Timer(const Duration(milliseconds: 20), () async {
      _sample = null;
      try {
        _transportBuffered = await _channel.bufferedAmount;
        if (state == ChannelState.open && _transportBuffered > 0) _startSampling();
      } catch (_) {
        // The reader drains queued packets before reporting transport closure.
      }
    });
  }

  Future<void> waitBufferedBelow(int threshold) async {
    await _channel.waitBufferedBelow(threshold);
    _transportBuffered = await _channel.bufferedAmount;
  }

  Future<void> _read() async {
    try {
      while (state == ChannelState.open) {
        final data = await _channel.receive();
        final message = data is String ? ChannelMessage(data) : ChannelMessage.fromBinary(data as Uint8List);
        if (state != ChannelState.open) break;
        _messages.add(message);
        onMessage?.call(message);
      }
    } catch (error) {
      failure = error;
      _markClosed();
    }
  }

  void _markClosed() {
    if (state == ChannelState.closed) return;
    state = ChannelState.closed;
    _sample?.cancel();
    _states.add(state);
    onDataChannelState?.call(state);
    unawaited(_messages.close());
    unawaited(_states.close());
  }

  Future<void> close() => _closing ??= () async {
    _markClosed();
    await _channel.close();
  }();
}

class ClientConfig {
  ClientConfig({
    required this.realm,
    required this.procedureWebRTCOffer,
    required this.topicAnswererOnCandidate,
    required this.topicOffererOnCandidate,
    required this.iceServers,
    required this.serializer,
    required this.session,
    required this.authenticator,
  });

  final String realm;
  final String procedureWebRTCOffer;
  final String topicAnswererOnCandidate;
  final String topicOffererOnCandidate;
  final List<Map<String, dynamic>> iceServers;
  final core.Serializer serializer;
  final Session session;
  final IClientAuthenticator authenticator;
}

class WebRTCSession {
  WebRTCSession(this.native, this.session);

  final core.WebRTCSession native;
  final Session session;
  final Map<String, Future<AppDataChannel>> _extra = {};

  core.WebRTCConnection get connection => native.connection;

  Future<AppDataChannel> extraChannel(String label) => _extra.putIfAbsent(label, () => openChannel(label));

  Future<AppDataChannel> openChannel(String label, [ChannelOptions? options]) async => AppDataChannel(
    await connection.openChannel(
      label,
      ordered: options?.ordered ?? label != 'vpn',
      maxRetransmits: options?.maxRetransmits ?? (label == 'vpn' ? 2 : null),
      maxPacketLifeTime: options?.maxPacketLifeTime,
    ),
  );
}

Future<WebRTCSession> connectWAMP(ClientConfig config) async {
  final peer = await core.WebRTCConnection.connect(
    config.session.native,
    config.realm,
    core.WebRTCOptions(
      offerProcedure: config.procedureWebRTCOffer,
      remoteCandidatesTopic: config.topicOffererOnCandidate,
      localCandidatesTopic: config.topicAnswererOnCandidate,
      iceServers: [
        for (final server in config.iceServers)
          {
            ...server,
            'urls': server['urls'] is String ? [server['urls']] : server['urls'],
          },
      ],
    ),
    client: core.Client(
      config: core.ClientConfig(authenticator: config.authenticator, serializer: config.serializer),
    ),
  );
  final session = Session(
    peer,
    release: () async {
      try {
        await peer.connection.close();
      } finally {
        await config.session.close();
      }
    },
  );
  return WebRTCSession(peer, session);
}

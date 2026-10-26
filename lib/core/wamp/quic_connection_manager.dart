import 'dart:async';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:flutter/foundation.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';

class QUICConnectionManager {
  static final _instance = QUICConnectionManager._();

  factory QUICConnectionManager() => _instance;

  QUICConnectionManager._() {
    ConnectivityService().onNetworkChanged.listen((_) => _handleNetworkChanged());
  }

  QUICSession? _root;
  Future<QUICSession>? _connecting;

  void _handleNetworkChanged() {
    final root = _root;
    if (root == null) return;
    _root = null;
    unawaited(root.close());
  }

  Future<Session> openSession(String realm, QUICDialerConfig config) async {
    final root = _root;
    if (root != null && root.isConnected()) {
      return _openRealmSession(root, realm, config);
    }

    final newRoot = await _connectRoot(realm, config);
    return _openRealmSession(newRoot, realm, config);
  }

  Future<Session> _openRealmSession(QUICSession root, String realm, QUICDialerConfig config) {
    return root
        .openSession(realm, config)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('WAMP session open did not complete', const Duration(seconds: 15)),
        );
  }

  // Coalesces concurrent callers into a single in-flight connect instead of
  // racing separate connectQUIC() calls, whose last-writer-wins assignment
  // to _root would silently orphan whichever session lost the race.
  Future<QUICSession> _connectRoot(String realm, QUICDialerConfig config) {
    return _connecting ??= () async {
      try {
        final newRoot = await _withRetry(
          () => connectQUIC(DeskconnConfig.quicAddr, realm, config).timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('QUIC root connect did not complete', const Duration(seconds: 15)),
          ),
        );
        _root = newRoot;
        newRoot.onDisconnect(() {
          if (_root == newRoot) {
            _root = null;
          }
        });
        ConnectivityService().reportBackendReachable();
        return newRoot;
      } catch (e) {
        ConnectivityService().reportBackendUnreachable();
        rethrow;
      } finally {
        _connecting = null;
      }
    }();
  }

  // The router only relays a raw stream to the realm its own connection
  // authenticated to, so a stream meant for a desktop can't ride the shared
  // root connection -- it needs one dialled straight into that realm. The
  // caller owns the returned session and closes it.
  Future<QUICSession> connectDedicated(String realm, QUICDialerConfig config) {
    return connectQUIC(DeskconnConfig.quicAddr, realm, config).timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('QUIC connect did not complete', const Duration(seconds: 15)),
    );
  }

  Future<void> close() async {
    final root = _root;
    _root = null;
    await root?.close();
  }
}

// A single transient hiccup (e.g. a brief handshake timeout during a cell
// tower handoff) previously required a manual user action (pull-to-refresh,
// leaving/reopening a screen) to recover. Retrying here, inside the
// deduped in-flight future, means concurrent callers share one retry
// sequence instead of each independently retrying against a struggling
// backend.
Future<T> _withRetry<T>(
  Future<T> Function() attempt, {
  int maxAttempts = 3,
  Duration delay = const Duration(milliseconds: 300),
}) async {
  for (var i = 0; i < maxAttempts; i++) {
    try {
      return await attempt();
    } catch (e, st) {
      debugPrint('QUIC connect attempt ${i + 1}/$maxAttempts failed: $e');
      if (i == maxAttempts - 1) {
        debugPrint('$st');
        rethrow;
      }
      await Future.delayed(delay);
    }
  }
  throw StateError('unreachable');
}

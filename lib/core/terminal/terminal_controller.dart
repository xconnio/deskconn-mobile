import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/core.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';

import 'shell_stream.dart';
import 'terminal_background_service.dart';

class TerminalController {
  TerminalController({required this.config, Terminal? terminal}) : terminal = terminal ?? Terminal();

  final Terminal terminal;
  final DesktopSessionLaunchConfig config;
  void Function()? onStarted;
  void Function()? onExit;
  void Function()? onClosed;
  void Function()? onModifierChanged;
  void Function(Object error)? onError;
  void Function()? onReconnecting;
  void Function()? onReconnected;
  bool ctrl = false;
  bool alt = false;
  bool _running = false;
  bool _disposed = false;
  bool _reconnecting = false;
  bool _exitFired = false;
  Timer? _resizeTimer;
  ShellHandle? _shellHandle;
  String _preview = '';
  static const _reconnectDelay = Duration(seconds: 2);

  bool get isActive => _running;

  bool get isReady => _shellHandle != null;

  String get preview => _preview;

  @visibleForTesting
  void writeOutput(String text) => _write(text);

  void _write(String text) {
    if (_disposed) return;
    try {
      terminal.write(text);
    } catch (e) {
      _log('terminal write failed error=$e');
    }
    final clean = text
        .replaceAll(RegExp(r'\x1B\][^\x07]*\x07'), '')
        .replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '')
        .replaceAll('\r', '');
    if (clean.isEmpty) return;
    _preview = _preview.length + clean.length > 800
        ? (_preview + clean).substring(_preview.length + clean.length - 800)
        : _preview + clean;
  }

  void _log(String message) => debugPrint('[Terminal ${config.realm}] $message');

  void _fireExit() {
    if (_exitFired) return;
    _exitFired = true;
    final callback = onExit;
    onExit = null;
    callback?.call();
  }

  Future<void> start() async {
    if (_running || _disposed) return;
    await _connectAndRun();
  }

  Future<void> _connectAndRun() async {
    _running = true;
    try {
      final connection =
          DesktopConnectionManager().get(config.realm) ??
          await DesktopConnectionManager().connect(
            realm: config.realm,
            authId: config.authId,
            privateKey: config.privateKey,
            webRtcEnabled: config.webRtcEnabled,
          );
      if (_disposed) return;
      final handle = await openShell(
        connection.session,
        terminal.viewWidth,
        terminal.viewHeight,
        (bytes) {
          if (!_disposed) _write(utf8.decode(bytes, allowMalformed: true));
        },
        () {
          _running = false;
          _shellHandle = null;
          _resizeTimer?.cancel();
          if (_disposed) return;
          if (connection.session.isConnected()) {
            onClosed?.call();
            _fireExit();
          } else {
            unawaited(_attemptReconnect());
          }
        },
        closeSession: false,
      );
      if (_disposed || !_running) {
        await handle.close();
        return;
      }
      _shellHandle = handle;
      terminal.onResize = (int width, int height, int pixelWidth, int pixelHeight) {
        _resizeTimer?.cancel();
        _resizeTimer = Timer(const Duration(milliseconds: 100), requestRedraw);
      };
      terminal.onOutput = (String data) {
        if (!_running || data.isEmpty) return;
        var output = data;
        if (ctrl) {
          output = _applyCtrl(output);
          ctrl = false;
          onModifierChanged?.call();
        }
        if (alt) {
          output = '\x1b$output';
          alt = false;
          onModifierChanged?.call();
        }
        sendSpecialKey(output);
      };
      handle.resize(terminal.viewWidth, terminal.viewHeight);
      onStarted?.call();
    } catch (error) {
      _running = false;
      if (!_disposed) onError?.call(error);
    }
  }

  Future<void> _attemptReconnect() async {
    if (_disposed || _reconnecting) return;
    _reconnecting = true;
    onReconnecting?.call();
    terminal.write('\r\n[Reconnecting…]\r\n');

    while (!_disposed) {
      if (!ConnectivityService().hasConnection) {
        await Future.delayed(_reconnectDelay);
        continue;
      }
      try {
        final connection = await DesktopConnectionManager().reacquire(
          realm: config.realm,
          authId: config.authId,
          privateKey: config.privateKey,
          webRtcEnabled: config.webRtcEnabled,
        );
        connection.isAgentOnline = true;
        break;
      } catch (e) {
        _log('reconnect failed error=$e');
        if (_disposed) {
          _reconnecting = false;
          return;
        }
        await Future.delayed(_reconnectDelay);
      }
    }

    _reconnecting = false;
    if (_disposed) return;
    onReconnected?.call();
    unawaited(_connectAndRun());
  }

  String _applyCtrl(String data) {
    return data.runes.map((code) {
      if (code >= 97 && code <= 122) return String.fromCharCode(code - 96);
      return String.fromCharCode(code);
    }).join();
  }

  void sendSpecialKey(String sequence) {
    if (_running) _shellHandle?.send(Uint8List.fromList(utf8.encode(sequence)));
  }

  void sendTab() => sendSpecialKey('\t');
  void sendEsc() => sendSpecialKey('\x1b');
  void sendCtrlC() => sendSpecialKey('\x03');
  void sendCtrlD() => sendSpecialKey('\x04');
  void sendArrowUp() => sendSpecialKey('\x1b[A');
  void sendArrowDown() => sendSpecialKey('\x1b[B');
  void sendArrowRight() => sendSpecialKey('\x1b[C');
  void sendArrowLeft() => sendSpecialKey('\x1b[D');
  void sendHome() => sendSpecialKey('\x1b[H');
  void sendEnd() => sendSpecialKey('\x1b[F');
  void sendDel() => sendSpecialKey('\x1b[3~');

  void clearScreen() {
    terminal.write('\x1b[2J\x1b[3J\x1b[H');
  }

  void requestRedraw() {
    if (_running) _shellHandle?.resize(terminal.viewWidth, terminal.viewHeight);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    _resizeTimer?.cancel();
    final handle = _shellHandle;
    _shellHandle = null;
    if (handle != null) unawaited(handle.close());
    _fireExit();
  }
}

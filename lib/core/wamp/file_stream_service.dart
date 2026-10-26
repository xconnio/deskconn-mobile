import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as web_rtc;

import 'package:deskconn_mobile_app/core/terminal/terminal_encryption.dart';

const int kFileStreamChannelPoolSize = 48;

List<String> fileStreamChannelLabels() => List.generate(kFileStreamChannelPoolSize, (i) => 'file-stream-$i');

class FileStreamPoolExhaustedException implements Exception {
  @override
  String toString() => 'file-stream channel pool exhausted for this connection';
}

class FileStreamRangeResult {
  FileStreamRangeResult({required this.offset, required this.length, required this.chunks});

  final int offset;
  final int length;
  final Stream<Uint8List> chunks;
}

const int _kindControl = 0;
const int _kindData = 1;
const int _parallelChunkSize = 4 * 1024 * 1024;
// A 4 MiB read plus its acknowledgement exceeds Core's 64-packet queue.
// Bound each worker's response burst while retaining parallel downloads.
const int _downloadChunkSize = 1024 * 1024;
const int _defaultParallelWorkers = 4;
const int _wireChunkSize = 65024;
const int _sendBufferHighWater = 512 * 1024;
const int _sendBufferLowWater = 256 * 1024;
const Duration _requestTimeout = Duration(seconds: 15);

class _Envelope {
  _Envelope(this.kind, this.data);

  final int kind;
  final Uint8List data;
}

class _FileStreamChannel {
  _FileStreamChannel._(this._channel, this._enc, this._events, this._controls);

  final AppDataChannel _channel;
  final Encryption _enc;
  final Stream<_Envelope> _events;
  final StreamIterator<_Envelope> _controls;

  static Future<_FileStreamChannel> open(web_rtc.WebRTCSession session, String label) async {
    final channel = await session.extraChannel(label);
    final enc = await Encryption.create();
    final peerKeyCompleter = Completer<Uint8List>();
    final eventsController = StreamController<_Envelope>.broadcast();
    // Control replies must survive gaps between requests and send completion.
    final controlsController = StreamController<_Envelope>();

    channel.onMessage = (ChannelMessage msg) {
      if (!peerKeyCompleter.isCompleted) {
        if (msg.isBinary) {
          peerKeyCompleter.completeError(Exception('expected plaintext key-exchange frame first'));
          return;
        }
        try {
          final peerKeyB64 = (jsonDecode(msg.text) as Map<String, dynamic>)['public_key'] as String;
          peerKeyCompleter.complete(base64Decode(peerKeyB64));
        } catch (e) {
          peerKeyCompleter.completeError(e);
        }
        return;
      }

      if (!msg.isBinary || msg.binary.isEmpty) return;
      final kind = msg.binary[0];
      try {
        final plaintext = enc.decrypt(msg.binary.sublist(1));
        final controller = kind == _kindControl ? controlsController : eventsController;
        if (!controller.isClosed) controller.add(_Envelope(kind, plaintext));
      } catch (e) {
        if (!eventsController.isClosed) eventsController.addError(e);
        if (!controlsController.isClosed) controlsController.addError(e);
      }
    };

    channel.onDataChannelState = (state) {
      if (state == ChannelState.closing || state == ChannelState.closed) {
        if (!peerKeyCompleter.isCompleted) {
          peerKeyCompleter.completeError(Exception('file-stream channel closed before key exchange'));
        }
        final failure = channel.failure;
        if (failure != null) {
          if (!eventsController.isClosed) eventsController.addError(failure);
          if (!controlsController.isClosed) controlsController.addError(failure);
        }
        if (!eventsController.isClosed) unawaited(eventsController.close());
        if (!controlsController.isClosed) unawaited(controlsController.close());
      }
    };

    await channel.send(ChannelMessage(jsonEncode({'public_key': base64Encode(enc.clientPublicKey)})));
    final peerKey = await peerKeyCompleter.future.timeout(_requestTimeout);
    await enc.acceptServerKey(Uint8List.fromList([...utf8.encode('KEY:'), ...peerKey]));

    return _FileStreamChannel._(channel, enc, eventsController.stream, StreamIterator(controlsController.stream));
  }

  Future<_Envelope> _nextControl() async {
    if (!await _controls.moveNext().timeout(_requestTimeout)) {
      throw StateError('file-stream channel closed before acknowledgement');
    }
    return _controls.current;
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> req) async {
    final payload = utf8.encode(jsonEncode(req));
    await _channel.send(ChannelMessage.fromBinary(Uint8List.fromList([_kindControl, ..._enc.encrypt(payload)])));

    final ack = await _nextControl();
    final decoded = jsonDecode(utf8.decode(ack.data)) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw Exception(decoded['error'] as String? ?? 'remote operation failed');
    }
    return decoded;
  }

  Stream<Uint8List> readAsStream(String path, String relPath, int offset, int length) {
    final controller = StreamController<Uint8List>();
    var received = 0;
    late StreamSubscription<_Envelope> sub;

    Future<void> run() async {
      sub = _events.where((e) => e.kind == _kindData).listen((e) {
        received += e.data.length;
        if (!controller.isClosed) controller.add(e.data);
        if (received >= length) {
          unawaited(sub.cancel());
          unawaited(controller.close());
          unawaited(close());
        }
      }, onError: controller.addError);

      try {
        await request({'op': 'read', 'path': path, 'rel_path': relPath, 'offset': offset, 'length': length});
        if (length == 0) {
          await sub.cancel();
          await controller.close();
          await close();
        }
      } catch (e) {
        await sub.cancel();
        if (!controller.isClosed) controller.addError(e);
        await controller.close();
        await close();
      }
    }

    unawaited(run());
    return controller.stream;
  }

  Future<void> readChunk(
    String path,
    String relPath,
    int offset,
    int length,
    void Function(int pieceOffset, Uint8List piece) onPiece,
  ) async {
    var received = 0;
    final doneCompleter = Completer<void>();
    final sub = _events
        .where((e) => e.kind == _kindData)
        .listen(
          (e) {
            onPiece(offset + received, e.data);
            received += e.data.length;
            if (received >= length && !doneCompleter.isCompleted) doneCompleter.complete();
          },
          onError: (Object e) {
            if (!doneCompleter.isCompleted) doneCompleter.completeError(e);
          },
        );

    try {
      await request({'op': 'read', 'path': path, 'rel_path': relPath, 'offset': offset, 'length': length});
      if (length > 0) {
        await doneCompleter.future.timeout(_requestTimeout);
      }
    } finally {
      await sub.cancel();
    }
  }

  Future<void> writeChunk(String path, String relPath, int offset, Uint8List data) async {
    await request({
      'op': 'write',
      'path': path,
      'rel_path': relPath,
      'offset': offset,
      'length': data.length,
      'source_is_dir': false,
      'target_is_dir_hint': false,
    });

    for (var i = 0; i < data.length; i += _wireChunkSize) {
      final piece = data.sublist(i, min(i + _wireChunkSize, data.length));
      await _waitForSendReady();
      await _channel.send(ChannelMessage.fromBinary(Uint8List.fromList([_kindData, ..._enc.encrypt(piece)])));
    }

    final finalAck = await _nextControl();
    final decoded = jsonDecode(utf8.decode(finalAck.data)) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw Exception(decoded['error'] as String? ?? 'remote write failed');
    }
  }

  Future<void> _waitForSendReady() async {
    if ((_channel.bufferedAmount ?? 0) <= _sendBufferHighWater) return;
    await _channel.waitBufferedBelow(_sendBufferLowWater).timeout(_requestTimeout);
  }

  Future<void> close() async {
    await _controls.cancel();
    try {
      await _channel.close();
    } catch (_) {}
  }
}

class FileStreamService {
  FileStreamService(this._session);

  final web_rtc.WebRTCSession _session;
  int _nextChannel = 0;

  String _claimLabel() {
    if (_nextChannel >= kFileStreamChannelPoolSize) {
      throw FileStreamPoolExhaustedException();
    }
    return 'file-stream-${_nextChannel++}';
  }

  Future<_FileStreamChannel> _openChannel({int attempts = 3}) async {
    Object? lastError;
    for (var i = 0; i < attempts; i++) {
      try {
        return await _FileStreamChannel.open(_session, _claimLabel());
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  Future<FileStreamRangeResult> openRange(String path, int offset, int length) async {
    final fsChannel = await _openChannel();
    final relPath = path.split('/').last;
    return FileStreamRangeResult(
      offset: offset,
      length: length,
      chunks: fsChannel.readAsStream(path, relPath, offset, length),
    );
  }

  Future<void> downloadFile(
    String path,
    RandomAccessFile destination, {
    int numWorkers = _defaultParallelWorkers,
    void Function(int received, int total)? onProgress,
  }) async {
    final listChannel = await _openChannel();
    final Map<String, dynamic> listResp;
    try {
      listResp = await listChannel.request({'op': 'list', 'path': path, 'recursive': false});
    } finally {
      await listChannel.close();
    }

    final entries = listResp['entries'] as List<dynamic>?;
    if (entries == null || entries.isEmpty) {
      throw Exception('$path: no such file or directory');
    }
    final entry = entries.first as Map<String, dynamic>;
    final relPath = entry['rel_path'] as String;
    final size = entry['size'] as int;

    if (size == 0) {
      onProgress?.call(0, 0);
      return;
    }

    final offsets = <int>[for (var off = 0; off < size; off += _downloadChunkSize) off];
    var nextIndex = 0;
    var totalReceived = 0;
    Object? workerError;

    Future<void> runWorker() async {
      final worker = await _openChannel();
      try {
        while (workerError == null) {
          if (nextIndex >= offsets.length) return;
          final offset = offsets[nextIndex++];
          final length = min(_downloadChunkSize, size - offset);
          await worker.readChunk(path, relPath, offset, length, (pieceOffset, piece) {
            destination.setPositionSync(pieceOffset);
            destination.writeFromSync(piece);
            totalReceived += piece.length;
            onProgress?.call(totalReceived, size);
          });
        }
      } finally {
        await worker.close();
      }
    }

    final workerCount = min(numWorkers, offsets.length);
    await Future.wait(List.generate(workerCount, (_) => runWorker().catchError((Object e) => workerError ??= e)));

    if (workerError != null) throw workerError!;
  }

  Future<void> uploadFile(
    String localPath,
    String remoteDir, {
    int numWorkers = _defaultParallelWorkers,
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = File(localPath);
    final size = await file.length();
    final fileName = localPath.split('/').last;
    final remotePath = remoteDir.isEmpty || remoteDir == '/' ? '/$fileName' : '$remoteDir/$fileName';

    final initChannel = await _FileStreamChannel.open(_session, _claimLabel());
    try {
      await initChannel.request({
        'op': 'init',
        'path': remotePath,
        'entries': [
          {'rel_path': fileName, 'size': size, 'mode': 420, 'is_dir': false},
        ],
        'source_is_dir': false,
        'target_is_dir_hint': false,
      });
    } finally {
      await initChannel.close();
    }

    if (size == 0) {
      onProgress?.call(0, 0);
      return;
    }

    final offsets = <int>[for (var off = 0; off < size; off += _parallelChunkSize) off];
    var nextIndex = 0;
    var totalSent = 0;
    Object? workerError;

    Future<void> runWorker() async {
      final worker = await _FileStreamChannel.open(_session, _claimLabel());
      final raf = await file.open();
      try {
        while (workerError == null) {
          if (nextIndex >= offsets.length) return;
          final offset = offsets[nextIndex++];
          final length = min(_parallelChunkSize, size - offset);
          await raf.setPosition(offset);
          final data = await raf.read(length);
          await worker.writeChunk(remotePath, fileName, offset, data);
          totalSent += data.length;
          onProgress?.call(totalSent, size);
        }
      } finally {
        await raf.close();
        await worker.close();
      }
    }

    final workerCount = min(numWorkers, offsets.length);
    await Future.wait(List.generate(workerCount, (_) => runWorker().catchError((Object e) => workerError ??= e)));

    if (workerError != null) throw workerError!;
  }
}

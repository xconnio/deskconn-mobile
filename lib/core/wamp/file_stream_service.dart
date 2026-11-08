import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'core_client.dart';
import 'rpc_stream.dart';

class FileStreamRangeResult {
  FileStreamRangeResult({required this.offset, required this.length, required this.chunks});

  final int offset;
  final int length;
  final Stream<Uint8List> chunks;
}

const int _parallelChunkSize = 4 * 1024 * 1024;
const int _downloadChunkSize = 1024 * 1024;
const int _defaultParallelWorkers = 4;
const int _wireChunkSize = 64 * 1024;
const Duration _requestTimeout = Duration(seconds: 15);

class _FileStreamChannel {
  _FileStreamChannel(this._stream);

  final RPCFeatureStream _stream;

  static Future<_FileStreamChannel> open(Session session, String operation) async => _FileStreamChannel(
    await RPCFeatureStream.open(
      session,
      'io.xconn.deskconn.file.stream.$operation',
      input: operation == 'init' || operation == 'write',
    ),
  );

  Future<Map<String, dynamic>> _response() async {
    final bytes = await _stream.readEncrypted().timeout(_requestTimeout);
    final response = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (response['ok'] != true) throw StateError(response['error'] as String? ?? 'Remote file operation failed');
    return response;
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    await _stream.writeEncrypted(utf8.encode(jsonEncode(request)));
    return _response();
  }

  Stream<Uint8List> readAsStream(String path, String relPath, int offset, int length) async* {
    try {
      await request({'op': 'read', 'path': path, 'rel_path': relPath, 'offset': offset, 'length': length});
      var remaining = length;
      while (remaining > 0) {
        final bytes = await _stream.readEncrypted().timeout(_requestTimeout);
        if (bytes.isEmpty || bytes.length > remaining) throw StateError('Invalid file stream chunk length');
        remaining -= bytes.length;
        yield bytes;
      }
    } finally {
      await close();
    }
  }

  Future<void> readChunk(
    String path,
    String relPath,
    int offset,
    int length,
    void Function(int offset, Uint8List bytes) onPiece,
  ) async {
    await request({'op': 'read', 'path': path, 'rel_path': relPath, 'offset': offset, 'length': length});
    var received = 0;
    while (received < length) {
      final bytes = await _stream.readEncrypted().timeout(_requestTimeout);
      if (bytes.isEmpty || bytes.length > length - received) throw StateError('Invalid file stream chunk length');
      onPiece(offset + received, bytes);
      received += bytes.length;
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
    for (var offset = 0; offset < data.length; offset += _wireChunkSize) {
      await _stream.writeEncrypted(data.sublist(offset, min(offset + _wireChunkSize, data.length)));
    }
    await _response();
  }

  Future<void> close() => _stream.close();
}

class FileStreamService {
  FileStreamService(this._session);

  final Session _session;

  Future<_FileStreamChannel> _openChannel(String operation) => _FileStreamChannel.open(_session, operation);

  Future<FileStreamRangeResult> openRange(String path, int offset, int length) async {
    final fsChannel = await _openChannel('read');
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
    final listChannel = await _openChannel('list');
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
      final worker = await _openChannel('read');
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

    final initChannel = await _openChannel('init');
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
      final worker = await _openChannel('write');
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

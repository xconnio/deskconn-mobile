import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:deskconn_mobile_app/core/wamp/core_webrtc.dart' as web_rtc;
import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_encryption.dart';
import 'package:deskconn_mobile_app/core/wamp/session_encryption.dart';
import 'package:deskconn_mobile_app/core/wamp/file_stream_service.dart';
import 'models.dart';

class FileExplorerController {
  final Session session;
  final String realm;
  final web_rtc.WebRTCSession? webRtcSession;
  Encryption? _encryption;
  FileStreamService? _fileStream;

  static final Map<String, Uint8List> _thumbnailCache = {};
  static final Map<String, Future<Uint8List>> _thumbnailFutures = {};
  static final Map<String, Uint8List> _readCache = {};
  static final Map<String, Future<Uint8List>> _readFutures = {};

  static int _activeDownloads = 0;
  static const int _maxConcurrentDownloads = 4;
  static final List<Completer<void>> _downloadWaiters = [];

  FileExplorerController(this.session, this.realm, {this.webRtcSession});

  FileStreamService? get _fs {
    final rtc = webRtcSession;
    if (rtc == null) return null;
    return _fileStream ??= FileStreamService(rtc);
  }

  bool get isKeyExchanged => _encryption != null;

  Future<void> ensureKeyExchanged() async {
    _encryption = await SessionEncryption.deskconnd(session).keys();
  }

  Future<FileBrowseResult> browse(String path, {String? cursor, int? limit}) async {
    await ensureKeyExchanged();
    final payload = <String, dynamic>{
      'path': path,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (limit != null && limit > 0) 'limit': limit,
    };
    final encryptedPayload = _encryption!.encrypt(utf8.encode(jsonEncode(payload)));
    final res = await session
        .call(DeskconnProcedures.deskconndFileBrowse, args: [encryptedPayload])
        .timeout(DeskconnConfig.callTimeout);
    if (res.args.isEmpty) throw Exception('Browse failed: empty response');
    final decrypted = _encryption!.decrypt(_coerceBytes(res.args[0]));
    return FileBrowseResult.fromJson(jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>);
  }

  /// media-app serves the index with its own keys, not deskconnd's.
  Future<FileBrowseResult> index(String category) async {
    final result = await SessionEncryption.media(session).call(
      DeskconnProcedures.deskconndIndexQuery,
      arg: {
        'categories': [category],
      },
    );
    return FileBrowseResult.fromJson(result as Map<String, dynamic>);
  }

  Future<Uint8List> read(String path) async {
    final cacheKey = '$realm:$path';
    if (_readCache.containsKey(cacheKey)) {
      return _readCache[cacheKey]!;
    }
    if (_readFutures.containsKey(cacheKey)) {
      return _readFutures[cacheKey]!;
    }

    final future = _runReadDownload(cacheKey, path);
    _readFutures[cacheKey] = future;
    return future;
  }

  Future<Uint8List> _runReadDownload(String cacheKey, String path) async {
    try {
      final data = await _download(path, false);
      _readCache[cacheKey] = data;
      return data;
    } finally {
      _readFutures.remove(cacheKey);
    }
  }

  Future<Uint8List> thumbnail(String path) async {
    final cacheKey = '$realm:$path';
    if (_thumbnailCache.containsKey(cacheKey)) {
      return _thumbnailCache[cacheKey]!;
    }
    if (_thumbnailFutures.containsKey(cacheKey)) {
      return _thumbnailFutures[cacheKey]!;
    }

    final future = _runThumbnailDownload(cacheKey, path);
    _thumbnailFutures[cacheKey] = future;
    return future;
  }

  Future<Uint8List> _runThumbnailDownload(String cacheKey, String path) async {
    try {
      final data = await _download(path, true);
      _thumbnailCache[cacheKey] = data;
      return data;
    } finally {
      _thumbnailFutures.remove(cacheKey);
    }
  }

  Future<Uint8List> _download(String path, bool isThumbnail) async {
    await _acquireSlot();
    try {
      return await _executeDownload(path, isThumbnail);
    } finally {
      _releaseSlot();
    }
  }

  Future<void> _acquireSlot() async {
    if (_activeDownloads < _maxConcurrentDownloads) {
      _activeDownloads++;
      return;
    }
    final waiter = Completer<void>();
    _downloadWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseSlot() {
    if (_downloadWaiters.isNotEmpty) {
      _downloadWaiters.removeAt(0).complete();
    } else {
      _activeDownloads--;
    }
  }

  Future<Uint8List> _executeDownload(String path, bool isThumbnail) async {
    final fs = _fs;
    if (fs == null) throw Exception('Download requires a direct connection');

    final tempFile = File('${(await getTemporaryDirectory()).path}/.rd_${DateTime.now().microsecondsSinceEpoch}');
    final raf = await tempFile.open(mode: FileMode.write);
    try {
      await fs.downloadFile(path, raf);
    } finally {
      await raf.close();
    }
    try {
      return await tempFile.readAsBytes();
    } finally {
      unawaited(tempFile.delete());
    }
  }

  Future<void> upload(String localFilePath, String remoteDir, {void Function(int sent, int total)? onProgress}) async {
    final fs = _fs;
    if (fs == null) throw Exception('Upload requires a direct connection');
    final file = File(localFilePath);
    if (!await file.exists()) throw Exception('File not found: $localFilePath');

    final fileName = localFilePath.split('/').last;
    final remoteFilePath = remoteDir.isEmpty || remoteDir == '/' ? '/$fileName' : '$remoteDir/$fileName';

    await fs.uploadFile(localFilePath, remoteDir, onProgress: onProgress);
    _invalidateCache(remoteFilePath);
  }

  Future<void> rename(String oldPath, String newPath) async {
    await _callEncrypted(DeskconnProcedures.deskconndFileRename, {'old_path': oldPath, 'new_path': newPath});
    _invalidateCache(oldPath);
    _invalidateCache(newPath);
  }

  Future<void> delete(String path) async {
    await _callEncrypted(DeskconnProcedures.deskconndFileDelete, {'path': path});
    _invalidateCache(path);
  }

  void invalidate(String path) => _invalidateCache(path);

  void _invalidateCache(String path) {
    final cacheKey = '$realm:$path';
    _readCache.remove(cacheKey);
    _thumbnailCache.remove(cacheKey);
  }

  Future<void> copy(String srcPath, String destPath) async =>
      _callEncrypted(DeskconnProcedures.deskconndFileCopy, {'src': srcPath, 'dst': destPath});

  Future<void> _callEncrypted(String procedure, Map<String, dynamic> payload) async {
    await ensureKeyExchanged();
    final encrypted = _encryption!.encrypt(utf8.encode(jsonEncode(payload)));
    await session.call(procedure, args: [encrypted]).timeout(DeskconnConfig.callTimeout);
  }

  Uint8List _coerceBytes(dynamic raw) {
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    if (raw is String) return Uint8List.fromList(base64.decode(raw));
    throw FormatException('Unsupported payload type: ${raw.runtimeType}');
  }
}

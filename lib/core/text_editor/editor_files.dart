import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:diff_match_patch/diff_match_patch.dart' as dmp;
import 'package:path_provider/path_provider.dart';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/file_explorer/file_explorer_controller.dart';
import 'package:deskconn_mobile_app/core/file_explorer/models.dart';
import 'package:deskconn_mobile_app/core/wamp/session_encryption.dart';

const int maxEditableBytes = 10 * 1024 * 1024;

enum GitFileStatus { untracked, added, modified, ignored }

class GitOriginal {
  final bool isRepo;
  final bool isNew;
  final bool untracked;
  final bool ignored;
  final String content;

  const GitOriginal({
    required this.isRepo,
    required this.isNew,
    required this.untracked,
    required this.ignored,
    required this.content,
  });

  static const none = GitOriginal(isRepo: false, isNew: false, untracked: false, ignored: false, content: '');

  bool get hasBaseline => isRepo && !ignored;

  String baselineFor(String current) => !hasBaseline ? current : (untracked || isNew ? '' : content);

  factory GitOriginal.fromJson(Map<String, dynamic> json) => GitOriginal(
    isRepo: json['is_repo'] == true,
    isNew: json['is_new'] == true,
    untracked: json['untracked'] == true,
    ignored: json['ignored'] == true,
    content: json['content'] as String? ?? '',
  );
}

class FileTooLargeException implements Exception {
  const FileTooLargeException();

  @override
  String toString() => 'File is too large to edit (max ${maxEditableBytes ~/ (1024 * 1024)} MB).';
}

bool isEditConflictError(Object error) => error.toString().toLowerCase().contains('could not be applied cleanly');

String buildEditPatch(String original, String edited) =>
    dmp.patchToText(dmp.patchMake(original, b: dmp.diff(original, edited, checklines: false)));

class EditorFiles {
  EditorFiles(this.explorer);

  final FileExplorerController explorer;

  SessionEncryption get _crypto => SessionEncryption.deskconnd(explorer.session);

  bool get canCreateFiles => explorer.webRtcSession != null;

  Future<FileBrowseResult> browse(String path) => explorer.browse(path);

  Future<String> read(String path, {void Function(int bytes)? onProgress}) async {
    for (var attempt = 0; ; attempt++) {
      final keys = await _crypto.keys();
      final builder = BytesBuilder(copy: false);
      var tooLarge = false;
      try {
        await explorer.session.callProgress(DeskconnProcedures.deskconndFileCat, (result) {
          if (tooLarge || result.args.isEmpty) return;
          builder.add(keys.decrypt(coerceBytes(result.args[0])));
          tooLarge = builder.length > maxEditableBytes;
          onProgress?.call(builder.length);
        }, args: [keys.encrypt(utf8.encode(jsonEncode(path)))]);
        if (tooLarge) throw const FileTooLargeException();
        return utf8.decode(builder.takeBytes(), allowMalformed: true);
      } catch (e) {
        if (attempt == 0 && isKeysRejectedError(e)) {
          _crypto.invalidate(keys);
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> save(String path, String original, String edited) => _crypto.call(
    DeskconnProcedures.deskconndFileEdit,
    arg: {'path': path, 'patch': buildEditPatch(original, edited)},
  );

  Future<void> create(String path, String content) async {
    final slash = path.lastIndexOf('/');
    final dir = slash > 0 ? path.substring(0, slash) : '/';
    final name = path.substring(slash + 1);
    final tempDir = await Directory(
      '${(await getTemporaryDirectory()).path}/editor_${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    final file = File('${tempDir.path}/$name');
    try {
      await file.writeAsString(content);
      await explorer.upload(file.path, dir);
    } finally {
      await tempDir.delete(recursive: true).catchError((Object _) => tempDir);
    }
  }

  Future<GitOriginal> gitOriginal(String path) async {
    try {
      final result = await _crypto.call(DeskconnProcedures.deskconndGitOriginal, arg: {'path': path});
      return GitOriginal.fromJson(Map<String, dynamic>.from(result as Map));
    } catch (_) {
      return GitOriginal.none;
    }
  }

  Future<Map<String, GitFileStatus>> gitStatus(String path) async {
    try {
      final result = Map<String, dynamic>.from(
        await _crypto.call(DeskconnProcedures.deskconndGitStatus, arg: {'path': path}) as Map,
      );
      return {
        for (final entry in (result['entries'] as List?) ?? const [])
          if (entry is Map && GitFileStatus.values.asNameMap()[entry['status']] != null)
            entry['path'] as String: GitFileStatus.values.asNameMap()[entry['status']]!,
      };
    } catch (_) {
      return const {};
    }
  }
}

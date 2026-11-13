import 'dart:async';

import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/file_explorer/models.dart';
import 'package:deskconn_mobile_app/core/text_editor/editor_files.dart';
import 'package:deskconn_mobile_app/theme/overlay.dart';
import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:deskconn_mobile_app/widgets/remote_path_picker.dart';

Color? gitStatusColor(GitFileStatus? status) => switch (status) {
  GitFileStatus.untracked || GitFileStatus.added => DeskconnGit.untracked,
  GitFileStatus.modified => DeskconnGit.modified,
  GitFileStatus.ignored => DeskconnGit.ignored,
  null => null,
};

const _skippedDirs = {'node_modules', 'build', 'dist', 'target', 'vendor', 'venv', '__pycache__'};
const _maxIndexedFiles = 5000;
const _maxResults = 100;

int? fuzzyScore(String query, String candidate) {
  final nameStart = candidate.lastIndexOf('/') + 1;
  var score = 0;
  var matched = 0;
  var last = -2;
  for (var i = 0; i < candidate.length && matched < query.length; i++) {
    if (candidate[i] != query[matched]) continue;
    score += i == last + 1 ? 5 : 1;
    if (i >= nameStart) score += i == nameStart ? 7 : 3;
    last = i;
    matched++;
  }
  return matched == query.length ? score : null;
}

class EditorFileTree extends StatefulWidget {
  final EditorFiles files;
  final String rootPath;
  final String? activePath;
  final ValueChanged<String> onOpenFile;

  const EditorFileTree({
    super.key,
    required this.files,
    required this.rootPath,
    required this.onOpenFile,
    this.activePath,
  });

  @override
  State<EditorFileTree> createState() => _EditorFileTreeState();
}

class _EditorFileTreeState extends State<EditorFileTree> {
  final Map<String, List<(String, FileEntry)>> _children = {};
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  Map<String, GitFileStatus> _status = const {};
  String? _error;
  final TextEditingController _query = TextEditingController();
  List<String>? _index;
  bool _indexing = false;
  bool _indexTruncated = false;
  int _indexGeneration = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(EditorFileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath) _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _children.clear();
      _expanded.clear();
      _error = null;
      _index = null;
      _indexing = false;
      _indexGeneration++;
    });
    if (_query.text.isNotEmpty) unawaited(_buildIndex());
    await Future.wait([_loadDir(widget.rootPath), _loadStatus()]);
  }

  Future<void> _loadStatus() async {
    final status = await widget.files.gitStatus(widget.rootPath);
    if (mounted) setState(() => _status = status);
  }

  Future<void> _loadDir(String path) async {
    setState(() => _loading.add(path));
    try {
      final browse = await widget.files.browse(path);
      final entries = [...browse.entries]..sort(compareEntries);
      if (!mounted) return;
      setState(() => _children[path] = [for (final e in entries) (entryPath(browse, e), e)]);
    } catch (e) {
      if (mounted && path == widget.rootPath) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading.remove(path));
    }
  }

  Future<void> _buildIndex() async {
    if (_index != null || _indexing) return;
    final generation = _indexGeneration;
    setState(() => _indexing = true);
    final files = <String>[];
    final pending = [widget.rootPath];
    var truncated = false;
    while (pending.isNotEmpty && !truncated) {
      final batch = [for (var i = 0; i < 4 && pending.isNotEmpty; i++) pending.removeLast()];
      final results = await Future.wait(
        batch.map((dir) => widget.files.browse(dir).then<FileBrowseResult?>((b) => b, onError: (_) => null)),
      );
      if (!mounted || generation != _indexGeneration) return;
      for (final browse in results.nonNulls) {
        for (final entry in browse.entries) {
          if (entry.name.startsWith('.')) continue;
          final path = entryPath(browse, entry);
          if (entry.isDir) {
            if (!_skippedDirs.contains(entry.name)) pending.add(path);
          } else if (files.length < _maxIndexedFiles) {
            files.add(path);
          } else {
            truncated = true;
          }
        }
      }
    }
    if (!mounted || generation != _indexGeneration) return;
    setState(() {
      _index = files;
      _indexing = false;
      _indexTruncated = truncated;
    });
  }

  String _relative(String path) {
    final root = widget.rootPath.endsWith('/') ? widget.rootPath : '${widget.rootPath}/';
    return path.startsWith(root) ? path.substring(root.length) : path;
  }

  List<String> _matches() {
    final query = _query.text.trim().toLowerCase().replaceAll(' ', '');
    final index = _index;
    if (query.isEmpty || index == null) return const [];
    final scored = <(String, int)>[];
    for (final path in index) {
      final score = fuzzyScore(query, _relative(path).toLowerCase());
      if (score != null) scored.add((path, score));
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : a.$1.length.compareTo(b.$1.length);
    });
    return [for (final (path, _) in scored.take(_maxResults)) path];
  }

  Widget _buildResults(ThemeData theme) {
    final matches = _matches();
    if (matches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _indexing ? 'Indexing files…' : 'No matching files',
          style: DeskconnText.body.copyWith(color: theme.hintColor),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: matches.length + (_indexTruncated ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == matches.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Only the first $_maxIndexedFiles files are searched.',
              style: DeskconnText.body.copyWith(color: theme.hintColor),
            ),
          );
        }
        final path = matches[index];
        final relative = _relative(path);
        final slash = relative.lastIndexOf('/');
        final color = gitStatusColor(_status[path]);
        return InkWell(
          onTap: () => widget.onOpenFile(path),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  relative.substring(slash + 1),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DeskconnText.body.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
                if (slash > 0)
                  Text(
                    relative.substring(0, slash),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DeskconnText.body.copyWith(color: theme.hintColor, fontSize: 12),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggle(String path) {
    if (_expanded.remove(path)) {
      setState(() {});
      return;
    }
    setState(() => _expanded.add(path));
    if (!_children.containsKey(path)) _loadDir(path);
  }

  List<(String, FileEntry, int)> _rows() {
    final rows = <(String, FileEntry, int)>[];
    void walk(String dir, int depth) {
      for (final (path, entry) in _children[dir] ?? const <(String, FileEntry)>[]) {
        rows.add((path, entry, depth));
        if (entry.isDir && _expanded.contains(path)) walk(path, depth + 1);
      }
    }

    walk(widget.rootPath, 0);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rootName = widget.rootPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? widget.rootPath;
    final rows = _rows();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  rootName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700,
                    color: gitStatusColor(_status[widget.rootPath]),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            controller: _query,
            autocorrect: false,
            enableSuggestions: false,
            onTap: () => unawaited(_buildIndex()),
            onChanged: (_) {
              unawaited(_buildIndex());
              setState(() {});
            },
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Go to file',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(_query.clear)),
              filled: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            ),
          ),
        ),
        if (_loading.contains(widget.rootPath) || (_indexing && _query.text.isNotEmpty))
          const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _query.text.trim().isNotEmpty
              ? _buildResults(theme)
              : _error != null
              ? Padding(padding: const EdgeInsets.all(16), child: Text(_error!))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final (path, entry, depth) = rows[index];
                    final color = gitStatusColor(_status[path]);
                    final active = path == widget.activePath;
                    final expanded = _expanded.contains(path);
                    return Material(
                      color: active ? theme.colorScheme.primary.withValues(alpha: 0.14) : Colors.transparent,
                      child: InkWell(
                        onTap: () => entry.isDir ? _toggle(path) : widget.onOpenFile(path),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(8.0 + depth * 14, 7, 12, 7),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 18,
                                child: entry.isDir
                                    ? _loading.contains(path)
                                          ? const SizedBox.square(
                                              dimension: 12,
                                              child: CircularProgressIndicator(strokeWidth: 1.5),
                                            )
                                          : Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 18)
                                    : null,
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                entry.isDir
                                    ? (expanded ? Icons.folder_open_outlined : Icons.folder_outlined)
                                    : Icons.insert_drive_file_outlined,
                                size: 18,
                                color: color ?? (entry.isDir ? theme.colorScheme.primary : theme.hintColor),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  entry.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DeskconnText.body.copyWith(
                                    color: color,
                                    fontWeight: active ? FontWeight.w600 : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

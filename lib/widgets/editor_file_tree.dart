import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/file_explorer/models.dart';
import 'package:deskconn_mobile_app/core/text_editor/editor_files.dart';
import 'package:deskconn_mobile_app/widgets/remote_path_picker.dart';

const kGitUntrackedColor = Color(0xFFF87171);
const kGitModifiedColor = Color(0xFF7FB4E0);
const kGitIgnoredColor = Color(0xFFF59E0B);

Color? gitStatusColor(GitFileStatus? status) => switch (status) {
  GitFileStatus.untracked || GitFileStatus.added => kGitUntrackedColor,
  GitFileStatus.modified => kGitModifiedColor,
  GitFileStatus.ignored => kGitIgnoredColor,
  null => null,
};

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
    });
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
        if (_loading.contains(widget.rootPath)) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _error != null
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
                                  style: TextStyle(
                                    fontSize: 14,
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

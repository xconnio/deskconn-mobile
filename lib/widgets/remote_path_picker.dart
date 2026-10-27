import 'package:flutter/material.dart';

import 'package:deskconn_mobile_app/core/file_explorer/models.dart';
import 'package:deskconn_mobile_app/core/text_editor/editor_files.dart';

enum RemotePickMode { openFile, openFolder, saveAs }

String joinRemotePath(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

String entryPath(FileBrowseResult browse, FileEntry entry) =>
    entry.path.isNotEmpty ? entry.path : joinRemotePath(browse.path, entry.name);

int compareEntries(FileEntry a, FileEntry b) {
  if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

class RemotePathPicker extends StatefulWidget {
  final EditorFiles files;
  final RemotePickMode mode;
  final String? initialPath;
  final String? initialName;

  const RemotePathPicker({super.key, required this.files, required this.mode, this.initialPath, this.initialName});

  static Future<String?> show(
    BuildContext context, {
    required EditorFiles files,
    required RemotePickMode mode,
    String? initialPath,
    String? initialName,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => RemotePathPicker(files: files, mode: mode, initialPath: initialPath, initialName: initialName),
      ),
    );
  }

  @override
  State<RemotePathPicker> createState() => _RemotePathPickerState();
}

class _RemotePathPickerState extends State<RemotePathPicker> {
  late final TextEditingController _name = TextEditingController(text: widget.initialName ?? '');
  FileBrowseResult? _browse;
  bool _loading = true;
  String? _error;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    _load(widget.initialPath ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final browse = await widget.files.browse(path);
      if (!mounted) return;
      setState(() {
        _browse = browse;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String? get _parent {
    final path = _browse?.path;
    if (path == null || path == '/') return null;
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }

  void _confirm() {
    final browse = _browse;
    if (browse == null) return;
    switch (widget.mode) {
      case RemotePickMode.openFolder:
        Navigator.pop(context, browse.path);
      case RemotePickMode.saveAs:
        final name = _name.text.trim();
        if (name.isEmpty || name.contains('/')) return;
        Navigator.pop(context, joinRemotePath(browse.path, name));
      case RemotePickMode.openFile:
        break;
    }
  }

  String get _title => switch (widget.mode) {
    RemotePickMode.openFile => 'Open file',
    RemotePickMode.openFolder => 'Open folder',
    RemotePickMode.saveAs => 'Save as',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final browse = _browse;
    final entries = [
      ...?browse?.entries.where(
        (e) => (_showHidden || !e.name.startsWith('.')) && (e.isDir || widget.mode != RemotePickMode.openFolder),
      ),
    ]..sort(compareEntries);

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: _showHidden ? 'Hide hidden files' : 'Show hidden files',
            icon: Icon(_showHidden ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
          IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.home_outlined),
            onPressed: () => _load(browse?.homePath ?? ''),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.arrow_upward),
              enabled: _parent != null && !_loading,
              title: Text(
                browse?.path ?? '…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              onTap: () => _load(_parent!),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          OutlinedButton(onPressed: () => _load(browse?.path ?? ''), child: const Text('Retry')),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        leading: Icon(
                          entry.isDir ? Icons.folder_outlined : Icons.description_outlined,
                          color: entry.isDir ? theme.colorScheme.primary : null,
                        ),
                        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          if (entry.isDir) {
                            _load(entryPath(browse!, entry));
                          } else if (widget.mode == RemotePickMode.openFile) {
                            Navigator.pop(context, entryPath(browse!, entry));
                          } else if (widget.mode == RemotePickMode.saveAs) {
                            setState(() => _name.text = entry.name);
                          }
                        },
                      );
                    },
                  ),
          ),
          if (widget.mode != RemotePickMode.openFile)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    if (widget.mode == RemotePickMode.saveAs) ...[
                      Expanded(
                        child: TextField(
                          controller: _name,
                          autofocus: widget.initialName == null,
                          decoration: const InputDecoration(labelText: 'File name', isDense: true),
                          onSubmitted: (_) => _confirm(),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ] else
                      const Spacer(),
                    FilledButton(
                      onPressed: browse == null || _loading ? null : _confirm,
                      child: Text(widget.mode == RemotePickMode.saveAs ? 'Save' : 'Open this folder'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/styles/monokai-sublime.dart';

import 'package:deskconn_mobile_app/core/file_explorer/file_explorer_controller.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/text_editor/editor_files.dart';
import 'package:deskconn_mobile_app/core/text_editor/editor_session_store.dart';
import 'package:deskconn_mobile_app/core/text_editor/line_diff.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/theme/editor_colors.dart';
import 'package:deskconn_mobile_app/theme/overlay.dart';
import 'package:deskconn_mobile_app/widgets/editor_file_tree.dart';
import 'package:deskconn_mobile_app/widgets/remote_path_picker.dart';

const _bg = DeskconnEditor.background;
const _bar = DeskconnEditor.bar;
const _border = DeskconnEditor.border;
const _text = DeskconnEditor.text;
const _muted = DeskconnEditor.muted;
const _accent = DeskconnEditor.accent;
const _dirty = DeskconnEditor.dirty;
const _added = DeskconnEditor.added;
const _removed = DeskconnEditor.removed;
const _maxHighlightSize = 256 * 1024;
const _reviewContext = 3;
const _closingPairs = {'(': ')', '[': ']', '{': '}', '"': '"', "'": "'"};

const _languageByName = {
  'dockerfile': 'dockerfile',
  'containerfile': 'dockerfile',
  'makefile': 'makefile',
  'gnumakefile': 'makefile',
  'cmakelists.txt': 'cmake',
  'gemfile': 'ruby',
  'rakefile': 'ruby',
  'vagrantfile': 'ruby',
  'jenkinsfile': 'groovy',
  '.bashrc': 'bash',
  '.bash_profile': 'bash',
  '.zshrc': 'bash',
  '.profile': 'bash',
  '.env': 'bash',
};

const _languageByExt = {
  'py': 'python',
  'pyi': 'python',
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'rs': 'rust',
  'rb': 'ruby',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'md': 'markdown',
  'mdx': 'markdown',
  'yml': 'yaml',
  'sh': 'bash',
  'zsh': 'bash',
  'fish': 'bash',
  'env': 'bash',
  'htm': 'xml',
  'html': 'xml',
  'vue': 'xml',
  'svelte': 'xml',
  'svg': 'xml',
  'h': 'cpp',
  'hpp': 'cpp',
  'cc': 'cpp',
  'cs': 'csharp',
  'sass': 'scss',
  'conf': 'ini',
  'cfg': 'ini',
  'toml': 'ini',
  'jl': 'julia',
};

String? _languageFor(String name) {
  final lower = name.toLowerCase();
  final byName = _languageByName[lower];
  if (byName != null) return byName;
  if (lower.startsWith('dockerfile') || lower.startsWith('containerfile')) return 'dockerfile';
  if (lower.startsWith('.env.')) return 'bash';
  final dot = lower.lastIndexOf('.');
  if (dot <= 0) return null;
  final ext = lower.substring(dot + 1);
  final lang = _languageByExt[ext] ?? ext;
  return builtinAllLanguages.containsKey(lang) ? lang : null;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _dirOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash > 0 ? path.substring(0, slash) : '/';
}

class _EditorDoc {
  _EditorDoc(this.path);

  String? path;
  final CodeLineEditingController controller = CodeLineEditingController();
  late final CodeFindController find = CodeFindController(controller);
  String original = '';
  GitOriginal git = GitOriginal.none;
  bool gitLoaded = false;
  bool loading = false;
  bool needsLoad = false;
  int loadedBytes = 0;
  String? loadError;
  bool saving = false;
  bool dirty = false;
  Map<int, LineChange> changes = const {};
  bool review = false;
  bool reviewWholeFile = false;
  final Set<int> expandedFolds = {};
  Timer? refreshTimer;

  String get name => path?.split('/').last ?? 'Untitled';

  bool get isBlank => path == null && !dirty;

  bool get showsChanges => gitLoaded && git.isRepo && !git.untracked && !git.ignored;

  void recompute() {
    final text = controller.text;
    dirty = text != original;
    changes = showsChanges ? computeLineDiff(git.isNew ? '' : git.content, text) : const {};
  }

  void dispose() {
    refreshTimer?.cancel();
    find.dispose();
    controller.dispose();
  }
}

class TextEditorScreen extends StatefulWidget {
  final DesktopSessionLaunchConfig? config;
  final FileExplorerController? controller;
  final String? path;
  final String? folder;
  final VoidCallback? onRequestClose;

  const TextEditorScreen({super.key, this.config, this.controller, this.path, this.folder, this.onRequestClose})
    : assert(config != null || controller != null);

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey();
  final List<_EditorDoc> _docs = [];
  int _active = 0;
  EditorFiles? _files;
  String? _connectError;
  String? _folder;
  bool _wordWrap = false;
  bool _autoClose = true;
  bool _keyboardOpen = false;

  _EditorDoc? get _doc => _docs.isEmpty ? null : _docs[_active.clamp(0, _docs.length - 1)];

  bool get _anyDirty => _docs.any((d) => d.dirty);

  @override
  void initState() {
    super.initState();
    _folder = widget.folder;
    WidgetsBinding.instance.addObserver(this);
    _connect();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final open = View.of(context).viewInsets.bottom > 0;
    if (open != _keyboardOpen) setState(() => _keyboardOpen = open);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final doc in _docs) {
      doc.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _connectError = null);
    try {
      var explorer = widget.controller;
      if (explorer == null) {
        final config = widget.config!;
        final connection =
            DesktopConnectionManager().get(config.realm) ??
            await DesktopConnectionManager().acquire(
              realm: config.realm,
              authId: config.authId,
              privateKey: config.privateKey,
              webRtcEnabled: config.webRtcEnabled,
            );
        explorer = connection.explorerController ??= FileExplorerController(
          connection.session,
          config.realm,
          webRtcSession: connection.webRtcSession,
        );
      }
      if (!mounted) return;
      setState(() => _files = EditorFiles(explorer!));
      if (_docs.isEmpty) {
        final path = widget.path;
        if (path != null) {
          _openPath(path);
        } else if (!await _restoreSession() && mounted && _docs.isEmpty) {
          _newFile();
        }
      }
    } catch (e) {
      if (mounted) setState(() => _connectError = e.toString());
    }
  }

  Future<bool> _restoreSession() async {
    final config = widget.config;
    if (config == null || widget.folder != null) return false;
    final saved = await EditorSessionStore.load(config.realm);
    if (!mounted || saved == null || _docs.isNotEmpty) return false;
    setState(() => _folder = saved.folder);
    if (saved.paths.isEmpty) return false;
    for (final path in saved.paths) {
      _addDoc(path).needsLoad = true;
    }
    _activate(saved.active.clamp(0, _docs.length - 1));
    return true;
  }

  void _saveSession() {
    final config = widget.config;
    if (config == null) return;
    final paths = [
      for (final doc in _docs)
        if (doc.path != null) doc.path!,
    ];
    final activePath = _doc?.path;
    final active = activePath == null ? 0 : paths.indexOf(activePath);
    unawaited(EditorSessionStore.save(config.realm, EditorSession(folder: _folder, paths: paths, active: active)));
  }

  void _activate(int index) {
    setState(() => _active = index);
    final doc = _doc;
    if (doc != null && doc.needsLoad) {
      doc.needsLoad = false;
      _load(doc);
    }
    _saveSession();
  }

  void _setFolder(String? folder) {
    setState(() => _folder = folder);
    _saveSession();
  }

  _EditorDoc _addDoc(String? path) {
    final current = _doc;
    if (current != null && current.isBlank && path != null) {
      setState(() => current.path = path);
      _saveSession();
      return current;
    }
    final doc = _EditorDoc(path);
    doc.controller.addListener(() => _scheduleRecompute(doc));
    setState(() {
      _docs.add(doc);
      _active = _docs.length - 1;
    });
    _saveSession();
    return doc;
  }

  void _scheduleRecompute(_EditorDoc doc) {
    if (doc.loading) return;
    doc.refreshTimer?.cancel();
    doc.refreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || !_docs.contains(doc)) return;
      final wasDirty = doc.dirty;
      final previous = doc.changes;
      doc.recompute();
      if (wasDirty != doc.dirty || previous.length != doc.changes.length || previous.isNotEmpty) setState(() {});
    });
  }

  void _newFile() => _addDoc(null);

  void _openPath(String path) {
    final existing = _docs.indexWhere((d) => d.path == path);
    if (existing != -1) {
      _activate(existing);
      return;
    }
    final doc = _addDoc(path);
    setState(() => _active = _docs.indexOf(doc));
    _load(doc);
  }

  Future<void> _load(_EditorDoc doc) async {
    final files = _files;
    final path = doc.path;
    if (files == null || path == null) return;
    setState(() {
      doc.loading = true;
      doc.loadError = null;
      doc.loadedBytes = 0;
      doc.gitLoaded = false;
      doc.review = false;
    });
    try {
      final text = await files.read(
        path,
        onProgress: (bytes) {
          if (mounted) setState(() => doc.loadedBytes = bytes);
        },
      );
      if (!mounted || !_docs.contains(doc)) return;
      doc.original = text;
      doc.controller.text = text;
      doc.controller.clearHistory();
      doc.recompute();
      setState(() => doc.loading = false);
      unawaited(_loadGit(doc));
    } catch (e) {
      if (mounted) {
        setState(() {
          doc.loading = false;
          doc.loadError = e.toString();
        });
      }
    }
  }

  Future<void> _loadGit(_EditorDoc doc) async {
    final files = _files;
    final path = doc.path;
    if (files == null || path == null) return;
    final git = await files.gitOriginal(path);
    if (!mounted || !_docs.contains(doc) || doc.path != path) return;
    setState(() {
      doc.git = git;
      doc.gitLoaded = true;
      doc.recompute();
    });
  }

  Future<void> _save(_EditorDoc doc) async {
    final files = _files;
    if (files == null || doc.saving || doc.loading) return;
    final path = doc.path;
    if (path == null) return _saveAs(doc);
    final text = doc.controller.text;
    if (text == doc.original) return;
    setState(() => doc.saving = true);
    try {
      await files.save(path, doc.original, text);
      doc.original = text;
      doc.recompute();
      _toast('Saved ${doc.name}');
    } catch (e) {
      if (isEditConflictError(e)) {
        _toast(
          '${doc.name} changed on the machine. Reload it to get the latest version.',
          action: ('Reload', () => _reload(doc)),
        );
      } else {
        _toast('Save failed: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => doc.saving = false);
    }
  }

  Future<void> _saveAs(_EditorDoc doc) async {
    final files = _files;
    if (files == null) return;
    if (!files.canCreateFiles) {
      _toast('Creating a file needs a connection to the machine.', error: true);
      return;
    }
    final path = await RemotePathPicker.show(
      context,
      files: files,
      mode: RemotePickMode.saveAs,
      initialPath: doc.path != null ? _dirOf(doc.path!) : _folder,
      initialName: doc.path == null ? null : doc.name,
    );
    if (path == null || !mounted) return;
    final text = doc.controller.text;
    setState(() => doc.saving = true);
    try {
      await files.create(path, text);
      doc.path = path;
      doc.original = text;
      doc.gitLoaded = false;
      doc.recompute();
      _saveSession();
      _toast('Saved ${doc.name}');
      unawaited(_loadGit(doc));
    } catch (e) {
      _toast('Save failed: $e', error: true);
    } finally {
      if (mounted) setState(() => doc.saving = false);
    }
  }

  Future<void> _reload(_EditorDoc doc) async {
    if (doc.path == null) return;
    if (doc.dirty && !await _confirm('Reload ${doc.name}?', 'Your unsaved changes will be lost.', 'Reload')) return;
    await _load(doc);
  }

  Future<void> _openFilePicker() async {
    final files = _files;
    if (files == null) return;
    final current = _doc?.path;
    final path = await RemotePathPicker.show(
      context,
      files: files,
      mode: RemotePickMode.openFile,
      initialPath: current != null ? _dirOf(current) : _folder,
    );
    if (path != null && mounted) _openPath(path);
  }

  Future<void> _openFolderPicker() async {
    final files = _files;
    if (files == null) return;
    final current = _doc?.path;
    final path = await RemotePathPicker.show(
      context,
      files: files,
      mode: RemotePickMode.openFolder,
      initialPath: _folder ?? (current != null ? _dirOf(current) : null),
    );
    if (path == null || !mounted) return;
    _setFolder(path);
    _scaffoldKey.currentState?.openDrawer();
  }

  Future<void> _closeDoc(_EditorDoc doc) async {
    if (doc.dirty && !await _confirm('Close ${doc.name}?', '${doc.name} has unsaved changes.', 'Close')) return;
    if (!mounted) return;
    setState(() {
      final index = _docs.indexOf(doc);
      _docs.removeAt(index);
      if (_active > index || _active >= _docs.length) _active = (_active - 1).clamp(0, _docs.length);
    });
    doc.dispose();
    _docs.isEmpty ? _saveSession() : _activate(_active);
  }

  Future<void> _closeEditor() async {
    if (_anyDirty) {
      final count = _docs.where((d) => d.dirty).length;
      final message = '$count file${count == 1 ? ' has' : 's have'} unsaved changes.';
      if (!await _confirm('Close the editor?', message, 'Close')) return;
    }
    if (!mounted) return;
    final close = widget.onRequestClose;
    close != null ? close() : Navigator.of(context).pop();
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    );
    return result ?? false;
  }

  void _toast(String message, {bool error = false, (String, VoidCallback)? action}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        duration: Duration(seconds: action != null ? 6 : 2),
        action: action == null ? null : SnackBarAction(label: action.$1, onPressed: action.$2),
      ),
    );
  }

  Future<void> _goToLine(_EditorDoc doc) async {
    final controller = doc.controller;
    final total = controller.codeLines.length;
    final current = controller.selection.extentIndex + 1;
    final line = await showDialog<int>(
      context: context,
      builder: (context) => _GoToLineDialog(total: total, current: current),
    );
    if (line == null || !mounted || !_docs.contains(doc)) return;
    if (doc.review) setState(() => doc.review = false);
    controller.selection = CodeLineSelection.collapsed(index: (line - 1).clamp(0, total - 1), offset: 0);
    controller.makeCursorCenterIfInvisible();
  }

  void _insert(String text) {
    final doc = _doc;
    if (doc == null || doc.review || doc.loading) return;
    final close = _autoClose ? _closingPairs[text] : null;
    if (close == null || !doc.controller.selection.isCollapsed) {
      doc.controller.replaceSelection(text);
      return;
    }
    doc.controller.replaceSelection('$text$close');
    doc.controller.moveCursor(AxisDirection.left);
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return PopScope(
      canPop: widget.onRequestClose != null || !_anyDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.onRequestClose == null) _closeEditor();
      },
      child: Theme(
        data: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: _bg,
          colorScheme: const ColorScheme.dark(primary: _accent, surface: _bar),
        ),
        child: Scaffold(
          key: _scaffoldKey,
          backgroundColor: _bg,
          drawer: _files == null ? null : _buildDrawer(),
          appBar: _buildAppBar(doc),
          body: Column(
            children: [
              if (_docs.length > 1) _buildTabStrip(),
              Expanded(child: _buildBody(doc)),
              if (_keyboardOpen && doc != null && !doc.review && !doc.loading)
                ValueListenableBuilder(
                  valueListenable: doc.find,
                  builder: (context, value, _) => value != null
                      ? const SizedBox.shrink()
                      : CodeEditorTapRegion(
                          child: _KeyBar(controller: doc.controller, onInsert: _insert),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(_EditorDoc? doc) {
    return AppBar(
      backgroundColor: _bar,
      foregroundColor: _text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      shape: const Border(bottom: BorderSide(color: _border, width: 0.5)),
      leading: IconButton(
        tooltip: 'Explorer',
        icon: const Icon(Icons.menu),
        onPressed: _files == null ? null : () => _scaffoldKey.currentState?.openDrawer(),
      ),
      title: doc == null
          ? const Text('Text Editor', style: TextStyle(fontSize: 16))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        doc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (doc.dirty) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(color: _dirty, shape: BoxShape.circle),
                      ),
                    ],
                  ],
                ),
                Text(
                  doc.path == null ? 'Not saved yet' : _dirOf(doc.path!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: _muted),
                ),
              ],
            ),
      actions: [
        if (doc != null && !doc.review && !doc.loading && doc.loadError == null)
          IconButton(tooltip: 'Find', icon: const Icon(Icons.search), onPressed: doc.find.findMode),
        if (doc != null && doc.path != null && !doc.loading && doc.loadError == null)
          IconButton(
            tooltip: doc.review ? 'Edit' : 'Review changes',
            isSelected: doc.review,
            icon: const Icon(Icons.difference_outlined),
            selectedIcon: const Icon(Icons.edit_outlined),
            onPressed: () => setState(() {
              doc.review = !doc.review;
              doc.expandedFolds.clear();
            }),
          ),
        if (doc != null)
          doc.saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  tooltip: 'Save',
                  icon: const Icon(Icons.save_outlined),
                  onPressed: doc.dirty ? () => _save(doc) : null,
                ),
        _buildMenu(doc),
      ],
    );
  }

  Widget _buildMenu(_EditorDoc? doc) {
    final ready = _files != null;
    final path = doc?.path;
    return PopupMenuButton<VoidCallback>(
      tooltip: 'More',
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        _menuItem(Icons.note_add_outlined, 'New file', ready ? _newFile : null),
        _menuItem(Icons.file_open_outlined, 'Open file…', ready ? _openFilePicker : null),
        _menuItem(Icons.folder_open_outlined, 'Open folder…', ready ? _openFolderPicker : null),
        if (_folder != null) _menuItem(Icons.folder_off_outlined, 'Close folder', () => _setFolder(null)),
        const PopupMenuDivider(),
        _menuItem(Icons.save_as_outlined, 'Save as…', doc != null && ready ? () => _saveAs(doc) : null),
        _menuItem(
          Icons.format_list_numbered,
          'Go to line…',
          doc != null && !doc.loading && doc.loadError == null ? () => _goToLine(doc) : null,
        ),
        _menuItem(Icons.refresh, 'Reload', doc != null && path != null ? () => _reload(doc) : null),
        CheckedPopupMenuItem<VoidCallback>(
          value: () => setState(() => _wordWrap = !_wordWrap),
          checked: _wordWrap,
          child: const Text('Word wrap'),
        ),
        CheckedPopupMenuItem<VoidCallback>(
          value: () => setState(() => _autoClose = !_autoClose),
          checked: _autoClose,
          child: const Text('Auto-close brackets'),
        ),
        const PopupMenuDivider(),
        _menuItem(Icons.tab_unselected, 'Close tab', doc != null ? () => _closeDoc(doc) : null),
        _menuItem(Icons.close, 'Close editor', _closeEditor),
      ],
    );
  }

  PopupMenuItem<VoidCallback> _menuItem(IconData icon, String label, VoidCallback? action) {
    return PopupMenuItem<VoidCallback>(
      value: action,
      enabled: action != null,
      child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]),
    );
  }

  Widget _buildDrawer() {
    final folder = _folder;
    return Drawer(
      backgroundColor: _bar,
      child: SafeArea(
        child: folder == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.folder_outlined, size: 40, color: _muted),
                      const SizedBox(height: 12),
                      const Text('No folder open', style: TextStyle(color: _muted)),
                      const SizedBox(height: 16),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.pop(context);
                          _openFolderPicker();
                        },
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('Open folder'),
                      ),
                    ],
                  ),
                ),
              )
            : EditorFileTree(
                files: _files!,
                rootPath: folder,
                activePath: _doc?.path,
                onOpenFile: (path) {
                  Navigator.pop(context);
                  _openPath(path);
                },
              ),
      ),
    );
  }

  Widget _buildTabStrip() {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: _bar,
        border: Border(bottom: BorderSide(color: _border, width: 0.5)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        itemCount: _docs.length,
        itemBuilder: (context, index) {
          final doc = _docs[index];
          final active = index == _active;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Material(
              color: active ? _bg : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: active ? _border : Colors.transparent),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _activate(index),
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 2),
                  child: Row(
                    children: [
                      Text(
                        doc.name,
                        style: TextStyle(
                          fontSize: 13,
                          color: active ? _text : _muted,
                          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 15,
                          tooltip: 'Close',
                          onPressed: () => _closeDoc(doc),
                          icon: doc.dirty
                              ? Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(color: _dirty, shape: BoxShape.circle),
                                )
                              : const Icon(Icons.close, color: _muted),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(_EditorDoc? doc) {
    if (_connectError != null) {
      return _Message(icon: Icons.cloud_off_outlined, message: _connectError!, action: ('Retry', _connect));
    }
    if (_files == null) return const Center(child: CircularProgressIndicator());
    if (doc == null) {
      return Center(
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _newFile,
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('New file'),
            ),
            OutlinedButton.icon(
              onPressed: _openFilePicker,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Open file'),
            ),
            OutlinedButton.icon(
              onPressed: _openFolderPicker,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Open folder'),
            ),
          ],
        ),
      );
    }
    if (doc.loading) {
      return Column(
        children: [
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 24),
          Text('Loading ${doc.name}… ${_formatBytes(doc.loadedBytes)}', style: const TextStyle(color: _muted)),
        ],
      );
    }
    if (doc.loadError != null) {
      return _Message(icon: Icons.error_outline, message: doc.loadError!, action: ('Retry', () => _load(doc)));
    }
    if (doc.review) return _ReviewView(key: ObjectKey(doc), doc: doc, onChanged: () => setState(() {}));
    return _EditorView(key: ObjectKey(doc), doc: doc, wordWrap: _wordWrap, autoClose: _autoClose);
  }
}

class _EditorView extends StatelessWidget {
  final _EditorDoc doc;
  final bool wordWrap;
  final bool autoClose;

  const _EditorView({super.key, required this.doc, required this.wordWrap, required this.autoClose});

  @override
  Widget build(BuildContext context) {
    final lang = _languageFor(doc.name);
    final mode = lang == null ? null : builtinAllLanguages[lang];
    return CodeEditor(
      controller: doc.controller,
      findController: doc.find,
      findBuilder: (context, controller, readOnly) => _FindBar(controller: controller),
      wordWrap: wordWrap,
      autocompleteSymbols: autoClose,
      style: CodeEditorStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        fontHeight: 1.4,
        textColor: _text,
        backgroundColor: _bg,
        cursorColor: _accent,
        selectionColor: _accent.withValues(alpha: 0.3),
        highlightColor: _dirty.withValues(alpha: 0.35),
        cursorLineColor: DeskconnEditor.cursorLine,
        codeTheme: mode == null
            ? null
            : CodeHighlightTheme(
                languages: {lang!: CodeHighlightThemeMode(mode: mode, maxSize: _maxHighlightSize)},
                theme: monokaiSublimeTheme,
              ),
      ),
      padding: const EdgeInsets.fromLTRB(6, 8, 12, 80),
      toolbarController: _toolbarFor(_commentStyleFor(lang)),
      indicatorBuilder: (context, editingController, chunkController, notifier) => Row(
        children: [
          _ChangeBars(notifier: notifier, changes: doc.changes),
          DefaultCodeLineNumber(
            controller: editingController,
            notifier: notifier,
            textStyle: const TextStyle(color: DeskconnEditor.lineNumber, fontSize: 12, fontFamily: 'monospace'),
            focusedTextStyle: const TextStyle(color: _muted, fontSize: 12, fontFamily: 'monospace'),
          ),
        ],
      ),
      leadingDivider: Container(width: 0.5, color: _border),
    );
  }
}

const _hashCommentLanguages = {
  'python',
  'bash',
  'yaml',
  'ruby',
  'dockerfile',
  'makefile',
  'cmake',
  'perl',
  'r',
  'ini',
  'powershell',
  'nginx',
  'elixir',
  'julia',
  'properties',
};
const _dashCommentLanguages = {'sql', 'lua', 'haskell', 'elm'};
const _markupCommentLanguages = {'xml', 'markdown'};

(CodeCommentFormatter, bool)? _commentStyleFor(String? lang) {
  if (lang == null) return null;
  if (_hashCommentLanguages.contains(lang)) return (DefaultCodeCommentFormatter(singleLinePrefix: '#'), true);
  if (_dashCommentLanguages.contains(lang)) return (DefaultCodeCommentFormatter(singleLinePrefix: '--'), true);
  if (_markupCommentLanguages.contains(lang)) {
    return (DefaultCodeCommentFormatter(multiLinePrefix: '<!--', multiLineSuffix: '-->'), false);
  }
  if (lang == 'css') return (DefaultCodeCommentFormatter(multiLinePrefix: '/*', multiLineSuffix: '*/'), false);
  return (DefaultCodeCommentFormatter(singleLinePrefix: '//'), true);
}

void _duplicateLines(CodeLineEditingController controller) {
  final selection = controller.selection;
  final start = selection.startIndex;
  final end = selection.endIndex;
  final lines = [for (var i = start; i <= end; i++) controller.codeLines[i].text];
  final endOffset = controller.codeLines[end].text.length;
  controller.replaceSelection('\n${lines.join('\n')}', CodeLineSelection.collapsed(index: end, offset: endOffset));
}

void _toggleComment(CodeLineEditingController controller, CodeCommentFormatter formatter, bool single) {
  final value = formatter.format(controller.value, controller.options.indent, single);
  controller.runRevocableOp(() => controller.value = value);
}

MobileSelectionToolbarController _toolbarFor((CodeCommentFormatter, bool)? comment) => MobileSelectionToolbarController(
  builder: ({required context, required anchors, required controller, required onDismiss, required onRefresh}) {
    void run(VoidCallback action) {
      action();
      onDismiss();
    }

    void keep(VoidCallback action) {
      action();
      onRefresh();
    }

    ContextMenuButtonItem item(String label, VoidCallback onPressed) =>
        ContextMenuButtonItem(label: label, onPressed: onPressed);

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: [
        if (!controller.selection.isCollapsed) ...[
          ContextMenuButtonItem(type: ContextMenuButtonType.cut, onPressed: () => run(controller.cut)),
          ContextMenuButtonItem(type: ContextMenuButtonType.copy, onPressed: () => run(controller.copy)),
        ],
        ContextMenuButtonItem(type: ContextMenuButtonType.paste, onPressed: () => run(controller.paste)),
        ContextMenuButtonItem(type: ContextMenuButtonType.selectAll, onPressed: () => keep(controller.selectAll)),
        item('Duplicate', () => run(() => _duplicateLines(controller))),
        item('Delete line', () => run(controller.deleteSelectionLines)),
        item('Move up', () => keep(controller.moveSelectionLinesUp)),
        item('Move down', () => keep(controller.moveSelectionLinesDown)),
        if (comment != null) item('Comment', () => run(() => _toggleComment(controller, comment.$1, comment.$2))),
        item('Indent', () => keep(controller.applyIndent)),
        item('Outdent', () => keep(controller.applyOutdent)),
      ],
    );
  },
);

class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;

  const _FindBar({required this.controller});

  static const _rowHeight = 44.0;
  static const _chipsHeight = 40.0;

  @override
  Size get preferredSize {
    final value = controller.value;
    if (value == null) return Size.zero;
    return Size.fromHeight(_rowHeight + _chipsHeight + (value.replaceMode ? _rowHeight : 0) + 1);
  }

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final result = value.result;
    final count = result == null || result.matches.isEmpty
        ? (controller.findInputController.text.isEmpty ? '' : 'No results')
        : '${result.index + 1}/${result.matches.length}';
    final hasMatches = result != null && result.matches.isNotEmpty;

    Widget iconButton(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      icon: Icon(icon),
      onPressed: onPressed,
    );

    Widget field(TextEditingController input, FocusNode focusNode, String hint) => Expanded(
      child: TextField(
        controller: input,
        focusNode: focusNode,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontSize: 14, fontFamily: 'monospace', color: _text),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(color: _muted),
          filled: true,
          fillColor: _bg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        ),
      ),
    );

    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => onTap(),
      ),
    );

    return CodeEditorTapRegion(
      child: Container(
        decoration: const BoxDecoration(
          color: _bar,
          border: Border(bottom: BorderSide(color: _border, width: 0.5)),
        ),
        padding: const EdgeInsets.only(left: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _rowHeight,
              child: Row(
                children: [
                  field(controller.findInputController, controller.findInputFocusNode, 'Find'),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(count, style: const TextStyle(color: _muted, fontSize: 12)),
                  ),
                  iconButton(Icons.keyboard_arrow_up, 'Previous', hasMatches ? controller.previousMatch : null),
                  iconButton(Icons.keyboard_arrow_down, 'Next', hasMatches ? controller.nextMatch : null),
                  iconButton(Icons.close, 'Close', controller.close),
                ],
              ),
            ),
            SizedBox(
              height: _chipsHeight,
              child: Row(
                children: [
                  chip('Match case', value.option.caseSensitive, controller.toggleCaseSensitive),
                  chip('Regex', value.option.regex, controller.toggleRegex),
                  chip('Replace', value.replaceMode, controller.toggleMode),
                ],
              ),
            ),
            if (value.replaceMode)
              SizedBox(
                height: _rowHeight,
                child: Row(
                  children: [
                    field(controller.replaceInputController, controller.replaceInputFocusNode, 'Replace'),
                    TextButton(onPressed: hasMatches ? controller.replaceMatch : null, child: const Text('Replace')),
                    TextButton(onPressed: hasMatches ? controller.replaceAllMatches : null, child: const Text('All')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChangeBars extends StatelessWidget {
  final CodeIndicatorValueNotifier notifier;
  final Map<int, LineChange> changes;

  const _ChangeBars({required this.notifier, required this.changes});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CodeIndicatorValue?>(
      valueListenable: notifier,
      builder: (context, value, _) => CustomPaint(
        size: const Size(4, double.infinity),
        painter: _ChangeBarsPainter(value?.paragraphs ?? const [], changes),
      ),
    );
  }
}

class _ChangeBarsPainter extends CustomPainter {
  final List<CodeLineRenderParagraph> paragraphs;
  final Map<int, LineChange> changes;

  _ChangeBarsPainter(this.paragraphs, this.changes);

  @override
  void paint(Canvas canvas, Size size) {
    if (changes.isEmpty) return;
    final added = Paint()..color = _added;
    final modified = Paint()..color = DeskconnGit.modified;
    for (final paragraph in paragraphs) {
      final change = changes[paragraph.index];
      if (change == null) continue;
      canvas.drawRect(
        Rect.fromLTWH(1, paragraph.top, 3, paragraph.height),
        change == LineChange.added ? added : modified,
      );
    }
  }

  @override
  bool shouldRepaint(_ChangeBarsPainter old) => old.paragraphs != paragraphs || old.changes != changes;
}

class _ReviewView extends StatelessWidget {
  final _EditorDoc doc;
  final VoidCallback onChanged;

  const _ReviewView({super.key, required this.doc, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final text = doc.controller.text;
    String? note;
    var lines = const <ReviewLine>[];
    if (!doc.gitLoaded) {
      note = 'Loading the last committed version…';
    } else if (!doc.git.hasBaseline) {
      note = 'Not tracked by git';
    } else {
      final computed = computeReviewLines(doc.git.baselineFor(text), text);
      if (computed == null) {
        note = 'Too large to compare';
      } else {
        lines = computed;
        if (lines.every((l) => l.kind == ReviewKind.context)) note = 'No changes since the last commit';
      }
    }
    final added = lines.where((l) => l.kind == ReviewKind.added).length;
    final removed = lines.where((l) => l.kind == ReviewKind.removed).length;
    final rows = note != null
        ? const <Object>[]
        : doc.reviewWholeFile
        ? lines
        : foldReviewLines(lines, _reviewContext, doc.expandedFolds);

    return Column(
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: _bar,
            border: Border(bottom: BorderSide(color: _border, width: 0.5)),
          ),
          child: Row(
            children: [
              if (note != null)
                Expanded(
                  child: Text(note, style: const TextStyle(color: _muted, fontSize: 13)),
                )
              else ...[
                Text(
                  '+$added',
                  style: const TextStyle(color: _added, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 10),
                Text(
                  '−$removed',
                  style: const TextStyle(color: _removed, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    doc.reviewWholeFile = !doc.reviewWholeFile;
                    onChanged();
                  },
                  child: Text(doc.reviewWholeFile ? 'Changes only' : 'Whole file'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 40),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              if (row is ReviewFold) {
                return InkWell(
                  onTap: () {
                    doc.expandedFolds.add(row.from);
                    onChanged();
                  },
                  child: Container(
                    color: _accent.withValues(alpha: 0.06),
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                    child: Text(
                      '⋯  ${row.count} unchanged line${row.count == 1 ? '' : 's'}',
                      style: const TextStyle(color: _accent, fontSize: 12),
                    ),
                  ),
                );
              }
              return _ReviewRow(line: row as ReviewLine);
            },
          ),
        ),
      ],
    );
  }
}

class _ReviewRow extends StatelessWidget {
  final ReviewLine line;

  const _ReviewRow({required this.line});

  @override
  Widget build(BuildContext context) {
    final (background, sign, signColor) = switch (line.kind) {
      ReviewKind.added => (_added.withValues(alpha: 0.14), '+', _added),
      ReviewKind.removed => (_removed.withValues(alpha: 0.14), '−', _removed),
      ReviewKind.context => (Colors.transparent, ' ', _muted),
    };
    const numberStyle = TextStyle(color: DeskconnEditor.lineNumber, fontSize: 11, fontFamily: 'monospace', height: 1.5);
    return Container(
      color: background,
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Text('${line.oldNo ?? ''}', textAlign: TextAlign.right, style: numberStyle),
          ),
          SizedBox(
            width: 36,
            child: Text('${line.newNo ?? ''}', textAlign: TextAlign.right, style: numberStyle),
          ),
          SizedBox(
            width: 20,
            child: Text(
              sign,
              textAlign: TextAlign.center,
              style: TextStyle(color: signColor, fontFamily: 'monospace', fontSize: 12.5, height: 1.4),
            ),
          ),
          Expanded(
            child: Text(
              line.text.replaceAll('\t', '    '),
              style: const TextStyle(color: _text, fontFamily: 'monospace', fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyBar extends StatelessWidget {
  final CodeLineEditingController controller;
  final ValueChanged<String> onInsert;

  const _KeyBar({required this.controller, required this.onInsert});

  static const _arrows = [
    (Icons.keyboard_arrow_left, AxisDirection.left),
    (Icons.keyboard_arrow_up, AxisDirection.up),
    (Icons.keyboard_arrow_down, AxisDirection.down),
    (Icons.keyboard_arrow_right, AxisDirection.right),
  ];

  static const _symbols = [
    '{',
    '}',
    '(',
    ')',
    '[',
    ']',
    '<',
    '>',
    '=',
    ';',
    ':',
    '"',
    "'",
    '/',
    r'\',
    '|',
    '&',
    '-',
    '_',
    '#',
    r'$',
  ];

  @override
  Widget build(BuildContext context) {
    Widget key(Widget child, VoidCallback? onTap, {double width = 40}) => SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        child: Center(child: child),
      ),
    );

    return Container(
      height: 42,
      decoration: const BoxDecoration(
        color: _bar,
        border: Border(top: BorderSide(color: _border, width: 0.5)),
      ),
      child: ValueListenableBuilder(
        valueListenable: controller,
        builder: (context, _, _) => ListView(
          scrollDirection: Axis.horizontal,
          children: [
            key(const Icon(Icons.keyboard_tab, size: 20, color: _text), () => onInsert('\t'), width: 48),
            key(
              Icon(Icons.undo, size: 20, color: controller.canUndo ? _text : _border),
              controller.canUndo ? controller.undo : null,
            ),
            key(
              Icon(Icons.redo, size: 20, color: controller.canRedo ? _text : _border),
              controller.canRedo ? controller.redo : null,
            ),
            Container(width: 0.5, margin: const EdgeInsets.symmetric(vertical: 10), color: _border),
            for (final (icon, direction) in _arrows)
              key(Icon(icon, size: 20, color: _text), () {
                controller.moveCursor(direction);
                controller.makeCursorVisible();
              }),
            Container(width: 0.5, margin: const EdgeInsets.symmetric(vertical: 10), color: _border),
            for (final symbol in _symbols)
              key(
                Text(
                  symbol,
                  style: const TextStyle(color: _text, fontFamily: 'monospace', fontSize: 16),
                ),
                () => onInsert(symbol),
                width: 36,
              ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String message;
  final (String, VoidCallback) action;

  const _Message({required this.icon, required this.message, required this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: _muted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: action.$2, child: Text(action.$1)),
          ],
        ),
      ),
    );
  }
}

class _GoToLineDialog extends StatefulWidget {
  final int total;
  final int current;

  const _GoToLineDialog({required this.total, required this.current});

  @override
  State<_GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<_GoToLineDialog> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final line = int.tryParse(_input.text.trim());
    if (line != null) Navigator.pop(context, line);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Go to line'),
      content: TextField(
        controller: _input,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(hintText: '1 – ${widget.total}', helperText: 'Currently on line ${widget.current}'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('Go')),
      ],
    );
  }
}

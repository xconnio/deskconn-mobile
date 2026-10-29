import 'dart:async';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/device/device_identity.dart';
import 'package:deskconn_mobile_app/core/file_explorer/file_explorer_controller.dart';
import 'package:deskconn_mobile_app/core/file_explorer/models.dart';
import 'package:deskconn_mobile_app/core/file_explorer/utils.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/share/share_service.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ShareUploadScreen extends StatefulWidget {
  final List<SharedUploadFile> files;

  const ShareUploadScreen({super.key, required this.files});

  @override
  State<ShareUploadScreen> createState() => _ShareUploadScreenState();
}

class _ShareUploadScreenState extends State<ShareUploadScreen> {
  Map<String, dynamic>? _desktop;
  FileExplorerController? _controller;
  FileBrowseResult? _browse;
  String? _error;
  bool _connecting = false;
  bool _loadingPath = false;
  bool _uploading = false;
  int _uploadIndex = 0;
  double _fileProgress = 0;
  bool _showHiddenDirs = false;

  bool get _selectingDesktop => _desktop == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = context.read<SessionProvider>();
      if (!session.desktopsLoading && session.desktops.isEmpty) {
        unawaited(session.loadDesktops());
      }
    });
  }

  Future<void> _selectDesktop(Map<String, dynamic> desktop) async {
    final realm = desktop['realm']?.toString();
    if (realm == null || realm.isEmpty) return;

    setState(() {
      _desktop = desktop;
      _connecting = true;
      _error = null;
      _controller = null;
      _browse = null;
    });

    try {
      final connection = await _connectTo(realm);
      final controller = FileExplorerController(connection.session, realm, webRtcSession: connection.webRtcSession);
      final browse = await controller.browse('');
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _browse = browse;
        _connecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = 'Could not open desktop: $e';
      });
    }
  }

  Future<DesktopConnection> _connectTo(String realm) async {
    if (!ConnectivityService().hasConnection) {
      throw Exception('No internet connection');
    }
    final authId = await DeviceIdentity.desktopAuthId();
    final privateKey = await DeviceIdentity.desktopPrivateKey();
    if (authId == null || privateKey == null) {
      throw Exception('Missing credentials');
    }
    final prefs = await SharedPreferences.getInstance();
    final webRtcEnabled = prefs.getBool(prefKeyWebRtcEnabled) ?? defaultWebRtcEnabled;
    final existing = DesktopConnectionManager().get(realm);
    return existing ??
        await DesktopConnectionManager().acquire(
          realm: realm,
          authId: authId,
          privateKey: privateKey,
          webRtcEnabled: webRtcEnabled,
        );
  }

  Future<void> _reconnectTo(String realm) async {
    if (!ConnectivityService().hasConnection) {
      throw Exception('No internet connection');
    }
    final authId = await DeviceIdentity.desktopAuthId();
    final privateKey = await DeviceIdentity.desktopPrivateKey();
    if (authId == null || privateKey == null) {
      throw Exception('Missing credentials');
    }
    final prefs = await SharedPreferences.getInstance();
    final webRtcEnabled = prefs.getBool(prefKeyWebRtcEnabled) ?? defaultWebRtcEnabled;
    final connection = await DesktopConnectionManager().reacquire(
      realm: realm,
      authId: authId,
      privateKey: privateKey,
      webRtcEnabled: webRtcEnabled,
    );
    _controller = FileExplorerController(connection.session, realm, webRtcSession: connection.webRtcSession);
  }

  // Mirrors the reconnect-on-drop pattern used elsewhere (FileExplorerScreen,
  // ResourceMonitorScreen) — without it, a dead cached session fails every
  // browse forever until the user backs all the way out and reopens this
  // dialog from scratch.
  Future<void> _loadPath(String path) async {
    final controller = _controller;
    final realm = _desktop?['realm']?.toString();
    if (controller == null || realm == null) return;
    setState(() {
      _loadingPath = true;
      _error = null;
    });
    try {
      final browse = await controller.browse(path);
      if (!mounted) return;
      setState(() {
        _browse = browse;
        _loadingPath = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (!DesktopConnectionManager().isDeadSessionError(controller.session, e)) {
        setState(() {
          _loadingPath = false;
          _error = 'Could not open folder: $e';
        });
        return;
      }
      try {
        await _reconnectTo(realm);
        final browse = await _controller!.browse(path);
        if (!mounted) return;
        setState(() {
          _browse = browse;
          _loadingPath = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _loadingPath = false;
          _error = 'Could not open folder: $e';
        });
      }
    }
  }

  void _goUp() {
    final current = _browse;
    if (current == null || current.path == '/' || current.path == current.homePath || current.path.isEmpty) {
      return;
    }
    final parts = current.path.split('/');
    parts.removeLast();
    final parentPath = parts.join('/');
    unawaited(_loadPath(parentPath.isEmpty ? '/' : parentPath));
  }

  String _fullPath(FileEntry entry) {
    if (entry.path.isNotEmpty) return entry.path;
    final dir = _browse?.path ?? '';
    return dir == '/' || dir.isEmpty ? '/${entry.name}' : '$dir/${entry.name}';
  }

  Future<void> _uploadHere() async {
    final controller = _controller;
    final remoteDir = _browse?.path;
    if (controller == null || remoteDir == null || _uploading) return;

    if (!ConnectivityService().hasConnection) {
      setState(() => _error = 'No internet connection');
      return;
    }

    setState(() {
      _uploading = true;
      _uploadIndex = 0;
      _fileProgress = 0;
      _error = null;
    });

    try {
      for (var i = 0; i < widget.files.length; i++) {
        final file = widget.files[i];
        if (!mounted) return;
        setState(() {
          _uploadIndex = i;
          _fileProgress = 0;
        });
        await controller.upload(
          file.path,
          remoteDir,
          onProgress: (sent, total) {
            if (!mounted || total <= 0) return;
            setState(() => _fileProgress = (sent / total).clamp(0.0, 1.0));
          },
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.files.length == 1 ? '${widget.files.first.name} uploaded' : 'Files uploaded')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      // Doesn't auto-retry the upload itself (partial-transfer state makes
      // that unsafe to resume blindly), but a dead session otherwise leaves
      // every subsequent manual retry failing the same way forever — so at
      // least get the connection healthy again for the next tap.
      final realm = _desktop?['realm']?.toString();
      if (realm != null && DesktopConnectionManager().isDeadSessionError(controller.session, e)) {
        try {
          await _reconnectTo(realm);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = 'Upload failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _selectingDesktop ? 'Choose desktop' : 'Choose destination';
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DialogHeader(
              title: title,
              showBack: !_selectingDesktop,
              onBack: _uploading
                  ? null
                  : () {
                      setState(() {
                        _desktop = null;
                        _controller = null;
                        _browse = null;
                        _error = null;
                      });
                    },
              onClose: _uploading ? null : () => Navigator.of(context).pop(),
            ),
            const Divider(height: 1),
            Flexible(child: _selectingDesktop ? _buildDesktopPicker() : _buildFolderPicker()),
            if (!_selectingDesktop) _buildUploadBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopPicker() {
    final session = context.watch<SessionProvider>();
    if (session.desktopsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (session.desktops.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => context.read<SessionProvider>().loadDesktops(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 160),
            Icon(Icons.desktop_windows_outlined, size: 72),
            SizedBox(height: 16),
            Center(child: Text('No desktops available')),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: session.desktops.length,
      itemBuilder: (context, index) {
        final desktop = session.desktops[index];
        final name = desktop['name']?.toString() ?? 'Unnamed Desktop';
        final authId = desktop['authid']?.toString() ?? '';
        final shortId = authId.length > 4 ? authId.substring(authId.length - 4) : authId;
        return Card(
          elevation: 0,
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            leading: const Icon(Icons.desktop_windows_outlined),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(shortId.isEmpty ? 'Desktop' : 'Desktop #$shortId'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _connecting ? null : () => _selectDesktop(desktop),
          ),
        );
      },
    );
  }

  Widget _buildFolderPicker() {
    if (_connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    final browse = _browse;
    if (browse == null) {
      return _ErrorView(message: _error ?? 'Could not load desktop', onRetry: () => _selectDesktop(_desktop!));
    }

    final dirs =
        browse.entries.where((entry) => entry.isDir && (_showHiddenDirs || !entry.name.startsWith('.'))).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Column(
      children: [
        _PathBar(
          path: browse.path.isEmpty ? '/' : browse.path,
          onUp: _goUp,
          showHidden: _showHiddenDirs,
          onToggleHidden: () => setState(() => _showHiddenDirs = !_showHiddenDirs),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: _loadingPath
              ? const Center(child: CircularProgressIndicator())
              : dirs.isEmpty
              ? const Center(child: Text('No folders here'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: dirs.length,
                  itemBuilder: (context, index) {
                    final entry = dirs[index];
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _uploading ? null : () => _loadPath(_fullPath(entry)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildUploadBar() {
    final files = widget.files;
    final current = files[_uploadIndex.clamp(0, files.length - 1)];
    final sizeText = current.size == null ? '' : ' · ${formatSize(current.size!)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _uploading
                ? 'Uploading ${_uploadIndex + 1} of ${files.length}: ${current.name}$sizeText'
                : files.length == 1
                ? current.name + sizeText
                : '${files.length} files selected',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (_uploading) LinearProgressIndicator(value: _fileProgress),
          if (_uploading) const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _controller == null || _browse == null || _uploading ? null : _uploadHere,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(_uploading ? 'Uploading...' : 'Upload here'),
          ),
        ],
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  final String title;
  final bool showBack;
  final VoidCallback? onBack;
  final VoidCallback? onClose;

  const _DialogHeader({required this.title, required this.showBack, this.onBack, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: [
          if (showBack)
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: onBack)
          else
            const SizedBox(width: 48),
          Expanded(
            child: Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: onClose),
        ],
      ),
    );
  }
}

class _PathBar extends StatelessWidget {
  final String path;
  final VoidCallback onUp;
  final bool showHidden;
  final VoidCallback onToggleHidden;

  const _PathBar({required this.path, required this.onUp, required this.showHidden, required this.onToggleHidden});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        leading: IconButton(icon: const Icon(Icons.arrow_upward), onPressed: onUp, tooltip: 'Up'),
        title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          icon: Icon(showHidden ? Icons.visibility : Icons.visibility_off),
          onPressed: onToggleHidden,
          tooltip: showHidden ? 'Hide hidden folders' : 'Show hidden folders',
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

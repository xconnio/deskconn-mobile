import 'package:flutter/material.dart';
import '../core/update/update_service.dart';
import '../theme/type_scale.dart';

class UpdateDialog extends StatefulWidget {
  final Map<String, dynamic> release;

  const UpdateDialog({super.key, required this.release});

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String _status = '';
  String? _error;

  Future<void> _startUpdate() async {
    final apkUrl = widget.release['apkUrl'] as String?;
    if (apkUrl == null) {
      setState(() {
        _error = 'Could not find the release APK file.';
      });
      return;
    }

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _status = 'Downloading update…';
      _error = null;
    });

    try {
      final updateService = UpdateService();
      await updateService.downloadAndInstall(apkUrl, (progressFraction) {
        if (mounted) {
          setState(() {
            _progress = progressFraction;
            final percentage = (progressFraction * 100).toStringAsFixed(0);
            _status = 'Downloading: $percentage%';
          });
        }
      });
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _error = 'Failed to download update: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final version = widget.release['version'] as String;
    final notes = widget.release['notes'] as String;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: DialogTheme.of(context).backgroundColor ?? theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.system_update_outlined, color: theme.colorScheme.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'New Version Available',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Version $version is ready to download.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            if (notes.isNotEmpty) ...[
              Text('Release Notes:', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 150),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.scaffoldBackgroundColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: Text(notes, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.3)),
                ),
                child: Text(_error!, style: DeskconnText.label.copyWith(color: theme.colorScheme.error)),
              ),
              const SizedBox(height: 16),
            ],
            if (_isDownloading) ...[
              Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: theme.dividerColor.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                ),
              ),
              const SizedBox(height: 8),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Later', style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(64, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onPressed: _startUpdate,
                    child: const Text('Update Now'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:deskconn_mobile_app/core/port_forward/port_forward_controller.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:deskconn_mobile_app/theme/type_scale.dart';
import 'package:deskconn_mobile_app/widgets/app_snack_bar.dart';

class PortForwardScreen extends StatelessWidget {
  final DesktopSessionLaunchConfig config;

  const PortForwardScreen({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(config.desktopName)),
      body: PortForwardView(config: config),
    );
  }
}

class PortForwardView extends StatefulWidget {
  final DesktopSessionLaunchConfig config;
  final bool embedded;

  const PortForwardView({super.key, required this.config, this.embedded = false});

  @override
  State<PortForwardView> createState() => _PortForwardViewState();
}

class _PortForwardViewState extends State<PortForwardView> {
  late final PortForwardController _controller = PortForwardController.forRealm(widget.config.realm);

  @override
  void initState() {
    super.initState();
    unawaited(_controller.load());
  }

  Future<void> _toggle(PortForwardRule rule, bool value) async {
    if (value) {
      await _controller.start(rule, widget.config);
      if (!mounted) return;
      if (rule.status == PortForwardStatus.failed && rule.error != null) {
        AppSnackBar.showError(context, rule.error!);
      }
      return;
    }
    await _controller.stop(rule);
  }

  Future<void> _addRule() async {
    final result = await showDialog<_RuleDraft>(
      context: context,
      builder: (_) => _AddRuleDialog(desktopName: widget.config.desktopName),
    );
    if (result == null) return;

    if (_controller.hasRule(result.direction, result.localPort, result.remotePort)) {
      if (mounted) AppSnackBar.showError(context, 'That forward already exists.');
      return;
    }

    final rule = await _controller.add(
      direction: result.direction,
      localPort: result.localPort,
      remotePort: result.remotePort,
    );
    await _toggle(rule, true);
  }

  Future<void> _remove(PortForwardRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove forward'),
        content: Text('Stop and remove ${_summary(rule)}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.remove(rule);
  }

  String _summary(PortForwardRule rule) {
    final desktop = widget.config.desktopName;
    if (rule.direction == PortForwardDirection.local) {
      return '127.0.0.1:${rule.localPort} → $desktop:${rule.remotePort}';
    }
    return '$desktop:${rule.remotePort} → 127.0.0.1:${rule.localPort}';
  }

  String _statusLabel(PortForwardRule rule) {
    return switch (rule.status) {
      PortForwardStatus.stopped => 'Stopped',
      PortForwardStatus.starting => 'Starting…',
      PortForwardStatus.active =>
        rule.connections == 0
            ? (rule.direction == PortForwardDirection.local ? 'Listening on this device' : 'Listening on the desktop')
            : '${rule.connections} active connection${rule.connections == 1 ? '' : 's'}',
      PortForwardStatus.failed => rule.error ?? 'Failed',
    };
  }

  Color _statusColor(PortForwardRule rule, DeskconnPalette palette) {
    return switch (rule.status) {
      PortForwardStatus.stopped => palette.subtle,
      PortForwardStatus.starting => palette.statusRouted,
      PortForwardStatus.active => palette.statusOnline,
      PortForwardStatus.failed => palette.statusOffline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final rules = _controller.rules;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.config.webRtcEnabled)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.surfaceTint,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: palette.statusRouted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This desktop is on a routed connection. Port forwarding needs a direct (P2P) connection.',
                        style: DeskconnText.caption.copyWith(color: palette.muted),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: rules.isEmpty
                  ? _EmptyState(palette: palette)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      itemCount: rules.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final rule = rules[index];
                        return Container(
                          decoration: BoxDecoration(
                            color: palette.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: palette.cardBorder),
                          ),
                          child: ListTile(
                            leading: Icon(
                              rule.direction == PortForwardDirection.local
                                  ? Icons.arrow_circle_right_outlined
                                  : Icons.arrow_circle_left_outlined,
                              color: palette.osXubuntu,
                            ),
                            title: Text(
                              _summary(rule),
                              style: DeskconnText.bodyStrong.copyWith(color: palette.heading),
                            ),
                            subtitle: Text(
                              _statusLabel(rule),
                              style: DeskconnText.caption.copyWith(color: _statusColor(rule, palette)),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(value: rule.isRunning, onChanged: (value) => unawaited(_toggle(rule, value))),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  tooltip: 'Remove',
                                  onPressed: () => unawaited(_remove(rule)),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton.icon(
                onPressed: () => unawaited(_addRule()),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add forward'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final DeskconnPalette palette;

  const _EmptyState({required this.palette});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_horiz, size: 40, color: palette.subtle),
            const SizedBox(height: 12),
            Text('No forwards yet', style: DeskconnText.subtitle.copyWith(color: palette.heading)),
            const SizedBox(height: 6),
            Text(
              'Reach a port on your desktop from this device, or expose a port of this device on the desktop.',
              textAlign: TextAlign.center,
              style: DeskconnText.caption.copyWith(color: palette.subtle),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleDraft {
  const _RuleDraft(this.direction, this.localPort, this.remotePort);

  final PortForwardDirection direction;
  final int localPort;
  final int remotePort;
}

class _AddRuleDialog extends StatefulWidget {
  final String desktopName;

  const _AddRuleDialog({required this.desktopName});

  @override
  State<_AddRuleDialog> createState() => _AddRuleDialogState();
}

class _AddRuleDialogState extends State<_AddRuleDialog> {
  final _formKey = GlobalKey<FormState>();
  final _localController = TextEditingController();
  final _remoteController = TextEditingController();

  PortForwardDirection _direction = PortForwardDirection.local;

  @override
  void dispose() {
    _localController.dispose();
    _remoteController.dispose();
    super.dispose();
  }

  String? _validatePort(String? value) {
    final port = int.tryParse((value ?? '').trim());
    if (port == null || port < 1 || port > 65535) return 'Enter a port between 1 and 65535';
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      _RuleDraft(_direction, int.parse(_localController.text.trim()), int.parse(_remoteController.text.trim())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = DeskconnPalette.of(context);
    final isLocal = _direction == PortForwardDirection.local;
    final hint = isLocal
        ? 'Traffic to 127.0.0.1 on this device is forwarded to ${widget.desktopName}.'
        : 'Traffic to ${widget.desktopName} is forwarded to 127.0.0.1 on this device.';

    return AlertDialog(
      title: const Text('Add forward'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<PortForwardDirection>(
              segments: const [
                ButtonSegment(value: PortForwardDirection.local, label: Text('To desktop')),
                ButtonSegment(value: PortForwardDirection.remote, label: Text('To device')),
              ],
              selected: {_direction},
              onSelectionChanged: (selection) => setState(() => _direction = selection.first),
            ),
            const SizedBox(height: 8),
            Text(hint, style: DeskconnText.caption.copyWith(color: palette.subtle)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _localController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: isLocal ? 'Local port (this device)' : 'Local port to expose'),
              validator: _validatePort,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _remoteController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: isLocal ? 'Desktop port to reach' : 'Desktop port to listen on'),
              validator: _validatePort,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}

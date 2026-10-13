import 'dart:convert';
import 'dart:typed_data';

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/network/connectivity_service.dart';
import 'package:deskconn_mobile_app/core/terminal/terminal_background_service.dart';
import 'package:deskconn_mobile_app/core/wamp/desktop_connection_manager.dart';
import 'package:deskconn_mobile_app/core/wamp/session_encryption.dart';
import 'package:deskconn_mobile_app/screens/file_explorer_screen.dart' show saveToDevice;
import 'package:flutter/material.dart';
import 'package:xconn/xconn.dart';

const _procLock = DeskconnProcedures.deskconndScreenLock;
const _procBrightnessGet = DeskconnProcedures.deskconndScreenBrightnessGet;
const _procBrightnessSet = DeskconnProcedures.deskconndScreenBrightnessSet;
const _procMprisPlayers = DeskconnProcedures.deskconndMprisPlayers;
const _procMprisPlayPause = DeskconnProcedures.deskconndMprisPlayPause;
const _procMprisPrev = DeskconnProcedures.deskconndMprisPrevious;
const _procMprisNext = DeskconnProcedures.deskconndMprisNext;
const _procAudioIsMuted = DeskconnProcedures.deskconndAudioIsMuted;
const _procAudioToggleMute = DeskconnProcedures.deskconndAudioToggleMute;
const _procScreenshot = DeskconnProcedures.deskconndScreenshot;

Uint8List _coerceBytes(dynamic raw) {
  if (raw is Uint8List) {
    return raw;
  }
  if (raw is List<int>) {
    return Uint8List.fromList(raw);
  }
  if (raw is List) {
    return Uint8List.fromList(raw.map((v) => (v as num).toInt()).toList());
  }
  if (raw is String) {
    return Uint8List.fromList(base64.decode(raw));
  }
  throw FormatException('Unsupported payload type: ${raw.runtimeType}');
}

Uint8List? _coerceArtBytes(dynamic raw) {
  if (raw == null) return null;
  try {
    final bytes = _coerceBytes(raw);
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

class _MprisPlayer {
  final String busName;
  final String identity;
  final String title;
  final String artist;
  final String album;
  final String artMimeType;
  final Uint8List? artData;
  final String playbackStatus;
  final bool canGoNext;
  final bool canGoPrevious;
  final bool canPlay;
  final bool canPause;

  const _MprisPlayer({
    required this.busName,
    required this.identity,
    required this.title,
    required this.artist,
    required this.album,
    required this.artMimeType,
    required this.artData,
    required this.playbackStatus,
    required this.canGoNext,
    required this.canGoPrevious,
    required this.canPlay,
    required this.canPause,
  });

  bool get isPlaying => playbackStatus == 'Playing';

  bool get hasMetadata => title.isNotEmpty || artist.isNotEmpty || album.isNotEmpty;

  bool get isStopped => playbackStatus == 'Stopped';

  bool get hasControls => canGoNext || canGoPrevious || canPlay || canPause;

  factory _MprisPlayer.fromMap(String busName, Map map) {
    final normalized = <String, dynamic>{
      for (final entry in map.entries) entry.key.toString().toLowerCase().replaceAll('_', ''): entry.value,
    };
    String str(String key) => normalized[key]?.toString() ?? '';
    bool flag(String key, {required bool orElse}) => normalized[key] as bool? ?? orElse;

    return _MprisPlayer(
      busName: busName,
      identity: str('identity').isNotEmpty ? str('identity') : busName,
      title: str('title'),
      artist: str('artist'),
      album: str('album'),
      artMimeType: str('artmimetype'),
      artData: _coerceArtBytes(normalized['artdata']),
      playbackStatus: str('playbackstatus'),
      canGoNext: flag('cangonext', orElse: true),
      canGoPrevious: flag('cangoprevious', orElse: true),
      canPlay: flag('canplay', orElse: true),
      canPause: flag('canpause', orElse: true),
    );
  }

  factory _MprisPlayer.legacy(String busName, dynamic identity) {
    return _MprisPlayer(
      busName: busName,
      identity: identity?.toString() ?? busName,
      title: '',
      artist: '',
      album: '',
      artMimeType: '',
      artData: null,
      playbackStatus: '',
      canGoNext: true,
      canGoPrevious: true,
      canPlay: true,
      canPause: true,
    );
  }
}

class RemoteControlScreen extends StatelessWidget {
  final DesktopSessionLaunchConfig config;

  const RemoteControlScreen({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(config.desktopName)),
      body: RemoteControlView(config: config),
    );
  }
}

class RemoteControlView extends StatefulWidget {
  final DesktopSessionLaunchConfig config;
  final bool embedded;

  const RemoteControlView({super.key, required this.config, this.embedded = false});

  @override
  State<RemoteControlView> createState() => _RemoteControlViewState();
}

class _RemoteControlViewState extends State<RemoteControlView> {
  double _brightness = 50;
  bool _brightnessLoaded = false;
  bool _brightnessAvailable = false;
  bool _locking = false;
  bool _capturingScreenshot = false;
  bool _mprisBusy = false;
  List<_MprisPlayer> _players = [];
  bool? _isMuted;
  bool _reconnecting = false;

  _MprisPlayer? get _primaryPlayer {
    if (_players.isEmpty) return null;
    final sorted = [..._players]..sort((a, b) => _playerScore(b).compareTo(_playerScore(a)));
    return sorted.first;
  }

  int _playerScore(_MprisPlayer player) {
    var score = 0;
    if (player.isPlaying) score += 100;
    if (!player.isStopped && player.playbackStatus.isNotEmpty) score += 40;
    if (player.hasMetadata) score += 30;
    if (player.hasControls) score += 10;
    return score;
  }

  Session? get _session => DesktopConnectionManager().get(widget.config.realm)?.session;

  Future<Session?> _ensureSession() async {
    final cached = _session;
    if (cached != null) return cached;
    if (!ConnectivityService().hasConnection) return null;
    if (mounted) setState(() => _reconnecting = true);
    try {
      final connection = await DesktopConnectionManager().acquire(
        realm: widget.config.realm,
        authId: widget.config.authId,
        privateKey: widget.config.privateKey,
        webRtcEnabled: widget.config.webRtcEnabled,
      );
      return connection.session;
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  Future<void> _run(Future<void> Function(Session session) action) async {
    final session = await _ensureSession();
    if (session == null) {
      _showOffline();
      return;
    }
    try {
      await action(session);
    } catch (_) {
      await _releaseStaleSession();
      if (mounted) _showOffline();
    }
  }

  Future<void> _releaseStaleSession() => DesktopConnectionManager().release(widget.config.realm);

  void _showOffline() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Desktop is offline. Action not sent.')));
  }

  @override
  void initState() {
    super.initState();
    _loadBrightness();
    _loadPlayers();
    _loadMuteState();
    ConnectivityService().addListener(_handleConnectivityChanged);
  }

  @override
  void dispose() {
    ConnectivityService().removeListener(_handleConnectivityChanged);
    super.dispose();
  }

  void _handleConnectivityChanged() {
    if (!mounted || !ConnectivityService().hasConnection || _session != null) return;
    _loadBrightness();
    _loadPlayers();
    _loadMuteState();
  }

  Future<void> _loadBrightness() async {
    final session = await _ensureSession();
    if (session == null) return;
    try {
      final brightness = await SessionEncryption.remoteControl(session).call(_procBrightnessGet) as num;
      if (mounted) {
        setState(() {
          _brightness = brightness.toDouble().clamp(1, 100);
          _brightnessLoaded = true;
          _brightnessAvailable = true;
        });
      }
    } catch (e) {
      if (e.toString().toLowerCase().contains('brightness device not available')) {
        if (mounted) setState(() => _brightnessAvailable = false);
      } else {
        await _releaseStaleSession();
      }
    }
  }

  Future<void> _loadPlayers() async {
    final session = await _ensureSession();
    if (session == null) return;
    try {
      final map = await SessionEncryption.remoteControl(session).call(_procMprisPlayers) as Map? ?? const {};
      if (mounted) {
        setState(() {
          _players = map.entries.map((entry) {
            final busName = entry.key.toString();
            final value = entry.value;
            return value is Map ? _MprisPlayer.fromMap(busName, value) : _MprisPlayer.legacy(busName, value);
          }).toList();
        });
      }
    } catch (_) {
      await _releaseStaleSession();
    }
  }

  Future<void> _loadMuteState() async {
    final session = await _ensureSession();
    if (session == null) return;
    try {
      final muted = await SessionEncryption.remoteControl(session).call(_procAudioIsMuted) as bool;
      if (mounted) {
        setState(() => _isMuted = muted);
      }
    } catch (_) {
      await _releaseStaleSession();
    }
  }

  Future<void> _toggleMute() async {
    await _run((session) async {
      final muted = await SessionEncryption.remoteControl(session).call(_procAudioToggleMute) as bool;
      if (mounted) {
        setState(() => _isMuted = muted);
      }
    });
  }

  Future<void> _lockScreen() async {
    if (_locking) return;
    setState(() => _locking = true);
    try {
      await _run((session) => SessionEncryption.remoteControl(session).call(_procLock));
    } finally {
      if (mounted) setState(() => _locking = false);
    }
  }

  Future<void> _setBrightness(int percent) async {
    await _run((session) => SessionEncryption.remoteControl(session).call(_procBrightnessSet, arg: percent));
  }

  Future<void> _takeScreenshot() async {
    if (_capturingScreenshot) return;
    final session = await _ensureSession();
    if (session == null) {
      _showOffline();
      return;
    }
    setState(() => _capturingScreenshot = true);
    try {
      final screenshot = await SessionEncryption.remoteControl(session).call(_procScreenshot) as Map;
      final bytes = _coerceBytes(screenshot['data']);
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => _ScreenshotPreviewScreen(bytes: bytes)));
      }
    } catch (e) {
      if (e.toString().toLowerCase().contains('screenshot not enabled')) {
        if (mounted) _showScreenshotDisabledDialog();
      } else {
        await _releaseStaleSession();
        if (mounted) _showOffline();
      }
    } finally {
      if (mounted) setState(() => _capturingScreenshot = false);
    }
  }

  void _showScreenshotDisabledDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Screenshot not enabled'),
        content: const Text("Run 'desk screenshot enable' on the desktop to allow remote screenshots."),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _mprisCall(String proc, {String? playerName}) async {
    if (_mprisBusy) return;
    final session = await _ensureSession();
    if (session == null) return;

    setState(() => _mprisBusy = true);
    try {
      await SessionEncryption.remoteControl(session).call(proc, arg: playerName);
    } catch (_) {}
    _refreshPlayersAfterMprisAction();
  }

  void _refreshPlayersAfterMprisAction() {
    for (final delay in const [
      Duration(milliseconds: 200),
      Duration(milliseconds: 700),
      Duration(milliseconds: 1400),
    ]) {
      Future.delayed(delay, () {
        if (mounted) _loadPlayers();
      });
    }
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _mprisBusy = false);
    });
  }

  Future<void> _togglePlayPause() async {
    final player = _primaryPlayer;
    await _mprisCall(_procMprisPlayPause, playerName: player?.busName);
  }

  Offset _brightnessTapPos = Offset.zero;

  void _showBrightnessControl() {
    if (widget.embedded) {
      showMenu<void>(
        context: context,
        position: RelativeRect.fromLTRB(
          _brightnessTapPos.dx,
          _brightnessTapPos.dy,
          _brightnessTapPos.dx,
          _brightnessTapPos.dy,
        ),
        items: [
          PopupMenuItem<void>(
            enabled: false,
            child: StatefulBuilder(
              builder: (context, setMenuState) {
                return SizedBox(
                  width: 220,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.brightness_6_outlined, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text('Brightness  ${_brightness.round()}%'),
                        ],
                      ),
                      Slider(
                        value: _brightness,
                        min: 1,
                        max: 100,
                        divisions: 99,
                        onChanged: (v) {
                          setMenuState(() {});
                          setState(() => _brightness = v);
                        },
                        onChangeEnd: (v) => _setBrightness(v.round()),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _BrightnessSheet(
        initial: _brightness,
        onChanged: (v) {
          if (mounted) setState(() => _brightness = v);
        },
        onChangeEnd: (v) => _setBrightness(v.round()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_reconnecting) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 4,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          children: [
            _IconTile(icon: _locking ? null : Icons.lock_outline, label: 'Lock', loading: _locking, onTap: _lockScreen),
            if (_brightnessAvailable)
              GestureDetector(
                onTapDown: (d) => _brightnessTapPos = d.globalPosition,
                child: _IconTile(
                  icon: Icons.brightness_6_outlined,
                  label: _brightnessLoaded ? '${_brightness.round()}%' : 'Brightness',
                  onTap: _showBrightnessControl,
                ),
              ),
            _IconTile(
              icon: _isMuted == null
                  ? Icons.volume_up_outlined
                  : (_isMuted! ? Icons.volume_off_outlined : Icons.volume_up_outlined),
              label: _isMuted == null ? 'Mute' : (_isMuted! ? 'Unmute' : 'Mute'),
              onTap: _toggleMute,
            ),
            _IconTile(
              icon: _capturingScreenshot ? null : Icons.photo_camera_outlined,
              label: 'Screenshot',
              loading: _capturingScreenshot,
              onTap: _takeScreenshot,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _MediaCard(
          player: _primaryPlayer,
          onPrev: _mprisBusy ? null : () => _mprisCall(_procMprisPrev, playerName: _primaryPlayer?.busName),
          onPlayPause: _mprisBusy ? null : _togglePlayPause,
          onNext: _mprisBusy ? null : () => _mprisCall(_procMprisNext, playerName: _primaryPlayer?.busName),
        ),
      ],
    );
  }
}

class _IconTile extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool loading;

  const _IconTile({required this.label, required this.onTap, this.icon, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            loading
                ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _MediaCard extends StatelessWidget {
  final _MprisPlayer? player;
  final VoidCallback? onPrev;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  const _MediaCard({required this.player, required this.onPrev, required this.onPlayPause, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final p = player;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: p == null
            ? Row(
                children: [
                  Icon(Icons.music_note, size: 16, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 6),
                  const Text('No active players'),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _ArtThumbnail(data: p.artData),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              p.title.isNotEmpty ? p.title : p.identity,
                              style: Theme.of(context).textTheme.titleSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (p.artist.isNotEmpty || p.album.isNotEmpty)
                              Text(
                                [p.artist, p.album].where((s) => s.isNotEmpty).join('  ·  '),
                                style: Theme.of(context).textTheme.bodySmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(icon: const Icon(Icons.skip_previous_rounded), iconSize: 40, onPressed: onPrev),
                      IconButton(
                        icon: Icon(
                          p.isPlaying ? Icons.pause_circle_outline_rounded : Icons.play_circle_outline_rounded,
                        ),
                        iconSize: 52,
                        onPressed: onPlayPause,
                      ),
                      IconButton(icon: const Icon(Icons.skip_next_rounded), iconSize: 40, onPressed: onNext),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _ArtThumbnail extends StatelessWidget {
  final Uint8List? data;

  const _ArtThumbnail({required this.data});

  @override
  Widget build(BuildContext context) {
    final bytes = data;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: bytes == null
          ? _placeholder(context)
          : Image.memory(
              bytes,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (context, _, _) => _placeholder(context),
            ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: Theme.of(context).colorScheme.primary),
    );
  }
}

class _BrightnessSheet extends StatefulWidget {
  final double initial;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _BrightnessSheet({required this.initial, required this.onChanged, required this.onChangeEnd});

  @override
  State<_BrightnessSheet> createState() => _BrightnessSheetState();
}

class _BrightnessSheetState extends State<_BrightnessSheet> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.brightness_6_outlined, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Text('Brightness  ${_value.round()}%', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Slider(
            value: _value,
            min: 1,
            max: 100,
            divisions: 99,
            onChanged: (v) {
              setState(() => _value = v);
              widget.onChanged(v);
            },
            onChangeEnd: widget.onChangeEnd,
          ),
        ],
      ),
    );
  }
}

class _ScreenshotPreviewScreen extends StatefulWidget {
  final Uint8List bytes;

  const _ScreenshotPreviewScreen({required this.bytes});

  @override
  State<_ScreenshotPreviewScreen> createState() => _ScreenshotPreviewScreenState();
}

class _ScreenshotPreviewScreenState extends State<_ScreenshotPreviewScreen> {
  bool _isSaving = false;

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final filename = 'screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
      final savedPath = await saveToDevice(filename, widget.bytes);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved: $savedPath'), duration: const Duration(seconds: 5)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Screenshot'),
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          _isSaving
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                  ),
                )
              : IconButton(icon: const Icon(Icons.download_outlined), tooltip: 'Save to device', onPressed: _save),
        ],
      ),
      body: InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: SizedBox.expand(
          child: Image.memory(
            widget.bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, size: 48)),
          ),
        ),
      ),
    );
  }
}

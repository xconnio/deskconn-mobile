import 'package:deskconn_mobile_app/core/wamp/core_client.dart';
import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/core/resource_monitor/models.dart';
import 'package:deskconn_mobile_app/core/wamp/session_encryption.dart';

class AppIcon {
  final String mime;
  final String data;

  const AppIcon({required this.mime, required this.data});

  String get dataUri => 'data:$mime;base64,$data';
}

const _systemAppId = 'system';

List<AppInfo> parseApps(List<dynamic> decoded) =>
    decoded.map((e) => AppInfo.fromJson(e as Map<String, dynamic>)).where((app) => app.id != _systemAppId).toList();

class ResourceMonitorController {
  final Session session;

  ResourceMonitorController(this.session);

  SessionEncryption get _encryption => SessionEncryption.deskconnd(session);

  Future<DeviceInfo> fetchInfo() async {
    final decoded = await _encryption.call(DeskconnProcedures.deskconndMachineInfo) as Map<String, dynamic>;
    return DeviceInfo.fromJson(decoded);
  }

  Future<List<ProcessInfo>> fetchProcesses() async {
    final decoded = await _encryption.call(DeskconnProcedures.deskconndProcessList) as List? ?? const [];
    return decoded.map((e) => ProcessInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<AppInfo>> fetchApps() async {
    final decoded = await _encryption.call(DeskconnProcedures.deskconndAppList) as List? ?? const [];
    return parseApps(decoded);
  }

  Future<AppIcon> fetchIcon(String iconName) async {
    final decoded = await _encryption.call(DeskconnProcedures.deskconndAppIcon, arg: iconName) as Map<String, dynamic>;
    return AppIcon(mime: decoded['mime'] as String? ?? 'image/png', data: decoded['data'] as String? ?? '');
  }

  Future<void> signalPids(List<int> pids, String signal) async {
    if (pids.isEmpty) return;
    await _encryption.call(DeskconnProcedures.deskconndProcessSignal, arg: {'pids': pids, 'signal': signal});
  }
}

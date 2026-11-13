import 'dart:convert';

import 'package:deskconn_mobile_app/core/errors/deskconn_error_mapper.dart';
import 'package:deskconn_mobile_app/core/wamp/core_client.dart';

typedef CloudCall = Future<List<dynamic>> Function(String procedure, {List<dynamic> args, Map<String, dynamic> kwargs});

typedef Json = Map<String, dynamic>;

const accessRoles = ['admin', 'member'];

String accessErrorMessage(Object error, String fallback) {
  if (error is ApplicationError && error.args != null && error.args!.isNotEmpty) {
    final raw = error.args!.first.toString();
    try {
      final parsed = jsonDecode(raw);
      if (parsed is List) return parsed.map((e) => e is Map ? (e['msg'] ?? e).toString() : e.toString()).join('; ');
    } catch (_) {}
    if (raw.isNotEmpty) return raw;
  }
  return DeskconnErrorMapper.messageFor(error, fallback: fallback);
}

String personName(Json? user, Object? fallbackId) {
  final name = user?['name']?.toString();
  if (name != null && name.isNotEmpty) return name;
  final email = user?['email']?.toString();
  if (email != null && email.isNotEmpty) return email;
  return fallbackId?.toString() ?? 'Unknown';
}

String? personEmail(Json? user) {
  final name = user?['name']?.toString();
  final email = user?['email']?.toString();
  return name != null && name.isNotEmpty && email != null && email.isNotEmpty ? email : null;
}

Json? asJson(Object? value) => value is Map ? Map<String, dynamic>.from(value) : null;

class AccessApi {
  AccessApi(this._call);

  final CloudCall _call;

  Future<List<Json>> _list(String procedure, [List<dynamic> args = const []]) async {
    final result = await _call(procedure, args: args);
    return [
      for (final item in result)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Future<Json?> _one(String procedure, [List<dynamic> args = const []]) async {
    final result = await _call(procedure, args: args);
    return result.isEmpty ? null : asJson(result.first);
  }

  Future<Json?> myMachineAccess(String desktopId) => _one('io.xconn.deskconn.desktop.access.user.me', [desktopId]);

  Future<List<Json>> machineUsers(String desktopId) => _list('io.xconn.deskconn.desktop.access.user.list', [desktopId]);

  Future<void> setUserRole(String accessId, String role) =>
      _call('io.xconn.deskconn.desktop.access.user.update', args: [accessId, role]);

  Future<void> revokeUser(String accessId) => _call('io.xconn.deskconn.desktop.access.user.revoke', args: [accessId]);

  Future<void> inviteToMachine(String desktopId, String email, String role) =>
      _call('io.xconn.deskconn.desktop.invitation.user.create', args: [desktopId, email, role]);

  Future<List<Json>> machineInvitesInbox() => _list('io.xconn.deskconn.desktop.invitation.inbox.list');

  Future<List<Json>> machineInvitesOutbox() => _list('io.xconn.deskconn.desktop.invitation.outbox.list');

  Future<void> respondToMachineInvite(String id, bool accept) =>
      _call('io.xconn.deskconn.desktop.invitation.respond', args: [id, accept ? 'accepted' : 'rejected']);

  Future<void> cancelMachineInvite(String id) => _call('io.xconn.deskconn.desktop.invitation.user.cancel', args: [id]);
}

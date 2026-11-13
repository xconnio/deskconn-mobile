import 'package:deskconn_mobile_app/core/access/access_api.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/widgets/app_empty_state.dart';
import 'package:deskconn_mobile_app/widgets/app_error_view.dart';
import 'package:deskconn_mobile_app/widgets/app_loading.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

AccessApi _api(BuildContext context) => AccessApi(context.read<SessionProvider>().cloudCall);

String _capitalize(String value) => value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

void _toast(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(content: Text(message), backgroundColor: error ? Theme.of(context).colorScheme.error : null),
  );
}

Future<bool> _confirm(BuildContext context, String title, String message, String action) async {
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

Future<bool> _run(BuildContext context, Future<void> Function() action, String failure, {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) _toast(context, success);
    return true;
  } catch (e) {
    if (context.mounted) _toast(context, accessErrorMessage(e, failure), error: true);
    return false;
  }
}

class _RoleChip extends StatelessWidget {
  final String role;

  const _RoleChip(this.role);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strong = role == 'owner' || role == 'admin';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: strong ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _capitalize(role),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: strong ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String label;
  final IconData? icon;

  const _Avatar(this.label, {this.icon});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      child: icon != null ? Icon(icon, size: 18) : Text(label.isEmpty ? '?' : label[0].toUpperCase()),
    );
  }
}

class _InviteDialog extends StatefulWidget {
  final String title;

  const _InviteDialog({required this.title});

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _email = TextEditingController();
  String _role = 'member';

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    Navigator.pop(context, (email, _role));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Email'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [for (final role in accessRoles) ButtonSegment(value: role, label: Text(_capitalize(role)))],
            selected: {_role},
            onSelectionChanged: (value) => setState(() => _role = value.first),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Send invite')),
      ],
    );
  }
}

Future<String?> _pickRole(BuildContext context, String current) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final role in accessRoles)
            ListTile(
              leading: Icon(role == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(_capitalize(role)),
              onTap: () => Navigator.pop(context, role),
            ),
        ],
      ),
    ),
  );
}

class _Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;
  final String failure;

  const _Loader({super.key, required this.load, required this.builder, required this.failure});

  @override
  State<_Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<_Loader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final data = await widget.load();
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_loading) return const AppLoading();
    if (data == null) {
      return AppErrorView(message: accessErrorMessage(_error ?? widget.failure, widget.failure), onRetry: _reload);
    }
    return RefreshIndicator(onRefresh: _reload, child: widget.builder(context, data, _reload));
  }
}

Widget _emptyList(IconData icon, String title, {String? subtitle}) => ListView(
  physics: const AlwaysScrollableScrollPhysics(),
  children: [
    const SizedBox(height: 48),
    AppEmptyState(icon: icon, title: title, subtitle: subtitle),
  ],
);

class AccessManagementScreen extends StatelessWidget {
  const AccessManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Access management'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Machines'),
              Tab(text: 'Invitations'),
            ],
          ),
        ),
        body: const TabBarView(children: [_MachinesTab(), _InvitationsTab()]),
      ),
    );
  }
}

class _MachinesTab extends StatelessWidget {
  const _MachinesTab();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final machines = session.desktops.where((d) => d['role'] == 'owner' || d['role'] == 'admin').toList();
    return RefreshIndicator(
      onRefresh: session.loadDesktops,
      child: machines.isEmpty
          ? _emptyList(
              Icons.computer_outlined,
              'No machines to manage',
              subtitle: 'Machines you own or administer appear here.',
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: machines.length,
              itemBuilder: (context, index) {
                final machine = machines[index];
                final name = machine['name']?.toString() ?? 'Machine';
                return ListTile(
                  leading: const _Avatar('', icon: Icons.computer_outlined),
                  title: Text(name),
                  subtitle: Text(_capitalize(machine['role']?.toString() ?? '')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MachineAccessScreen(desktopId: machine['id'].toString(), name: name),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _InvitationsTab extends StatelessWidget {
  const _InvitationsTab();

  @override
  Widget build(BuildContext context) {
    return _Loader<List<Json>>(
      load: () => _api(context).machineInvitesInbox(),
      failure: 'Could not load invitations.',
      builder: (context, invites, reload) => invites.isEmpty
          ? _emptyList(Icons.mail_outline, 'No pending invitations')
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: invites.length,
              itemBuilder: (context, index) {
                final invite = invites[index];
                final name = asJson(invite['desktop'])?['name']?.toString() ?? 'A machine';
                final role = invite['role']?.toString() ?? 'member';
                final id = invite['id'].toString();

                Future<void> respond(bool accept) async {
                  final session = context.read<SessionProvider>();
                  final api = _api(context);
                  final ok = await _run(
                    context,
                    () => api.respondToMachineInvite(id, accept),
                    'Could not respond to the invitation.',
                    success: accept ? 'Joined $name' : 'Invitation declined',
                  );
                  if (!ok) return;
                  if (accept) await session.loadDesktops();
                  await reload();
                }

                return Card(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.computer_outlined, size: 20),
                            const SizedBox(width: 10),
                            Expanded(child: Text(name, style: Theme.of(context).textTheme.titleSmall)),
                            _RoleChip(role),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(onPressed: () => respond(false), child: const Text('Decline')),
                            FilledButton.tonal(onPressed: () => respond(true), child: const Text('Accept')),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _MachineAccessData {
  final Json? me;
  final List<Json> users;
  final List<Json> invites;

  _MachineAccessData(this.me, this.users, this.invites);

  bool get canManage => me?['role'] == 'owner' || me?['role'] == 'admin';
}

class MachineAccessScreen extends StatefulWidget {
  final String desktopId;
  final String name;

  const MachineAccessScreen({super.key, required this.desktopId, required this.name});

  @override
  State<MachineAccessScreen> createState() => _MachineAccessScreenState();
}

class _MachineAccessScreenState extends State<MachineAccessScreen> {
  Key _key = UniqueKey();
  bool _canManage = false;
  bool _isOwner = false;

  void _refresh() => setState(() => _key = UniqueKey());

  Future<_MachineAccessData> _load() async {
    final api = _api(context);
    final id = widget.desktopId;
    final me = await api.myMachineAccess(id).catchError((Object _) => null);
    final canManage = me?['role'] == 'owner' || me?['role'] == 'admin';
    final results = await Future.wait([api.machineUsers(id), if (canManage) api.machineInvitesOutbox()]);
    final invites = canManage ? results[1].where((i) => i['desktop_id']?.toString() == id).toList() : <Json>[];
    final isOwner = me?['role'] == 'owner';
    if (mounted && (canManage != _canManage || isOwner != _isOwner)) {
      setState(() {
        _canManage = canManage;
        _isOwner = isOwner;
      });
    }
    return _MachineAccessData(me, results[0], invites);
  }

  Future<void> _invite() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _InviteDialog(title: 'Invite to machine'),
    );
    if (result == null || !mounted) return;
    final (email, role) = result;
    if (await _run(
      context,
      () => _api(context).inviteToMachine(widget.desktopId, email, role),
      'Could not send the invitation.',
      success: 'Invitation sent to $email',
    )) {
      _refresh();
    }
  }

  Future<void> _deleteMachine() async {
    final session = context.read<SessionProvider>();
    final desktop = session.desktops.firstWhere(
      (d) => d['id']?.toString() == widget.desktopId,
      orElse: () => {'id': widget.desktopId, 'name': widget.name},
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${widget.name}?'),
        content: const Text(
          'It is removed from your account and everyone it was shared with loses access. '
          'To add it back, attach it again from the desktop.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (await _run(
          context,
          () => session.deleteDesktop(desktop),
          'Could not delete ${widget.name}.',
          success: 'Deleted ${widget.name}',
        ) &&
        mounted) {
      Navigator.pop(context);
    }
  }

  Widget _people(_MachineAccessData data) {
    if (data.users.isEmpty) return _emptyList(Icons.people_outline, 'No collaborators');
    final myId = context.read<SessionProvider>().account?['id']?.toString();
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: data.users.length,
      itemBuilder: (_, index) {
        final access = data.users[index];
        final user = asJson(access['user']);
        final name = personName(user, access['user_id']);
        final role = access['role']?.toString() ?? 'member';
        final isMe = access['user_id']?.toString() == myId;
        final editable = data.canManage && role != 'owner' && !isMe;
        return ListTile(
          leading: _Avatar(name),
          title: Text(isMe ? '$name (you)' : name),
          subtitle: personEmail(user) == null ? null : Text(personEmail(user)!),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RoleChip(role),
              if (editable)
                PopupMenuButton<String>(
                  onSelected: (action) async {
                    final api = _api(context);
                    final id = access['id'].toString();
                    if (action == 'role') {
                      final next = await _pickRole(context, role);
                      if (next == null || next == role || !mounted) return;
                      if (await _run(context, () => api.setUserRole(id, next), 'Could not change the role.')) {
                        _refresh();
                      }
                    } else if (await _confirm(
                          context,
                          'Remove $name?',
                          '$name will lose access to this machine.',
                          'Remove',
                        ) &&
                        mounted &&
                        await _run(context, () => api.revokeUser(id), 'Could not remove access.')) {
                      _refresh();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'role', child: Text('Change role')),
                    PopupMenuItem(value: 'remove', child: Text('Remove access')),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _sentInvites(_MachineAccessData data) {
    if (data.invites.isEmpty) return _emptyList(Icons.send_outlined, 'No pending invites');
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: data.invites.length,
      itemBuilder: (_, index) {
        final invite = data.invites[index];
        final user = asJson(invite['invitee_user']);
        final name = personName(user, invite['invitee_user_id']);
        return ListTile(
          leading: const _Avatar('', icon: Icons.mail_outline),
          title: Text(name),
          subtitle: Text('${_capitalize(invite['role']?.toString() ?? 'member')} · pending'),
          trailing: TextButton(
            onPressed: () async {
              final api = _api(context);
              if (await _run(
                context,
                () => api.cancelMachineInvite(invite['id'].toString()),
                'Could not cancel the invite.',
              )) {
                _refresh();
              }
            },
            child: const Text('Cancel'),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name),
        actions: [
          if (_isOwner)
            IconButton(
              icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              tooltip: 'Delete machine',
              onPressed: _deleteMachine,
            ),
        ],
      ),
      floatingActionButton: _canManage
          ? FloatingActionButton.extended(
              heroTag: null,
              onPressed: _invite,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Invite'),
            )
          : null,
      body: _Loader<_MachineAccessData>(
        key: _key,
        load: _load,
        failure: 'Could not load access for this machine.',
        builder: (context, data, reload) => DefaultTabController(
          length: data.canManage ? 2 : 1,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  Tab(text: 'People (${data.users.length})'),
                  if (data.canManage) Tab(text: 'Invites (${data.invites.length})'),
                ],
              ),
              Expanded(child: TabBarView(children: [_people(data), if (data.canManage) _sentInvites(data)])),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:deskconn_mobile_app/core/constants.dart';
import 'package:deskconn_mobile_app/widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/screens/sign_in_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final nameCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  bool savingProfile = false;
  bool savingPassword = false;
  String? error;
  bool _obscurePassword = true;

  @override
  void dispose() {
    nameCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = context.read<SessionProvider>();
    final account = session.account;
    if (account != null && nameCtrl.text.isEmpty) {
      nameCtrl.text = account['name'] ?? '';
    }
  }

  bool get _canUpdateProfile {
    final session = context.read<SessionProvider>();
    final account = session.account;
    if (account == null) return false;
    return nameCtrl.text.trim() != (account['name'] ?? '');
  }

  bool get _canChangePassword {
    return passCtrl.text.isNotEmpty;
  }

  Future<void> _updateProfile() async {
    FocusScope.of(context).unfocus();

    if (!_canUpdateProfile) return;

    final session = context.read<SessionProvider>();

    setState(() {
      savingProfile = true;
    });

    try {
      final res = await session.session!
          .call(DeskconnProcedures.accountUpdate, kwargs: {'name': nameCtrl.text.trim()})
          .timeout(DeskconnConfig.callTimeout);

      if (!mounted) return;

      if (res.args.isNotEmpty) {
        session.updateAccount(Map<String, dynamic>.from(res.args[0] as Map));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }

    if (mounted) {
      setState(() {
        savingProfile = false;
      });
    }
  }

  Future<void> _changePassword() async {
    FocusScope.of(context).unfocus();

    if (!_canChangePassword) return;

    setState(() {
      savingPassword = true;
    });

    try {
      final session = context.read<SessionProvider>();
      await session.session!
          .call(DeskconnProcedures.accountUpdate, kwargs: {'password': passCtrl.text})
          .timeout(DeskconnConfig.callTimeout);
      passCtrl.clear();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }

    if (mounted) {
      setState(() {
        savingPassword = false;
      });
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete account'),
          content: const Text('This action cannot be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      _delete();
    }
  }

  Future<void> _delete() async {
    FocusScope.of(context).unfocus();

    final session = context.read<SessionProvider>();

    try {
      await session.session!.call(DeskconnProcedures.accountDelete).timeout(DeskconnConfig.callTimeout);
    } catch (_) {}

    await session.logout();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const SignInScreen()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final account = session.account;
    final standalone = session.standalone;

    if (standalone != null) {
      return AppShell(
        title: 'Account',
        currentSection: AppShellSection.account,
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text('Machine'),
            const SizedBox(height: 4),
            Text(standalone.address),
            const SizedBox(height: 24),
            const Text('Username'),
            const SizedBox(height: 4),
            Text(standalone.authId),
            const SizedBox(height: 24),
            const Text('Signed in to a standalone machine, without a Deskconn account.'),
          ],
        ),
      );
    }

    if (account == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return AppShell(
      title: 'Account',
      currentSection: AppShellSection.account,
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const Text('Email'),
          const SizedBox(height: 4),
          Text(account['email'] ?? ''),
          const SizedBox(height: 24),
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(labelText: 'username'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          savingProfile
              ? const Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2)))
              : ElevatedButton(
                  onPressed: _canUpdateProfile ? _updateProfile : null,
                  child: const Text('Update profile'),
                ),
          const SizedBox(height: 32),
          const Text('Security'),
          const SizedBox(height: 12),
          TextField(
            controller: passCtrl,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: 'New password',
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () {
                  setState(() {
                    _obscurePassword = !_obscurePassword;
                  });
                },
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          savingPassword
              ? const Center(child: SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2)))
              : ElevatedButton(
                  onPressed: _canChangePassword ? _changePassword : null,
                  child: const Text('Change password'),
                ),
          const SizedBox(height: 40),
          const Divider(),
          const SizedBox(height: 16),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: _confirmDelete,
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
  }
}

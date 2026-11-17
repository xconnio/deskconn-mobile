import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/l10n/generated/app_localizations.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';
import 'package:deskconn_mobile_app/providers/theme_provider.dart';
import 'package:deskconn_mobile_app/screens/account_screen.dart';
import 'package:deskconn_mobile_app/screens/sign_in_screen.dart';
import 'package:deskconn_mobile_app/widgets/app_shell.dart';
import 'package:deskconn_mobile_app/widgets/settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String prefKeyDockAutoHide = 'dock_auto_hide';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _dockAutoHide = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dockAutoHide = prefs.getBool(prefKeyDockAutoHide) ?? false;
    });
  }

  Future<void> _setDockAutoHide(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKeyDockAutoHide, value);
    if (!mounted) return;
    setState(() => _dockAutoHide = value);
  }

  Future<void> _chooseTheme(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.read<ThemeProvider>();
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (dialogContext) {
        var pending = theme.mode;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return SimpleDialog(
              title: Text(l10n.chooseTheme),
              children: [
                RadioGroup<ThemeMode>(
                  groupValue: pending,
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => pending = value);
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<ThemeMode>(title: Text(l10n.themeSystem), value: ThemeMode.system),
                      RadioListTile<ThemeMode>(title: Text(l10n.themeLight), value: ThemeMode.light),
                      RadioListTile<ThemeMode>(title: Text(l10n.themeDark), value: ThemeMode.dark),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(l10n.cancel)),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: () => Navigator.pop(dialogContext, pending), child: Text(l10n.ok)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (selected != null) theme.setTheme(selected);
  }

  String _themeLabel(AppLocalizations l10n, ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => l10n.themeSystem,
      ThemeMode.light => l10n.themeLight,
      ThemeMode.dark => l10n.themeDark,
    };
  }

  Future<void> _logout(BuildContext context) async {
    final session = context.read<SessionProvider>();
    await session.logout();
    if (context.mounted) {
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const SignInScreen()), (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final l10n = AppLocalizations.of(context)!;

    return AppShell(
      title: l10n.settingsTitle,
      currentSection: AppShellSection.settings,
      body: ListView(
        children: [
          SettingsTile(
            icon: Icons.person_outline,
            title: l10n.accountTitle,
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen())),
          ),
          const Divider(),
          if (isDesktopLayout(context)) ...[
            SwitchListTile(
              secondary: const Icon(Icons.dock_outlined),
              title: Text(l10n.autoHideDock),
              subtitle: Text(l10n.autoHideDockSubtitle),
              value: _dockAutoHide,
              onChanged: _setDockAutoHide,
            ),
            const Divider(),
          ],
          SettingsTile(
            icon: Icons.brightness_6_outlined,
            title: l10n.theme,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _themeLabel(l10n, theme.mode),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
            onTap: () => _chooseTheme(context),
          ),
          const Divider(),
          SettingsTile(icon: Icons.logout, title: l10n.logout, destructive: true, onTap: () => _logout(context)),
        ],
      ),
    );
  }
}

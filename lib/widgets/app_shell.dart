import 'package:deskconn_mobile_app/core/responsive.dart';
import 'package:deskconn_mobile_app/screens/account_screen.dart';
import 'package:deskconn_mobile_app/screens/settings_screen.dart';
import 'package:deskconn_mobile_app/screens/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:deskconn_mobile_app/providers/session_provider.dart';

enum AppShellSection { account, desktops, settings }

class AppShell extends StatelessWidget {
  final String title;
  final Widget body;
  final PreferredSizeWidget? bottom;
  final AppShellSection currentSection;
  final List<Widget>? actions;

  const AppShell({
    super.key,
    required this.title,
    required this.body,
    required this.currentSection,
    this.bottom,
    this.actions,
  });

  Future<void> _openSection(
    BuildContext context, {
    required AppShellSection section,
    required WidgetBuilder builder,
    bool closeDrawer = false,
  }) async {
    if (closeDrawer) Navigator.pop(context);
    if (section == currentSection) return;
    if (section == AppShellSection.desktops) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: builder));
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    final account = session.account;
    final colorScheme = Theme.of(context).colorScheme;

    final standalone = session.standalone;
    final name = (standalone?.authId ?? account?['name'] as String? ?? '').trim();
    final email = (standalone?.host ?? account?['email'] as String? ?? '').trim();
    final initial = name.isNotEmpty
        ? name[0].toUpperCase()
        : email.isNotEmpty
        ? email[0].toUpperCase()
        : '?';
    final showSidebar = isDesktopLayout(context);
    final sidebar = _AppSidebar(
      currentSection: currentSection,
      name: name,
      email: email,
      initial: initial,
      colorScheme: colorScheme,
      session: session,
      openSection: _openSection,
      closeDrawerOnTap: !showSidebar,
    );

    final showMobileDrawer = !showSidebar && currentSection == AppShellSection.desktops;

    return Scaffold(
      appBar: AppBar(title: Text(title), bottom: bottom, actions: actions),
      drawer: showMobileDrawer ? Drawer(child: sidebar) : null,
      body: showSidebar
          ? Row(
              children: [
                SizedBox(width: 280, child: sidebar),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }
}

class _AppSidebar extends StatelessWidget {
  final AppShellSection currentSection;
  final String name;
  final String email;
  final String initial;
  final ColorScheme colorScheme;
  final SessionProvider session;
  final Future<void> Function(
    BuildContext context, {
    required AppShellSection section,
    required WidgetBuilder builder,
    bool closeDrawer,
  })
  openSection;
  final bool closeDrawerOnTap;

  const _AppSidebar({
    required this.currentSection,
    required this.name,
    required this.email,
    required this.initial,
    required this.colorScheme,
    required this.session,
    required this.openSection,
    required this.closeDrawerOnTap,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => openSection(
              context,
              section: AppShellSection.account,
              builder: (_) => const AccountScreen(),
              closeDrawer: closeDrawerOnTap,
            ),
            child: Container(
              color: colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: colorScheme.onSurface.withValues(alpha: 0.12),
                    child: Text(
                      initial,
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colorScheme.onSurface),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (name.isNotEmpty)
                    Text(
                      name,
                      style: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  if (email.isNotEmpty)
                    Text(email, style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 13)),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _NavTile(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  selected: currentSection == AppShellSection.settings,
                  onTap: () => openSection(
                    context,
                    section: AppShellSection.settings,
                    builder: (_) => const SettingsScreen(),
                    closeDrawer: closeDrawerOnTap,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: ListTile(
              leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
              title: Text('Logout', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              onTap: () async {
                if (closeDrawerOnTap) Navigator.pop(context);
                await session.logout();
                if (context.mounted) {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const SignInScreen()),
                    (_) => false,
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavTile({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final defaultColor = colorScheme.onSurface.withValues(alpha: 0.88);
    final selectedColor = colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: ListTile(
        leading: Icon(icon, color: selected ? selectedColor : defaultColor),
        title: Text(
          label,
          style: TextStyle(
            color: selected ? selectedColor : defaultColor,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        selected: selected,
        selectedTileColor: colorScheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        onTap: onTap,
      ),
    );
  }
}

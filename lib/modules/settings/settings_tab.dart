import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gerrymanderx/core/constants/app_constants.dart';
import 'package:gerrymanderx/modules/auth/widgets/sign_out_dialog.dart';
import 'package:gerrymanderx/modules/auth/widgets/user_menu_button.dart';
import 'package:gerrymanderx/providers/app_settings_store.dart';
import 'package:gerrymanderx/providers/auth_store.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettingsStore>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
        children: [
          // ── Account ──
          const _AccountSection(),

          // ── Appearance ──
          const _SectionTitle(title: 'Appearance'),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.dark_mode),
              title: const Text('Theme'),
              trailing: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (set) => settings.setThemeMode(set.first),
              ),
            ),
          ),

          const SizedBox(height: 30),

          // ── About & Legal ──
          const _SectionTitle(title: 'About & Legal'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                const _FeedbackTile(),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  trailing: const Icon(Icons.open_in_new, size: 16),
                  onTap: () =>
                      launchUrl(Uri.parse(AppConstants.privacyPolicyUrl)),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                const _VersionTile(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The signed-in account: who you are, sign-out, and the account deletion the
/// App Store requires from any app that offers sign-in (guideline 5.1.1(v)).
class _AccountSection extends StatelessWidget {
  const _AccountSection();

  Future<void> _confirmDelete(BuildContext context) async {
    final auth = context.read<AuthStore>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: Text(
          'This permanently deletes the ${auth.displayName} account. '
          'You may be asked to sign in again to confirm.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await auth.deleteAccount();
    if (!context.mounted || auth.error == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(auth.error!)));
  }

  @override
  Widget build(BuildContext context) {
    // Nullable lookup: the tab is also pumped on its own in widget tests,
    // where no AuthStore is in scope.
    final auth = context.watch<AuthStore?>();
    if (auth == null || !auth.isSignedIn) return const SizedBox.shrink();
    final email = auth.user?.email;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(title: 'Account'),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: UserAvatar(auth: auth, radius: 18),
                title: Text(auth.displayName),
                subtitle: Text(
                  email == null || email.isEmpty
                      ? 'Signed in with ${auth.providerName}'
                      : '$email · ${auth.providerName}',
                ),
                trailing: TextButton.icon(
                  onPressed: auth.isBusy ? null : () => confirmSignOut(context),
                  icon: const Icon(Icons.logout, size: 16),
                  label: const Text('Sign out'),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('Delete Account'),
                subtitle:
                    const Text('Removes your account and profile for good'),
                onTap: auth.isBusy ? null : () => _confirmDelete(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}

/// Opens the user's mail client with the support address pre-filled and the
/// app version in the subject, so reports arrive already labelled.
class _FeedbackTile extends StatelessWidget {
  const _FeedbackTile();

  Future<void> _sendMail(BuildContext context) async {
    final version = await _appVersion();
    final uri = Uri(
      scheme: 'mailto',
      path: AppConstants.supportEmail,
      queryParameters: {'subject': '${AppConstants.appName} (v$version)'},
    );
    if (!await launchUrl(uri)) {
      if (!context.mounted) return;
      // No mail client configured — show the address so it can be copied.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Feedback: ${AppConstants.supportEmail}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.mail_outline),
      title: const Text('Feedback'),
      subtitle: const Text('Email us about a bug or an idea'),
      trailing: const Icon(Icons.open_in_new, size: 16),
      onTap: () => _sendMail(context),
    );
  }
}

/// App version row; reads the bundle version once and caches it.
class _VersionTile extends StatelessWidget {
  const _VersionTile();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _appVersion(),
      builder: (context, snapshot) => ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('About'),
        trailing: Text(
          'Version ${snapshot.data ?? ''}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}

Future<String>? _versionFuture;

/// Bundle version (e.g. "1.0.0"), read once per launch.
Future<String> _appVersion() {
  return _versionFuture ??= PackageInfo.fromPlatform()
      .then((info) => info.version)
      .catchError((Object e) {
    debugPrint('SettingsTab: version lookup failed: $e');
    return '';
  });
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

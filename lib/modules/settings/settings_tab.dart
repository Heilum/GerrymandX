import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gerrymanderx/core/constants/app_constants.dart';
import 'package:gerrymanderx/providers/app_settings_store.dart';

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

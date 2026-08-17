import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gerrymanderx/core/constants/app_constants.dart';

/// Renders the bundled `assets/help/help.md` user guide.
class HelpTab extends StatelessWidget {
  const HelpTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: FutureBuilder<String>(
        future: DefaultAssetBundle.of(context)
            .loadString(AppConstants.helpAssetPath),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return const Center(child: Text('Failed to load help content.'));
          }
          return Markdown(
            data: snapshot.data!,
            selectable: true,
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            onTapLink: (text, href, title) {
              if (href != null) launchUrl(Uri.parse(href));
            },
          );
        },
      ),
    );
  }
}

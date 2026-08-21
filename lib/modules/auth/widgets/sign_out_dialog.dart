import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:gerrymanderx/core/constants/app_constants.dart';
import 'package:gerrymanderx/providers/auth_store.dart';

/// Confirms before ending the session. Sign-out sits one click away in the
/// side menu, and getting back in means another round trip through the
/// provider, so it is worth a question first.
///
/// Pass a [context] that outlives the menu the tap came from — the menu
/// overlay is gone by the time this runs.
Future<void> confirmSignOut(BuildContext context) async {
  final auth = context.read<AuthStore>();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Sign out?'),
      content: Text(
        'You will need to sign in again to use ${AppConstants.appName}.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  if (confirmed == true) await auth.signOut();
}

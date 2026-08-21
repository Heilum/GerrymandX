import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:gerrymanderx/core/constants/app_constants.dart';
import 'package:gerrymanderx/modules/auth/sign_in_page.dart';
import 'package:gerrymanderx/modules/main_shell.dart';
import 'package:gerrymanderx/providers/auth_store.dart';

/// Decides what the app shows at all: the shell is only ever built for a
/// signed-in user, so no screen below it has to handle a null account.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    if (auth.isRestoring) return const _RestoringSession();
    return auth.isSignedIn ? const MainShell() : const SignInPage();
  }
}

/// Shown for the moment it takes Firebase to read the persisted session, so a
/// returning user never sees the sign-in screen flash past.
class _RestoringSession extends StatelessWidget {
  const _RestoringSession();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppConstants.appName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

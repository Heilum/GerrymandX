import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gerrymanderx/core/constants/app_constants.dart';
import 'package:gerrymanderx/providers/auth_store.dart';

/// The only screen an unregistered user can reach. Signing in with either
/// provider creates the account on first use — there is no separate sign-up.
class SignInPage extends StatelessWidget {
  const SignInPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.how_to_vote,
                    size: 44,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppConstants.appName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in to explore election results precinct by precinct.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  _GoogleButton(
                    onPressed: auth.isBusy ? null : auth.signInWithGoogle,
                  ),
                  if (AppConstants.appleSignInEnabled) ...[
                    const SizedBox(height: 12),
                    SignInWithAppleButton(
                      onPressed: auth.isBusy ? () {} : auth.signInWithApple,
                      style: theme.brightness == Brightness.dark
                          ? SignInWithAppleButtonStyle.white
                          : SignInWithAppleButtonStyle.black,
                      iconAlignment: SignInWithAppleIconAlignment.left,
                    ),
                  ],
                  SizedBox(
                    height: 36,
                    child: Center(
                      child: auth.isBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : auth.error == null
                          ? null
                          : Text(
                              auth.error!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        launchUrl(Uri.parse(AppConstants.privacyPolicyUrl)),
                    child: Text(
                      'Privacy Policy',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sized to match [SignInWithAppleButton] so the two stack evenly.
class _GoogleButton extends StatelessWidget {
  final VoidCallback? onPressed;
  const _GoogleButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.g_mobiledata, size: 26),
        label: const Text('Sign in with Google'),
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

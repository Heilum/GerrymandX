import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:gerrymanderx/modules/auth/widgets/sign_out_dialog.dart';
import 'package:gerrymanderx/providers/auth_store.dart';

/// Avatar + nickname pinned to the bottom of the side menu.
///
/// Clicking it opens a popup that names the account (nickname, email, which
/// provider it came from) — that identity check is the confirmation step —
/// and only then offers sign-out.
class UserMenuButton extends StatelessWidget {
  const UserMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    if (!auth.isSignedIn) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return MenuAnchor(
      // Open to the right of the rail rather than off the bottom of the window.
      style: const MenuStyle(alignment: Alignment.topRight),
      alignmentOffset: const Offset(6, 0),
      menuChildren: [
        _AccountHeader(auth: auth),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout, size: 18),
          // `context` here is the widget's own, not the menu overlay's: the
          // overlay is disposed before the dialog opens.
          onPressed: auth.isBusy ? null : () => confirmSignOut(context),
          child: const Text('Sign out'),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: auth.displayName,
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UserAvatar(auth: auth, radius: 16),
                const SizedBox(height: 4),
                Text(
                  auth.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Who you are signed in as — the popup's confirmation half.
class _AccountHeader extends StatelessWidget {
  final AuthStore auth;
  const _AccountHeader({required this.auth});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = auth.user?.email;

    return SizedBox(
      width: 260,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            UserAvatar(auth: auth, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    auth.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (email != null && email.isNotEmpty)
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    'Signed in with ${auth.providerName}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Provider photo when there is one — Apple never supplies one, so the
/// initials stand in, and they also cover a photo that fails to load.
class UserAvatar extends StatelessWidget {
  final AuthStore auth;
  final double radius;
  const UserAvatar({super.key, required this.auth, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    final photo = auth.photoUrl;
    final cs = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: cs.secondaryContainer,
      foregroundImage: photo == null ? null : NetworkImage(photo),
      child: Text(
        auth.initials,
        style: TextStyle(
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w600,
          color: cs.onSecondaryContainer,
        ),
      ),
    );
  }
}

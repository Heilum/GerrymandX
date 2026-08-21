import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// The signed-in user, and the only way the app changes who that is.
///
/// Firebase keeps the session in the macOS keychain, so a returning user is
/// already signed in before the first frame; [isRestoring] covers the gap
/// until Firebase reports whether that session exists.
class AuthStore extends ChangeNotifier {
  AuthStore({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance {
    // `userChanges` rather than `authStateChanges`: it also fires for profile
    // edits, which is how the display name we copy off Apple reaches the UI.
    _sub = _auth.userChanges().listen((user) {
      _user = user;
      _restoring = false;
      notifyListeners();
    });
  }

  final FirebaseAuth _auth;
  StreamSubscription<User?>? _sub;

  /// Google's SDK must be initialised once before any other call; kept as a
  /// future so concurrent callers share the same initialisation.
  Future<void>? _googleInit;

  User? _user;
  bool _restoring = true;
  bool _busy = false;
  String? _error;

  User? get user => _user;
  bool get isSignedIn => _user != null;

  /// True until Firebase has reported the persisted session (or its absence).
  bool get isRestoring => _restoring;

  /// True while a sign-in, sign-out or delete is in flight.
  bool get isBusy => _busy;

  /// Last failure, for display on the sign-in screen. Cleared on each attempt.
  String? get error => _error;

  /// Name for the side menu: the provider's name, else the email's local part.
  String get displayName {
    final name = _user?.displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final email = _user?.email;
    if (email != null && email.isNotEmpty) return email.split('@').first;
    return 'Account';
  }

  String? get photoUrl {
    final url = _user?.photoURL;
    return (url == null || url.isEmpty) ? null : url;
  }

  /// Up to two letters for the fallback avatar, e.g. "Jane Roe" -> "JR".
  String get initials {
    final words = displayName.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final letters = words.take(2).map((w) => w.substring(0, 1));
    return letters.join().toUpperCase();
  }

  /// Human-readable provider ("Google" / "Apple"), for the account popup.
  String get providerName {
    final id = _user?.providerData.firstOrNull?.providerId;
    return switch (id) {
      'google.com' => 'Google',
      'apple.com' => 'Apple',
      _ => 'Firebase',
    };
  }

  Future<void> signInWithGoogle() => _run(() async {
    final credential = await _googleCredential();
    if (credential == null) return; // picker dismissed
    await _auth.signInWithCredential(credential);
  });

  Future<void> signInWithApple() => _run(() async {
    final result = await _appleCredential();
    if (result == null) return; // sheet dismissed
    final userCredential = await _auth.signInWithCredential(result.credential);
    // Apple hands over the real name only on the very first authorization.
    // If it is not copied into the Firebase profile now, it is gone for
    // good and the side menu would be left with just an email.
    final user = userCredential.user;
    if (user != null &&
        result.name.isNotEmpty &&
        (user.displayName ?? '').isEmpty) {
      await user.updateDisplayName(result.name);
    }
  });

  Future<void> signOut() => _run(() async {
    try {
      await _ensureGoogleInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      // Not signed in with Google, or its SDK is unavailable — the
      // Firebase sign-out below is what actually ends the session.
      debugPrint('AuthStore: Google sign-out skipped: $e');
    }
    await _auth.signOut();
  });

  /// Deletes the account and its Firebase record (App Store guideline
  /// 5.1.1(v)). Firebase refuses to delete on a stale session, so the user is
  /// sent back through their provider once and the delete is retried.
  Future<void> deleteAccount() => _run(() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await user.delete();
    } on FirebaseAuthException catch (e) {
      if (e.code != 'requires-recent-login') rethrow;
      final credential = await _reauthCredential();
      if (credential == null) return; // re-auth dismissed
      await user.reauthenticateWithCredential(credential);
      await user.delete();
    }
  });

  Future<void> _ensureGoogleInitialized() =>
      _googleInit ??= GoogleSignIn.instance.initialize();

  /// Google credential for Firebase, or null if the user dismissed the picker.
  /// The client id comes from `GoogleService-Info.plist` in the app bundle.
  Future<AuthCredential?> _googleCredential() async {
    await _ensureGoogleInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: const ['email'],
      );
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw StateError('Google returned no ID token');
      }
      return GoogleAuthProvider.credential(idToken: idToken);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Apple credential plus the name Apple only discloses on first authorization.
  /// Null if the user dismissed the sheet.
  Future<({AuthCredential credential, String name})?> _appleCredential() async {
    // The raw nonce goes to Firebase, its SHA-256 to Apple: Firebase rehashes
    // it and rejects the token if the two do not line up (replay protection).
    final rawNonce = generateNonce();
    final AuthorizationCredentialAppleID apple;
    try {
      apple = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      rethrow;
    }
    return (
      credential: OAuthProvider(
        'apple.com',
      ).credential(idToken: apple.identityToken, rawNonce: rawNonce),
      name: [
        apple.givenName,
        apple.familyName,
      ].whereType<String>().join(' ').trim(),
    );
  }

  /// Fresh credential from whichever provider the account is linked to.
  Future<AuthCredential?> _reauthCredential() async {
    final id = _user?.providerData.firstOrNull?.providerId;
    return switch (id) {
      'google.com' => _googleCredential(),
      'apple.com' => (await _appleCredential())?.credential,
      _ => null,
    };
  }

  /// Runs [action] as the single in-flight auth operation, turning failures
  /// into [error] rather than letting them escape into the widget tree.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      debugPrint('AuthStore: ${e.code} ${e.message}');
      _error = _messageFor(e);
    } catch (e, stack) {
      debugPrint('AuthStore: $e\n$stack');
      _error = 'Sign-in failed. Please check your connection and try again.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  String _messageFor(FirebaseAuthException e) => switch (e.code) {
    'account-exists-with-different-credential' =>
      'That email is already registered with the other sign-in method.',
    'network-request-failed' =>
      'No network connection. Please try again once you are back online.',
    'keychain-error' =>
      'Could not reach the keychain. Enable the Keychain Sharing capability '
          'on the Runner target and relaunch.',
    'user-disabled' => 'This account has been disabled.',
    _ => e.message ?? 'Sign-in failed (${e.code}).',
  };

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

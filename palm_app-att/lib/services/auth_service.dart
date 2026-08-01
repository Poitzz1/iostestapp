import 'package:firebase_auth/firebase_auth.dart';

/// Thrown when an email outside [AuthService.allowedDomain] is used to sign
/// in or register. Kept distinct from [FirebaseAuthException] so callers
/// (and `_friendlyError` in the sign-in screen) can give a precise message
/// without string-matching a Firebase error code.
class DisallowedEmailDomainException implements Exception {
  final String email;
  const DisallowedEmailDomainException(this.email);

  @override
  String toString() =>
      'Only @${AuthService.allowedDomain} college email addresses are allowed.';
}

/// Firebase Authentication (README §3). Students sign in with their college
/// email. The derived student id is used as the enrollment key.
///
/// Enrollment is restricted to college accounts: only emails ending in
/// [allowedDomain] may sign in or register. This is enforced here (so the
/// app never even calls Firebase Auth with a disallowed email) AND in
/// `firestore.rules` (`isAllowedDomain()`) as defense-in-depth — Firebase
/// Auth itself will still create an account for any email/password unless a
/// blocking Cloud Function is deployed, so the Firestore rule is what
/// actually stops a disallowed account from ever reading/writing enrollment
/// data, even if it bypasses this app's UI (e.g. via the Auth REST API
/// directly). If both need to change, change both.
///
/// Registration also requires proving the student actually controls that
/// college inbox: [register] sends a verification email, and
/// `firestore.rules` additionally requires `token.email_verified == true` —
/// the domain check alone only proves the address is *shaped* right, not
/// that this student owns it.
class AuthService {
  static const String allowedDomain = 'citchennai.net';

  final FirebaseAuth _auth;
  AuthService([FirebaseAuth? auth]) : _auth = auth ?? FirebaseAuth.instance;

  Stream<User?> get authState => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  static bool isAllowedEmail(String email) {
    final local = email.trim().toLowerCase();
    return local.endsWith('@$allowedDomain');
  }

  Future<UserCredential> signIn(String email, String password) {
    final trimmed = email.trim();
    if (!isAllowedEmail(trimmed)) {
      throw DisallowedEmailDomainException(trimmed);
    }
    return _auth.signInWithEmailAndPassword(
        email: trimmed, password: password);
  }

  /// Registers the account and immediately sends the verification email —
  /// callers should route to a "verify your email" screen next, not straight
  /// into the app (see [User.emailVerified] / [reloadAndCheckVerified]).
  Future<UserCredential> register(String email, String password) async {
    final trimmed = email.trim();
    if (!isAllowedEmail(trimmed)) {
      throw DisallowedEmailDomainException(trimmed);
    }
    final cred = await _auth.createUserWithEmailAndPassword(
        email: trimmed, password: password);
    await cred.user?.sendEmailVerification();
    return cred;
  }

  Future<void> signOut() => _auth.signOut();

  Future<void> sendVerificationEmail() async {
    await _auth.currentUser?.sendEmailVerification();
  }

  /// Firebase caches `User.emailVerified` from sign-in/registration time — it
  /// does not update itself when the student clicks the link in another tab.
  /// Reload from the server before trusting this value (e.g. when the user
  /// taps "I've verified, continue").
  ///
  /// A reload needs the network. When it fails for that reason we fall back to
  /// the CACHED `emailVerified` rather than propagating: the session on disk is
  /// still valid, and treating an offline moment as "not verified" would strand
  /// a verified user on the verify-email screen — or, if the caller lets the
  /// error escape, on a dead-end error screen that looks exactly like being
  /// signed out. Only a token the server actively rejects is a real failure.
  Future<bool> reloadAndCheckVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
    } on FirebaseAuthException catch (e) {
      // These mean the session itself is gone — Firebase clears it and the
      // caller should route to sign-in.
      const fatal = {
        'user-not-found',
        'user-disabled',
        'user-token-expired',
        'invalid-user-token',
      };
      if (fatal.contains(e.code)) return false;
      return user.emailVerified; // offline / transient — trust the cache
    }
    return _auth.currentUser?.emailVerified ?? false;
  }

  bool get isEmailVerified => _auth.currentUser?.emailVerified ?? false;

  /// Student id derived from the college email local-part, e.g.
  /// "2023cs041@citchennai.net" -> "2023CS041". Override with your
  /// institution's real mapping if the email does not encode the roll number.
  String studentIdFor(User user) {
    final email = user.email ?? user.uid;
    final local = email.split('@').first;
    return local.toUpperCase();
  }
}

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for PalmPay.
///
/// Project: attcit-52e7d
/// Firestore region: asia-south1 (India) — MUST NOT be changed (README §6).
///
/// NOTE: The Android and iOS app IDs below use the web app ID as a fallback.
/// For production, register dedicated Android/iOS apps in Firebase Console and
/// update the appId values with the platform-specific ones.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('PalmPay enrollment app is mobile-only.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for '
          '${defaultTargetPlatform.name}.',
        );
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Firebase project: attcit-52e7d
  // ──────────────────────────────────────────────────────────────────────────

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDy62WRnWC4DvKH9fZtiQQDpBQBDxyIq5g',
    appId: '1:9708266649:web:12155f5a4436433e81c408',
    messagingSenderId: '9708266649',
    projectId: 'attcit-52e7d',
    storageBucket: 'attcit-52e7d.firebasestorage.app',
    authDomain: 'attcit-52e7d.firebaseapp.com',
    databaseURL: 'https://attcit-52e7d.firebaseio.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDy62WRnWC4DvKH9fZtiQQDpBQBDxyIq5g',
    appId: '1:9708266649:web:12155f5a4436433e81c408',
    messagingSenderId: '9708266649',
    projectId: 'attcit-52e7d',
    storageBucket: 'attcit-52e7d.firebasestorage.app',
    authDomain: 'attcit-52e7d.firebaseapp.com',
    databaseURL: 'https://attcit-52e7d.firebaseio.com',
    iosBundleId: 'com.palmpay.palmPayEnroll',
  );
}

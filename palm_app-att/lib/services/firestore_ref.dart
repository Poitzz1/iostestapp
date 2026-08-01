import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

/// The project's Firestore database is literally named `default` — NOT the
/// conventional `(default)`. Every SDK (Flutter, Admin, the firebase CLI)
/// targets `(default)` unless told otherwise, which is why early writes failed
/// with:
///
///   NOT_FOUND: The database (default) does not exist for project attcit-52e7d
///
/// So every Firestore handle in this app must go through here. Do not call
/// `FirebaseFirestore.instance` directly.
///
/// The server side has the same requirement — see `getFirestore("default")` in
/// functions/index.js — and the CLI is pinned via the `"database": "default"`
/// entry in firebase.json.
const String kFirestoreDatabaseId = 'default';

FirebaseFirestore get appFirestore =>
    FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: kFirestoreDatabaseId,
    );

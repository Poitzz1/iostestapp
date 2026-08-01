import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_ref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/student_profile.dart';

/// Local-first persistence for the single `students/{student_id}` profile
/// document (unified spec §8). One document per student — enrollment stores the
/// palm template, the enrolled hand side, roster fields, and the device
/// binding.
///
/// - Writes locally to SharedPreferences immediately (never blocks UI on net).
/// - Upserts to Firestore in the background; retried on connectivity change.
/// - One-tap delete removes local immediately + a tombstone, then deletes the
///   server doc in the background so a deleted profile can't be resurrected by
///   a later read.
class StudentService {
  static const _collection = 'students';
  static const _localKey = 'student_profile_local';
  static const _pendingDeleteKey = 'student_profile_pending_delete';
  static const _networkTimeout = Duration(seconds: 10);

  final FirebaseFirestore _firestore;
  final Connectivity _connectivity;
  SharedPreferences? _prefs;

  StudentService({FirebaseFirestore? firestore, Connectivity? connectivity})
      : _firestore = firestore ?? appFirestore,
        _connectivity = connectivity ?? Connectivity();

  DocumentReference<Map<String, dynamic>> _doc(String id) =>
      _firestore.collection(_collection).doc(id);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ── Save (local-first) ──────────────────────────────────────────────────
  Future<void> saveProfile(StudentProfile profile) async {
    await _clearPendingDelete(profile.studentId);

    final existing = _localProfile();
    final toSave = (existing != null && existing.studentId == profile.studentId)
        ? profile.asUpdateOf(existing)
        : profile;

    await _saveLocal(toSave);

    _doc(toSave.docId)
        .set(toSave.toFirestore(), SetOptions(merge: true))
        .timeout(_networkTimeout)
        .then((_) {
      _saveLocal(toSave.copyWith(synced: true));
      debugPrint('[StudentService] synced ${toSave.docId}');
    }).catchError((e) {
      debugPrint('[StudentService] sync deferred: $e');
    });
  }

  // ── Delete (DPDP §10 — one tap, optimistic) ─────────────────────────────

  /// Erase the student's biometric data.
  ///
  /// This CLEARS the biometric fields rather than deleting the document.
  /// Deleting the whole doc also destroyed `section` / `assigned_classroom` /
  /// `roster_email` — fields the advisor owns and the student cannot re-create
  /// — so a student who deleted their palm silently vanished from their
  /// section's roster and could never take attendance again, even after
  /// re-enrolling (the fresh doc had no section to inherit). DPDP requires
  /// erasing the biometric, not the class membership.
  Future<void> deleteProfile(String studentId) async {
    await _removeLocal();
    await _setPendingDelete(studentId);

    _clearBiometricsRemote(studentId).then((_) {
      _clearPendingDelete(studentId);
      debugPrint('[StudentService] cleared biometrics for $studentId');
    }).catchError((e) {
      debugPrint('[StudentService] biometric clear for $studentId queued: $e');
    });
  }

  /// The server-side erasure: drop the biometric fields, leave everything the
  /// advisor set untouched. `FieldValue.delete()` removes the keys outright so
  /// no stale embedding lingers in the document.
  Future<void> _clearBiometricsRemote(String studentId) {
    return _doc(studentId).update({
      'embedding': FieldValue.delete(),
      'hand_side': FieldValue.delete(),
      'model_version': FieldValue.delete(),
      'consent': false,
      'updated_at': DateTime.now().toIso8601String(),
    }).timeout(_networkTimeout);
  }

  // ── Read ────────────────────────────────────────────────────────────────
  /// Returns the student's profile, or null if not enrolled. Tries Firestore,
  /// falls back to the local cache; never blocks longer than [_networkTimeout].
  Future<StudentProfile?> getProfile(String studentId) async {
    try {
      final connectivity = await _connectivity.checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        return _localProfileFor(studentId);
      }

      // Flush a queued erasure in the background — don't block the read on it.
      unawaited(_processPendingDelete());
      final clearPending = _pendingDelete() == studentId;

      final snap = await _doc(studentId)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(_networkTimeout);

      if (!snap.exists) {
        // Server says no doc. Keep an unsynced local profile (not yet pushed),
        // otherwise clear the cache so a server-side delete propagates here.
        final local = _localProfileFor(studentId);
        if (local != null && !local.synced) return local;
        await _removeLocal();
        return null;
      }

      var remote = StudentProfile.fromFirestore(snap.data()!).copyWith(synced: true);

      // An erasure that hasn't reached the server yet: the doc still carries
      // the old embedding, so present it as already-erased (roster intact)
      // rather than letting the palm appear to come back.
      if (clearPending) {
        final cleared = remote.withoutBiometrics();
        await _saveLocal(cleared);
        return cleared;
      }

      // Don't let a stale server read clobber a newer local write that hasn't
      // synced yet — e.g. a background sync that's still in flight, or one
      // that failed (a security-rule rejection, a network blip). Without this,
      // a foreground refresh right after enrolling could show the pre-enroll
      // (or pre-re-enroll) server state and make the just-captured embedding
      // appear to "disappear". Kick a sync retry now that we know we're online.
      final local = _localProfileFor(studentId);
      if (local != null && !local.synced && local.updatedAt.isAfter(remote.updatedAt)) {
        unawaited(syncPending());
        // Keep the newer local biometric fields, but take the roster fields
        // (section / classroom / device binding) from the server — the student
        // can't write those, so a local value is only ever a stale copy. This
        // is what made "start attendance" report "section not set" right after
        // a re-enrollment.
        final merged = local.withRosterFrom(remote);
        await _saveLocal(merged);
        return merged;
      }

      await _saveLocal(remote);
      return remote;
    } catch (e) {
      debugPrint('[StudentService] read failed, using local: $e');
      return _localProfileFor(studentId);
    }
  }

  Future<int> syncPending() async {
    var done = await _processPendingDelete();
    final local = _localProfile();
    if (local != null && !local.synced) {
      try {
        await _doc(local.docId)
            .set(local.toFirestore(), SetOptions(merge: true))
            .timeout(_networkTimeout);
        await _saveLocal(local.copyWith(synced: true));
        done++;
      } catch (_) {/* retry next time */}
    }
    return done;
  }

  void startAutoSync() {
    _connectivity.onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) syncPending();
    });
  }

  // ── Private ─────────────────────────────────────────────────────────────
  Future<int> _processPendingDelete() async {
    final id = _pendingDelete();
    if (id == null) return 0;
    try {
      // Retries the biometric CLEAR, not a document delete — see deleteProfile.
      await _clearBiometricsRemote(id);
      await _clearPendingDelete(id);
      return 1;
    } catch (e) {
      debugPrint('[StudentService] pending erasure $id still queued: $e');
      return 0;
    }
  }

  Future<void> _saveLocal(StudentProfile profile) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_localKey, profile.encode());
  }

  Future<void> _removeLocal() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_localKey);
  }

  StudentProfile? _localProfile() {
    final raw = _prefs?.getString(_localKey);
    if (raw == null) return null;
    try {
      return StudentProfile.decode(raw);
    } catch (_) {
      return null;
    }
  }

  StudentProfile? _localProfileFor(String studentId) {
    final p = _localProfile();
    return (p != null && p.studentId == studentId) ? p : null;
  }

  String? _pendingDelete() => _prefs?.getString(_pendingDeleteKey);

  Future<void> _setPendingDelete(String id) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_pendingDeleteKey, id);
  }

  Future<void> _clearPendingDelete(String id) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    if (prefs.getString(_pendingDeleteKey) == id) {
      await prefs.remove(_pendingDeleteKey);
    }
  }
}

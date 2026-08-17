import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/hand_detector.dart';
import 'palm_template.dart';

/// Timestamp fields in this collection are written by both this app (always
/// ISO8601 strings) and Cloud Functions (which must also write strings — see
/// the created_at fix in functions/index.js — but a Firestore `Timestamp`
/// could still end up here from a bug or a manual Console edit). Never let a
/// timestamp field of the wrong type crash the whole read.
DateTime? _coerceTimestamp(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is Timestamp) return v.toDate();
  return null;
}

/// One enrollment/profile record per student — the `students/{student_id}`
/// document (unified spec §8).
///
/// Unlike the earlier per-hand design, there is exactly ONE document per
/// student: verification is 1:1 (the student is signed in on their own
/// device), so we only ever need this student's single stored template. The
/// enrolled [handSide] is stored explicitly and gated on before any cosine
/// comparison — the server rejects a probe whose hand side differs.
///
/// Stores ONLY the embedding — never the raw palm image (data minimisation,
/// §10).
class StudentProfile {
  final String studentId;

  // Roster / section fields — used by the advisor session flow and by the
  // server to check a submission's section matches an open session.
  final String? department;
  final String? year;
  final String? section;
  final String? assignedClassroom;

  final HandSide handSide;
  /// LEGACY single template. Kept readable and writable during migration:
  /// 8,000+ students are already enrolled with one, and forcing them all to
  /// re-enrol is not acceptable. New enrolments write [templates] instead.
  final List<double> embedding; // 256 floats, L2-normalized template

  /// MULTI-TEMPLATE enrolment: several vectors captured under different
  /// lighting. Verification takes max(cosine(probe, t)) server-side.
  ///
  /// Empty on a legacy record — [allTemplates] papers over the difference so
  /// no caller has to branch on which era a student enrolled in.
  final List<PalmTemplate> templates;

  /// False when enrolment could not achieve the required lighting spread and
  /// the record was stored anyway. Flagged rather than silently accepted: three
  /// identical templates look like multi-template enrolment while delivering
  /// none of its benefit.
  final bool templateSpreadOk;
  final String modelVersion;

  final bool consent;
  final DateTime consentAt;

  // Device binding (§7): one registered device per student. Populated on
  // enrollment; the server checks a submission's device_id against this.
  final String? boundDeviceId;
  final DateTime? deviceBoundAt;

  /// Illumination the template was ENROLLED under — mean/spread of the luma of
  /// the accepted frames, as the camera's own auto-exposure settled them. See
  /// CaptureIllumination and issue.md: a genuine pair can be rejected purely
  /// for enrolling and verifying under different light, and without this stored
  /// on the template there is nothing to compare a probe against.
  ///
  /// Null on templates enrolled before this was recorded, and on roster-only
  /// documents.
  final Map<String, dynamic>? enrollIllumination;

  /// Pose the template was ENROLLED at — see CapturePose. Out-of-plane tilt is
  /// the largest UNCORRECTED nuisance factor (r=-0.169); the rotation-aligned
  /// crop cancels in-plane rotation but cannot undo foreshortening.
  final Map<String, dynamic>? enrollPose;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Local-first sync bookkeeping (not part of the Firestore document body).
  final bool synced;

  StudentProfile({
    required this.studentId,
    this.department,
    this.year,
    this.section,
    this.assignedClassroom,
    required this.handSide,
    required this.embedding,
    this.templates = const [],
    this.templateSpreadOk = true,
    required this.modelVersion,
    required this.consent,
    required this.consentAt,
    this.boundDeviceId,
    this.deviceBoundAt,
    this.enrollIllumination,
    this.enrollPose,
    required this.createdAt,
    DateTime? updatedAt,
    this.synced = false,
  }) : updatedAt = updatedAt ?? createdAt;

  /// The Firestore document id is just the student id (one doc per student).
  String get docId => studentId;

  /// True once a palm template has actually been captured. A roster-only doc
  /// created by an advisor (section assigned, palm not yet enrolled) has an
  /// empty embedding and reads as not-enrolled.
  bool get isEnrolled => embedding.length == 256 || templates.any((t) => t.isValid);

  /// Every usable template, whichever schema the record uses. A legacy single
  /// `embedding` is presented as a one-element list so callers never branch.
  List<PalmTemplate> get allTemplates => templates.isNotEmpty
      ? templates.where((t) => t.isValid).toList()
      : (embedding.length == 256
          ? [
              PalmTemplate(
                vec: embedding,
                handSide: handSide,
                modelVersion: modelVersion,
                // Pre-telemetry: the lighting it was captured under was never
                // recorded, and null is the honest value.
                enrollLumaMean: null,
                capturedAt: createdAt,
              )
            ]
          : const []);

  int get templateCount => allTemplates.length;

  /// Spread of enrolment lighting across the stored templates. Null when fewer
  /// than two record a luma — which is the normal state for backfilled records.
  double? get templateLumaSpread => PalmTemplate.lumaSpread(allTemplates);

  /// Whether this template was produced by [currentModelVersion].
  ///
  /// v4 changed the embedding space, so a template enrolled under an earlier
  /// model is not comparable to a probe from the current one — scoring it
  /// yields a meaningless number that could land on either side of the
  /// threshold. The server rejects such a comparison outright
  /// (`model_version_mismatch`); the client mirrors that here so the UI can
  /// prompt re-enrollment instead of letting the student walk into a
  /// guaranteed failure at the classroom door.
  bool isUsableWith(String currentModelVersion) =>
      isEnrolled && modelVersion == currentModelVersion;

  Map<String, dynamic> toFirestore() => {
        'student_id': studentId,
        if (department != null) 'department': department,
        if (year != null) 'year': year,
        if (section != null) 'section': section,
        if (assignedClassroom != null) 'assigned_classroom': assignedClassroom,
        'hand_side': handSide.label,
        // Write BOTH shapes during migration. The legacy field keeps an
        // older client (or a rollback) working; the array is what the server
        // prefers.
        if (embedding.isNotEmpty) 'embedding': embedding,
        if (templates.isNotEmpty)
          'embeddings': templates.map((t) => t.toJson()).toList(),
        if (templates.isNotEmpty) 'embedding_count': templates.length,
        if (templates.isNotEmpty) 'template_spread_ok': templateSpreadOk,
        'model_version': modelVersion,
        'consent': consent,
        'consent_at': consentAt.toIso8601String(),
        if (boundDeviceId != null) 'bound_device_id': boundDeviceId,
        if (deviceBoundAt != null) 'device_bound_at': deviceBoundAt!.toIso8601String(),
        if (enrollIllumination != null) 'enroll_illumination': enrollIllumination,
        if (enrollPose != null) 'enroll_pose': enrollPose,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory StudentProfile.fromFirestore(Map<String, dynamic> d) {
    // Tolerate a roster-only doc: an advisor can create students/{id} with a
    // section but no palm yet, so embedding / hand_side / consent / timestamps
    // may all be absent. Those fields are only meaningful once [isEnrolled].
    final created = _coerceTimestamp(d['created_at']) ?? DateTime.now();
    return StudentProfile(
      studentId: d['student_id'] as String,
      department: d['department'] as String?,
      year: d['year'] as String?,
      section: d['section'] as String?,
      assignedClassroom: d['assigned_classroom'] as String?,
      handSide: d['hand_side'] != null
          ? HandSideLabel.fromLabel(d['hand_side'] as String)
          : HandSide.left,
      embedding: (d['embedding'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const [],
      templates: ((d['embeddings'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => PalmTemplate.fromJson(e.cast<String, dynamic>()))
          .where((t) => t.isValid)
          .toList(),
      templateSpreadOk: d['template_spread_ok'] as bool? ?? true,
      modelVersion: d['model_version'] as String? ?? '',
      consent: d['consent'] as bool? ?? false,
      consentAt: _coerceTimestamp(d['consent_at']) ?? created,
      boundDeviceId: d['bound_device_id'] as String?,
      deviceBoundAt: _coerceTimestamp(d['device_bound_at']),
      enrollIllumination:
          (d['enroll_illumination'] as Map?)?.cast<String, dynamic>(),
      enrollPose: (d['enroll_pose'] as Map?)?.cast<String, dynamic>(),
      createdAt: created,
      updatedAt: _coerceTimestamp(d['updated_at']) ?? created,
      synced: true,
    );
  }

  Map<String, dynamic> toLocalJson() => {
        ...toFirestore(),
        'synced': synced,
      };

  factory StudentProfile.fromLocalJson(Map<String, dynamic> d) =>
      StudentProfile.fromFirestore(d).copyWith(synced: d['synced'] as bool? ?? false);

  static StudentProfile fromTemplate({
    required String studentId,
    String? department,
    String? year,
    String? section,
    String? assignedClassroom,
    required HandSide handSide,
    required Float32List template,
    required String modelVersion,
    required DateTime consentAt,
    String? boundDeviceId,
    Map<String, dynamic>? enrollIllumination,
    Map<String, dynamic>? enrollPose,
    List<PalmTemplate> templates = const [],
    bool templateSpreadOk = true,
  }) {
    final now = DateTime.now();
    return StudentProfile(
      studentId: studentId,
      department: department,
      year: year,
      section: section,
      assignedClassroom: assignedClassroom,
      handSide: handSide,
      embedding: List<double>.from(template),
      templates: templates,
      templateSpreadOk: templateSpreadOk,
      modelVersion: modelVersion,
      consent: true,
      consentAt: consentAt,
      boundDeviceId: boundDeviceId,
      deviceBoundAt: boundDeviceId != null ? now : null,
      enrollIllumination: enrollIllumination,
      enrollPose: enrollPose,
      createdAt: now,
      updatedAt: now,
      synced: false,
    );
  }

  /// A re-enrollment: keeps the original [createdAt] and, unless overridden,
  /// the existing device binding; bumps [updatedAt] to now and takes every
  /// other field from this (the freshly captured) value.
  StudentProfile asUpdateOf(StudentProfile previous) => copyWith(
        createdAt: previous.createdAt,
        updatedAt: DateTime.now(),
        boundDeviceId: boundDeviceId ?? previous.boundDeviceId,
        deviceBoundAt: deviceBoundAt ?? previous.deviceBoundAt,
      );

  /// This profile with the biometric data stripped, but the roster record
  /// (section / classroom / identity) intact.
  ///
  /// This is what "delete my palm" produces. Deleting the whole document would
  /// also destroy `section` and `assigned_classroom` — data the ADVISOR owns,
  /// not the student — silently dropping them off the roster so they can no
  /// longer take attendance even after re-enrolling. DPDP requires erasing the
  /// biometric; it does not require erasing class membership.
  StudentProfile withoutBiometrics() => StudentProfile(
        studentId: studentId,
        department: department,
        year: year,
        section: section,
        assignedClassroom: assignedClassroom,
        handSide: handSide,
        // The actual erasure — BOTH shapes must go, or the biometric survives
        // in the array while the record claims to be erased.
        embedding: const [],
        templates: const [],
        modelVersion: '',
        consent: false,
        consentAt: consentAt,
        boundDeviceId: boundDeviceId,
        deviceBoundAt: deviceBoundAt,
        // Describe the template that just got erased — meaningless without it.
        enrollIllumination: null,
        enrollPose: null,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        synced: synced,
      );

  /// Overlay the SERVER's roster fields onto this (local) profile.
  ///
  /// `section`, `assigned_classroom`, `department`, `year` and the device
  /// binding are not student-writable (see firestore.rules) — only an advisor
  /// or a Cloud Function sets them, so the server copy is always authoritative
  /// for them and a locally-cached value can only ever be stale. The local
  /// copy still wins for everything the student DOES own (the embedding,
  /// hand side, consent), which is the whole reason we're preferring local.
  ///
  /// Without this, an unsynced local profile captured before an advisor
  /// assigned the section would keep reporting `section == null` — surfacing
  /// as "your section is not set" on the attendance screen even though
  /// Firestore had the section all along.
  StudentProfile withRosterFrom(StudentProfile server) => copyWith(
        department: server.department,
        year: server.year,
        section: server.section,
        assignedClassroom: server.assignedClassroom,
        boundDeviceId: server.boundDeviceId,
        deviceBoundAt: server.deviceBoundAt,
      );

  StudentProfile copyWith({
    bool? synced,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? boundDeviceId,
    DateTime? deviceBoundAt,
    String? department,
    String? year,
    String? section,
    String? assignedClassroom,
  }) =>
      StudentProfile(
        studentId: studentId,
        department: department ?? this.department,
        year: year ?? this.year,
        section: section ?? this.section,
        assignedClassroom: assignedClassroom ?? this.assignedClassroom,
        handSide: handSide,
        embedding: embedding,
        templates: templates,
        templateSpreadOk: templateSpreadOk,
        modelVersion: modelVersion,
        consent: consent,
        consentAt: consentAt,
        boundDeviceId: boundDeviceId ?? this.boundDeviceId,
        deviceBoundAt: deviceBoundAt ?? this.deviceBoundAt,
        enrollIllumination: enrollIllumination,
        enrollPose: enrollPose,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        synced: synced ?? this.synced,
      );

  String encode() => jsonEncode(toLocalJson());
  static StudentProfile decode(String s) =>
      StudentProfile.fromLocalJson(jsonDecode(s) as Map<String, dynamic>);
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../config/deploy_config.dart';
import '../models/student_profile.dart';
import '../services/attendance_service.dart';
import '../services/auth_service.dart';
import '../services/capture_controller.dart';
import '../services/classroom_service.dart';
import '../services/device_service.dart';
import '../services/liveness_detector.dart';
import '../services/hand_detector.dart';
import '../services/location_service.dart';
import '../services/palm_model_service.dart';
import '../services/parity_test.dart';
import '../services/preprocessing.dart';
import '../services/roster_service.dart';
import '../services/session_service.dart';
import '../services/staff_service.dart';
import '../services/student_service.dart';
import '../services/wifi_scan_service.dart';

// ─── Config ──────────────────────────────────────────────────────────────────

final deployConfigProvider = FutureProvider<DeployConfig>((ref) async {
  return DeployConfig.load();
});

// ─── Auth ────────────────────────────────────────────────────────────────────

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Firebase restores a persisted session from disk ASYNCHRONOUSLY at startup,
/// and `authStateChanges()` emits its first event only once that restore has
/// finished. So the first emission — and nothing before it — is the
/// authoritative answer to "is anyone signed in?".
///
/// Await `authStateProvider.future` for that answer. Do NOT branch on
/// [currentUserProvider] during startup; see the warning on it.
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authState;
});

/// The signed-in user, or null.
///
/// CAUTION: this collapses "still restoring the session" and "signed out" into
/// the same `null`, because `AsyncValue.value` is null while loading. That is
/// fine for a widget (it rebuilds when the stream emits) but WRONG for a
/// one-shot startup decision: reading it before the restore completes reports
/// nobody signed in, and the app routes a perfectly valid session to the
/// sign-in screen. That was why every hot restart appeared to log the user out.
/// For startup routing use `await ref.read(authStateProvider.future)`.
final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authStateProvider).value;
});

/// Current student id (uppercased email local-part), or null if signed out.
final studentIdProvider = Provider<String?>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  return ref.read(authServiceProvider).studentIdFor(user);
});

// ─── Roles (advisor / admin) ─────────────────────────────────────────────────

final staffServiceProvider = Provider<StaffService>((ref) => StaffService());

/// Staff profile for the signed-in user, or null if they're an ordinary
/// student. Drives role-based routing (student vs advisor home).
final staffProfileProvider = FutureProvider<StaffProfile?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  return ref.read(staffServiceProvider).profileFor(user.uid);
});

// ─── Model & Preprocessing ──────────────────────────────────────────────────

final palmModelProvider = FutureProvider<PalmModelService>((ref) async {
  final cfg = await ref.watch(deployConfigProvider.future);
  final model = PalmModelService(cfg);
  await model.load();
  return model;
});

final preprocessorProvider = FutureProvider<PalmPreprocessor>((ref) async {
  final cfg = await ref.watch(deployConfigProvider.future);
  return PalmPreprocessor(cfg);
});

// ─── Capture (shared by enrollment + attendance) ─────────────────────────────

final captureControllerProvider =
    FutureProvider.family<CaptureController, void>((ref, _) async {
  final cfg = await ref.watch(deployConfigProvider.future);
  final model = await ref.watch(palmModelProvider.future);
  final pre = await ref.watch(preprocessorProvider.future);
  final detector = MediaPipeHandDetector();
  await detector.init();

  final ctrl = CaptureController(
    cfg: cfg,
    model: model,
    pre: pre,
    handDetector: detector,
    liveness: const LivenessDetector(),
  );

  ref.onDispose(() {
    ctrl.dispose();
    detector.dispose();
  });

  return ctrl;
});

// ─── Student profile (students/{id}) ─────────────────────────────────────────

final studentServiceProvider = FutureProvider<StudentService>((ref) async {
  final svc = StudentService();
  await svc.init();
  svc.startAutoSync();
  return svc;
});

/// The signed-in student's profile, or null if not enrolled.
final studentProfileProvider = FutureProvider<StudentProfile?>((ref) async {
  final studentId = ref.watch(studentIdProvider);
  if (studentId == null) return null;
  final svc = await ref.watch(studentServiceProvider.future);
  return svc.getProfile(studentId);
});

// ─── Presence services ───────────────────────────────────────────────────────

final deviceServiceProvider = Provider<DeviceService>((ref) => DeviceService());
final wifiScanServiceProvider = Provider<WifiScanService>((ref) => WifiScanService());
final locationServiceProvider = Provider<LocationService>((ref) => LocationService());

// ─── Attendance / sessions / classrooms ──────────────────────────────────────

final attendanceServiceProvider =
    Provider<AttendanceService>((ref) => AttendanceService());
final sessionServiceProvider = Provider<SessionService>((ref) => SessionService());
final classroomServiceProvider =
    Provider<ClassroomService>((ref) => ClassroomService());
final rosterServiceProvider = Provider<RosterService>((ref) => RosterService());

// ─── Parity Test ─────────────────────────────────────────────────────────────

final parityResultProvider = FutureProvider<ParityResult>((ref) async {
  final cfg = await ref.watch(deployConfigProvider.future);
  final model = await ref.watch(palmModelProvider.future);
  final pre = await ref.watch(preprocessorProvider.future);
  final test = ParityTest(cfg: cfg, model: model, pre: pre);
  return test.run();
});

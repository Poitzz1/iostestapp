import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vibration/vibration.dart';

import '../config/app_theme.dart';
import '../models/attendance_session.dart';
import '../models/student_profile.dart';
import '../providers/providers.dart';
import '../services/attendance_service.dart';
import '../services/location_service.dart';
import '../services/wifi_scan_service.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Attendance marking flow (spec §5). The client only gathers evidence and
/// calls the server; the server decides. Steps: confirm enrolled → find an open
/// session → collect Wi-Fi + GPS → capture palm → submit → show the result.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

enum _Step { checking, notEnrolled, noSession, ready, submitting, result, error }

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  _Step _step = _Step.checking;
  StudentProfile? _profile;
  AttendanceSession? _session;
  String _statusLine = '';
  String? _errorMsg;

  /// True when the student IS enrolled but under a superseded palm model, so
  /// the "not enrolled" state can explain that rather than implying they never
  /// enrolled at all.
  bool _staleModel = false;
  AttendanceDecision? _decision;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _step = _Step.checking;
      _statusLine = 'Loading your profile…';
    });
    try {
      // studentProfileProvider is a FutureProvider — it fetches once and
      // caches. Without invalidating first, re-enrolling (or an advisor
      // assigning a section) while this provider's stale result is still
      // cached shows the pre-update profile here — e.g. "your section is not
      // set" even though Firestore already has it. Same fix as
      // AdvisorHomeScreen._load() for staffProfileProvider.
      ref.invalidate(studentProfileProvider);
      final profile = await ref.read(studentProfileProvider.future);
      // A template from an older model is unusable — the server would reject
      // it with model_version_mismatch — so route to re-enrollment here rather
      // than letting the student scan and fail at the classroom door.
      final cfg = await ref.read(deployConfigProvider.future);
      if (profile == null || !profile.isUsableWith(cfg.modelVersion)) {
        setState(() {
          _step = _Step.notEnrolled;
          _staleModel = profile != null && profile.isEnrolled;
        });
        return;
      }
      _profile = profile;

      final section = profile.section;
      if (section == null || section.isEmpty) {
        setState(() {
          _step = _Step.error;
          _errorMsg = 'Your section is not set on your profile. Contact your advisor.';
        });
        return;
      }

      setState(() => _statusLine = 'Checking for an open session…');
      final session = await ref.read(attendanceServiceProvider).openSessionFor(section);
      if (session == null) {
        setState(() => _step = _Step.noSession);
        return;
      }
      _session = session;
      setState(() => _step = _Step.ready);
    } catch (e) {
      setState(() {
        _step = _Step.error;
        _errorMsg = e.toString();
      });
    }
  }

  Future<void> _submitFlow() async {
    final profile = _profile!;
    final session = _session!;
    setState(() {
      _step = _Step.submitting;
      _statusLine = 'Scanning Wi-Fi to confirm you\'re in class…';
    });

    // 1. Wi-Fi (primary presence signal) — surface specific fixes on failure.
    final wifi = await ref.read(wifiScanServiceProvider).scan();
    if (!wifi.ok) {
      setState(() {
        _step = _Step.error;
        _errorMsg = switch (wifi.failure!) {
          WifiScanFailure.locationServiceOff =>
            'Turn on Location so we can confirm you\'re in the classroom (Wi-Fi scanning needs it).',
          WifiScanFailure.permissionDenied =>
            'Location permission is needed to read Wi-Fi. Enable it in settings.',
          WifiScanFailure.unsupported =>
            'Wi-Fi scanning isn\'t supported on this device.',
          // Reached when the scan returned NO networks at all — which is not
          // a "wrong room" situation, so the message must not imply one. In
          // practice it is almost always the system Location toggle (Android
          // returns zero BSSIDs while it is off, even with permission granted).
          WifiScanFailure.cannotScan =>
            'Couldn\'t see any Wi-Fi networks. Check that both Wi-Fi AND '
                'Location are switched on, then try again. If you have just '
                'retried several times, wait about two minutes — Android '
                'limits an app to 4 Wi-Fi scans every 2 minutes.',
        };
      });
      return;
    }

    // 2. GPS (coarse campus sanity check + mock-location risk flag).
    setState(() => _statusLine = 'Checking location…');
    final loc = await ref.read(locationServiceProvider).current();
    // GPS failure is non-fatal here — the server treats GPS as a coarse check;
    // Wi-Fi is what actually gates. Pass whatever we have.
    final GpsReading? gps = loc.reading;

    // 3. Nonce (replay protection).
    setState(() => _statusLine = 'Preparing secure submission…');
    final String nonce;
    final String deviceId;
    try {
      nonce = await ref.read(attendanceServiceProvider).requestNonce();
      deviceId = await ref.read(deviceServiceProvider).deviceId();
    } catch (e) {
      setState(() {
        _step = _Step.error;
        _errorMsg = 'Could not reach the attendance server. Check your connection.';
      });
      return;
    }

    // 4. Palm capture — reuse the shared capture screen in attendance mode.
    if (!mounted) return;
    // Capture returns the probe vector AND the illumination it was taken
    // under; the latter rides along to the server so a low score can later be
    // correlated with a lighting difference instead of guessed at (issue.md).
    final captured = await Navigator.of(context).pushNamed<Object?>(
      '/capture',
      arguments: {'mode': 'attendance', 'handSide': profile.handSide},
    );
    if (captured is! Map) {
      // User backed out of capture.
      setState(() => _step = _Step.ready);
      return;
    }
    final template = captured['template'];
    if (template is! Float32List) {
      setState(() => _step = _Step.ready);
      return;
    }
    final probeIllumination =
        (captured['illumination'] as Map?)?.cast<String, dynamic>();
    final probePose = (captured['pose'] as Map?)?.cast<String, dynamic>();

    // 5. Submit — the server decides.
    setState(() {
      _step = _Step.submitting;
      _statusLine = 'Verifying…';
    });
    try {
      final decision = await ref.read(attendanceServiceProvider).submit(
            sessionId: session.sessionId,
            nonce: nonce,
            probeEmbedding: template,
            handSide: profile.handSide,
            wifi: wifi.aps,
            gps: gps,
            isMockLocation: gps?.isMock ?? false,
            deviceId: deviceId,
            illumination: probeIllumination,
            pose: probePose,
          );
      if (!mounted) return;
      _decision = decision;
      setState(() => _step = _Step.result);
      if (decision.isPresent) {
        Vibration.hasVibrator().then((h) {
          if (h == true) Vibration.vibrate(duration: 80, amplitude: 128);
        });
      }
    } catch (e) {
      setState(() {
        _step = _Step.error;
        _errorMsg = 'Submission failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Mark Attendance'),
      ),
      extendBodyBehindAppBar: true,
      body: ParticleBackground(
        particleCount: 25,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.spacingLg),
            child: Center(child: _body()),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_step) {
      case _Step.checking:
      case _Step.submitting:
        return _busy(_statusLine);
      case _Step.notEnrolled:
        return _message(
          Icons.fingerprint,
          _staleModel ? 'Re-enrollment needed' : 'Not enrolled',
          _staleModel
              ? 'The palm recognition model has been updated. Your previous '
                  'scan was made with the older model and can no longer be '
                  'matched, so please enroll your palm again.'
              : 'You need to enroll your palm before marking attendance.',
          actionLabel: _staleModel ? 'Re-enroll now' : 'Enroll now',
          onAction: () => Navigator.of(context).pushReplacementNamed('/consent'),
        );
      case _Step.noSession:
        return _message(
          Icons.schedule,
          'Attendance not open',
          "Attendance isn't open yet for your section. Try again when your advisor opens it.",
          actionLabel: 'Check again',
          onAction: _bootstrap,
        );
      case _Step.ready:
        return _ready();
      case _Step.error:
        return _message(Icons.error_outline, 'Cannot continue',
            _errorMsg ?? 'Something went wrong.',
            actionLabel: 'Retry', onAction: _bootstrap, danger: true);
      case _Step.result:
        return _result();
    }
  }

  Widget _busy(String line) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppTheme.accentCyan),
          const SizedBox(height: AppTheme.spacingLg),
          Text(line, style: AppTheme.bodyMedium, textAlign: TextAlign.center),
        ],
      );

  Widget _ready() {
    final room = _session?.classroomId ?? _profile?.assignedClassroom ?? '—';
    return GlassmorphicCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on_outlined, color: AppTheme.accentCyan, size: 40),
          const SizedBox(height: AppTheme.spacingMd),
          Text('Session open', style: AppTheme.headlineLarge),
          const SizedBox(height: 6),
          Text('Classroom $room', style: AppTheme.bodyMedium),
          const SizedBox(height: 4),
          Text('We\'ll confirm Wi-Fi, location, then scan your palm.',
              style: AppTheme.bodySmall, textAlign: TextAlign.center),
          const SizedBox(height: AppTheme.spacingLg),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _submitFlow,
              icon: const Icon(Icons.front_hand_outlined),
              label: const Text('Scan palm & submit'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentCyan,
                foregroundColor: AppTheme.backgroundDark,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn();
  }

  Widget _result() {
    final d = _decision!;
    final ok = d.isPresent;
    return GlassmorphicCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.cancel_outlined,
              color: ok ? AppTheme.successGreen : AppTheme.errorRed, size: 56),
          const SizedBox(height: AppTheme.spacingMd),
          Text(ok ? 'Present' : 'Not marked',
              style: AppTheme.displayMedium.copyWith(
                  color: ok ? AppTheme.successGreen : AppTheme.errorRed)),
          const SizedBox(height: AppTheme.spacingSm),
          Text(d.message, style: AppTheme.bodyMedium, textAlign: TextAlign.center),
          if (d.palmScore != null) ...[
            const SizedBox(height: AppTheme.spacingSm),
            Text('Palm match: ${d.palmScore!.toStringAsFixed(3)}',
                style: AppTheme.bodySmall),
          ],
          const SizedBox(height: AppTheme.spacingLg),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
          if (!ok)
            TextButton(onPressed: _bootstrap, child: const Text('Try again')),
        ],
      ),
    ).animate().fadeIn();
  }

  Widget _message(IconData icon, String title, String body,
      {String? actionLabel, VoidCallback? onAction, bool danger = false}) {
    return GlassmorphicCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: danger ? AppTheme.errorRed : AppTheme.accentCyan, size: 48),
          const SizedBox(height: AppTheme.spacingMd),
          Text(title, style: AppTheme.headlineLarge, textAlign: TextAlign.center),
          const SizedBox(height: AppTheme.spacingSm),
          Text(body, style: AppTheme.bodyMedium, textAlign: TextAlign.center),
          if (actionLabel != null) ...[
            const SizedBox(height: AppTheme.spacingLg),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: onAction, child: Text(actionLabel)),
            ),
          ],
        ],
      ),
    ).animate().fadeIn();
  }
}

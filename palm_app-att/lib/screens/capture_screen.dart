import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import '../config/app_theme.dart';
import '../providers/providers.dart';
import '../services/capture_controller.dart' as cap;
import '../services/hand_detector.dart';
import '../services/quality_gate.dart';
import '../widgets/quality_feedback_overlay.dart';
import '../widgets/scan_ring_painter.dart';

/// Real camera capture screen.
///
/// Streams live CameraImage frames through the existing pipeline:
///   camera frame → QualityGate → HandDetector → PalmPreprocessor → ONNX model
///
/// Features:
/// - Full-screen camera preview with animated scan ring overlay
/// - Real-time quality feedback messages
/// - Frame-by-frame progress dots with pulse + haptic on acceptance
/// - Auto-completes when maxFrames captured
/// - No placeholders: uses the real device camera and real ONNX inference.
class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen>
    with TickerProviderStateMixin {
  CameraController? _camera;
  cap.CaptureController? _captureCtrl;
  StreamSubscription<cap.CaptureProgress>? _progressSub;
  bool _navigating = false;

  late final AnimationController _ringRotation;
  late final AnimationController _pulse;

  /// Built ONCE. `Listenable.merge([...])` allocates a new object every call,
  /// so creating it inline in build() made AnimatedBuilder detach and
  /// re-attach its listeners on every single progress event — pure overhead
  /// on the frame path, several times a second.
  late final Listenable _ringRepaint;

  cap.CaptureProgress _progress = const cap.CaptureProgress(
    phase: cap.CapturePhase.idle,
    goodFrames: 0,
    targetFrames: 8,
    pass: 1,
    totalPasses: 4,
    message: 'Initializing camera…',
  );

  bool _permissionDenied = false;
  bool _initializing = true;

  /// Route arguments, read ONCE in didChangeDependencies.
  ///
  /// `ModalRoute.of(context)` is not a plain lookup — it calls
  /// `dependOnInheritedWidgetOfExactType<_ModalScopeStatus>()`, which
  /// REGISTERS this element as a dependent of that InheritedWidget. Doing that
  /// from an async gap or a post-frame callback (i.e. outside build /
  /// didChangeDependencies) can register a dependency on an InheritedElement
  /// that is already being torn down by the very navigation we're performing —
  /// which trips `InheritedElement.debugDeactivated()`'s
  /// `assert(_dependents.isEmpty)` and shows as the red screen after capture.
  /// didChangeDependencies is the one place the framework guarantees is safe
  /// for this, so we read there and cache.
  Map? _routeArgs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeArgs ??= ModalRoute.of(context)?.settings.arguments as Map?;
  }

  @override
  void initState() {
    super.initState();
    _ringRotation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _ringRepaint = Listenable.merge([_ringRotation, _pulse]);
    _initCamera();
  }

  Future<void> _initCamera() async {
    // Request camera permission
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _permissionDenied = true;
        _initializing = false;
      });
      return;
    }

    try {
      // Get available cameras — use back camera (better for palm capture)
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _progress = _progress.copyWith(
            phase: cap.CapturePhase.error,
            message: 'No camera available',
            error: 'No camera found on device',
          );
        });
        return;
      }

      // Prefer back camera
      final cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // Create camera controller
      _camera = CameraController(
        cam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _camera!.initialize();

      // Get capture controller from providers
      _captureCtrl = await ref.read(captureControllerProvider(null).future);

      // Listen to capture progress
      _progressSub = _captureCtrl!.progress.listen(_onProgress);

      // Start capture engine
      // Enrollment builds the template every future scan is compared against,
      // so it takes 4 passes to average out pose and lighting. Attendance runs
      // every day and only has to clear a threshold — 2 passes (16 frames)
      // keeps probe variance low without making the student hold still four
      // times at the classroom door. (Was 1; with the genuine-score margin
      // over the threshold as thin as it is, the extra pass of averaging is
      // cheap insurance against false rejects.)
      // Modes: 'enroll' (student, 4 passes), 'attendance' (student probe),
      // 'staff-enroll' (staff template), 'staff-open' (staff probe to open a
      // session). Staff use the SAME pipeline as students — same quality
      // gates, same multi-frame average, same model-version gate — because a
      // second capture path would be a second thing to keep correct.
      final mode = (_routeArgs?['mode'] as String?) ?? 'enroll';
      final isProbe = mode == 'attendance' || mode == 'staff-open';
      final isAttendance = isProbe;
      _captureCtrl!.start(
        sensorOrientation: cam.sensorOrientation,
        passes: isProbe ? 2 : 4,
        // Enrollment varies (and VERIFIES) the pose across passes so the
        // template generalises; attendance holds one pose — the probe needs
        // to match the template, not add diversity to it.
        // Pose AND lighting variation are for the STUDENT enrolment only —
        // they build a template that generalises. A probe must MATCH the
        // template, so attendance and staff opening hold one pose.
        varyPose: mode == 'enroll',
      );

      // Start streaming frames to capture controller
      await _camera!.startImageStream((CameraImage frame) {
        _captureCtrl?.onFrame(frame);
      });

      setState(() => _initializing = false);
    } catch (e) {
      setState(() {
        _initializing = false;
        _progress = _progress.copyWith(
          phase: cap.CapturePhase.error,
          message: 'Camera error',
          error: e.toString(),
        );
      });
    }
  }

  /// Illumination the finished capture was taken under.
  ///
  /// MEASURED, not controlled. The app deliberately does not drive exposure —
  /// see the note in QualityGate. These numbers describe whatever the camera's
  /// own auto-exposure settled on, which is exactly what makes them worth
  /// recording: they are an observation of the real operating condition rather
  /// than of something the app forced.
  Map<String, dynamic> _illuminationPayload() {
    final ill = _captureCtrl?.illumination ?? cap.CaptureIllumination.empty;
    return ill.toJson();
  }

  /// Pose the finished capture was taken at — see [cap.CapturePose]. Recorded
  /// alongside illumination because out-of-plane tilt is the second-largest
  /// measured nuisance factor (r=-0.169) and, unlike in-plane rotation, nothing
  /// in the pipeline corrects it.
  Map<String, dynamic> _posePayload() {
    final pose = _captureCtrl?.pose ?? cap.CapturePose.empty;
    return pose.toJson();
  }

  void _onProgress(cap.CaptureProgress p) {
    if (!mounted) return;
    setState(() => _progress = p);


    // Haptic + pulse on accepted frame. A completed pass gets a longer,
    // stronger buzz so it reads as distinct from a single accepted frame.
    if (p.justAcceptedFrame) {
      _pulse.forward(from: 0);
      Vibration.hasVibrator().then((has) {
        if (has == true) {
          Vibration.vibrate(
            duration: p.passComplete ? 90 : 30,
            amplitude: p.passComplete ? 160 : 64,
          );
        }
      });
    }

    // Navigate on completion. Guard against firing twice — a second
    // Navigator call on an already-navigating-away context is exactly what
    // trips Flutter's "_dependents.isEmpty" assertion.
    if (p.phase == cap.CapturePhase.done &&
        _captureCtrl!.hasEnough &&
        !_navigating) {
      _navigating = true;
      _onCaptureDone();
    }
  }

  Future<void> _onCaptureDone() async {
    if (!mounted) return;

    // Everything that touches an InheritedWidget is resolved HERE, before any
    // await — `Navigator.of` and the route args both walk the element tree and
    // (for ModalRoute) register a dependency. Capturing the NavigatorState now
    // means the later navigation needs no BuildContext at all, so nothing can
    // register a dependency on a route that is already tearing down.
    final navigator = Navigator.of(context);
    final args = _routeArgs;
    if (args == null) return;
    final mode = (args['mode'] as String?) ?? 'enroll';
    final handSide = args['handSide'] as HandSide;

    // Build the averaged, L2-normalized template (spec §3 — same routine for
    // enrollment and attendance; only what happens to the vector differs).
    final template = _captureCtrl!.buildTemplate();

    // Illumination this vector was captured under, carried alongside it. See
    // CaptureIllumination — without this a rejected genuine scan leaves no
    // record of the one variable most likely to have caused it.
    final illumination = _illuminationPayload();
    final pose = _posePayload();

    // The user's explicit selection is authoritative for identity; the
    // detector's handedness is logged only for diagnostics.
    final detectedSide = _captureCtrl!.autoDetectedSide;
    if (detectedSide != null && detectedSide != handSide) {
      debugPrint('capture: detector saw ${detectedSide.label} palm but user '
          'selected ${handSide.label} — keeping user selection');
    }

    // Stop the frame stream before navigating so no further progress events
    // (and no further setState) can land while the route is being replaced.
    _progressSub?.cancel();
    _progressSub = null;
    _captureCtrl?.stop();
    try {
      await _camera?.stopImageStream();
    } catch (_) {}

    // Brief beat so the final "Captured" state is visible.
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    // Every probe/enrol flow other than the student's own enrolment simply
    // hands the vector back to whoever pushed this screen.
    if (mode == 'attendance' ||
        mode == 'staff-open' ||
        mode == 'staff-enroll') {
      navigator.pop({
        'template': template,
        'illumination': illumination,
        'pose': pose,
        'handSide': handSide,
      });
      return;
    }

    final consentAt = args['consentAt'] as DateTime;
    navigator.pushReplacementNamed('/success', arguments: {
      'template': template,
      'handSide': handSide,
      'consentAt': consentAt,
      'illumination': illumination,
      'pose': pose,
      // MULTI-TEMPLATE: the per-pass vectors kept SEPARATE, each with the
      // lighting it was captured under. Averaging them into one blurred
      // template is what the max()-scoring change exists to avoid.
      'passTemplates': _captureCtrl!.passTemplates,
      'lightingSpread': _captureCtrl!.lightingSpread,
      'lightingSpreadOk': _captureCtrl!.lightingSpreadOk,
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _ringRotation.dispose();
    _pulse.dispose();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) {
      return _buildPermissionDenied();
    }

    if (_initializing) {
      return _buildLoading();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          if (_camera != null && _camera!.value.isInitialized)
            ClipRect(
              child: OverflowBox(
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _camera!.value.previewSize?.height ?? 0,
                    height: _camera!.value.previewSize?.width ?? 0,
                    child: CameraPreview(_camera!),
                  ),
                ),
              ),
            ),

          // Dark overlay outside scan area
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.6),
                ],
                stops: const [0.35, 0.85],
              ),
            ),
          ),

          // Animated scan ring. RepaintBoundary keeps the continuously
          // repainting ring from forcing the camera preview underneath it to
          // repaint too.
          Center(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _ringRepaint,
                builder: (context, _) {
                  return CustomPaint(
                    size: Size(
                      MediaQuery.of(context).size.width,
                      MediaQuery.of(context).size.width,
                    ),
                    painter: ScanRingPainter(
                      progress: _progress.ratio,
                      pulseValue: _pulse.value,
                      rotationAngle: _ringRotation.value * math.pi * 2 * 0.1,
                      isActive: _progress.phase == cap.CapturePhase.capturing,
                    ),
                  );
                },
              ),
            ),
          ),

          // Top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.spacingMd),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: _navigating
                          ? null
                          : () {
                              _navigating = true;
                              Navigator.of(context).pop();
                            },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, color: Colors.white),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusXl),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Only meaningful when there's more than one pass —
                          // "Pass 1 / 1" on the attendance scan is just noise.
                          if (_progress.totalPasses > 1)
                            Text(
                              'Pass ${_progress.pass} / ${_progress.totalPasses}',
                              style: AppTheme.labelSmall.copyWith(
                                color: AppTheme.accentCyan.withOpacity(0.8),
                              ),
                            ),
                          Text(
                            '${_progress.goodFrames} / ${_progress.targetFrames}',
                            style: AppTheme.labelLarge.copyWith(
                              color: AppTheme.accentCyan,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
              .animate()
              .fadeIn(duration: 400.ms),

          // Quality feedback overlay
          QualityFeedbackOverlay(
            report: _progress.lastQuality,
            message: _progress.message,
            goodFrames: _progress.goodFrames,
            targetFrames: _progress.targetFrames,
          ),

          // Center guidance text.
          //
          // Deliberately always mounted, with only its opacity animated. It
          // used to be conditionally inserted on `goodFrames == 0` while
          // carrying an infinitely-repeating flutter_animate ticker — so every
          // time the counter crossed 0 (which now happens at the start of each
          // of the 4 passes) that ticker-owning subtree was torn down and
          // rebuilt mid-stream. Mounting/unmounting a repeating animation on a
          // hot path is exactly the kind of element-lifecycle churn that
          // surfaces as a framework assertion. An AnimatedOpacity changes
          // nothing about the tree shape, so there is nothing to churn.
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: (_progress.phase == cap.CapturePhase.capturing &&
                      _progress.goodFrames == 0)
                  ? 1.0
                  : 0.0,
              duration: const Duration(milliseconds: 400),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 180),
                    Text(
                      'Place your palm\ninside the ring',
                      style: AppTheme.headlineLarge.copyWith(
                        color: Colors.white.withOpacity(0.8),
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: AppTheme.accentCyan,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: AppTheme.spacingLg),
            Text('Preparing camera…', style: AppTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionDenied() {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacingXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.errorRed.withOpacity(0.15),
                ),
                child: const Icon(Icons.camera_alt_outlined,
                    size: 40, color: AppTheme.errorRed),
              ),
              const SizedBox(height: AppTheme.spacingLg),
              Text(
                'Camera Permission Required',
                style: AppTheme.headlineLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppTheme.spacingMd),
              Text(
                'Cit Attendance needs camera access to capture your palm for enrollment. '
                'Please grant camera permission in your device settings.',
                style: AppTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppTheme.spacingXl),
              ElevatedButton.icon(
                onPressed: () => openAppSettings(),
                icon: const Icon(Icons.settings),
                label: const Text('Open Settings'),
              ),
              const SizedBox(height: AppTheme.spacingMd),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

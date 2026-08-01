import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../config/deploy_config.dart';
import 'embedding.dart';
import 'hand_detector.dart';
import 'liveness_detector.dart';
import 'palm_model_service.dart';
import 'preprocessing.dart';
import 'quality_gate.dart';

enum CapturePhase { idle, warming, capturing, done, error }

/// What each enrollment pass asks the student to change, verified by the
/// pose-conformance gate rather than taken on trust.
enum _PoseVariant { baseline, further, closer, tilted }

class CaptureProgress {
  final CapturePhase phase;
  final int goodFrames;
  final int targetFrames;

  /// Which capture pass this is (1-based) and how many make up the full
  /// enrollment. Each pass independently gathers [targetFrames] frames and is
  /// averaged into its own template; the final template is the average of all
  /// passes' templates — repeating the whole capture, not just taking more
  /// frames in one sitting, samples more hand angles/lighting and produces a
  /// cleaner embedding.
  final int pass;
  final int totalPasses;

  final QualityReport? lastQuality;
  final LivenessReport? lastLiveness;
  final String message;
  final bool justAcceptedFrame; // pulse for haptics/animation
  final bool passComplete; // true for the one progress event ending a pass
  final String? error;

  const CaptureProgress({
    required this.phase,
    required this.goodFrames,
    required this.targetFrames,
    this.pass = 1,
    this.totalPasses = 1,
    this.lastQuality,
    this.lastLiveness,
    this.message = '',
    this.justAcceptedFrame = false,
    this.passComplete = false,
    this.error,
  });

  double get ratio => targetFrames == 0 ? 0 : goodFrames / targetFrames;

  CaptureProgress copyWith({
    CapturePhase? phase,
    int? goodFrames,
    int? pass,
    int? totalPasses,
    QualityReport? lastQuality,
    LivenessReport? lastLiveness,
    String? message,
    bool? justAcceptedFrame,
    bool? passComplete,
    String? error,
  }) =>
      CaptureProgress(
        phase: phase ?? this.phase,
        goodFrames: goodFrames ?? this.goodFrames,
        targetFrames: targetFrames,
        pass: pass ?? this.pass,
        totalPasses: totalPasses ?? this.totalPasses,
        lastQuality: lastQuality ?? this.lastQuality,
        lastLiveness: lastLiveness ?? this.lastLiveness,
        message: message ?? this.message,
        justAcceptedFrame: justAcceptedFrame ?? false,
        passComplete: passComplete ?? false,
        error: error ?? this.error,
      );
}

/// Drives the live capture loop over the REAL camera stream:
///
///   camera frame -> quality gate -> liveness checks -> preprocess -> model.embed()
///   -> embedding variance check -> collect 5..8 L2-normalized embeddings
///   -> average + renormalize  ->  ONE PASS template
///
/// Repeated for [totalPasses] passes (default 4), then the per-pass templates
/// (each already an L2-normalized average of 5-8 frames) are themselves
/// averaged + renormalized into the final enrollment template. Passes run
/// back-to-back automatically — the camera stream is never stopped between
/// them, only the frame buffer resets — so the student just keeps holding
/// still through a brief "Pass 2 of 4" message.
///
/// Three-layer liveness detection is integrated into the pipeline:
///  1. Motion liveness (frame differencing for micro-tremor)
///  2. Texture analysis (moiré/print detection)
///  3. Embedding variance (consecutive similarity check)
///
/// Inference is synchronous native work; we throttle: process at most one frame
/// at a time and drop frames that arrive while busy. This keeps the preview at
/// full frame rate (README §5).
class CaptureController {
  final DeployConfig cfg;
  final PalmModelService model;
  final PalmPreprocessor pre;
  final QualityGate gate;
  final HandDetector handDetector;
  final LivenessDetector liveness;

  final int minFrames;
  final int maxFrames;

  /// Default number of passes when [start] isn't given an override.
  final int totalPasses;

  /// Passes for the CURRENT run — set per [start] call.
  ///
  /// Enrollment and attendance want different amounts of work. Enrollment
  /// happens once and the template it produces is compared against forever, so
  /// it takes 4 passes to average out pose/lighting. Attendance happens every
  /// day and only has to clear a threshold, so one pass of [maxFrames] frames
  /// is enough — still a multi-frame average (never a single shot), just
  /// without asking the student to hold still four times at the classroom door.
  int _passesThisRun = 1;
  int get activePasses => _passesThisRun;

  CaptureController({
    required this.cfg,
    required this.model,
    required this.pre,
    required this.handDetector,
    required this.liveness,
    this.gate = const QualityGate(),
    this.minFrames = 5,
    this.maxFrames = 8,
    this.totalPasses = 4,
  });

  final _progress = StreamController<CaptureProgress>.broadcast();
  Stream<CaptureProgress> get progress => _progress.stream;

  // Current pass's frames.
  final List<Float32List> _embeddings = [];
  // One averaged, L2-normalized template per completed pass.
  final List<Float32List> _passTemplates = [];
  int _pass = 1;
  Float32List? _finalTemplate;

  HandSide? _autoDetectedSide;
  HandSide? get autoDetectedSide => _autoDetectedSide;

  // Liveness state: stored between frames for comparison.
  List<int>? _previousLuma;
  Float32List? _previousEmbedding;
  int _frameCount = 0;

  bool _busy = false;
  bool _running = false;
  int _sensorOrientation = 0;

  // Paced acceptance: a stationary, well-lit palm passes every gate on almost
  // every camera tick (~30fps), so without this a whole 8-frame pass lands in
  // well under a second — visually instant, and the frames are so close in
  // time they're near-duplicates of each other rather than genuinely
  // independent samples. Spacing acceptances out both makes progress visible
  // and samples more real micro-variation (tiny hand tremor, lighting
  // flicker) into the average.
  static const _minFrameGap = Duration(milliseconds: 220);
  DateTime? _lastAcceptedAt;

  // Separately, cap how often we run the ANALYSIS pipeline at all. The camera
  // streams ~30fps, and every frame we look at costs a luma scan (quality
  // gate), a MediaPipe platform call, and a texture analysis — on the UI
  // isolate. Doing that 30x/second is what makes the preview stutter. Looking
  // at ~8 frames/second keeps the on-screen feedback responsive while leaving
  // the bulk of each second free for the camera preview to render smoothly.
  static const _minProcessGap = Duration(milliseconds: 120);
  DateTime? _lastProcessedAt;

  // True during the deliberate pause between passes (see the pass-complete
  // branch below) — frames are ignored while this is set so the next pass
  // doesn't silently start capturing while the "Pass complete" message is
  // still on screen.
  bool _pausedBetweenPasses = false;

  /// Prompt shown at the start of each enrollment pass.
  ///
  /// Deliberately asks for a SLIGHTLY DIFFERENT pose each time. Four passes
  /// captured back-to-back with "hold still" produce four near-identical
  /// templates, so the averaged result only represents the one pose and
  /// lighting the student happened to enrol under — which is exactly why a
  /// scan later only matches when they reproduce those conditions. Varying
  /// the pose across passes is what makes the stored template generalise.
  ///
  /// When [varyPose] is false (attendance), passes just repeat the same
  /// hold-still capture — the probe needs to MATCH the template, not add
  /// diversity to it, so asking a student to move mid-scan would only push
  /// their score down.
  static String _passPrompt(int pass, int total, {required bool varyPose}) {
    if (total <= 1 || !varyPose) return 'Center your palm and hold still';
    final hint = switch (_poseVariantFor(pass)) {
      _PoseVariant.baseline => 'hold as you did before',
      _PoseVariant.further => 'move your hand slightly further away',
      _PoseVariant.closer => 'bring your hand a little closer',
      _PoseVariant.tilted => 'tilt your palm very slightly',
    };
    return 'Pass $pass of $total — $hint';
  }

  static _PoseVariant _poseVariantFor(int pass) => switch ((pass - 1) % 4) {
        1 => _PoseVariant.further,
        2 => _PoseVariant.closer,
        3 => _PoseVariant.tilted,
        _ => _PoseVariant.baseline,
      };

  // ── Pose-conformance state (enrollment only, see start(varyPose:)) ────────
  //
  // The prompts above are VERIFIED, not taken on trust: pass 1 records what
  // the student's normal pose measures (palm size in frame = distance proxy,
  // width/height landmark ratio = tilt proxy), and later passes refuse to
  // accept frames until the measured pose actually differs from that baseline
  // in the direction asked for. Without this, a student who ignores the
  // prompt gets 4 identical passes and a template that only matches under the
  // exact enrollment conditions — the failure mode this exists to prevent.
  bool _varyPose = false;
  double? _baselineSize; // mean roi.halfWFrac of accepted pass-1 frames
  double? _baselineRatio; // mean roi.poseRatio of accepted pass-1 frames
  final List<double> _passSizes = [];
  final List<double> _passRatios = [];

  /// How different the measured pose must be from baseline to count as
  /// conforming. 10% on apparent size (~distance), 7% on the tilt ratio —
  /// tolerant enough to reach in a second or two, real enough that "didn't
  /// move at all" never passes.
  static const _sizeDelta = 0.10;
  static const _tiltDelta = 0.07;

  /// Null when the frame's pose satisfies this pass's requirement; otherwise
  /// the corrective hint to show. Fails OPEN when there is nothing to compare
  /// against (no baseline captured, attendance mode, pass 1).
  String? _poseHint(PalmRoi? roi) {
    if (!_varyPose || _pass == 1) return null;
    final base = _baselineSize;
    final baseRatio = _baselineRatio;
    if (base == null || base <= 0) return null; // no baseline — fail open
    if (roi == null) return 'Center your palm'; // can't measure without landmarks
    return switch (_poseVariantFor(_pass)) {
      _PoseVariant.further => roi.halfWFrac <= base * (1 - _sizeDelta)
          ? null
          : 'Move your hand a little further away',
      _PoseVariant.closer => roi.halfWFrac >= base * (1 + _sizeDelta)
          ? null
          : 'Bring your hand a little closer',
      _PoseVariant.tilted => (baseRatio != null &&
              baseRatio > 0 &&
              (roi.poseRatio - baseRatio).abs() >= baseRatio * _tiltDelta)
          ? null
          : 'Tilt your palm slightly — a small angle is enough',
      _PoseVariant.baseline => null,
    };
  }

  /// [passes] overrides [totalPasses] for this run — 4 for enrollment, 2 for
  /// attendance. [varyPose] turns on the enrollment pose prompts AND their
  /// verification (see the pose-conformance block above); attendance leaves it
  /// off because a probe should match the template, not diversify it.
  void start({int sensorOrientation = 0, int? passes, bool varyPose = false}) {
    _passesThisRun = (passes ?? totalPasses).clamp(1, 10);
    _varyPose = varyPose;
    _baselineSize = null;
    _baselineRatio = null;
    _passSizes.clear();
    _passRatios.clear();
    _embeddings.clear();
    _passTemplates.clear();
    _pass = 1;
    _finalTemplate = null;
    _autoDetectedSide = null;
    _previousLuma = null;
    _previousEmbedding = null;
    _frameCount = 0;
    _lastAcceptedAt = null;
    _lastProcessedAt = null;
    _pausedBetweenPasses = false;
    _busy = false;
    _running = true;
    _sensorOrientation = sensorOrientation;
    _emit(CaptureProgress(
      phase: CapturePhase.capturing,
      goodFrames: 0,
      targetFrames: maxFrames,
      pass: _pass,
      totalPasses: _passesThisRun,
      message: 'Center your palm',
    ));
  }

  void stop() => _running = false;

  /// Feed one live frame. Non-blocking: returns immediately, drops frames while
  /// a previous frame is still being embedded, or during the pause between
  /// passes.
  void onFrame(CameraImage frame) {
    if (!_running || _busy || _pausedBetweenPasses) return;
    // Drop frames we don't need to look at — cheapest possible early exit,
    // before any pixel touches the analysis pipeline. See _minProcessGap.
    final now = DateTime.now();
    if (_lastProcessedAt != null && now.difference(_lastProcessedAt!) < _minProcessGap) {
      return;
    }
    _lastProcessedAt = now;
    _busy = true;
    _process(frame).whenComplete(() => _busy = false);
  }

  Future<void> _process(CameraImage frame) async {
    try {
      // ── Step 1: Quality gate ──────────────────────────────────────────────
      final q = gate.evaluate(frame);
      if (!q.passed) {
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          message: q.hint,
        ));
        return;
      }

      // ── Step 2: Hand detection (must be an OPEN palm) ─────────────────────
      final det = await handDetector.detect(frame, rotationDegrees: _sensorOrientation);
      if (!det.present || !det.openPalm) {
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          message: det.present
              ? 'Open your hand — spread your fingers'
              : 'No palm detected',
        ));
        return;
      }
      _autoDetectedSide ??= det.side;

      // ── Step 2.5: Pose conformance (enrollment passes 2+) ─────────────────
      // The pass prompt asked for a specific change (further / closer / tilt);
      // don't accept a single frame until the measured pose actually shows it.
      final poseHint = _poseHint(det.roi);
      if (poseHint != null) {
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          message: poseHint,
        ));
        return;
      }

      // ── Step 3: Liveness — motion check ───────────────────────────────────
      final motionResult = liveness.evaluateMotion(frame, _previousLuma);
      // Store current luma for next frame comparison (before any early return).
      _previousLuma = liveness.copyLuma(frame);
      _frameCount++;

      if (!motionResult.passed && _frameCount > LivenessDetector.warmupFrames) {
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          lastLiveness: motionResult,
          message: motionResult.hint,
        ));
        return;
      }

      // ── Step 4: Liveness — texture analysis ───────────────────────────────
      final textureResult = liveness.evaluateTexture(frame);
      if (!textureResult.passed) {
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          lastLiveness: textureResult,
          message: textureResult.hint,
        ));
        return;
      }

      // ── Step 4.5: Pace acceptance ──────────────────────────────────────────
      // All gates passed, but don't run the (relatively expensive) embed step
      // if we'd just be accepting another frame within _minFrameGap of the
      // last one — see the field doc on _minFrameGap for why this matters.
      final now = DateTime.now();
      if (_lastAcceptedAt != null && now.difference(_lastAcceptedAt!) < _minFrameGap) {
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          message: 'Hold still…',
        ));
        return;
      }

      // ── Step 5: Preprocess + embed ────────────────────────────────────────
      // The palm ROI from THIS frame's detection is passed through: the v4
      // model was trained on landmark-cropped palms, so embedding an
      // uncropped frame would reproduce the exact train/deploy domain gap the
      // v4 retrain was done to remove. `det.roi` is null only when MediaPipe
      // found no hand, in which case the preprocessor falls back to a centre
      // square — the same fallback the training pipeline uses.
      final tensor = pre.fromCameraImage(
        frame,
        rotationDegrees: _sensorOrientation,
        palmRoi: det.roi,
      );
      final emb = model.embed(tensor); // already L2-normalized by the graph

      // ── Step 6: Liveness — embedding variance check ───────────────────────
      final embResult = liveness.evaluateEmbeddingVariance(emb, _previousEmbedding);
      _previousEmbedding = emb; // store for next comparison

      if (!embResult.passed) {
        // Don't add this embedding — it's either static (spoof) or too different.
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          lastLiveness: embResult,
          message: embResult.hint,
        ));
        return;
      }

      // ── All checks passed — accept frame ──────────────────────────────────
      _embeddings.add(emb);
      _lastAcceptedAt = now;
      // Pose samples for this pass — pass 1's mean becomes the baseline the
      // later passes are verified against.
      final roi = det.roi;
      if (_varyPose && roi != null) {
        _passSizes.add(roi.halfWFrac);
        _passRatios.add(roi.poseRatio);
      }

      final passDone = _embeddings.length >= maxFrames;
      if (!passDone) {
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          lastLiveness: embResult,
          message: 'Hold still…',
          justAcceptedFrame: true,
        ));
        return;
      }

      // This pass just finished: fold its frames into one pass template.
      _passTemplates.add(EmbeddingMath.buildTemplate(_embeddings));
      _embeddings.clear();

      // Pass 1 defines the pose baseline that passes 2+ are checked against.
      if (_varyPose && _pass == 1 && _passSizes.isNotEmpty) {
        _baselineSize =
            _passSizes.reduce((a, b) => a + b) / _passSizes.length;
        _baselineRatio =
            _passRatios.reduce((a, b) => a + b) / _passRatios.length;
      }
      _passSizes.clear();
      _passRatios.clear();

      final allPassesDone = _passTemplates.length >= _passesThisRun;
      if (!allPassesDone) {
        final finishedPass = _pass;
        // Pause capture and show a clear "Pass complete" confirmation before
        // starting the next pass — both gives the student a moment to reset
        // their hand position and avoids piling straight into the next pass's
        // frames while this message is still the thing on screen.
        _pausedBetweenPasses = true;
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: maxFrames,
          targetFrames: maxFrames,
          pass: finishedPass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          lastLiveness: embResult,
          message: 'Pass $finishedPass of $_passesThisRun complete ✓',
          justAcceptedFrame: true,
          passComplete: true,
        ));
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (!_running) return; // stopped/disposed during the pause
          _pass = finishedPass + 1;
          _previousLuma = null;
          _previousEmbedding = null;
          _frameCount = 0;
          _lastAcceptedAt = null;
          _pausedBetweenPasses = false;
          _emit(CaptureProgress(
            phase: CapturePhase.capturing,
            goodFrames: 0,
            targetFrames: maxFrames,
            pass: _pass,
            totalPasses: _passesThisRun,
            message: _passPrompt(_pass, _passesThisRun, varyPose: _varyPose),
          ));
        });
        return;
      }

      // All passes done: average the per-pass templates into the final one.
      _finalTemplate = EmbeddingMath.buildTemplate(_passTemplates);
      _emit(CaptureProgress(
        phase: CapturePhase.done,
        goodFrames: maxFrames,
        targetFrames: maxFrames,
        pass: _pass,
        totalPasses: _passesThisRun,
        lastQuality: q,
        lastLiveness: embResult,
        message: 'Captured',
        justAcceptedFrame: true,
        passComplete: true,
      ));
      _running = false;
    } catch (e, st) {
      debugPrint('capture error: $e\n$st');
      _emit(CaptureProgress(
        phase: CapturePhase.error,
        goodFrames: _embeddings.length,
        targetFrames: maxFrames,
        pass: _pass,
        totalPasses: _passesThisRun,
        message: 'Capture error',
        error: e.toString(),
      ));
      _running = false;
    }
  }

  /// True once every pass has completed and the final template is ready.
  bool get hasEnough => _finalTemplate != null;

  /// The final enrollment template: the average of all [totalPasses] pass
  /// templates, each of which is itself the average of that pass's frames.
  Float32List buildTemplate() {
    final t = _finalTemplate;
    if (t == null) {
      throw StateError('buildTemplate() called before all passes completed');
    }
    return t;
  }

  void _emit(CaptureProgress p) {
    if (!_progress.isClosed) _progress.add(p);
  }

  void dispose() {
    _running = false;
    _progress.close();
  }
}

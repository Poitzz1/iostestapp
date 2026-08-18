import 'dart:async';
import 'dart:math' as math;
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

/// Illumination the template/probe was actually captured under.
///
/// Recorded because a genuine pair can be rejected purely for having been
/// enrolled and verified under different lighting — one measured case scored
/// 0.407 against a 0.5508 threshold for the same palm (see issue.md). Nothing
/// in the system could explain that after the fact: attendance records carried
/// GPS, Wi-Fi and device id but no measure of light, and the student document
/// never recorded what the template was enrolled under. So the correlation
/// between "how different was the lighting" and "how far did the score fall"
/// could only ever be reproduced by hand, one attempt at a time.
///
/// These stats are taken over the frames that were ACCEPTED — the ones actually
/// averaged into the vector — not every frame the camera produced, so they
/// describe the image the model really saw.
class CaptureIllumination {
  /// How many accepted frames these statistics summarise.
  final int frames;

  /// Mean luma (0..255) across accepted frames, and its spread. A large [std]
  /// means the lighting moved DURING capture, which is its own problem: the
  /// template is then an average over conditions rather than a record of one.
  final double lumaMean;
  final double lumaStd;
  final double lumaMin;
  final double lumaMax;

  /// Mean fraction of near-saturated pixels — glare, which this model family
  /// degrades under far more than it does under simple darkening.
  final double blowoutMean;

  const CaptureIllumination({
    required this.frames,
    required this.lumaMean,
    required this.lumaStd,
    required this.lumaMin,
    required this.lumaMax,
    required this.blowoutMean,
  });

  static const empty = CaptureIllumination(
    frames: 0,
    lumaMean: 0,
    lumaStd: 0,
    lumaMin: 0,
    lumaMax: 0,
    blowoutMean: 0,
  );

  double _r(double v) => (v * 1000).roundToDouble() / 1000;

  Map<String, dynamic> toJson() => {
        'frames': frames,
        'luma_mean': _r(lumaMean),
        'luma_std': _r(lumaStd),
        'luma_min': _r(lumaMin),
        'luma_max': _r(lumaMax),
        'blowout_mean': _r(blowoutMean),
      };
}

/// Pose the template/probe was actually captured at.
///
/// The companion to [CaptureIllumination], and recorded for the same reason:
/// a genuine pair can be pushed down purely by HOW the palm was presented, and
/// until this was logged there was no way to tell that apart from a bad match.
///
/// v5's own diagnostic (3,210 real comparisons) ranked the two geometric
/// nuisance factors: in-plane rotation r=-0.322, out-of-plane tilt r=-0.169.
/// The rotation-aligned crop CANCELS the first. Nothing cancels the second —
/// a crop cannot undo foreshortening. Field observation: same palm, same
/// lighting, phone angled up vs down scored 0.607 where same-angle scored
/// 0.800.
///
/// So [poseRatioMean] is the field that matters here. [tiltDegMean] is logged
/// as a CONTROL: v5 should have removed its influence, and if low scores still
/// track it, the rotation alignment is not doing its job.
class CapturePose {
  final int frames;

  /// Palm width / palm height — dist(index_mcp, pinky_mcp) over
  /// dist(wrist, middle_mcp). Foreshortening from out-of-plane tilt squashes
  /// one axis, so this moving is the proxy for "the palm was angled".
  final double poseRatioMean;
  final double poseRatioStd;

  /// In-plane rotation the palm was presented at, degrees from vertical.
  /// Expected to have NO effect on score — see the class doc.
  final double tiltDegMean;
  final double tiltDegStd;

  /// Apparent palm size as a fraction of frame width — a distance proxy.
  final double sizeMean;
  final double sizeStd;

  const CapturePose({
    required this.frames,
    required this.poseRatioMean,
    required this.poseRatioStd,
    required this.tiltDegMean,
    required this.tiltDegStd,
    required this.sizeMean,
    required this.sizeStd,
  });

  static const empty = CapturePose(
    frames: 0,
    poseRatioMean: 0,
    poseRatioStd: 0,
    tiltDegMean: 0,
    tiltDegStd: 0,
    sizeMean: 0,
    sizeStd: 0,
  );

  double _r(double v) => (v * 10000).roundToDouble() / 10000;

  Map<String, dynamic> toJson() => {
        'frames': frames,
        'pose_ratio_mean': _r(poseRatioMean),
        'pose_ratio_std': _r(poseRatioStd),
        'tilt_deg_mean': _r(tiltDegMean),
        'tilt_deg_std': _r(tiltDegStd),
        'size_mean': _r(sizeMean),
        'size_std': _r(sizeStd),
      };
}

/// What each enrollment pass asks the student to change, verified by the
/// pose-conformance gate rather than taken on trust.
enum _PoseVariant { baseline, further, closer, tilted }

/// What each pass asks the student to change about the LIGHT.
///
/// This is the load-bearing half of multi-template enrolment. Storing three
/// templates helps only if they span the person's lighting range: in the
/// offline simulation the groups were built by sorting crops by luma and
/// splitting, so the spread existed by construction. Three passes captured
/// back-to-back in one spot produce three near-identical vectors and zero
/// improvement — the schema change alone does nothing.
///
/// So the student is asked to MOVE, and compliance is checked against the
/// measured accepted-frame luma exactly the way pose conformance already is.
/// The camera is never driven to fake the difference: a torch and an
/// exposure-compensation controller were both tried and reverted (the torch
/// made a palm stop matching itself; the controller deadlocked capture against
/// the blowout gate). The student moves; auto-exposure is left alone.
enum _LightVariant { baseline, brighter, dimmer }

/// Minimum change in mean luma (0-255) that counts as "the student actually
/// moved into different light".
///
/// 18 is deliberately modest. The measured cross-illumination failure in
/// issue.md involved a luma delta of ~27, and the bench showed score changes
/// from deltas of that order — but a classroom often cannot offer more, and an
/// unreachable bar would just train students to fake compliance by waving the
/// phone. Under-spread enrolments are FLAGGED rather than refused (see
/// [lightingSpreadOk]); the alternative is refusing to enrol someone whose room
/// has uniform light, which is worse than enrolling them with a warning.
const double kMinLumaSpread = 18.0;

/// One pass's averaged template plus the lighting it was captured under.
class PassTemplate {
  final Float32List vec;

  /// Null when the pass recorded no accepted-frame luma. Null is meaningful —
  /// it means "unknown", not "dark" — and must not be coerced to 0 anywhere,
  /// or a spread calculation will read it as a huge lighting difference.
  final double? lumaMean;
  final double? lumaStd;

  const PassTemplate({required this.vec, this.lumaMean, this.lumaStd});
}

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

  // Illumination of every ACCEPTED frame, across all passes — see
  // [CaptureIllumination]. Kept as raw samples so the spread can be reported,
  // not just the mean; "lighting changed mid-capture" and "lighting was steady
  // but wrong" are different faults and a mean alone cannot tell them apart.
  final List<double> _acceptedLuma = [];
  final List<double> _acceptedBlowout = [];
  // Pose of every accepted frame — see [CapturePose].
  // Luma of the frames accepted in the CURRENT pass, and one entry per
  // completed pass. These are what turn multi-template enrolment from a schema
  // change into a real improvement: each stored template carries the lighting
  // it was captured under, and the spread across them is checked rather than
  // assumed (see kMinLumaSpread).
  final List<double> _passLuma = [];
  final List<double> _passTemplateLuma = [];
  final List<double> _passTemplateLumaStd = [];

  final List<double> _acceptedPoseRatio = [];
  final List<double> _acceptedTiltDeg = [];
  final List<double> _acceptedSize = [];

  /// Illumination the template was captured under. Valid once frames have been
  /// accepted; [CaptureIllumination.empty] before that.
  CaptureIllumination get illumination {
    if (_acceptedLuma.isEmpty) return CaptureIllumination.empty;
    final n = _acceptedLuma.length;
    final mean = _acceptedLuma.reduce((a, b) => a + b) / n;
    var sq = 0.0;
    for (final v in _acceptedLuma) {
      sq += (v - mean) * (v - mean);
    }
    return CaptureIllumination(
      frames: n,
      lumaMean: mean,
      lumaStd: math.sqrt(sq / n),
      lumaMin: _acceptedLuma.reduce(math.min),
      lumaMax: _acceptedLuma.reduce(math.max),
      blowoutMean: _acceptedBlowout.isEmpty
          ? 0
          : _acceptedBlowout.reduce((a, b) => a + b) / _acceptedBlowout.length,
    );
  }

  /// Pose the template was captured at. See [CapturePose].
  CapturePose get pose {
    if (_acceptedPoseRatio.isEmpty) return CapturePose.empty;
    (double, double) stat(List<double> xs) {
      final m = xs.reduce((a, b) => a + b) / xs.length;
      var sq = 0.0;
      for (final v in xs) {
        sq += (v - m) * (v - m);
      }
      return (m, math.sqrt(sq / xs.length));
    }

    final (pr, prSd) = stat(_acceptedPoseRatio);
    final (td, tdSd) = stat(_acceptedTiltDeg);
    final (sz, szSd) = stat(_acceptedSize);
    return CapturePose(
      frames: _acceptedPoseRatio.length,
      poseRatioMean: pr,
      poseRatioStd: prSd,
      tiltDegMean: td,
      tiltDegStd: tdSd,
      sizeMean: sz,
      sizeStd: szSd,
    );
  }

  // Liveness state: stored between frames for comparison.
  List<int>? _previousLuma;
  Float32List? _previousEmbedding;
  int _frameCount = 0;

  bool _busy = false;
  bool _running = false;
  int _sensorOrientation = 0;

  // ── Timing instrumentation (local-only; see README addon on capture perf) ──
  //
  // Debug-only per-stage timings so a slow/unreliable capture can be diagnosed
  // from real numbers instead of guessing which stage dominates. Nothing here
  // is sent anywhere — it's a debugPrint, stripped from release builds by the
  // kDebugMode check.
  Stopwatch? _sessionClock;
  int _framesSeenThisPass = 0;

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
    final pose = switch (_poseVariantFor(pass)) {
      _PoseVariant.baseline => 'hold as you did before',
      _PoseVariant.further => 'move your hand slightly further away',
      _PoseVariant.closer => 'bring your hand a little closer',
      _PoseVariant.tilted => 'tilt your palm very slightly',
    };
    // The LIGHTING instruction leads, because it is the one that decides
    // whether multi-template enrolment does anything at all.
    final light = switch (_lightVariantFor(pass)) {
      _LightVariant.baseline => null,
      _LightVariant.brighter => 'move toward the window or a brighter spot',
      _LightVariant.dimmer => 'step away from the light, into shade',
    };
    return light == null
        ? 'Pass $pass of $total — $pose'
        : 'Pass $pass of $total — $light, then $pose';
  }

  /// Pass 1 is the baseline; later passes alternate brighter / dimmer so the
  /// stored templates straddle the student's normal lighting rather than all
  /// sitting to one side of it.
  static _LightVariant _lightVariantFor(int pass) => switch ((pass - 1) % 3) {
        1 => _LightVariant.brighter,
        2 => _LightVariant.dimmer,
        _ => _LightVariant.baseline,
      };

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
    _acceptedLuma.clear();
    _acceptedBlowout.clear();
    _acceptedPoseRatio.clear();
    _acceptedTiltDeg.clear();
    _acceptedSize.clear();
    _passLuma.clear();
    _passTemplateLuma.clear();
    _passTemplateLumaStd.clear();
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
    _sessionClock = Stopwatch()..start();
    _framesSeenThisPass = 0;
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
    final frameClock = Stopwatch()..start();
    _framesSeenThisPass++;
    final stageUs = <String, int>{};
    // Time from the previous call to onFrame() reaching us here — the closest
    // proxy this stream-based pipeline has to "camera_frame_acquire_ms" (there
    // is no shutter round-trip to measure; frames arrive continuously from
    // camera.startImageStream).
    try {
      // ── Step 1: Quality gate ──────────────────────────────────────────────
      final gateClock = Stopwatch()..start();
      final q = gate.evaluate(frame);
      stageUs['quality_gate_us'] = gateClock.elapsedMicroseconds;
      if (!q.passed) {
        _logFrame(frameClock, stageUs, 'quality_gate:${q.issue.name}');
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
      final detectClock = Stopwatch()..start();
      final det = await handDetector.detect(frame, rotationDegrees: _sensorOrientation);
      stageUs['hand_detect_us'] = detectClock.elapsedMicroseconds;
      if (!det.present || !det.openPalm) {
        _logFrame(frameClock, stageUs,
            det.present ? 'not_open_palm' : 'no_hand');
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
      // ── Step 2.4: The whole palm must be IN the frame ─────────────────────
      // MediaPipe reports 21 landmarks even when only the fingers are in shot,
      // extrapolating the wrist and knuckles past the edge. Those phantom
      // points are correctly proportioned, so every check above passes, and the
      // crop then centres off-frame and is clipped to a sliver that gets
      // stretched to 224x224 and embedded as a palm.
      //
      // Nothing downstream can detect this. The embedding is well-formed, the
      // cosine score is a normal-looking number — just of the wrong picture.
      // It is what let finger-only frames be captured, and what made one
      // student's scans scatter from 0.21 to 0.86 against their own template.
      // Averaging makes it worse, not better: a few sliver frames poison the
      // whole template, and a poisoned template then mis-scores every honest
      // scan afterwards.
      final roi = det.roi;
      if (roi != null && !roi.isFullyVisible) {
        _logFrame(frameClock, stageUs, 'palm_not_fully_visible');
        _emit(CaptureProgress(
          phase: CapturePhase.capturing,
          goodFrames: _embeddings.length,
          targetFrames: maxFrames,
          pass: _pass,
          totalPasses: _passesThisRun,
          lastQuality: q,
          message: roi.palmPointsInFrame < 7
              ? 'Show your whole palm — move your hand back'
              : 'Move your palm into the ring',
        ));
        return;
      }

      _autoDetectedSide ??= det.side;

      // ── Step 2.5: Pose conformance (enrollment passes 2+) ─────────────────
      // The pass prompt asked for a specific change (further / closer / tilt);
      // don't accept a single frame until the measured pose actually shows it.
      final poseHint = _poseHint(det.roi);
      if (poseHint != null) {
        _logFrame(frameClock, stageUs, 'pose_hint');
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
        _logFrame(frameClock, stageUs, 'liveness_motion:${motionResult.issue.name}');
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
        _logFrame(frameClock, stageUs, 'liveness_texture:${textureResult.issue.name}');
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
        _logFrame(frameClock, stageUs, 'paced_out');
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
      //
      // NOTE: pre.fromCameraImage does YUV->RGB decode, crop, and resize in one
      // call — roi_crop_ms and preprocess_ms (per the addon's instrumentation
      // spec) are not separable without splitting that method, so both are
      // reported together here as preprocess_us.
      final preprocessClock = Stopwatch()..start();
      final tensor = pre.fromCameraImage(
        frame,
        rotationDegrees: _sensorOrientation,
        palmRoi: det.roi,
      );
      stageUs['preprocess_us'] = preprocessClock.elapsedMicroseconds;

      final inferenceClock = Stopwatch()..start();
      // Awaited: the web runtime returns a JS promise, so embed() is async on
      // every target now. `_process` was already an async frame handler.
      final emb = await model.embed(tensor); // already L2-normalized by the graph
      stageUs['inference_us'] = inferenceClock.elapsedMicroseconds;

      // ── Step 6: Liveness — embedding variance check ───────────────────────
      final embResult = liveness.evaluateEmbeddingVariance(emb, _previousEmbedding);
      _previousEmbedding = emb; // store for next comparison

      if (!embResult.passed) {
        // Don't add this embedding — it's either static (spoof) or too different.
        _logFrame(frameClock, stageUs, 'liveness_embedding:${embResult.issue.name}');
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
      _logFrame(frameClock, stageUs, 'accepted');
      _embeddings.add(emb);
      _lastAcceptedAt = now;
      // Illumination of the frames that actually reached the model (see
      // [CaptureIllumination]). Recorded here, at acceptance, so rejected
      // frames cannot skew what we claim the template was captured under.
      _acceptedLuma.add(q.brightness);
      _acceptedBlowout.add(q.blowoutFraction);
      _passLuma.add(q.brightness);
      if (roi != null) {
        _acceptedPoseRatio.add(roi.poseRatio);
        _acceptedTiltDeg.add(roi.tiltFromVerticalDeg);
        _acceptedSize.add(roi.halfWFrac);
      }
      // Pose samples for this pass — pass 1's mean becomes the baseline the
      // later passes are verified against.
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

      // Record the lighting THIS pass was captured under, before the buffer is
      // reset. Without it a stored template cannot say what light it came from,
      // and the spread check below has nothing to work with.
      if (_passLuma.isNotEmpty) {
        final m = _passLuma.reduce((a, b) => a + b) / _passLuma.length;
        var sq = 0.0;
        for (final v in _passLuma) {
          sq += (v - m) * (v - m);
        }
        _passTemplateLuma.add(m);
        _passTemplateLumaStd.add(math.sqrt(sq / _passLuma.length));
      } else {
        _passTemplateLuma.add(double.nan);
        _passTemplateLumaStd.add(double.nan);
      }
      _passLuma.clear();

      // Pass 1 defines the pose baseline that passes 2+ are checked against.
      if (_varyPose && _pass == 1 && _passSizes.isNotEmpty) {
        _baselineSize =
            _passSizes.reduce((a, b) => a + b) / _passSizes.length;
        _baselineRatio =
            _passRatios.reduce((a, b) => a + b) / _passRatios.length;
      }
      _passSizes.clear();
      _passRatios.clear();

      if (kDebugMode) {
        debugPrint('[capture-timing] pass=$_pass frames_needed_to_complete='
            '$_framesSeenThisPass (target=$maxFrames)');
      }
      _framesSeenThisPass = 0;

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
      if (kDebugMode) {
        debugPrint('[capture-timing] total_session_ms='
            '${_sessionClock?.elapsedMilliseconds} passes=$_passesThisRun '
            'frames_per_pass=$maxFrames');
      }
      _sessionClock?.stop();
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

  /// The per-pass templates as SEPARATE vectors, each with the lighting it was
  /// captured under — the multi-template enrolment payload.
  ///
  /// This is the same data [buildTemplate] averages into one vector; here it is
  /// kept apart instead. Averaging across lighting conditions produces a single
  /// blurred template that matches none of them well; keeping them separate and
  /// scoring max() at verification is what cut false rejects 28.7% -> 11.1% in
  /// the offline simulation.
  ///
  /// Returns fewer entries than passes only if a pass produced no accepted
  /// frames, which cannot normally happen (a pass ends when it fills).
  List<PassTemplate> get passTemplates {
    final out = <PassTemplate>[];
    for (var i = 0; i < _passTemplates.length; i++) {
      final luma = i < _passTemplateLuma.length ? _passTemplateLuma[i] : double.nan;
      final std = i < _passTemplateLumaStd.length ? _passTemplateLumaStd[i] : double.nan;
      out.add(PassTemplate(
        vec: _passTemplates[i],
        lumaMean: luma.isNaN ? null : luma,
        lumaStd: std.isNaN ? null : std,
      ));
    }
    return out;
  }

  /// Spread of enrolment lighting actually achieved, or null if fewer than two
  /// passes recorded a luma.
  double? get lightingSpread {
    final l = _passTemplateLuma.where((v) => !v.isNaN).toList();
    if (l.length < 2) return null;
    l.sort();
    return l.last - l.first;
  }

  /// Did the student actually move into different light?
  ///
  /// False means the stored templates are near-duplicates and multi-template
  /// enrolment will deliver none of its benefit for this student. The record is
  /// still stored — refusing to enrol someone whose room has uniform light is
  /// worse than enrolling them with a flag — but it is flagged, never silently
  /// accepted as if it had worked.
  bool get lightingSpreadOk => (lightingSpread ?? 0) >= kMinLumaSpread;

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

  /// Debug-only per-frame timing log — see the field docs above [_sessionClock].
  /// [exit] names which stage the frame left the pipeline at (a gate name, or
  /// 'accepted'); [stageUs] holds whichever of quality_gate_us / hand_detect_us
  /// / preprocess_us / inference_us actually ran before that exit.
  void _logFrame(Stopwatch frameClock, Map<String, int> stageUs, String exit) {
    if (!kDebugMode) return;
    final parts = stageUs.entries
        .map((e) => '${e.key}=${(e.value / 1000).toStringAsFixed(1)}ms')
        .join(' ');
    debugPrint('[capture-timing] exit=$exit total_per_frame_ms='
        '${frameClock.elapsedMilliseconds} $parts');
  }

  void dispose() {
    _running = false;
    _progress.close();
  }
}

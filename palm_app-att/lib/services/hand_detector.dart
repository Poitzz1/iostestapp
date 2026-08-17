import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:hand_detection/hand_detection.dart' as hd;

/// Hand side (left / right). Stored explicitly on every enrollment because left
/// and right palms are different identities — the app must never rely on the
/// embedding alone to tell them apart (README §4).
enum HandSide { left, right }

extension HandSideLabel on HandSide {
  String get label => this == HandSide.left ? 'left' : 'right';
  static HandSide fromLabel(String s) =>
      s == 'right' ? HandSide.right : HandSide.left;
}

/// The palm ROI to crop before embedding, expressed as fractions of the
/// source image so it can be applied to any scaled version of the same frame.
///
/// The model was TRAINED on these crops, so inference must reproduce them
/// exactly or we recreate the train/deploy domain gap the retrains exist to
/// close (under the v3/v4 mismatch impostor scores averaged 0.514).
///
/// v5: the crop is ROTATION-ALIGNED. The frame is first rotated so the
/// wrist(0) -> middle_mcp(9) axis points straight up, and the square is taken
/// from that rotated frame. [rotationDeg] carries the rotation and
/// [cxFrac]/[cyFrac] are coordinates in the ROTATED canvas (same size as the
/// source), NOT in the original frame — applying them without rotating first
/// crops the wrong pixels.
class PalmRoi {
  /// Centre in the ROTATED canvas, as a fraction of image width / height.
  final double cxFrac;
  final double cyFrac;

  /// Half the square's side, as a fraction of width / height respectively.
  /// Stored per-axis so the same square survives a change of scale; both map
  /// to an equal number of pixels as long as the aspect ratio is unchanged.
  final double halfWFrac;
  final double halfHFrac;

  /// Palm width ÷ palm height: distance(index_mcp(5) → pinky_mcp(17)) over
  /// distance(wrist(0) → middle_mcp(9)).
  ///
  /// PURELY a pose metric — it plays no part in the crop, which must stay
  /// bit-identical to the v5 training spec. Used by enrollment's
  /// pose-conformance gate: an out-of-plane tilt foreshortens one axis, so
  /// this ratio moving away from its baseline is how "tilt your palm
  /// slightly" is actually verified rather than taken on trust.
  final double poseRatio;

  /// Degrees the source frame must be rotated about its centre, in OpenCV's
  /// `getRotationMatrix2D` convention, BEFORE the square is cut:
  ///
  ///   x' =  cos(t)*x + sin(t)*y      (about the image centre)
  ///   y' = -sin(t)*x + cos(t)*y
  ///
  /// Derived so the wrist -> middle_mcp axis ends up pointing straight up
  /// (-90 deg in image coordinates, y down). Zero means no rotation.
  final double rotationDeg;

  const PalmRoi({
    required this.cxFrac,
    required this.cyFrac,
    required this.halfWFrac,
    required this.halfHFrac,
    this.poseRatio = 0,
    this.rotationDeg = 0,
    this.insideFraction = 1,
    this.palmPointsInFrame = 7,
  });

  /// In-plane rotation the palm was actually presented at, in degrees away from
  /// vertical. Pose/UX only — the crop already cancels it out.
  double get tiltFromVerticalDeg => rotationDeg.abs() > 180
      ? 360 - rotationDeg.abs()
      : rotationDeg.abs();

  /// Fraction (0..1) of the ROI square that actually falls inside the frame.
  ///
  /// THE GATE THAT WAS MISSING. MediaPipe returns 21 landmarks even when only
  /// part of the hand is visible — it EXTRAPOLATES the wrist and knuckles past
  /// the edge of the image. Those phantom points stay correctly proportioned,
  /// so every structural check ([isPlausibleHand], [countExtendedFingers])
  /// passes, and the crop then centres outside the frame and gets clipped to a
  /// sliver which is stretched to 224x224 and embedded as if it were a palm.
  ///
  /// This is what let "only fingers in shot" be captured, and it is why one
  /// person's scans scattered between 0.21 and 0.86 against their own template:
  /// a good frame and a clipped sliver are simply different images. Neither the
  /// score nor any earlier gate could tell you which you had — the number is
  /// the same shape either way, just wrong.
  final double insideFraction;

  /// How many of the 7 palm landmarks (0,1,2,5,9,13,17) lie inside the frame.
  /// Extrapolated points fall outside, so anything under 7 means part of the
  /// palm is off-screen and its position is a guess, not a measurement.
  final int palmPointsInFrame;

  /// True when the whole palm is really in shot: every palm landmark measured
  /// rather than extrapolated, and the crop essentially unclipped.
  bool get isFullyVisible =>
      palmPointsInFrame == 7 && insideFraction >= minInsideFraction;

  /// A few percent of clipping is normal at the frame edge and harmless — the
  /// training pipeline clips too. A crop missing a tenth of its area is not a
  /// palm picture any more.
  static const double minInsideFraction = 0.90;
}

/// One MediaPipe hand landmark, normalised to the detector's processed image
/// so it survives a change of scale.
///
/// Carried only for the DATA COLLECTOR (`lib/collector/`), which stores all 21
/// points alongside each captured sample so future geometric analysis is
/// possible without re-running detection. Nothing in the enrollment or
/// attendance path reads this.
class PalmLandmark {
  /// 0..1 fractions of the detector's processed image width / height.
  final double x;
  final double y;

  /// Raw MediaPipe depth, relative to the hand's centre — NOT normalised and
  /// not in the same units as [x]/[y]. Stored verbatim.
  final double z;

  const PalmLandmark(this.x, this.y, this.z);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'z': z};

  static PalmLandmark fromJson(Map<String, dynamic> j) => PalmLandmark(
        (j['x'] as num).toDouble(),
        (j['y'] as num).toDouble(),
        (j['z'] as num).toDouble(),
      );
}

class HandDetection {
  final bool present;

  /// True only when the hand is an OPEN palm (>= 4 fingers extended).
  /// A closed fist, a face, or a random object must never pass.
  final bool openPalm;

  /// Handedness AFTER the mirror correction below — this is the value the app
  /// uses. See [rawSide] for the uncorrected label.
  final HandSide? side;

  /// MediaPipe's handedness label EXACTLY as returned, before any mirror
  /// correction. MediaPipe assumes a non-mirrored image; a mirrored (front
  /// camera) feed swaps left and right, so the corrected [side] is a
  /// derivation, not ground truth. The collector stores both so the correction
  /// can be re-derived offline if it ever turns out to be wrong.
  final HandSide? rawSide;

  final double confidence;

  /// Palm ROI derived from the hand landmarks, or null when no hand was
  /// detected — in which case callers must fall back to a centre square,
  /// exactly as the training pipeline does.
  final PalmRoi? roi;

  /// All 21 landmarks, normalised to the detector's processed image. Populated
  /// only when landmarks were available. Collector-only — see [PalmLandmark].
  final List<PalmLandmark>? landmarks;

  /// Dimensions of the image the detector actually processed (rotated, and
  /// downscaled to its own `maxDim`) — the space [landmarks] and [roi] are
  /// normalised against.
  ///
  /// Carried so the collector's live hand-assist overlay can map landmarks onto
  /// the camera preview using the detector's real aspect ratio rather than
  /// inferring one from the preview size and hoping the rotation assumption
  /// holds. Zero when no hand was detected.
  final int imageWidth;
  final int imageHeight;

  const HandDetection({
    required this.present,
    this.openPalm = false,
    this.side,
    this.rawSide,
    this.confidence = 0,
    this.roi,
    this.landmarks,
    this.imageWidth = 0,
    this.imageHeight = 0,
  });

  static const none = HandDetection(present: false);
}

/// Pluggable hand detector. [MediaPipeHandDetector] is the production
/// implementation; [ManualHandDetector] remains as a permissive fallback for
/// tests and platforms where the MediaPipe runtime is unavailable.
abstract class HandDetector {
  Future<void> init();
  Future<HandDetection> detect(CameraImage frame, {int rotationDegrees = 0});
  void dispose();
}

/// Real palm detection using MediaPipe hand landmarks (via `hand_detection`).
///
/// A frame is only accepted when:
///  1. a hand is detected in the frame, and
///  2. the hand is an OPEN palm — at least 4 of the non-thumb fingers have
///     their tip clearly farther from the wrist than their PIP joint. Curled
///     fingers fold the tip back toward the wrist, so a closed fist fails.
class MediaPipeHandDetector implements HandDetector {
  hd.HandDetector? _detector;

  /// Ratio by which the tip→wrist distance must exceed the PIP→wrist distance
  /// for a finger to count as extended.
  static const double extendedRatio = 1.15;

  /// How many of the 4 non-thumb fingers must be extended for an open palm.
  static const int minExtendedFingers = 4;

  // ── Detector tuning ───────────────────────────────────────────────────────
  //
  // Defaults reproduce the production enrollment/attendance settings EXACTLY.
  // They are parameters only so the data collector can be more permissive
  // without touching the verification path — see [MediaPipeHandDetector.tuned].

  final double detectorConf;
  final double minLandmarkScore;

  /// Longest side the frame is downscaled to before detection. Bigger finds
  /// smaller hands (an arm extended at "far" distance) at a real CPU cost.
  ///
  /// 480, NOT the 800 in `roi_crop_spec.detect_max_px`. 800 was tried on the
  /// grounds that v5 derives a crop ROTATION from the wrist -> middle_mcp pair,
  /// so landmark jitter becomes crop-angle error — but the size of that effect
  /// was overestimated. Over a typical ~120 px palm span, a 2 px landmark error
  /// is atan(2/120) ~= 1 degree of crop rotation, which moves the crop edge by
  /// about 2 px out of 224. The cost was not small: the capture stream is
  /// ResolutionPreset.medium (~720x480), so maxDim 800 disables downscaling
  /// entirely and hands MediaPipe 2.25x the pixels — inside the awaited
  /// `detect` call that gates the whole capture loop. Detection resolution does
  /// not change the crop geometry, which is scale-invariant.
  final int maxDim;

  /// MediaPipe-style detect-and-track: a hand's landmark ROI is carried to the
  /// next frame and landmarked directly, so the palm detector does not have to
  /// re-find it every frame.
  final bool enableTracking;

  // 0.6 / 0.5. These were briefly lowered to 0.45 / 0.4 to find palms in dim
  // rooms; that was a mistake and is why the same palm started scoring anywhere
  // between 0.21 and 0.86 against its own template.
  //
  // Below this bar MediaPipe still returns 21 landmarks for a PARTIAL hand — it
  // extrapolates the wrist and knuckles off the edge of the frame when only the
  // fingers are visible. Those phantom points are proportioned like a hand, so
  // [isPlausibleHand] and [countExtendedFingers] both pass, and the ROI then
  // centres on a point outside the image and crops a clipped sliver. The
  // containment check in [palmRoiFrom] now rejects that outright, but keeping
  // the detector honest is the first line: do not lower these again to chase
  // low light. See the note in QualityGate: the app deliberately does not
  // drive the camera, and low light is a model/enrollment-protocol problem
  // (issue.md) — not something to fix by believing weaker detections.
  MediaPipeHandDetector({
    this.detectorConf = 0.6,
    this.minLandmarkScore = 0.5,
    this.maxDim = 480,
    this.enableTracking = false,
  });

  /// Settings for the DATA COLLECTOR (`lib/collector/`).
  ///
  /// The collector deliberately asks people to stand in direct sun, in dim
  /// corridors, and at arm's length — precisely the conditions the production
  /// settings lose the hand in. Losing it there is not a harmless miss: those
  /// are the exact frames the collection exists to gather, so a detector that
  /// gives up on them collects a dataset that carefully avoids the model's
  /// known weakness.
  ///
  /// So: a lower confidence bar, a larger working image so a small far-away
  /// palm still registers, and tracking ON so a hand that was found once
  /// survives a few bad frames of glare instead of having to be re-acquired
  /// from scratch.
  ///
  /// None of this touches enrollment or attendance, which keep the stricter
  /// defaults above — a permissive detector is right for collecting and wrong
  /// for building a template.
  factory MediaPipeHandDetector.forCollector() => MediaPipeHandDetector(
        // Was 0.35 / 0.30. That was permissive enough to accept FEET as hands:
        // MediaPipe's palm detector fires on a foot at low confidence, and the
        // open-palm test below (tips farther from the wrist than the PIPs) is
        // satisfied by spread toes. Real captures of feet reached the dataset.
        //
        // Raised to a middle ground — still looser than production's 0.6/0.5,
        // because the collector genuinely needs to find hands in glare and at
        // arm's length, but no longer low enough to hallucinate a hand out of
        // any five-lobed blob. The structural [isPlausibleHand] check is what
        // actually rejects feet; this just stops feeding it junk.
        detectorConf: 0.5,
        minLandmarkScore: 0.45,
        maxDim: 640,
        enableTracking: true,
      );

  @override
  Future<void> init() async {
    _detector = await hd.HandDetector.create(
      mode: hd.HandMode.boxesAndLandmarks,
      maxDetections: 1,
      detectorConf: detectorConf,
      minLandmarkScore: minLandmarkScore,
      enableTracking: enableTracking,
    );
  }

  @override
  Future<HandDetection> detect(CameraImage frame,
      {int rotationDegrees = 0}) async {
    final detector = _detector;
    if (detector == null) return HandDetection.none;

    try {
      final rotation = switch (rotationDegrees % 360) {
        90 => hd.CameraFrameRotation.cw90,
        180 => hd.CameraFrameRotation.cw180,
        270 => hd.CameraFrameRotation.cw270,
        _ => null, // 0° — frame is already upright
      };
      final hands = await detector.detectFromCameraImage(
        frame,
        rotation: rotation,
        maxDim: maxDim,
      );
      if (hands.isEmpty) return HandDetection.none;

      final hand = hands.first;
      if (!hand.hasLandmarks || hand.landmarks.length < 21) {
        // Palm box found but no landmarks — treat as present-but-not-open so
        // the pipeline keeps waiting instead of embedding an unverified frame.
        return const HandDetection(present: true, openPalm: false);
      }

      final pts = hand.landmarks
          .map((l) => math.Point<double>(l.x, l.y))
          .toList(growable: false);

      // Reject anything shaped wrong for a hand (a foot, most notably) before
      // it can be reported as an open palm. Treated as "present but not an
      // open palm" rather than "nothing here", so the collector's gate refuses
      // it and the UI says "open your hand" instead of pretending the frame is
      // empty.
      if (!isPlausibleHand(pts)) {
        return const HandDetection(present: true, openPalm: false);
      }

      final extended = countExtendedFingers(pts);

      // MediaPipe handedness assumes a mirrored (selfie) image. This app uses
      // the unmirrored back camera, so the label is swapped.
      final rawSide =
          hand.handedness == hd.Handedness.left ? HandSide.left : HandSide.right;
      final side = rawSide == HandSide.left ? HandSide.right : HandSide.left;

      return HandDetection(
        present: true,
        openPalm: extended >= minExtendedFingers,
        side: side,
        rawSide: rawSide,
        // `hand.score` is the palm DETECTOR's confidence, not a handedness
        // probability — the package does not surface one separately. Recorded
        // as-is; the collector labels it accordingly.
        confidence: hand.score,
        // Landmarks are returned in pixels of the image the detector actually
        // processed (rotated, and downscaled to maxDim) — `hand.imageWidth/
        // Height` describe that image, so normalising here lets the ROI be
        // applied to the full-resolution frame in the preprocessor.
        roi: palmRoiFrom(pts, hand.imageWidth, hand.imageHeight),
        landmarks: [
          for (final l in hand.landmarks)
            PalmLandmark(l.x / hand.imageWidth, l.y / hand.imageHeight, l.z),
        ],
        imageWidth: hand.imageWidth,
        imageHeight: hand.imageHeight,
      );
    } catch (e) {
      debugPrint('[MediaPipeHandDetector] detect failed: $e');
      return HandDetection.none;
    }
  }

  /// Palm ROI from the 21 MediaPipe landmarks, matching the v5 TRAINING crop
  /// bit-for-bit. Any divergence here silently reintroduces the train/deploy
  /// domain gap, so `deploy_config.json -> roi_crop_spec` is restated inline:
  ///
  ///   1. angle          : atan2(y9 - y0, x9 - x0), degrees, on the ORIGINAL
  ///                       unrotated frame
  ///   2. rotation_needed: -90 - angle   (what would bring the axis to
  ///                       "straight up"; y is DOWN, so up is -90)
  ///   3. rotate by      : -rotation_needed = 90 + angle, about the image
  ///                       centre, canvas size unchanged
  ///   4. landmarks      : pushed through the SAME matrix
  ///   5. centre         : mean of ROTATED wrist(0), thumb_cmc(1),
  ///                       thumb_mcp(2), index_mcp(5), middle_mcp(9),
  ///                       ring_mcp(13), pinky_mcp(17)
  ///   6. half-size      : 1.1 x distance(wrist(0) -> middle_mcp(9))
  ///   7. crop           : square [centre - half, centre + half] of the ROTATED
  ///                       image, clipped to bounds (training clips too, so do
  ///                       NOT re-square it afterwards)
  ///
  /// Why rotation matters: on 3,210 real comparisons in-plane rotation drove
  /// score decay at r=-0.322 — about double the effect of out-of-plane tilt.
  /// Cropping without aligning is what made v4 angle-sensitive.
  ///
  /// Note the span is measured on the ORIGINAL landmarks: rotation is rigid, so
  /// distance(0, 9) is identical before and after, and measuring it first
  /// avoids compounding the rotation's floating-point error into the crop size.
  ///
  /// [lm] must be in pixel coordinates of an image [imgW] x [imgH].
  /// Pure geometry — exposed for unit tests.
  @visibleForTesting
  static PalmRoi? palmRoiFrom(List<math.Point<double>> lm, int imgW, int imgH) {
    if (lm.length < 21 || imgW <= 0 || imgH <= 0) return null;
    const roiIndices = [0, 1, 2, 5, 9, 13, 17];

    final span = lm[0].distanceTo(lm[9]);
    final half = 1.1 * span;
    if (!half.isFinite || half <= 0) return null;

    // Steps 1-3. `theta` is the OpenCV getRotationMatrix2D angle.
    final angleDeg =
        math.atan2(lm[9].y - lm[0].y, lm[9].x - lm[0].x) * 180.0 / math.pi;
    final thetaDeg = 90.0 + angleDeg;
    final thetaRad = thetaDeg * math.pi / 180.0;
    final a = math.cos(thetaRad);
    final b = math.sin(thetaRad);

    // Rotation about the image centre, canvas size unchanged:
    //   x' =  a*(x - ox) + b*(y - oy) + ox
    //   y' = -b*(x - ox) + a*(y - oy) + oy
    final ox = imgW / 2.0;
    final oy = imgH / 2.0;

    // Step 4-5: mean of the rotated palm points. Rotation is affine, so this
    // equals rotating the mean of the originals — computed the long way anyway
    // so the code reads as the spec does and stays right if the point set or
    // the transform ever stops being a plain rotation.
    var sx = 0.0, sy = 0.0;
    for (final i in roiIndices) {
      final dx = lm[i].x - ox;
      final dy = lm[i].y - oy;
      sx += a * dx + b * dy + ox;
      sy += -b * dx + a * dy + oy;
    }
    final cx = sx / roiIndices.length;
    final cy = sy / roiIndices.length;

    if (!cx.isFinite || !cy.isFinite) return null;

    // ── Containment (see PalmRoi.insideFraction) ────────────────────────────
    // How much of the square actually falls on real pixels. Measured in the
    // ROTATED canvas, which is where the crop is taken and which has the same
    // dimensions as the source.
    final vx0 = math.max(0.0, cx - half);
    final vy0 = math.max(0.0, cy - half);
    final vx1 = math.min(imgW.toDouble(), cx + half);
    final vy1 = math.min(imgH.toDouble(), cy + half);
    final visW = math.max(0.0, vx1 - vx0);
    final visH = math.max(0.0, vy1 - vy0);
    final inside = (visW * visH) / (4 * half * half);

    // Landmarks are checked on the ORIGINAL, unrotated points — that is where
    // MediaPipe's extrapolation past the frame edge actually shows up.
    var pointsIn = 0;
    for (final i in roiIndices) {
      final p = lm[i];
      if (p.x >= 0 && p.x < imgW && p.y >= 0 && p.y < imgH) pointsIn++;
    }

    return PalmRoi(
      cxFrac: cx / imgW,
      cyFrac: cy / imgH,
      halfWFrac: half / imgW,
      halfHFrac: half / imgH,
      // Pose-only metric (see PalmRoi.poseRatio) — not part of the crop.
      poseRatio: lm[5].distanceTo(lm[17]) / span,
      rotationDeg: thetaDeg,
      insideFraction: inside.isFinite ? inside.clamp(0.0, 1.0) : 0.0,
      palmPointsInFrame: pointsIn,
    );
  }

  /// Minimum mean finger length, as a fraction of palm length, for the
  /// landmarks to describe a plausible HAND rather than a foot.
  ///
  /// Hands measure roughly 0.75–1.2 on this ratio; feet measure roughly
  /// 0.2–0.45, because toes are stubby relative to the sole. 0.55 sits in the
  /// empty gap between the two distributions, so it rejects feet without
  /// coming near a real hand — including a foreshortened one, which shortens
  /// fingers and palm together and so barely moves the ratio.
  static const double minFingerToPalmRatio = 0.55;

  /// True when the landmark geometry is proportioned like a hand.
  ///
  /// MediaPipe's palm detector will happily fire on a FOOT — five digits, a
  /// broad pad, roughly the right topology — and [countExtendedFingers] does
  /// not catch it, because spread toes pass the "tip farther from the wrist
  /// than the PIP" test exactly like fingers do. Feet were reaching the
  /// dataset.
  ///
  /// What separates them is PROPORTION, not pose: fingers are about as long as
  /// the palm, toes are a fraction of the sole. Comparing mean finger length
  /// against palm length is scale-invariant (so distance from camera does not
  /// matter), rotation-invariant (all distances), and needs no extra model.
  ///
  /// Pure geometry — exposed for unit tests.
  @visibleForTesting
  static bool isPlausibleHand(List<math.Point<double>> lm) {
    if (lm.length < 21) return false;

    // Palm length: wrist -> middle knuckle. The same measure the ROI crop uses.
    final palm = lm[0].distanceTo(lm[9]);
    if (palm <= 0) return false;

    // Mean length of the four non-thumb fingers, knuckle -> tip. The mean
    // rather than one finger so a single mis-tracked digit cannot decide it.
    const mcpToTip = [
      [5, 8], // index
      [9, 12], // middle
      [13, 16], // ring
      [17, 20], // pinky
    ];
    var total = 0.0;
    for (final f in mcpToTip) {
      total += lm[f[0]].distanceTo(lm[f[1]]);
    }
    final meanFinger = total / mcpToTip.length;

    return meanFinger / palm >= minFingerToPalmRatio;
  }

  /// Number of extended non-thumb fingers from the 21 MediaPipe landmarks
  /// (0 = wrist, [pip, tip] pairs: index 6/8, middle 10/12, ring 14/16,
  /// pinky 18/20). Pure geometry — exposed for unit tests.
  @visibleForTesting
  static int countExtendedFingers(List<math.Point<double>> lm) {
    if (lm.length < 21) return 0;
    final wrist = lm[0];
    const fingers = [
      [6, 8], // index: pip, tip
      [10, 12], // middle
      [14, 16], // ring
      [18, 20], // pinky
    ];
    var extended = 0;
    for (final f in fingers) {
      final dPip = wrist.distanceTo(lm[f[0]]);
      final dTip = wrist.distanceTo(lm[f[1]]);
      if (dPip > 0 && dTip > dPip * extendedRatio) extended++;
    }
    return extended;
  }

  @override
  void dispose() {
    _detector?.dispose();
    _detector = null;
  }
}

/// Permissive no-op detector: assumes an open palm is present and defers
/// handedness to the user's explicit selection. Only for tests / platforms
/// without the MediaPipe runtime — never use in the production capture path.
class ManualHandDetector implements HandDetector {
  @override
  Future<void> init() async {}

  @override
  Future<HandDetection> detect(CameraImage frame,
      {int rotationDegrees = 0}) async {
    return const HandDetection(
        present: true, openPalm: true, side: null, confidence: 1);
  }

  @override
  void dispose() {}
}

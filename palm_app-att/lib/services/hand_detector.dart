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
/// The v4 model was TRAINED on these crops, so inference must reproduce them
/// exactly or we recreate the train/deploy domain gap the v4 retrain existed
/// to close (impostor scores averaged 0.514 under the mismatch).
class PalmRoi {
  /// Centre, as a fraction of image width / height.
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
  /// bit-identical to the v4 training spec. Used by enrollment's
  /// pose-conformance gate: an out-of-plane tilt foreshortens one axis, so
  /// this ratio moving away from its baseline is how "tilt your palm
  /// slightly" is actually verified rather than taken on trust.
  final double poseRatio;

  const PalmRoi({
    required this.cxFrac,
    required this.cyFrac,
    required this.halfWFrac,
    required this.halfHFrac,
    this.poseRatio = 0,
  });
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
  final int maxDim;

  /// MediaPipe-style detect-and-track: a hand's landmark ROI is carried to the
  /// next frame and landmarked directly, so the palm detector does not have to
  /// re-find it every frame.
  final bool enableTracking;

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

  /// Palm ROI from the 21 MediaPipe landmarks, matching the v4 TRAINING crop
  /// bit-for-bit. Any divergence here silently reintroduces the train/deploy
  /// domain gap, so the spec is restated inline:
  ///
  ///   landmarks used : wrist(0), thumb_cmc(1), thumb_mcp(2), index_mcp(5),
  ///                    middle_mcp(9), ring_mcp(13), pinky_mcp(17)
  ///   centre         : mean(x), mean(y) of those points, in pixels
  ///   half-size      : 1.1 x distance(wrist(0) -> middle_mcp(9))
  ///   crop           : square [centre - half, centre + half], clipped to the
  ///                    image (clipping may leave it non-square at the edges —
  ///                    training clips too, so do NOT re-square it afterwards)
  ///
  /// [lm] must be in pixel coordinates of an image [imgW] x [imgH].
  /// Pure geometry — exposed for unit tests.
  @visibleForTesting
  static PalmRoi? palmRoiFrom(List<math.Point<double>> lm, int imgW, int imgH) {
    if (lm.length < 21 || imgW <= 0 || imgH <= 0) return null;
    const roiIndices = [0, 1, 2, 5, 9, 13, 17];

    var sx = 0.0, sy = 0.0;
    for (final i in roiIndices) {
      sx += lm[i].x;
      sy += lm[i].y;
    }
    final cx = sx / roiIndices.length;
    final cy = sy / roiIndices.length;

    final height = lm[0].distanceTo(lm[9]);
    final half = 1.1 * height;
    if (!half.isFinite || half <= 0) return null;

    return PalmRoi(
      cxFrac: cx / imgW,
      cyFrac: cy / imgH,
      halfWFrac: half / imgW,
      halfHFrac: half / imgH,
      // Pose-only metric (see PalmRoi.poseRatio) — not part of the crop.
      poseRatio: lm[5].distanceTo(lm[17]) / height,
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

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

class HandDetection {
  final bool present;

  /// True only when the hand is an OPEN palm (>= 4 fingers extended).
  /// A closed fist, a face, or a random object must never pass.
  final bool openPalm;
  final HandSide? side; // null if the detector cannot determine handedness
  final double confidence;

  /// Palm ROI derived from the hand landmarks, or null when no hand was
  /// detected — in which case callers must fall back to a centre square,
  /// exactly as the training pipeline does.
  final PalmRoi? roi;

  const HandDetection({
    required this.present,
    this.openPalm = false,
    this.side,
    this.confidence = 0,
    this.roi,
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

  @override
  Future<void> init() async {
    _detector = await hd.HandDetector.create(
      mode: hd.HandMode.boxesAndLandmarks,
      maxDetections: 1,
      detectorConf: 0.6,
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
        maxDim: 480,
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
      final extended = countExtendedFingers(pts);

      // MediaPipe handedness assumes a mirrored (selfie) image. This app uses
      // the unmirrored back camera, so the label is swapped.
      final side = hand.handedness == hd.Handedness.left
          ? HandSide.right
          : HandSide.left;

      return HandDetection(
        present: true,
        openPalm: extended >= minExtendedFingers,
        side: side,
        confidence: 1,
        // Landmarks are returned in pixels of the image the detector actually
        // processed (rotated, and downscaled to maxDim) — `hand.imageWidth/
        // Height` describe that image, so normalising here lets the ROI be
        // applied to the full-resolution frame in the preprocessor.
        roi: palmRoiFrom(pts, hand.imageWidth, hand.imageHeight),
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

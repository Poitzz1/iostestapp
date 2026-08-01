import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:palmpay_enroll/services/hand_detector.dart';

/// Guards the v4 ROI crop against drift.
///
/// The v4 model was trained on crops produced by an exact formula; if the app's
/// crop diverges the model silently degrades (impostor scores averaged 0.514
/// under the previous train/deploy mismatch) with nothing failing loudly. These
/// tests pin the formula:
///
///   landmarks : 0, 1, 2, 5, 9, 13, 17
///   centre    : mean of those points
///   half-size : 1.1 x distance(wrist(0) -> middle_mcp(9))
void main() {
  /// 21 landmarks, all at (0,0) unless overridden.
  List<math.Point<double>> lms(Map<int, math.Point<double>> pts) => List.generate(
        21,
        (i) => pts[i] ?? const math.Point<double>(0, 0),
      );

  test('centre is the mean of exactly landmarks 0,1,2,5,9,13,17', () {
    // Put the 7 ROI landmarks at x=10..70 (mean 40), y=100 for all.
    final roiPts = {
      0: const math.Point<double>(10, 100),
      1: const math.Point<double>(20, 100),
      2: const math.Point<double>(30, 100),
      5: const math.Point<double>(40, 100),
      9: const math.Point<double>(50, 100),
      13: const math.Point<double>(60, 100),
      17: const math.Point<double>(70, 100),
      // Decoys on unused indices — must NOT affect the centre.
      4: const math.Point<double>(9999, 9999),
      20: const math.Point<double>(-9999, -9999),
    };
    final roi = MediaPipeHandDetector.palmRoiFrom(lms(roiPts), 200, 400)!;

    expect(roi.cxFrac * 200, closeTo(40, 1e-9));
    expect(roi.cyFrac * 400, closeTo(100, 1e-9));
  });

  test('half-size is 1.1 x distance(wrist -> middle_mcp)', () {
    // 3-4-5 triangle: distance(0 -> 9) = 5, so half = 5.5
    final roi = MediaPipeHandDetector.palmRoiFrom(
      lms({
        0: const math.Point<double>(0, 0),
        9: const math.Point<double>(3, 4),
      }),
      100,
      100,
    )!;

    expect(roi.halfWFrac * 100, closeTo(5.5, 1e-9));
    expect(roi.halfHFrac * 100, closeTo(5.5, 1e-9));
  });

  test('fractions are scale-invariant — same square at any resolution', () {
    final pts = lms({
      0: const math.Point<double>(100, 200),
      9: const math.Point<double>(100, 260),
      5: const math.Point<double>(80, 240),
      13: const math.Point<double>(120, 240),
    });
    // Same geometry, described at half resolution.
    final half = lms({
      0: const math.Point<double>(50, 100),
      9: const math.Point<double>(50, 130),
      5: const math.Point<double>(40, 120),
      13: const math.Point<double>(60, 120),
    });

    final a = MediaPipeHandDetector.palmRoiFrom(pts, 640, 480)!;
    final b = MediaPipeHandDetector.palmRoiFrom(half, 320, 240)!;

    expect(a.cxFrac, closeTo(b.cxFrac, 1e-9));
    expect(a.cyFrac, closeTo(b.cyFrac, 1e-9));
    expect(a.halfWFrac, closeTo(b.halfWFrac, 1e-9));
    expect(a.halfHFrac, closeTo(b.halfHFrac, 1e-9));
  });

  test('degenerate input returns null so the caller uses the centre-square '
      'fallback rather than a zero-size crop', () {
    // wrist == middle_mcp -> half-size 0
    expect(
      MediaPipeHandDetector.palmRoiFrom(
        lms({0: const math.Point<double>(5, 5), 9: const math.Point<double>(5, 5)}),
        100,
        100,
      ),
      isNull,
    );
    // too few landmarks
    expect(
      MediaPipeHandDetector.palmRoiFrom(
        [const math.Point<double>(1, 1)],
        100,
        100,
      ),
      isNull,
    );
    // zero-size image
    expect(
      MediaPipeHandDetector.palmRoiFrom(
        lms({0: const math.Point<double>(0, 0), 9: const math.Point<double>(3, 4)}),
        0,
        0,
      ),
      isNull,
    );
  });
}

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:palmpay_enroll/services/hand_detector.dart';

/// Guards the v5 ROTATION-ALIGNED ROI crop against drift.
///
/// The model is trained on crops produced by an exact formula; if the app's
/// crop diverges the model silently degrades (impostor scores averaged 0.514
/// under the earlier train/deploy mismatch) with nothing failing loudly. These
/// tests pin the formula from `deploy_config.json -> roi_crop_spec`:
///
///   rotate    : so wrist(0) -> middle_mcp(9) points straight up (-90 deg,
///               y down), about the image centre, canvas size unchanged
///   landmarks : 0, 1, 2, 5, 9, 13, 17, pushed through the same rotation
///   centre    : mean of those ROTATED points
///   half-size : 1.1 x distance(wrist(0) -> middle_mcp(9))
void main() {
  /// 21 landmarks, all at (0,0) unless overridden.
  List<math.Point<double>> lms(Map<int, math.Point<double>> pts) =>
      List.generate(21, (i) => pts[i] ?? const math.Point<double>(0, 0));

  math.Point<double> p(double x, double y) => math.Point<double>(x, y);

  /// Re-applies the rotation a [PalmRoi] describes, so a test can assert where
  /// a landmark LANDS rather than restating the matrix.
  math.Point<double> rotate(
      math.Point<double> pt, double thetaDeg, int w, int h) {
    final t = thetaDeg * math.pi / 180.0;
    final a = math.cos(t), b = math.sin(t);
    final dx = pt.x - w / 2.0, dy = pt.y - h / 2.0;
    return math.Point<double>(
      a * dx + b * dy + w / 2.0,
      -b * dx + a * dy + h / 2.0,
    );
  }

  group('rotation alignment (the v5 change)', () {
    // A palm already pointing "up" needs no rotation; every other orientation
    // must be turned until it does. This is the whole point of v5: in-plane
    // rotation drove score decay at r=-0.322 on 3,210 real comparisons.
    final orientations = <String, List<math.Point<double>>>{
      'already up': [p(320, 300), p(320, 200)],
      'pointing right': [p(300, 240), p(400, 240)],
      'pointing left': [p(400, 240), p(300, 240)],
      'pointing down': [p(320, 200), p(320, 300)],
      'tilted right': [p(320, 300), p(370, 213)],
      'tilted left': [p(320, 300), p(270, 213)],
      'off-centre': [p(100, 90), p(140, 10)],
    };

    orientations.forEach((name, wristAndMcp) {
      test('$name -> wrist->middle_mcp ends up vertical', () {
        const w = 640, h = 480;
        final roi = MediaPipeHandDetector.palmRoiFrom(
          lms({0: wristAndMcp[0], 9: wristAndMcp[1]}),
          w,
          h,
        )!;

        final r0 = rotate(wristAndMcp[0], roi.rotationDeg, w, h);
        final r9 = rotate(wristAndMcp[1], roi.rotationDeg, w, h);
        final angle = math.atan2(r9.y - r0.y, r9.x - r0.x) * 180 / math.pi;

        // -90 deg == straight up, because image y grows downward.
        expect(angle, closeTo(-90.0, 1e-9), reason: 'after rotating $name');
      });
    });

    test('a palm already vertical is not rotated at all', () {
      final roi = MediaPipeHandDetector.palmRoiFrom(
        lms({0: p(320, 300), 9: p(320, 200)}),
        640,
        480,
      )!;
      expect(roi.rotationDeg, closeTo(0.0, 1e-9));
    });

    test('rotation is rigid — the crop size never changes with angle', () {
      // Same 100px palm span presented at many angles must give one half-size.
      const w = 640, h = 480;
      for (var deg = 0; deg < 360; deg += 17) {
        final r = deg * math.pi / 180;
        final roi = MediaPipeHandDetector.palmRoiFrom(
          lms({
            0: p(320, 240),
            9: p(320 + 100 * math.cos(r), 240 + 100 * math.sin(r)),
          }),
          w,
          h,
        )!;
        expect(roi.halfWFrac * w, closeTo(110.0, 1e-9), reason: 'at $deg deg');
      }
    });
  });

  test('centre is the mean of exactly landmarks 0,1,2,5,9,13,17', () {
    // Lay the 7 ROI landmarks out along a palm that is ALREADY vertical, so
    // rotation is the identity and the expected centre is plain to read.
    // Decoys sit on unused indices and must not move the centre.
    const w = 200, h = 400;
    final roi = MediaPipeHandDetector.palmRoiFrom(
      lms({
        0: p(100, 300), // wrist
        9: p(100, 200), // middle_mcp, directly above -> no rotation
        1: p(70, 290),
        2: p(75, 270),
        5: p(85, 210),
        13: p(115, 210),
        17: p(130, 220),
        4: p(9999, 9999),
        20: p(-9999, -9999),
      }),
      w,
      h,
    )!;

    expect(roi.rotationDeg, closeTo(0.0, 1e-9));
    final expectedX = (100 + 70 + 75 + 85 + 100 + 115 + 130) / 7.0;
    final expectedY = (300 + 290 + 270 + 210 + 200 + 210 + 220) / 7.0;
    expect(roi.cxFrac * w, closeTo(expectedX, 1e-9));
    expect(roi.cyFrac * h, closeTo(expectedY, 1e-9));
  });

  test('centre follows the palm through the rotation, not the raw mean', () {
    // A hand pointing right: the raw landmark mean and the rotated mean differ,
    // and the crop must use the ROTATED one. Cropping at the unrotated mean is
    // exactly the v4 bug.
    const w = 640, h = 480;
    final pts = {
      0: p(200, 100),
      9: p(300, 100),
      1: p(210, 130),
      2: p(230, 130),
      5: p(290, 70),
      13: p(290, 130),
      17: p(270, 140),
    };
    final roi = MediaPipeHandDetector.palmRoiFrom(lms(pts), w, h)!;

    var rx = 0.0, ry = 0.0;
    for (final i in [0, 1, 2, 5, 9, 13, 17]) {
      final r = rotate(pts[i]!, roi.rotationDeg, w, h);
      rx += r.x;
      ry += r.y;
    }
    expect(roi.cxFrac * w, closeTo(rx / 7, 1e-9));
    expect(roi.cyFrac * h, closeTo(ry / 7, 1e-9));

    // And it is genuinely different from the unrotated mean.
    final rawX = pts.values.map((e) => e.x).reduce((a, b) => a + b) / 7;
    expect((roi.cxFrac * w - rawX).abs(), greaterThan(1.0));
  });

  test('half-size is 1.1 x distance(wrist -> middle_mcp)', () {
    // 3-4-5 triangle: distance(0 -> 9) = 5, so half = 5.5
    final roi = MediaPipeHandDetector.palmRoiFrom(
      lms({0: p(0, 0), 9: p(3, 4)}),
      100,
      100,
    )!;

    expect(roi.halfWFrac * 100, closeTo(5.5, 1e-9));
    expect(roi.halfHFrac * 100, closeTo(5.5, 1e-9));
  });

  test('fractions are scale-invariant — same square at any resolution', () {
    final pts = lms({
      0: p(100, 200),
      9: p(100, 260),
      5: p(80, 240),
      13: p(120, 240),
    });
    // Same geometry, described at half resolution.
    final half = lms({
      0: p(50, 100),
      9: p(50, 130),
      5: p(40, 120),
      13: p(60, 120),
    });

    final a = MediaPipeHandDetector.palmRoiFrom(pts, 640, 480)!;
    final b = MediaPipeHandDetector.palmRoiFrom(half, 320, 240)!;

    expect(a.cxFrac, closeTo(b.cxFrac, 1e-9));
    expect(a.cyFrac, closeTo(b.cyFrac, 1e-9));
    expect(a.halfWFrac, closeTo(b.halfWFrac, 1e-9));
    expect(a.halfHFrac, closeTo(b.halfHFrac, 1e-9));
    expect(a.rotationDeg, closeTo(b.rotationDeg, 1e-9));
  });

  group('containment — the gate that stops finger-only frames', () {
    /// A hand whose palm sits at ([cx],[cy]) and points straight up, so the
    /// rotation is a no-op and the geometry is easy to reason about.
    List<math.Point<double>> handAt(double cx, double cy, double span) => lms({
          0: p(cx, cy + span / 2), // wrist
          9: p(cx, cy - span / 2), // middle_mcp, directly above
          1: p(cx - 20, cy + span / 3),
          2: p(cx - 16, cy + span / 6),
          5: p(cx - 18, cy - span / 3),
          13: p(cx + 18, cy - span / 3),
          17: p(cx + 24, cy - span / 5),
        });

    test('a palm fully inside the frame is fully visible', () {
      final roi = MediaPipeHandDetector.palmRoiFrom(
          handAt(320, 240, 100), 640, 480)!;
      expect(roi.palmPointsInFrame, 7);
      expect(roi.insideFraction, closeTo(1.0, 1e-9));
      expect(roi.isFullyVisible, isTrue);
    });

    test('extrapolated landmarks off the top of the frame are counted', () {
      // Only the fingers are in shot: MediaPipe puts the wrist and knuckles
      // above the top edge (negative y). This is the real failure mode.
      final roi = MediaPipeHandDetector.palmRoiFrom(
          handAt(320, -30, 100), 640, 480)!;
      expect(roi.palmPointsInFrame, lessThan(7));
      expect(roi.isFullyVisible, isFalse,
          reason: 'a palm centred off-frame must never be embedded');
    });

    test('a palm half out of the left edge is rejected', () {
      final roi =
          MediaPipeHandDetector.palmRoiFrom(handAt(5, 240, 100), 640, 480)!;
      expect(roi.insideFraction, lessThan(PalmRoi.minInsideFraction));
      expect(roi.isFullyVisible, isFalse);
    });

    test('insideFraction is the real clipped-area ratio', () {
      // half = 1.1 * 100 = 110, centred at x=0 -> exactly half the square's
      // width is off-frame, so half its area survives.
      final roi =
          MediaPipeHandDetector.palmRoiFrom(handAt(0, 240, 100), 640, 480)!;
      expect(roi.insideFraction, closeTo(0.5, 0.02));
    });

    test('a few percent of edge clipping is still acceptable', () {
      // Nudged so a sliver of the square hangs off the edge — training clips
      // too, so this must NOT be rejected.
      final roi =
          MediaPipeHandDetector.palmRoiFrom(handAt(115, 240, 100), 640, 480)!;
      expect(roi.palmPointsInFrame, 7);
      expect(roi.insideFraction, greaterThan(PalmRoi.minInsideFraction));
      expect(roi.isFullyVisible, isTrue);
    });
  });

  test('degenerate input returns null so the caller uses the centre-square '
      'fallback rather than a zero-size crop', () {
    // wrist == middle_mcp -> half-size 0, and no defined rotation
    expect(
      MediaPipeHandDetector.palmRoiFrom(lms({0: p(5, 5), 9: p(5, 5)}), 100, 100),
      isNull,
    );
    // too few landmarks
    expect(MediaPipeHandDetector.palmRoiFrom([p(1, 1)], 100, 100), isNull);
    // zero-size image
    expect(
      MediaPipeHandDetector.palmRoiFrom(lms({0: p(0, 0), 9: p(3, 4)}), 0, 0),
      isNull,
    );
  });
}

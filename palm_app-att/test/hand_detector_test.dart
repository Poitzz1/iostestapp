import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:palmpay_enroll/services/hand_detector.dart';

/// Build a 21-landmark hand from wrist + per-finger [pip, tip] positions.
/// Landmarks not involved in the check are filled with the wrist position.
List<Point<double>> _hand({
  required Point<double> wrist,
  required Map<int, Point<double>> joints,
}) {
  final lm = List<Point<double>>.filled(21, wrist);
  joints.forEach((i, p) => lm[i] = p);
  return lm;
}

void main() {
  group('MediaPipeHandDetector.countExtendedFingers', () {
    test('open palm — all four fingers extended', () {
      final lm = _hand(
        wrist: const Point(50, 90),
        joints: const {
          6: Point(41, 50), 8: Point(40, 35), // index pip, tip
          10: Point(50, 47), 12: Point(50, 30), // middle
          14: Point(57, 50), 16: Point(57, 34), // ring
          18: Point(65, 55), 20: Point(66, 43), // pinky
        },
      );
      expect(MediaPipeHandDetector.countExtendedFingers(lm), 4);
    });

    test('closed fist — tips curled back toward wrist, none extended', () {
      final lm = _hand(
        wrist: const Point(50, 90),
        joints: const {
          6: Point(41, 55), 8: Point(42, 72), // tip closer to wrist than pip
          10: Point(50, 52), 12: Point(50, 70),
          14: Point(57, 55), 16: Point(56, 72),
          18: Point(65, 60), 20: Point(63, 75),
        },
      );
      expect(MediaPipeHandDetector.countExtendedFingers(lm), 0);
    });

    test('two fingers up (victory sign) is not an open palm', () {
      final lm = _hand(
        wrist: const Point(50, 90),
        joints: const {
          6: Point(41, 50), 8: Point(40, 30), // index extended
          10: Point(50, 47), 12: Point(50, 28), // middle extended
          14: Point(57, 55), 16: Point(56, 72), // ring curled
          18: Point(65, 60), 20: Point(63, 75), // pinky curled
        },
      );
      final extended = MediaPipeHandDetector.countExtendedFingers(lm);
      expect(extended, 2);
      expect(extended >= MediaPipeHandDetector.minExtendedFingers, isFalse);
    });

    test('fewer than 21 landmarks counts as nothing extended', () {
      expect(
        MediaPipeHandDetector.countExtendedFingers(
            const [Point(0.0, 0.0), Point(1.0, 1.0)]),
        0,
      );
    });
  });
}

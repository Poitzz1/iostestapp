import 'dart:math' as math;

import 'package:camera/camera.dart';

/// Real-time capture quality gates (README §5).
///
/// We only accept a frame for embedding when the palm is present, centered, in
/// focus and adequately lit. These run on the luminance plane of the live
/// camera frame so they are cheap enough for every frame.
enum QualityIssue { tooDark, tooBright, blurry, offCenter, noPalm, noMotion, spoofDetected, ok }

class QualityReport {
  final bool passed;
  final QualityIssue issue;
  final double brightness; // 0..255 mean luma
  final double blowoutFraction; // 0..1, fraction of pixels near-saturated (>= saturationLevel)
  final double sharpness; // relative focus measure
  final double centerScore; // 0..1, higher = better centered
  final String hint;

  const QualityReport({
    required this.passed,
    required this.issue,
    required this.brightness,
    this.blowoutFraction = 0,
    required this.sharpness,
    required this.centerScore,
    required this.hint,
  });
}

class QualityGate {
  // Tunable thresholds. Kept conservative; adjust with field data.
  //
  // Overexposure is checked as LOCALIZED blowout (fraction of near-saturated
  // pixels), not mean brightness — real overexposure on skin shows up as small
  // saturated patches (specular highlight/glare), not uniform brightness. The
  // gate is intentionally asymmetric: the model handles darkening well
  // (same-palm cosine ~0.935 under -40% brightness) but degrades under
  // brightening (~0.704 under +40%, worse with real glare), so we stay strict
  // on overexposure and lenient on underexposure.
  final double minBrightness;
  final double saturationLevel; // pixel value considered "near-saturated"
  final double maxBlowoutFraction; // fraction of pixels allowed >= saturationLevel
  final double minSharpness;
  final double minCenterScore;

  /// [minBrightness] 40 — the original value, restored.
  ///
  /// It was briefly dropped to 22 to get dim rooms working. That was the wrong
  /// lever: it does not make a dark frame usable, it just stops us saying so,
  /// and the embedding is computed either way. A refusal the student can act on
  /// ("find better light") is worth more than a scan that will not match.
  const QualityGate({
    this.minBrightness = 40,
    this.saturationLevel = 250,
    this.maxBlowoutFraction = 0.025,
    this.minSharpness = 8.0,
    this.minCenterScore = 0.55,
  });

  // ── Low light: the app does NOT drive the camera ──────────────────────────
  //
  // DO NOT add an exposure controller here, and DO NOT add a torch. Both were
  // tried; both made things worse, in different ways.
  //
  // The torch made the same palm stop matching itself. An LED a hand's width
  // from a palm is a specular hotspot with hard falloff, and glare is this
  // model's documented worst case (see the asymmetry note above: ~0.935 under
  // 40% DARKENING but ~0.704 under 40% brightening, "worse with real glare").
  // With v5's genuine mean at 0.6279 against a 0.5508 threshold there is only
  // 0.077 of margin — far less than glare costs.
  //
  // Driving exposure compensation toward a target mean luma was worse still: it
  // deadlocked capture completely. The control signal available here is
  // [_mean] over the WHOLE FRAME, and a palm held close against a dark
  // background has a low frame mean even when the palm itself is correctly lit.
  // Chasing that mean saturates the palm long before the mean arrives, at which
  // point [maxBlowoutFraction] rejects the frame as "too bright" — while the
  // mean, still short of target, tells the controller to push harder. The gate
  // and the controller fight each other and nothing is ever capturable.
  //
  // Fixing that properly needs a control signal measured over the PALM REGION
  // rather than the frame, which is not available at this point in the pipeline
  // (the ROI comes from hand detection, which runs after this gate). Until it
  // is, the camera's own auto-exposure — a well-tuned vendor algorithm with
  // access to the real metering grid — is left alone to do its job.
  //
  // Low light is now understood to be a MODEL/ENROLLMENT-PROTOCOL problem, not
  // a capture-tuning one. See issue.md: the remaining work is re-deriving the
  // threshold against cross-illumination genuine pairs and enrolling across
  // lighting conditions, not another loop in this file.

  /// Evaluate a live YUV/BGRA frame using its luminance.
  QualityReport evaluate(CameraImage frame) {
    final luma = _lumaPlane(frame);
    final w = frame.width, h = frame.height;

    final brightness = _mean(luma);
    if (brightness < minBrightness) {
      return _fail(QualityIssue.tooDark, brightness, 0, 0, 0, 'Too dark — find better light');
    }

    // Localized overexposure check: small saturated patches (glare/specular
    // highlight) are what actually hurt the model, not overall brightness.
    final blowout = _blowoutFraction(luma);
    if (blowout > maxBlowoutFraction) {
      return _fail(QualityIssue.tooBright, brightness, blowout, 0, 0,
          'Too bright — step out of direct light');
    }

    final sharpness = _sharpness(luma, w, h);
    if (sharpness < minSharpness) {
      return _fail(
          QualityIssue.blurry, brightness, blowout, sharpness, 0, 'Hold still — image is blurry');
    }

    // Center energy vs edge energy as a crude "is the palm centered" proxy.
    final centerScore = _centerScore(luma, w, h);
    if (centerScore < minCenterScore) {
      return _fail(QualityIssue.offCenter, brightness, blowout, sharpness, centerScore,
          'Center your palm in the ring');
    }

    return QualityReport(
      passed: true,
      issue: QualityIssue.ok,
      brightness: brightness,
      blowoutFraction: blowout,
      sharpness: sharpness,
      centerScore: centerScore,
      hint: 'Hold still…',
    );
  }

  QualityReport _fail(
          QualityIssue i, double b, double blowout, double s, double c, String hint) =>
      QualityReport(
          passed: false,
          issue: i,
          brightness: b,
          blowoutFraction: blowout,
          sharpness: s,
          centerScore: c,
          hint: hint);

  List<int> _lumaPlane(CameraImage frame) {
    // Plane 0 is luminance for YUV420; for BGRA we approximate with the green
    // channel stride — good enough for gates. YUV is the Android default.
    return frame.planes.first.bytes;
  }

  double _mean(List<int> data) {
    var sum = 0;
    // Sample every 4th byte for speed; luma plane is large.
    var count = 0;
    for (var i = 0; i < data.length; i += 4) {
      sum += data[i];
      count++;
    }
    return count == 0 ? 0 : sum / count;
  }

  /// Fraction of sampled pixels at or above [saturationLevel] — i.e. small
  /// blown-out patches (specular highlight/glare) rather than overall
  /// brightness. This is what actually predicts model degradation, since a
  /// uniformly bright-but-unsaturated frame is fine.
  double _blowoutFraction(List<int> data) {
    var saturated = 0;
    var count = 0;
    for (var i = 0; i < data.length; i += 4) {
      if (data[i] >= saturationLevel) saturated++;
      count++;
    }
    return count == 0 ? 0 : saturated / count;
  }

  /// Variance-of-Laplacian-style focus measure on a subsampled grid.
  double _sharpness(List<int> luma, int w, int h) {
    if (luma.length < w * h) return 0;
    const step = 8;
    var sum = 0.0, sumSq = 0.0, n = 0;
    for (var y = step; y < h - step; y += step) {
      for (var x = step; x < w - step; x += step) {
        final c = luma[y * w + x];
        final lap = (4 * c) -
            luma[y * w + (x - step)] -
            luma[y * w + (x + step)] -
            luma[(y - step) * w + x] -
            luma[(y + step) * w + x];
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 0;
    final mean = sum / n;
    return math.sqrt((sumSq / n) - (mean * mean));
  }

  /// Ratio of mean brightness in the central region vs the whole frame. A palm
  /// filling the center raises this above the surrounding background.
  double _centerScore(List<int> luma, int w, int h) {
    if (luma.length < w * h) return 0;
    final cx0 = (w * 0.25).floor(), cx1 = (w * 0.75).floor();
    final cy0 = (h * 0.25).floor(), cy1 = (h * 0.75).floor();
    var centerSum = 0.0, centerN = 0;
    for (var y = cy0; y < cy1; y += 4) {
      for (var x = cx0; x < cx1; x += 4) {
        centerSum += luma[y * w + x];
        centerN++;
      }
    }
    final centerMean = centerN == 0 ? 0 : centerSum / centerN;
    final overall = _mean(luma);
    if (overall == 0) return 0;
    // Normalize into 0..1: palm-in-center typically 1.0–1.4x background.
    final ratio = centerMean / overall;
    return (ratio - 0.7).clamp(0.0, 1.0) / 0.7;
  }
}

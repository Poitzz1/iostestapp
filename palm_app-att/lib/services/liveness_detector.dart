import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';

/// On-device liveness detection for anti-spoofing (three-layer approach).
///
/// Prevents enrollment from printed photos, phone/tablet screens, and static
/// images. Runs on the luminance plane and per-frame embeddings — no extra ML
/// model, no internet, no added UX friction.
///
/// Three complementary layers:
///  1. **Motion liveness** — frame-to-frame pixel difference detects micro-tremor
///     that real hands have but photos don't.
///  2. **Texture analysis** — high-frequency energy detects moiré patterns from
///     screens and unnatural flatness from prints.
///  3. **Embedding variance** — cosine similarity between consecutive embeddings.
///     A photo produces near-identical embeddings (>0.998); a real palm varies
///     naturally (0.85–0.98).

enum LivenessIssue {
  ok,
  noMotion,        // static image — no micro-tremor detected
  tooMuchMotion,   // scene change / camera moving too fast
  screenDetected,  // moiré pattern from a display
  printDetected,   // unnaturally flat texture from a printout
  embeddingStatic, // consecutive embeddings too similar (photo)
  embeddingWild,   // consecutive embeddings too different (not same palm)
}

class LivenessReport {
  final bool passed;
  final LivenessIssue issue;
  final double motionScore;
  final double textureVariance;
  final double moireScore;
  final double embeddingSimilarity;
  final String hint;

  const LivenessReport({
    required this.passed,
    required this.issue,
    this.motionScore = 0,
    this.textureVariance = 0,
    this.moireScore = 0,
    this.embeddingSimilarity = 0,
    required this.hint,
  });

  static const ok = LivenessReport(
    passed: true,
    issue: LivenessIssue.ok,
    hint: 'Live palm detected',
  );
}

class LivenessDetector {
  /// Minimum mean absolute pixel difference between consecutive frames.
  /// Real hand micro-tremor is typically 3–15; photos score <2.
  final double minMotionScore;

  /// Upper bound for motion — rejects scene changes / camera switching.
  final double maxMotionScore;

  /// Below this texture variance, the image is suspiciously flat (print).
  final double minTextureVariance;

  /// Above this moiré ratio, a screen display is likely.
  final double maxMoireScore;

  /// Above this cosine similarity, embeddings are suspiciously identical (photo).
  final double maxEmbeddingSimilarity;

  /// Below this cosine similarity, it's a different palm or garbage frame.
  final double minEmbeddingSimilarity;

  /// Number of initial frames to skip motion check (need a previous frame).
  static const int warmupFrames = 1;

  const LivenessDetector({
    this.minMotionScore = 1.8,
    this.maxMotionScore = 45.0,
    this.minTextureVariance = 4.0,
    this.maxMoireScore = 0.45,
    this.maxEmbeddingSimilarity = 0.998,
    this.minEmbeddingSimilarity = 0.80,
  });

  // ─── Layer 1: Motion Liveness ───────────────────────────────────────────────

  /// Compute mean absolute pixel difference between current and previous frame
  /// in the central 50% of the luminance plane. Real hands have natural
  /// micro-tremor; photos held still produce near-zero motion.
  LivenessReport evaluateMotion(CameraImage current, List<int>? previousLuma) {
    if (previousLuma == null) {
      // First frame — skip motion check, can't compare yet.
      return LivenessReport.ok;
    }

    final currentLuma = _lumaPlane(current);
    final w = current.width, h = current.height;

    if (currentLuma.length < w * h || previousLuma.length < w * h) {
      return LivenessReport.ok; // can't evaluate, pass through
    }

    // Analyze the central 50% region (where the palm should be).
    final cx0 = (w * 0.25).floor(), cx1 = (w * 0.75).floor();
    final cy0 = (h * 0.25).floor(), cy1 = (h * 0.75).floor();

    var totalDiff = 0.0;
    var count = 0;

    // Subsample every 4th pixel for speed.
    for (var y = cy0; y < cy1; y += 4) {
      for (var x = cx0; x < cx1; x += 4) {
        final idx = y * w + x;
        totalDiff += (currentLuma[idx] - previousLuma[idx]).abs();
        count++;
      }
    }

    final motionScore = count == 0 ? 0.0 : totalDiff / count;

    if (motionScore < minMotionScore) {
      return LivenessReport(
        passed: false,
        issue: LivenessIssue.noMotion,
        motionScore: motionScore,
        hint: 'Move your hand slightly',
      );
    }

    if (motionScore > maxMotionScore) {
      return LivenessReport(
        passed: false,
        issue: LivenessIssue.tooMuchMotion,
        motionScore: motionScore,
        hint: 'Hold steady — too much movement',
      );
    }

    return LivenessReport(
      passed: true,
      issue: LivenessIssue.ok,
      motionScore: motionScore,
      hint: 'Live palm detected',
    );
  }

  // ─── Layer 2: Texture Analysis ──────────────────────────────────────────────

  /// Analyze the frame for signs of screen display (moiré) or print (flat texture).
  ///
  /// - **Moiré detection**: Screens display a pixel grid that creates periodic
  ///   high-frequency energy when photographed. We measure the ratio of
  ///   high-frequency to low-frequency Laplacian energy.
  /// - **Texture flatness**: Printed photos have unnaturally uniform texture
  ///   compared to real skin with pores, lines, and natural variation.
  LivenessReport evaluateTexture(CameraImage frame) {
    final luma = _lumaPlane(frame);
    final w = frame.width, h = frame.height;

    if (luma.length < w * h) {
      return LivenessReport.ok; // can't evaluate
    }

    // --- Texture variance (fine-grained Laplacian in center region) ---
    final textureVar = _textureVariance(luma, w, h);
    if (textureVar < minTextureVariance) {
      return LivenessReport(
        passed: false,
        issue: LivenessIssue.printDetected,
        textureVariance: textureVar,
        hint: 'Spoof detected — use a real palm',
      );
    }

    // --- Moiré detection (periodic high-frequency energy) ---
    final moireScore = _moireScore(luma, w, h);
    if (moireScore > maxMoireScore) {
      return LivenessReport(
        passed: false,
        issue: LivenessIssue.screenDetected,
        moireScore: moireScore,
        textureVariance: textureVar,
        hint: 'Screen detected — use a real palm',
      );
    }

    return LivenessReport(
      passed: true,
      issue: LivenessIssue.ok,
      textureVariance: textureVar,
      moireScore: moireScore,
      hint: 'Live palm detected',
    );
  }

  /// Fine-grained texture variance using a small 3×3 Laplacian kernel on the
  /// central region. Real skin has rich micro-texture (pores, lines); prints
  /// are smooth and flat.
  double _textureVariance(List<int> luma, int w, int h) {
    final cx0 = (w * 0.3).floor(), cx1 = (w * 0.7).floor();
    final cy0 = (h * 0.3).floor(), cy1 = (h * 0.7).floor();

    var sum = 0.0, sumSq = 0.0, n = 0;

    // Small step for fine-grained texture analysis.
    const step = 3;
    for (var y = cy0 + step; y < cy1 - step; y += step) {
      for (var x = cx0 + step; x < cx1 - step; x += step) {
        final c = luma[y * w + x];
        // 3×3 Laplacian (sum of 4-connected neighbors minus 4× center)
        final lap = luma[(y - 1) * w + x] +
            luma[(y + 1) * w + x] +
            luma[y * w + (x - 1)] +
            luma[y * w + (x + 1)] -
            4 * c;
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }

    if (n == 0) return 0;
    final mean = sum / n;
    return math.sqrt((sumSq / n) - (mean * mean));
  }

  /// Detect moiré patterns from screens. Screens have a periodic pixel grid
  /// that creates regular high-frequency patterns when photographed. We compare
  /// energy at fine vs coarse Laplacian scales — screens have abnormally high
  /// fine-scale energy relative to coarse.
  double _moireScore(List<int> luma, int w, int h) {
    final cx0 = (w * 0.3).floor(), cx1 = (w * 0.7).floor();
    final cy0 = (h * 0.3).floor(), cy1 = (h * 0.7).floor();

    var fineEnergy = 0.0, coarseEnergy = 0.0;
    var fineN = 0, coarseN = 0;

    // Fine-scale: step 2 (captures screen pixel grid).
    for (var y = cy0 + 2; y < cy1 - 2; y += 4) {
      for (var x = cx0 + 2; x < cx1 - 2; x += 4) {
        final c = luma[y * w + x];
        final lap = luma[(y - 1) * w + x] +
            luma[(y + 1) * w + x] +
            luma[y * w + (x - 1)] +
            luma[y * w + (x + 1)] -
            4 * c;
        fineEnergy += lap.abs();
        fineN++;
      }
    }

    // Coarse-scale: step 8 (natural skin texture).
    for (var y = cy0 + 8; y < cy1 - 8; y += 8) {
      for (var x = cx0 + 8; x < cx1 - 8; x += 8) {
        final c = luma[y * w + x];
        final lap = luma[(y - 4) * w + x] +
            luma[(y + 4) * w + x] +
            luma[y * w + (x - 4)] +
            luma[y * w + (x + 4)] -
            4 * c;
        coarseEnergy += lap.abs();
        coarseN++;
      }
    }

    final fineMean = fineN == 0 ? 0.0 : fineEnergy / fineN;
    final coarseMean = coarseN == 0 ? 1.0 : coarseEnergy / coarseN;

    if (coarseMean < 1) return 0; // avoid division by near-zero
    // Ratio of fine-to-coarse energy. Screens score high (>0.4); real skin lower.
    return fineMean / (coarseMean + fineMean);
  }

  // ─── Layer 3: Embedding Variance ────────────────────────────────────────────

  /// Check cosine similarity between the current and previous frame's embedding.
  /// A photo produces near-identical embeddings (>0.998); a real palm varies
  /// naturally across frames (typically 0.92–0.98).
  LivenessReport evaluateEmbeddingVariance(
    Float32List currentEmb,
    Float32List? previousEmb,
  ) {
    if (previousEmb == null) {
      // First embedding — nothing to compare, pass through.
      return LivenessReport.ok;
    }

    final similarity = _cosine(currentEmb, previousEmb);

    if (similarity > maxEmbeddingSimilarity) {
      return LivenessReport(
        passed: false,
        issue: LivenessIssue.embeddingStatic,
        embeddingSimilarity: similarity,
        hint: 'Spoof detected — static image',
      );
    }

    if (similarity < minEmbeddingSimilarity) {
      return LivenessReport(
        passed: false,
        issue: LivenessIssue.embeddingWild,
        embeddingSimilarity: similarity,
        hint: 'Keep your palm steady',
      );
    }

    return LivenessReport(
      passed: true,
      issue: LivenessIssue.ok,
      embeddingSimilarity: similarity,
      hint: 'Live palm detected',
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  /// Extract luminance plane from a camera frame.
  List<int> _lumaPlane(CameraImage frame) {
    return frame.planes.first.bytes;
  }

  /// Store a copy of the luminance plane for the next frame comparison.
  List<int> copyLuma(CameraImage frame) {
    return List<int>.from(frame.planes.first.bytes);
  }

  /// Cosine similarity between two float vectors.
  double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    final denom = math.sqrt(na) * math.sqrt(nb);
    if (denom == 0) return 0;
    return dot / denom;
  }
}

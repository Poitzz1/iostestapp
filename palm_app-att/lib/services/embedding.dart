import 'dart:math' as math;
import 'dart:typed_data';

/// Embedding math (README §2, "Critical model facts").
///
/// - The model output is ALREADY L2-normalized (baked into the ONNX graph).
///   We do NOT normalize a single model output again.
/// - Enrollment template = mean of the per-frame L2-normalized embeddings,
///   then re-normalized once. Store that single 256-float vector.
/// - Similarity is cosine (dot product of unit vectors).
class EmbeddingMath {
  /// Cosine similarity. For unit vectors this is just the dot product, but we
  /// divide by norms defensively so the parity test is meaningful even if an
  /// input is not perfectly normalized.
  static double cosine(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('length mismatch: ${a.length} vs ${b.length}');
    }
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    final denom = math.sqrt(na) * math.sqrt(nb);
    if (denom == 0) return 0.0;
    return dot / denom;
  }

  /// L2-normalize a vector in place-safe manner (returns a new list).
  static Float32List l2Normalize(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = math.sqrt(sum);
    final out = Float32List(v.length);
    if (norm == 0) return out;
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  /// Build the enrollment template: mean of the per-frame embeddings, then a
  /// single re-normalization. Each input is expected to already be L2-normalized
  /// (they come straight from the model output).
  static Float32List buildTemplate(List<Float32List> perFrame) {
    if (perFrame.isEmpty) {
      throw ArgumentError('need at least one frame embedding');
    }
    final dim = perFrame.first.length;
    final acc = Float64List(dim);
    for (final e in perFrame) {
      if (e.length != dim) {
        throw ArgumentError('embedding dim mismatch');
      }
      for (var i = 0; i < dim; i++) {
        acc[i] += e[i];
      }
    }
    final mean = List<double>.generate(dim, (i) => acc[i] / perFrame.length);
    return l2Normalize(mean); // re-normalize once
  }
}

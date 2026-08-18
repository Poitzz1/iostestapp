import 'dart:math' as math;
import 'dart:typed_data';

import '../config/deploy_config.dart';

/// Numeric precision the embedding model is executed at.
///
/// ## INT8 is deliberately absent, and must stay absent
///
/// This is not an oversight and not a "we haven't got round to it". The model's
/// own deploy notes record that INT8 quantization CORRUPTS this backbone: the
/// quantized weights score ~0.70 cosine against the fp32 weights on the same
/// input — meaning the INT8 model is not a slightly-lossier version of this
/// model, it is a different model that happens to have the same shape. Every
/// enrolled template in Firestore was produced at fp32; scoring an INT8 probe
/// against them compares vectors from two different embedding spaces, and the
/// resulting similarity number is meaningless rather than merely noisy.
///
/// That finding is a property of the BACKBONE, not of any particular runtime,
/// so it carries over to web unchanged. There is no "INT8-web" variant to reach
/// for when WASM inference feels slow. Fix slowness with a better execution
/// provider, a smaller input, or fewer frames — never with INT8.
enum ModelPrecision {
  /// The default, everywhere, on every target. Universally supported across
  /// ONNX Runtime execution providers (WASM, WebGL, WebGPU, native CPU) with no
  /// per-backend surprises, and it is the precision every stored template was
  /// generated at.
  fp32,

  /// OPTIONAL upgrade, web only, and only when BOTH hold:
  ///   1. a performant fp16-capable backend is actually available (in practice
  ///      WebGPU — the WASM provider gains nothing from fp16), and
  ///   2. [PalmModel.verifyPrecisionParity] has passed against fp32 on a fixed
  ///      test image at >= [DeployConfig.parityThreshold] cosine (0.999).
  ///
  /// Never selected implicitly. If the parity check has not been run and
  /// passed in THIS session, the model stays on [fp32].
  fp16,
}

/// Swappable on-device embedding model.
///
/// The concrete implementation differs per target — native uses the
/// `onnxruntime` package (FFI, no web support), web bridges to the
/// `onnxruntime-web` JS package via `dart:js_interop` — but nothing outside
/// this file's implementers should care which is underneath. Callers depend on
/// this interface only.
abstract class PalmModel {
  DeployConfig get cfg;

  bool get isLoaded;

  /// Precision the session is currently executing at. Always [ModelPrecision.fp32]
  /// until a parity check has explicitly promoted it.
  ModelPrecision get precision;

  /// Human-readable execution backend, for diagnostics/logs
  /// (e.g. `"onnxruntime-web/wasm"`, `"onnxruntime/native"`).
  String get backend;

  Future<void> load();

  /// Run one NCHW [1,3,H,W] float tensor through the model and return the raw
  /// [DeployConfig.embeddingDim]-float output. The output is already
  /// L2-normalized by the graph — implementations must NOT normalize it again
  /// (README §2).
  Future<Float32List> embed(Float32List nchw);

  void dispose();
}

/// Result of comparing an fp16 session against the fp32 reference on a fixed
/// input. See [ModelPrecision.fp16].
class PrecisionParityResult {
  /// Cosine similarity between the fp16 and fp32 embeddings of the same image.
  final double cosine;

  /// The bar [cosine] had to clear — `deploy_config.parity_threshold` (0.999).
  final double threshold;

  const PrecisionParityResult({required this.cosine, required this.threshold});

  bool get passed => cosine >= threshold;

  @override
  String toString() =>
      'PrecisionParityResult(cosine: ${cosine.toStringAsFixed(6)}, '
      'threshold: $threshold, passed: $passed)';
}

/// Cosine similarity between two equal-length vectors.
///
/// Both operands here are model outputs, which the graph has already
/// L2-normalized, so this reduces to a dot product — but the norms are divided
/// out anyway so a caller passing an un-normalized vector gets a correct answer
/// rather than a silently inflated one.
double cosineSimilarity(Float32List a, Float32List b) {
  if (a.length != b.length) {
    throw ArgumentError('length mismatch: ${a.length} vs ${b.length}');
  }
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

/// Deployment / preprocessing contract for the palm model.
///
/// Every value that affects the image -> tensor pipeline lives here and is read
/// from `assets/models/deploy_config.json`. NOTHING about preprocessing is
/// hardcoded in Dart — a mismatch (size, channel order, scale, mean, std)
/// silently corrupts every embedding, so there is exactly one source of truth.
class DeployConfig {
  final String modelFile;
  final String modelVersion;
  final String inputName;
  final String outputName;
  final int inputSize;
  final String channelOrder; // "RGB"
  final String layout; // "NCHW"
  final String scale; // "divide_by_255"
  final List<double> normalizeMean;
  final List<double> normalizeStd;
  final bool outputIsL2Normalized;
  final int embeddingDim;
  final String similarity; // "cosine"
  final double parityThreshold;

  const DeployConfig({
    required this.modelFile,
    required this.modelVersion,
    required this.inputName,
    required this.outputName,
    required this.inputSize,
    required this.channelOrder,
    required this.layout,
    required this.scale,
    required this.normalizeMean,
    required this.normalizeStd,
    required this.outputIsL2Normalized,
    required this.embeddingDim,
    required this.similarity,
    required this.parityThreshold,
  });

  static const String assetPath = 'assets/models/deploy_config.json';

  factory DeployConfig.fromJson(Map<String, dynamic> j) {
    List<double> doubles(dynamic v) =>
        (v as List).map((e) => (e as num).toDouble()).toList(growable: false);

    final cfg = DeployConfig(
      modelFile: j['model_file'] as String,
      modelVersion: j['model_version'] as String,
      inputName: j['input_name'] as String,
      outputName: j['output_name'] as String,
      inputSize: (j['input_size'] as num).toInt(),
      channelOrder: j['channel_order'] as String,
      layout: j['layout'] as String,
      scale: j['scale'] as String,
      normalizeMean: doubles(j['normalize_mean']),
      normalizeStd: doubles(j['normalize_std']),
      outputIsL2Normalized: j['output_is_l2_normalized'] as bool,
      embeddingDim: (j['embedding_dim'] as num?)?.toInt() ?? 256,
      similarity: (j['similarity'] as String?) ?? 'cosine',
      parityThreshold: (j['parity_threshold'] as num?)?.toDouble() ?? 0.999,
    );
    cfg._assertSupported();
    return cfg;
  }

  static Future<DeployConfig> load() async {
    final raw = await rootBundle.loadString(assetPath);
    return DeployConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Fail loud and early if the config asks for something the pipeline in
  /// [PalmPreprocessor] does not implement, rather than silently producing a
  /// wrong tensor.
  void _assertSupported() {
    if (channelOrder.toUpperCase() != 'RGB') {
      throw UnsupportedError('channel_order "$channelOrder" not supported (RGB only)');
    }
    if (layout.toUpperCase() != 'NCHW') {
      throw UnsupportedError('layout "$layout" not supported (NCHW only)');
    }
    if (scale != 'divide_by_255') {
      throw UnsupportedError('scale "$scale" not supported (divide_by_255 only)');
    }
    if (normalizeMean.length != 3 || normalizeStd.length != 3) {
      throw ArgumentError('normalize_mean/std must have 3 channels');
    }
  }
}

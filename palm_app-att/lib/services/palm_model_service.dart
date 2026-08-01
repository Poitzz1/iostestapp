import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import '../config/deploy_config.dart';

/// Loads `palm_256_l2_fp32.onnx` and runs inference on-device.
///
/// One [OrtSession] is created once and reused for every frame. Inference is
/// synchronous native work; callers should run capture-loop inference off the
/// UI isolate (see [CaptureController]).
class PalmModelService {
  final DeployConfig cfg;
  OrtSession? _session;

  PalmModelService(this.cfg);

  bool get isLoaded => _session != null;

  Future<void> load() async {
    if (_session != null) return;
    OrtEnv.instance.init();
    final raw = await rootBundle.load('assets/models/${cfg.modelFile}');
    final bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    _session = OrtSession.fromBuffer(bytes, options);
  }

  /// Run one NCHW [1,3,H,W] float tensor through the model and return the raw
  /// 256-float output. The output is already L2-normalized by the graph — we do
  /// NOT normalize it again here (README §2).
  Float32List embed(Float32List nchw) {
    final session = _session;
    if (session == null) {
      throw StateError('PalmModelService.load() not called');
    }
    final s = cfg.inputSize;
    final shape = [1, 3, s, s];
    final inputTensor = OrtValueTensor.createTensorWithDataList(nchw, shape);
    final inputs = {cfg.inputName: inputTensor};
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = session.run(runOptions, inputs, [cfg.outputName]);
      final out = outputs.first!.value;
      final flat = _flatten(out);
      if (flat.length != cfg.embeddingDim) {
        throw StateError(
            'model returned ${flat.length} dims, expected ${cfg.embeddingDim}');
      }
      return Float32List.fromList(flat);
    } finally {
      inputTensor.release();
      runOptions.release();
      outputs?.forEach((o) => o?.release());
    }
  }

  List<double> _flatten(Object? value) {
    // onnxruntime returns nested lists shaped like the output ([1, 256]).
    if (value is List && value.isNotEmpty && value.first is List) {
      return (value.first as List).map((e) => (e as num).toDouble()).toList();
    }
    if (value is List) {
      return value.map((e) => (e as num).toDouble()).toList();
    }
    throw StateError('unexpected model output type: ${value.runtimeType}');
  }

  void dispose() {
    _session?.release();
    _session = null;
    OrtEnv.instance.release();
  }
}

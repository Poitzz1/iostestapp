import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

import '../config/deploy_config.dart';
import 'palm_model.dart';

/// Native [PalmModel] — the `onnxruntime` package over FFI.
///
/// This implementation is unreachable on web: `onnxruntime` 1.4.1 declares
/// support for Android/iOS/Linux/macOS/Windows only ("Web (Coming soon)"), and
/// it transitively imports `dart:ffi`, which `dart compile js` rejects outright
/// with "Only JS interop members may be 'external'". That is why the model sits
/// behind [PalmModel] at all — see `palm_model_web.dart` for the browser path.
///
/// One [OrtSession] is created once and reused for every frame. Inference is
/// synchronous native work; callers should run capture-loop inference off the
/// UI isolate (see `CaptureController`).
class NativePalmModel implements PalmModel {
  @override
  final DeployConfig cfg;

  OrtSession? _session;

  NativePalmModel(this.cfg);

  @override
  bool get isLoaded => _session != null;

  /// Native always runs fp32. The fp16 path is a web-only optimisation gated on
  /// a WebGPU-class backend; there is nothing to gain from it here, and every
  /// stored template was produced at fp32.
  @override
  ModelPrecision get precision => ModelPrecision.fp32;

  @override
  String get backend => 'onnxruntime/native';

  @override
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

  @override
  Future<Float32List> embed(Float32List nchw) async {
    final session = _session;
    if (session == null) {
      throw StateError('NativePalmModel.load() not called');
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

  @override
  void dispose() {
    _session?.release();
    _session = null;
    OrtEnv.instance.release();
  }
}

/// Factory used by the conditional import in `palm_model_service.dart`.
PalmModel createPalmModel(DeployConfig cfg) => NativePalmModel(cfg);

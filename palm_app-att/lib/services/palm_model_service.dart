import 'dart:typed_data';

import '../config/deploy_config.dart';
import 'palm_model.dart';

// Resolved at compile time. Native gets the FFI-backed `onnxruntime` package;
// web gets the `dart:js_interop` bridge to `onnxruntime-web`, because
// `onnxruntime` has no web target and `dart:ffi` cannot be compiled to JS.
// Callers of PalmModelService are unaffected by which one they got.
import 'palm_model_native.dart'
    if (dart.library.js_interop) 'palm_model_web.dart';

export 'palm_model.dart' show ModelPrecision, PrecisionParityResult;

/// Loads the .onnx named by `deploy_config.json -> model_file` and runs
/// inference on-device.
///
/// Thin facade over the platform [PalmModel] implementation, kept so the rest
/// of the app has one name to depend on. The swap between the native and web
/// runtimes happens in the conditional import above and is invisible here.
class PalmModelService {
  final DeployConfig cfg;
  final PalmModel _model;

  PalmModelService(this.cfg) : _model = createPalmModel(cfg);

  /// Escape hatch for tests and for the fp16 parity check, which needs the
  /// concrete web implementation. Production code should not reach for this.
  PalmModel get model => _model;

  bool get isLoaded => _model.isLoaded;

  /// Precision inference is running at — [ModelPrecision.fp32] unless a parity
  /// check has explicitly promoted it. Never INT8; see [ModelPrecision].
  ModelPrecision get precision => _model.precision;

  /// Execution backend, for diagnostics (`onnxruntime/native`,
  /// `onnxruntime-web/wasm`).
  String get backend => _model.backend;

  Future<void> load() => _model.load();

  /// Run one NCHW [1,3,H,W] float tensor through the model and return the raw
  /// 256-float output. The output is already L2-normalized by the graph — we do
  /// NOT normalize it again here (README §2).
  ///
  /// Now returns a Future: the web runtime's `run()` is asynchronous and there
  /// is no way to block on a JS promise in the browser. Native inference is
  /// still synchronous work under the hood.
  Future<Float32List> embed(Float32List nchw) => _model.embed(nchw);

  void dispose() => _model.dispose();
}

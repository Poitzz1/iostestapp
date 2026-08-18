import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../config/deploy_config.dart';
import 'palm_model.dart';

// ─── onnxruntime-web JS interop ──────────────────────────────────────────────
//
// The `onnxruntime` pub package has no web target (it is FFI-backed and fails
// `dart compile js` outright), so the browser path bridges to the official
// `onnxruntime-web` npm package instead. `web/index.html` loads the UMD bundle
// and exposes it as the global `ort`.
//
// Only the handful of members actually used are declared. The `ort` API surface
// is large and mostly irrelevant here; binding more of it would be surface to
// keep in sync for no benefit.

@JS('ort')
external ORT get _ort;

extension type ORT._(JSObject _) implements JSObject {
  external ORTEnv get env;

  // Capitalised because it binds the JS property `ort.InferenceSession` by
  // name; renaming it to satisfy the lint would bind a property that does not
  // exist.
  // ignore: non_constant_identifier_names
  external ORTInferenceSessionFactory get InferenceSession;
}

extension type ORTEnv._(JSObject _) implements JSObject {
  external ORTWasmEnv get wasm;
}

extension type ORTWasmEnv._(JSObject _) implements JSObject {
  /// Where the `.wasm` binaries are served from. Set explicitly so the runtime
  /// does not try to fetch them from a CDN — the app must work on a campus
  /// network with no external egress, and a silent CDN dependency turns into a
  /// blank capture screen for every student at once.
  external set wasmPaths(JSAny paths);

  /// Threads require cross-origin isolation (COOP/COEP headers). Most static
  /// hosts do not send them, and without isolation `SharedArrayBuffer` is
  /// unavailable and multi-threaded init throws. Pinned to 1 so the session
  /// initialises on any host; see the note in [WebPalmModel.load].
  external set numThreads(int n);
}

extension type ORTInferenceSessionFactory._(JSObject _) implements JSObject {
  external JSPromise<ORTInferenceSession> create(JSAny model, JSObject options);
}

extension type ORTInferenceSession._(JSObject _) implements JSObject {
  external JSPromise<JSObject> run(JSObject feeds);
  external JSPromise<JSAny?> release();
}

@JS('ort.Tensor')
extension type ORTTensor._(JSObject _) implements JSObject {
  external ORTTensor(String type, JSAny data, JSArray<JSNumber> dims);

  external JSAny get data;
}

/// Web [PalmModel] — bridges to `onnxruntime-web` through `dart:js_interop`.
///
/// Behaviourally equivalent to [NativePalmModel] from the caller's side: same
/// [PalmModel] interface, same NCHW input contract, same
/// already-L2-normalized output that must not be re-normalized. The preprocessing
/// constants are untouched and are NOT re-derived here — they come from
/// `deploy_config.json` exactly as on native.
class WebPalmModel implements PalmModel {
  @override
  final DeployConfig cfg;

  ORTInferenceSession? _session;
  ModelPrecision _precision = ModelPrecision.fp32;
  String _backend = 'onnxruntime-web/wasm';

  WebPalmModel(this.cfg);

  @override
  bool get isLoaded => _session != null;

  /// fp32 unless [verifyPrecisionParity] has explicitly promoted it this
  /// session. Never promoted implicitly — see [ModelPrecision].
  @override
  ModelPrecision get precision => _precision;

  @override
  String get backend => _backend;

  @override
  Future<void> load() async {
    if (_session != null) return;

    // Serve the WASM binaries from our own origin (see [wasmPaths]).
    //
    // Must be an ABSOLUTE url. onnxruntime-web loads its backend glue as an ES
    // module, and a bare relative path like 'assets/ort/' fails module
    // resolution with:
    //   no available backend found. ERR: [wasm] TypeError: Failed to resolve
    //   module specifier 'assets/ort/ort-wasm-simd-threaded.mjs'
    // `Uri.base` is the page URL on web, so resolving against it also keeps
    // this correct when the app is served under a sub-path (--base-href).
    _ort.env.wasm.wasmPaths = Uri.base.resolve('assets/ort/').toString().toJS;
    // Single-threaded: no cross-origin isolation assumption. See [numThreads].
    _ort.env.wasm.numThreads = 1;

    final raw = await rootBundle.load('assets/models/${cfg.modelFile}');
    final bytes = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);

    // Execution providers in preference order. 'webgl' is listed after 'wasm'
    // deliberately: the WebGL provider silently falls back to fp32 for
    // unsupported ops and has historically mis-executed some reductions, and a
    // WRONG embedding is far worse here than a slow one — it scores against
    // every stored template as if it were a different palm.
    final options = _jsObject({
      'executionProviders': ['wasm'].map((e) => e.toJS).toList().toJS,
      'graphOptimizationLevel': 'all'.toJS,
    });

    _session = await _ort.InferenceSession
        .create(bytes.toJS, options)
        .toDart;
    _backend = 'onnxruntime-web/wasm';
  }

  @override
  Future<Float32List> embed(Float32List nchw) async {
    final session = _session;
    if (session == null) {
      throw StateError('WebPalmModel.load() not called');
    }
    final s = cfg.inputSize;
    final expected = 1 * 3 * s * s;
    if (nchw.length != expected) {
      throw ArgumentError(
          'input tensor has ${nchw.length} floats, expected $expected for '
          '[1,3,$s,$s]');
    }

    final tensor = ORTTensor(
      'float32',
      nchw.toJS,
      <JSNumber>[1.toJS, 3.toJS, s.toJS, s.toJS].toJS,
    );

    final feeds = _jsObject({cfg.inputName: tensor as JSAny});
    final results = await session.run(feeds).toDart;

    final out = results.getProperty(cfg.outputName.toJS) as ORTTensor?;
    if (out == null) {
      throw StateError(
          'model produced no output named "${cfg.outputName}"');
    }
    final flat = (out.data as JSFloat32Array).toDart;
    if (flat.length != cfg.embeddingDim) {
      throw StateError(
          'model returned ${flat.length} dims, expected ${cfg.embeddingDim}');
    }
    return Float32List.fromList(flat);
  }

  /// Compare this session's output against the fp32 reference on a FIXED test
  /// image, and promote to [ModelPrecision.fp16] only on a pass.
  ///
  /// This is the gate referenced by [ModelPrecision.fp16]. It is never called
  /// automatically — fp16 is an opt-in upgrade, and an un-run check leaves the
  /// model on fp32, which is the correct default on every target.
  ///
  /// Returns the measured result either way so a failure is visible rather than
  /// silently ignored.
  Future<PrecisionParityResult> verifyPrecisionParity({
    required Float32List fixedInputNchw,
    required Float32List fp32Reference,
  }) async {
    final got = await embed(fixedInputNchw);
    final result = PrecisionParityResult(
      cosine: cosineSimilarity(got, fp32Reference),
      threshold: cfg.parityThreshold,
    );
    if (result.passed) {
      _precision = ModelPrecision.fp16;
    } else {
      // Stay on fp32 and say so loudly. A near-miss here is exactly the shape
      // of the INT8 corruption finding (see [ModelPrecision]) and must not be
      // waved through as "close enough".
      _precision = ModelPrecision.fp32;
      debugPrint('[WebPalmModel] fp16 parity FAILED ($result) — staying fp32');
    }
    return result;
  }

  @override
  void dispose() {
    final s = _session;
    _session = null;
    if (s != null) {
      // Fire-and-forget: the interface is synchronous and there is nothing
      // useful to do with a release failure during teardown.
      unawaited(s.release().toDart.then((_) {}, onError: (Object e) {
        debugPrint('[WebPalmModel] session release failed: $e');
      }));
    }
  }
}

/// Build a plain JS object from a Dart map. `jsify` is not used because it
/// deep-converts, which would mangle the already-JS [ORTTensor] values.
JSObject _jsObject(Map<String, JSAny> entries) {
  final o = JSObject();
  entries.forEach((k, v) => o.setProperty(k.toJS, v));
  return o;
}

/// Factory used by the conditional import in `palm_model_service.dart`.
PalmModel createPalmModel(DeployConfig cfg) => WebPalmModel(cfg);

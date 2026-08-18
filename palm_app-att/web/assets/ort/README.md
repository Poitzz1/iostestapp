# ONNX Runtime Web — vendored runtime

This directory is intentionally checked in **empty apart from this file**. The
`onnxruntime-web` distribution is ~10 MB of JS + WASM and does not belong in
git; it is vendored at build time.

## Why this exists at all

The `onnxruntime` pub package has no web target. It is FFI-backed, and building
the web bundle against it fails outright:

```
/…/ffi-2.2.0/lib/src/allocation.dart:11:18:
Error: Only JS interop members may be 'external'.
external Pointer posixMalloc(int size);
```

pub.dev confirms it: platforms are Android, iOS, Linux, macOS, Windows, with
"Web (Coming soon)". So the web build talks to the official `onnxruntime-web`
npm package through `dart:js_interop` instead — see
`lib/services/palm_model_web.dart`, which is selected by the conditional import
in `lib/services/palm_model_service.dart`. Native builds are untouched and still
use the pub package.

(For contrast: `hand_detection` **does** have real web support — it declares
`web: pluginClass: HandDetectionWeb` and ships a full MediaPipe web
implementation under `lib/src/web/` — so it needs no bridge.)

## Populate it

```bash
npm install onnxruntime-web@1.20.1
cp node_modules/onnxruntime-web/dist/ort.min.js        web/assets/ort/
cp node_modules/onnxruntime-web/dist/*.wasm            web/assets/ort/
```

`web/index.html` loads `assets/ort/ort.min.js`, and `palm_model_web.dart` pins
`ort.env.wasm.wasmPaths` to `assets/ort/` so the runtime fetches its `.wasm`
binaries from this origin.

## Do not point this at a CDN

It is one line to change the `<script>` to a jsDelivr/unpkg URL and it will work
on your laptop. It fails closed on a campus network with restricted egress —
every student, simultaneously, at the capture screen, with no local fallback.
Keep it self-hosted.

## Precision

fp32 only, by default, on every target. The model's deploy notes record that
INT8 quantization corrupts this backbone (~0.70 self-cosine against fp32) — that
is a property of the backbone, not of the runtime, so it applies here too. There
is no INT8-web variant to reach for if WASM inference feels slow. fp16 is an
opt-in upgrade gated on a WebGPU-class backend **and** a passing parity check
(≥0.999 cosine vs fp32 on a fixed image) — see `ModelPrecision` in
`lib/services/palm_model.dart`.

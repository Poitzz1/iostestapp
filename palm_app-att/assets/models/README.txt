MODEL ASSETS
============

Place the fp32 reference model here (this is what THIS Flutter app loads):

    palm_256_l2_fp32.onnx        <-- USE THIS ONE (mobile). Currently model_version
                                      "palm_256_l2_fp32_v2" — see deploy_config.json.

Also present, NOT used by this app:

    palm_fp16_web.onnx           <-- for the separate laptop/web attendance app
                                      (ONNX Runtime Web). Not referenced in
                                      pubspec.yaml, not bundled into the mobile build.
                                      Hand it off to whoever builds that app.

Do NOT ship either of these:

    palm_int8_mobile.onnx        <-- FAILED drift validation (~0.70 self-cosine vs fp32)
    palm_int8_web.onnx           <-- FAILED drift validation

Why fp32 only:
  The INT8 files corrupt embeddings ("everything matches everyone"). A working
  quantized model needs quantization-aware training (a Colab training-time fix),
  not post-training quantization of this backbone. Until that is retrained and
  passes identity-disjoint validation, fp32 is the only mobile model.

Swapping in a retrained model:
  If a new palm_256_l2_fp32.onnx has different weights than the one currently
  shipped (different checksum), bump `model_version` in deploy_config.json (e.g.
  _v2 -> _v3). Enrollments are tagged with the model_version active at capture
  time — a silent swap without a version bump makes old and new embeddings look
  compatible when they may not be.

All preprocessing constants are read from deploy_config.json at runtime.
Nothing about the pipeline is hardcoded in Dart — change the JSON, not the code.

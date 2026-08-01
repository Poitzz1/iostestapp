import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../config/deploy_config.dart';
import 'embedding.dart';
import 'palm_model_service.dart';
import 'preprocessing.dart';

/// Preprocessing parity self-test (README §2, "do this").
///
/// Before trusting any embedding, prove the app produces the SAME vector as
/// Colab for a known image. Drop a reference pair into:
///
///   assets/parity/test_image.png          (the exact image used in Colab)
///   assets/parity/expected_embedding.json  ({ "embedding": [256 floats] })
///
/// If cosine(app, expected) <= parity_threshold (0.999), preprocessing is wrong
/// and enrollment must be blocked until it is fixed.
class ParityTest {
  final DeployConfig cfg;
  final PalmModelService model;
  final PalmPreprocessor pre;

  ParityTest({required this.cfg, required this.model, required this.pre});

  static const _imageAsset = 'assets/parity/test_image.png';
  static const _expectedAsset = 'assets/parity/expected_embedding.json';

  Future<ParityResult> run() async {
    // Reference pair is optional in dev; absence => "skipped", not "passed".
    late final ByteData imgData;
    late final String expectedRaw;
    try {
      imgData = await rootBundle.load(_imageAsset);
      expectedRaw = await rootBundle.loadString(_expectedAsset);
    } catch (_) {
      return const ParityResult.skipped(
          'No reference pair in assets/parity/ — add one to enable the self-test.');
    }

    final decoded = img.decodeImage(imgData.buffer.asUint8List());
    if (decoded == null) {
      return const ParityResult.failed(0, 'Could not decode test_image.png');
    }

    final expected = (jsonDecode(expectedRaw) as Map<String, dynamic>)['embedding'];
    final expectedVec = (expected as List)
        .map((e) => (e as num).toDouble())
        .toList(growable: false);

    final tensor = pre.fromImage(decoded);
    final Float32List appVec = model.embed(tensor);

    final sim = EmbeddingMath.cosine(appVec, expectedVec);
    if (sim > cfg.parityThreshold) {
      return ParityResult.passed(sim);
    }
    return ParityResult.failed(
        sim, 'cosine=$sim <= ${cfg.parityThreshold}; preprocessing is wrong.');
  }
}

enum ParityStatus { passed, failed, skipped }

class ParityResult {
  final ParityStatus status;
  final double cosine;
  final String message;

  const ParityResult.passed(this.cosine)
      : status = ParityStatus.passed,
        message = 'Parity OK';
  const ParityResult.failed(this.cosine, this.message)
      : status = ParityStatus.failed;
  const ParityResult.skipped(this.message)
      : status = ParityStatus.skipped,
        cosine = 0;

  bool get ok => status != ParityStatus.failed;
}

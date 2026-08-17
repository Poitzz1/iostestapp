import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:palmpay_enroll/config/deploy_config.dart';
import 'package:palmpay_enroll/services/hand_detector.dart';
import 'package:palmpay_enroll/services/preprocessing.dart';

/// [PalmPreprocessor.fromCameraImage] no longer decodes and rotates the whole
/// frame before cropping — it maps each output pixel straight back to the
/// camera planes, folding the sensor rotation and the v5 palm rotation into one
/// inverse transform (see `_cropRoiFromCameraImage`).
///
/// That is a pure speed change, and this file is what makes that claim
/// checkable: it runs the OLD, obvious pipeline (decode -> copyRotate -> ROI
/// crop -> resize -> normalize) as a reference and asserts the fast path
/// produces the same tensor. Preprocessing is the #1 correctness risk in this
/// app — a silent divergence here degrades every embedding with nothing failing
/// loudly — so the optimisation is only safe while this test passes.
void main() {
  const cfg = DeployConfig(
    modelFile: 'x.onnx',
    modelVersion: 'test',
    inputName: 'input',
    outputName: 'embedding',
    inputSize: 224,
    channelOrder: 'RGB',
    layout: 'NCHW',
    scale: 'divide_by_255',
    normalizeMean: [0.485, 0.456, 0.406],
    normalizeStd: [0.229, 0.224, 0.225],
    outputIsL2Normalized: true,
    embeddingDim: 256,
    similarity: 'cosine',
    parityThreshold: 0.999,
  );

  final pre = PalmPreprocessor(cfg);

  /// A synthetic YUV420 frame with structured, non-uniform content — flat or
  /// random noise would hide an off-by-one in the coordinate mapping.
  CameraImage makeYuvFrame(int w, int h, int seed) {
    final rnd = math.Random(seed);
    final y = Uint8List(w * h);
    final uvW = w ~/ 2, uvH = h ~/ 2;
    final u = Uint8List(uvW * uvH);
    final v = Uint8List(uvW * uvH);

    for (var j = 0; j < h; j++) {
      for (var i = 0; i < w; i++) {
        // Gradients + a grid + a little noise: every pixel is distinguishable
        // from its neighbours, so a shifted or transposed mapping cannot pass.
        final grid = ((i ~/ 7) + (j ~/ 5)) % 2 == 0 ? 40 : 0;
        y[j * w + i] =
            ((i * 255 ~/ w) * 0.5 + (j * 255 ~/ h) * 0.3 + grid + rnd.nextInt(12))
                .round()
                .clamp(0, 255);
      }
    }
    for (var j = 0; j < uvH; j++) {
      for (var i = 0; i < uvW; i++) {
        u[j * uvW + i] = (i * 255 ~/ uvW).clamp(0, 255);
        v[j * uvW + i] = (j * 255 ~/ uvH).clamp(0, 255);
      }
    }

    // The map-based constructor is deprecated but public, and it is the only
    // one that does not drag camera_platform_interface in as a direct
    // dependency — adding one invalidates the native build-hook cache and
    // forces a full OpenCV rebuild (via dartcv4) just to run a unit test.
    Map<dynamic, dynamic> plane(Uint8List b, int rowBytes, int pw, int ph) => {
          'bytes': b,
          'bytesPerPixel': 1,
          'bytesPerRow': rowBytes,
          'width': pw,
          'height': ph,
        };

    // ignore: deprecated_member_use
    return CameraImage.fromPlatformData(<dynamic, dynamic>{
      'format': 35, // android.graphics.ImageFormat.YUV_420_888
      'width': w,
      'height': h,
      'lensAperture': null,
      'sensorExposureTime': null,
      'sensorSensitivity': null,
      'planes': <dynamic>[
        plane(y, w, w, h),
        plane(u, uvW, uvW, uvH),
        plane(v, uvW, uvW, uvH),
      ],
    });
  }

  /// The OLD pipeline, written out longhand as the reference.
  Float32List reference(CameraImage frame, int rotationDegrees, PalmRoi roi) {
    final rgb = _yuv420ToRgbReference(frame);
    final rotated = rotationDegrees == 0
        ? rgb
        : img.copyRotate(rgb, angle: rotationDegrees);
    return pre.fromImage(rotated, palmRoi: roi);
  }

  /// Builds an ROI the way MediaPipeHandDetector would, for a hand placed at
  /// [angleDeg] in the SENSOR-ROTATED canvas.
  PalmRoi roiFor(int rw, int rh, double angleDeg, double span, double cx, double cy) {
    final r = angleDeg * math.pi / 180.0;
    final wrist = math.Point<double>(cx - span / 2 * math.cos(r), cy - span / 2 * math.sin(r));
    final mcp = math.Point<double>(cx + span / 2 * math.cos(r), cy + span / 2 * math.sin(r));
    final lm = List<math.Point<double>>.generate(21, (i) {
      if (i == 0) return wrist;
      if (i == 9) return mcp;
      // Spread the other palm points around the centre so the mean is not
      // degenerate.
      final k = i * 0.7;
      return math.Point<double>(cx + 8 * math.cos(k), cy + 8 * math.sin(k));
    });
    return MediaPipeHandDetector.palmRoiFrom(lm, rw, rh)!;
  }

  for (final rot in [0, 90, 180, 270]) {
    for (final angle in [0.0, 23.0, -47.0, 90.0, 160.0]) {
      test('fast path == reference pipeline (sensor rot $rot, palm $angle deg)',
          () {
        const fw = 160, fh = 120;
        final frame = makeYuvFrame(fw, fh, rot + angle.toInt());

        final swap = rot == 90 || rot == 270;
        final rw = swap ? fh : fw;
        final rh = swap ? fw : fh;

        final roi = roiFor(rw, rh, angle, 44.0, rw / 2 + 6, rh / 2 - 4);

        final fast = pre.fromCameraImage(frame,
            rotationDegrees: rot, palmRoi: roi);
        final ref = reference(frame, rot, roi);

        expect(fast.length, ref.length);

        var maxDiff = 0.0;
        for (var i = 0; i < ref.length; i++) {
          final d = (fast[i] - ref[i]).abs();
          if (d > maxDiff) maxDiff = d;
        }

        // The two paths do the same arithmetic in the same order, so they
        // should agree to floating-point noise. A real geometry bug moves
        // whole pixels and would show up here as a diff of order 1.
        expect(maxDiff, lessThan(1e-4),
            reason: 'max per-element tensor difference was $maxDiff');
      });
    }
  }

  test('no-hand fallback still uses the centre square of the rotated frame',
      () {
    const fw = 160, fh = 120;
    final frame = makeYuvFrame(fw, fh, 99);
    final fast = pre.fromCameraImage(frame, rotationDegrees: 90);

    final rgb = _yuv420ToRgbReference(frame);
    final rotated = img.copyRotate(rgb, angle: 90);
    final ref = pre.fromImage(rotated);

    var maxDiff = 0.0;
    for (var i = 0; i < ref.length; i++) {
      final d = (fast[i] - ref[i]).abs();
      if (d > maxDiff) maxDiff = d;
    }
    expect(maxDiff, lessThan(1e-6));
  });
}

/// Verbatim copy of the original full-frame YUV->RGB decode, kept here so the
/// reference stays fixed even if the production one is optimised further.
img.Image _yuv420ToRgbReference(CameraImage frame) {
  final w = frame.width, h = frame.height;
  final out = img.Image(width: w, height: h);
  final yP = frame.planes[0];
  final uP = frame.planes[1];
  final vP = frame.planes[2];
  final uvRow = uP.bytesPerRow;
  final uvPix = uP.bytesPerPixel ?? 1;

  for (var y = 0; y < h; y++) {
    final yRow = y * yP.bytesPerRow;
    final uvR = (y >> 1) * uvRow;
    for (var x = 0; x < w; x++) {
      final yv = yP.bytes[yRow + x];
      final uvI = uvR + (x >> 1) * uvPix;
      final u = uP.bytes[uvI];
      final v = vP.bytes[uvI];

      final yf = yv.toDouble();
      final uf = u - 128.0;
      final vf = v - 128.0;
      final r = (yf + 1.370705 * vf).round();
      final g = (yf - 0.337633 * uf - 0.698001 * vf).round();
      final b = (yf + 1.732446 * uf).round();
      out.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
    }
  }
  return out;
}

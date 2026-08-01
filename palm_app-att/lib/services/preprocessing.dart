import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import '../config/deploy_config.dart';
import 'hand_detector.dart' show PalmRoi;

/// THE #1 correctness risk (see README §2).
///
/// This converts a captured palm image into exactly the float tensor the model
/// was trained/evaluated with. It MUST match the Colab pipeline bit-for-bit in
/// intent:
///   1. center-crop to square, resize to input_size (bilinear)
///   2. RGB channel order
///   3. scale: pixel / 255.0
///   4. per-channel normalize: (x - mean) / std
///   5. layout: NCHW, float32
///
/// All constants come from [DeployConfig] (deploy_config.json). Do not hardcode.
class PalmPreprocessor {
  final DeployConfig cfg;
  PalmPreprocessor(this.cfg);

  /// Preprocess an already-decoded RGB image. Returns a Float32List laid out
  /// NCHW: [1, 3, H, W].
  ///
  /// [palmRoi] is the landmark-derived palm ROI (see [PalmRoi]); when null we
  /// fall back to a centre square, which is exactly what the v4 training
  /// pipeline does for images where MediaPipe finds no hand.
  Float32List fromImage(img.Image src, {PalmRoi? palmRoi}) {
    final size = cfg.inputSize;

    // 1. Crop. Landmark ROI when we have one, centre square otherwise —
    //    matching training. NOTE: after a landmark crop we do NOT re-square:
    //    training clips the square to the image bounds and resizes whatever
    //    remains, so forcing it square again here would crop tighter than the
    //    model ever saw.
    final img.Image cropped =
        palmRoi != null ? _cropPalmRoi(src, palmRoi) : _centerCropSquare(src);

    // 2. Resize to input_size x input_size (bilinear = the standard eval interp).
    final resized = img.copyResize(
      cropped,
      width: size,
      height: size,
      interpolation: img.Interpolation.linear,
    );

    return _toNchwFloat32(resized);
  }

  /// Square crop around the palm centre, clipped to the image — the inference
  /// half of the v4 training crop. See [MediaPipeHandDetector.palmRoiFrom] for
  /// the centre/half-size definition.
  img.Image _cropPalmRoi(img.Image src, PalmRoi roi) {
    final cx = roi.cxFrac * src.width;
    final cy = roi.cyFrac * src.height;
    // Both axes describe the same square; averaging guards against a tiny
    // aspect-ratio drift between the detector's image and this one.
    final half = 0.5 * (roi.halfWFrac * src.width + roi.halfHFrac * src.height);

    var x0 = (cx - half).round();
    var y0 = (cy - half).round();
    var x1 = (cx + half).round();
    var y1 = (cy + half).round();

    // Clip to bounds (training clips too).
    x0 = x0.clamp(0, src.width - 1);
    y0 = y0.clamp(0, src.height - 1);
    x1 = x1.clamp(x0 + 1, src.width);
    y1 = y1.clamp(y0 + 1, src.height);

    return img.copyCrop(src, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  }

  /// Convert a live camera frame (YUV420 on Android, BGRA on iOS) to the tensor.
  /// This is what runs inside the capture loop.
  /// [palmRoi] must come from a detection run on the SAME rotation as
  /// [rotationDegrees], so the normalised coordinates line up with the rotated
  /// image produced here.
  Float32List fromCameraImage(CameraImage frame,
      {int rotationDegrees = 0, PalmRoi? palmRoi}) {
    final rgb = _cameraImageToRgb(frame);
    final rotated = rotationDegrees == 0
        ? rgb
        : img.copyRotate(rgb, angle: rotationDegrees);
    return fromImage(rotated, palmRoi: palmRoi);
  }

  img.Image _centerCropSquare(img.Image src) {
    final side = math.min(src.width, src.height);
    final x = ((src.width - side) / 2).round();
    final y = ((src.height - side) / 2).round();
    return img.copyCrop(src, x: x, y: y, width: side, height: side);
  }

  /// (x/255 - mean) / std, written channel-planar (NCHW).
  Float32List _toNchwFloat32(img.Image im) {
    final size = cfg.inputSize;
    assert(im.width == size && im.height == size);

    final mean = cfg.normalizeMean;
    final std = cfg.normalizeStd;
    final out = Float32List(3 * size * size);

    final plane = size * size;
    const rC = 0, gC = 1, bC = 2;

    var p = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++, p++) {
        final px = im.getPixel(x, y);
        final r = px.rNormalized; // already 0..1 (image pkg normalized getter)
        final g = px.gNormalized;
        final b = px.bNormalized;
        out[rC * plane + p] = (r - mean[0]) / std[0];
        out[gC * plane + p] = (g - mean[1]) / std[1];
        out[bC * plane + p] = (b - mean[2]) / std[2];
      }
    }
    return out;
  }

  // ---- Camera frame decoding -------------------------------------------------

  img.Image _cameraImageToRgb(CameraImage frame) {
    switch (frame.format.group) {
      case ImageFormatGroup.yuv420:
        return _yuv420ToRgb(frame);
      case ImageFormatGroup.bgra8888:
        return _bgra8888ToRgb(frame);
      default:
        throw UnsupportedError('Unsupported camera format: ${frame.format.group}');
    }
  }

  img.Image _bgra8888ToRgb(CameraImage frame) {
    final plane = frame.planes.first;
    return img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: plane.bytes.buffer,
      rowStride: plane.bytesPerRow,
      order: img.ChannelOrder.bgra,
    );
  }

  img.Image _yuv420ToRgb(CameraImage frame) {
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

        // BT.601 full-range YUV -> RGB
        final yf = yv.toDouble();
        final uf = u - 128.0;
        final vf = v - 128.0;
        var r = (yf + 1.370705 * vf).round();
        var g = (yf - 0.337633 * uf - 0.698001 * vf).round();
        var b = (yf + 1.732446 * uf).round();
        out.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
      }
    }
    return out;
  }
}


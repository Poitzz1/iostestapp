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
  /// fall back to a centre square with NO rotation, which is exactly what the
  /// v5 training
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

  /// Square crop around the palm centre **of the rotation-aligned frame** —
  /// the inference half of the v5 training crop. See
  /// [MediaPipeHandDetector.palmRoiFrom] for the angle/centre/half-size
  /// definition; this is step 5-8 of `deploy_config.json -> roi_crop_spec`.
  ///
  /// The spec rotates the WHOLE frame and then cuts the square out of it. We
  /// cut the square directly, inverse-mapping each output pixel back into the
  /// unrotated source. That is not an approximation: `warpAffine` computes every
  /// destination pixel independently by inverse mapping, so warping the whole
  /// canvas and then slicing it yields exactly these pixels — we just skip
  /// warping the ~90% of the frame that gets thrown away, which matters because
  /// this runs on every accepted capture frame.
  ///
  /// Out-of-frame samples clamp to the edge pixel = OpenCV `BORDER_REPLICATE`.
  img.Image _cropPalmRoi(img.Image src, PalmRoi roi) {
    final w = src.width;
    final h = src.height;

    // Centre and half-size are already expressed in the ROTATED canvas, which
    // has the same dimensions as the source.
    final cx = roi.cxFrac * w;
    final cy = roi.cyFrac * h;
    // Both axes describe the same square; averaging guards against a tiny
    // aspect-ratio drift between the detector's image and this one.
    final half = 0.5 * (roi.halfWFrac * w + roi.halfHFrac * h);

    // Clip to the canvas exactly as the training pipeline's array slice does.
    // Clipping can leave the crop non-square at the frame edges; that is the
    // trained behaviour, so it is NOT re-squared afterwards.
    final x0 = (cx - half).round().clamp(0, w - 1);
    final y0 = (cy - half).round().clamp(0, h - 1);
    final x1 = (cx + half).round().clamp(x0 + 1, w);
    final y1 = (cy + half).round().clamp(y0 + 1, h);
    final cw = x1 - x0;
    final ch = y1 - y0;

    // Inverse of the rotation in PalmRoi.rotationDeg (a rotation by -theta
    // about the image centre).
    final t = roi.rotationDeg * math.pi / 180.0;
    final a = math.cos(t);
    final b = math.sin(t);
    final ox = w / 2.0;
    final oy = h / 2.0;

    final out = img.Image(width: cw, height: ch, numChannels: 3);

    for (var j = 0; j < ch; j++) {
      final dy = (y0 + j) - oy;
      for (var i = 0; i < cw; i++) {
        final dx = (x0 + i) - ox;
        final sxf = a * dx - b * dy + ox;
        final syf = b * dx + a * dy + oy;
        final p = _sampleBilinearReplicate(src, sxf, syf);
        out.setPixelRgb(i, j, p[0], p[1], p[2]);
      }
    }
    return out;
  }

  /// Bilinear sample with edge clamping (`BORDER_REPLICATE`), matching
  /// `warpAffine(..., INTER_LINEAR, BORDER_REPLICATE)`.
  static List<int> _sampleBilinearReplicate(img.Image src, double x, double y) {
    final w = src.width;
    final h = src.height;

    final fx = x.floor();
    final fy = y.floor();
    final tx = x - fx;
    final ty = y - fy;

    final x0 = fx.clamp(0, w - 1);
    final y0 = fy.clamp(0, h - 1);
    final x1 = (fx + 1).clamp(0, w - 1);
    final y1 = (fy + 1).clamp(0, h - 1);

    final p00 = src.getPixel(x0, y0);
    final p10 = src.getPixel(x1, y0);
    final p01 = src.getPixel(x0, y1);
    final p11 = src.getPixel(x1, y1);

    final w00 = (1 - tx) * (1 - ty);
    final w10 = tx * (1 - ty);
    final w01 = (1 - tx) * ty;
    final w11 = tx * ty;

    int mix(num c00, num c10, num c01, num c11) =>
        (c00 * w00 + c10 * w10 + c01 * w01 + c11 * w11)
            .round()
            .clamp(0, 255);

    return [
      mix(p00.r, p10.r, p01.r, p11.r),
      mix(p00.g, p10.g, p01.g, p11.g),
      mix(p00.b, p10.b, p01.b, p11.b),
    ];
  }

  /// Convert a live camera frame (YUV420 on Android, BGRA on iOS) to the tensor.
  /// This is what runs inside the capture loop.
  /// [palmRoi] must come from a detection run on the SAME rotation as
  /// [rotationDegrees], so the normalised coordinates line up with the rotated
  /// image produced here.
  ///
  /// PERFORMANCE. The obvious implementation — decode the whole frame to RGB,
  /// rotate the whole frame, crop, resize — walks every pixel of the frame
  /// three times to keep a square that is usually under a tenth of it, and it
  /// does so on the UI isolate for every accepted frame. Measured on a
  /// 1280x720 frame that is 44 ms to decode + 21 ms to rotate before the crop
  /// even starts, which is what makes capture visibly stutter.
  ///
  /// So when we have an ROI we go straight from the camera planes to the crop
  /// in ONE pass ([_cropRoiFromCameraImage]), folding the sensor rotation and
  /// the v5 palm rotation into a single inverse mapping. Same pixels, ~1/10th
  /// the work. The no-hand fallback keeps the simple path — it is rare and has
  /// no ROI to exploit.
  Float32List fromCameraImage(CameraImage frame,
      {int rotationDegrees = 0, PalmRoi? palmRoi}) {
    if (palmRoi != null) {
      final cropped = _cropRoiFromCameraImage(frame, rotationDegrees, palmRoi);
      final resized = img.copyResize(
        cropped,
        width: cfg.inputSize,
        height: cfg.inputSize,
        interpolation: img.Interpolation.linear,
      );
      return _toNchwFloat32(resized);
    }
    final rgb = _cameraImageToRgb(frame);
    final rotated = rotationDegrees == 0
        ? rgb
        : img.copyRotate(rgb, angle: rotationDegrees);
    return fromImage(rotated);
  }

  /// The v5 crop, taken directly from the camera planes.
  ///
  /// Produces exactly the pixels that
  /// `copyRotate(decode(frame), sensorRotation)` -> [_cropPalmRoi] produces —
  /// see `test/preprocessing_equivalence_test.dart`, which asserts that on
  /// random frames at every rotation. It just never materialises the two
  /// full-frame intermediates.
  ///
  /// Coordinate chain, applied per OUTPUT pixel (all of it inverse-mapped, the
  /// same way warpAffine works):
  ///
  ///   crop pixel (i,j)
  ///     -> palm-rotated canvas   : (x0+i, y0+j)
  ///     -> sensor-rotated canvas : inverse of PalmRoi.rotationDeg about centre
  ///     -> raw frame             : inverse of the 90-degree sensor rotation
  ///     -> YUV/BGRA sample       : bilinear over the 4 neighbours
  ///
  /// Each of the four neighbours is converted to RGB with the SAME formula
  /// [_yuv420ToRgb] uses (including its nearest-neighbour chroma), then blended
  /// — which is what makes this identical to decoding first and warping after.
  img.Image _cropRoiFromCameraImage(
      CameraImage frame, int rotationDegrees, PalmRoi roi) {
    final fw = frame.width, fh = frame.height;

    // The canvas the ROI fractions are expressed in: the frame after the
    // sensor rotation (which swaps the axes for 90/270).
    final rot = ((rotationDegrees % 360) + 360) % 360;
    final swap = rot == 90 || rot == 270;
    final rw = swap ? fh : fw;
    final rh = swap ? fw : fh;

    final cx = roi.cxFrac * rw;
    final cy = roi.cyFrac * rh;
    final half = 0.5 * (roi.halfWFrac * rw + roi.halfHFrac * rh);

    final x0 = (cx - half).round().clamp(0, rw - 1);
    final y0 = (cy - half).round().clamp(0, rh - 1);
    final x1 = (cx + half).round().clamp(x0 + 1, rw);
    final y1 = (cy + half).round().clamp(y0 + 1, rh);
    final cw = x1 - x0, ch = y1 - y0;

    final t = roi.rotationDeg * math.pi / 180.0;
    final a = math.cos(t), b = math.sin(t);
    final ox = rw / 2.0, oy = rh / 2.0;

    // Packed 0xRRGGBB at an integer point of the SENSOR-ROTATED canvas.
    // Hoisted out of the loop so the format branch is taken once.
    final readRotated = _rotatedPixelReader(frame, rot, fw, fh);

    final out = Uint8List(cw * ch * 3);
    var o = 0;
    for (var j = 0; j < ch; j++) {
      final dy = (y0 + j) - oy;
      for (var i = 0; i < cw; i++) {
        final dx = (x0 + i) - ox;
        final fx = a * dx - b * dy + ox;
        final fy = b * dx + a * dy + oy;

        final ix = fx.floor(), iy = fy.floor();
        final tx = fx - ix, ty = fy - iy;

        // Clamp = OpenCV BORDER_REPLICATE.
        final u0 = ix < 0 ? 0 : (ix > rw - 1 ? rw - 1 : ix);
        final v0 = iy < 0 ? 0 : (iy > rh - 1 ? rh - 1 : iy);
        final ix1 = ix + 1, iy1 = iy + 1;
        final u1 = ix1 < 0 ? 0 : (ix1 > rw - 1 ? rw - 1 : ix1);
        final v1 = iy1 < 0 ? 0 : (iy1 > rh - 1 ? rh - 1 : iy1);

        final c00 = readRotated(u0, v0);
        final c10 = readRotated(u1, v0);
        final c01 = readRotated(u0, v1);
        final c11 = readRotated(u1, v1);

        final w00 = (1 - tx) * (1 - ty);
        final w10 = tx * (1 - ty);
        final w01 = (1 - tx) * ty;
        final w11 = tx * ty;

        final rr = ((c00 >> 16) & 0xff) * w00 +
            ((c10 >> 16) & 0xff) * w10 +
            ((c01 >> 16) & 0xff) * w01 +
            ((c11 >> 16) & 0xff) * w11;
        final gg = ((c00 >> 8) & 0xff) * w00 +
            ((c10 >> 8) & 0xff) * w10 +
            ((c01 >> 8) & 0xff) * w01 +
            ((c11 >> 8) & 0xff) * w11;
        final bb = (c00 & 0xff) * w00 +
            (c10 & 0xff) * w10 +
            (c01 & 0xff) * w01 +
            (c11 & 0xff) * w11;

        out[o++] = rr.round().clamp(0, 255);
        out[o++] = gg.round().clamp(0, 255);
        out[o++] = bb.round().clamp(0, 255);
      }
    }

    return img.Image.fromBytes(
      width: cw,
      height: ch,
      bytes: out.buffer,
      order: img.ChannelOrder.rgb,
      numChannels: 3,
    );
  }

  /// Returns `(u, v) -> 0xRRGGBB`, reading the SENSOR-ROTATED canvas straight
  /// out of the camera planes.
  ///
  /// The inverse of `img.copyRotate` for the four right-angle cases is pinned
  /// here; it was derived by testing the library rather than assumed, and
  /// `test/preprocessing_equivalence_test.dart` re-checks it.
  int Function(int u, int v) _rotatedPixelReader(
      CameraImage frame, int rot, int fw, int fh) {
    switch (frame.format.group) {
      case ImageFormatGroup.yuv420:
        final yP = frame.planes[0], uP = frame.planes[1], vP = frame.planes[2];
        final yB = yP.bytes, uB = uP.bytes, vB = vP.bytes;
        final yStride = yP.bytesPerRow;
        final uvStride = uP.bytesPerRow;
        final uvPix = uP.bytesPerPixel ?? 1;

        int at(int sx, int sy) {
          final yv = yB[sy * yStride + sx].toDouble();
          final uvI = (sy >> 1) * uvStride + (sx >> 1) * uvPix;
          final uf = uB[uvI] - 128.0;
          final vf = vB[uvI] - 128.0;
          // BT.601 full-range — identical to _yuv420ToRgb.
          final r = (yv + 1.370705 * vf).round().clamp(0, 255);
          final g = (yv - 0.337633 * uf - 0.698001 * vf).round().clamp(0, 255);
          final b = (yv + 1.732446 * uf).round().clamp(0, 255);
          return (r << 16) | (g << 8) | b;
        }

        return _withInverseRotation(at, rot, fw, fh);

      case ImageFormatGroup.bgra8888:
        final p = frame.planes.first;
        final bytes = p.bytes;
        final stride = p.bytesPerRow;

        int at(int sx, int sy) {
          final i = sy * stride + sx * 4;
          return (bytes[i + 2] << 16) | (bytes[i + 1] << 8) | bytes[i];
        }

        return _withInverseRotation(at, rot, fw, fh);

      default:
        throw UnsupportedError(
            'Unsupported camera format: ${frame.format.group}');
    }
  }

  /// Wraps a raw-frame reader so it can be indexed in sensor-ROTATED
  /// coordinates. Mapping verified against `img.copyRotate`.
  int Function(int u, int v) _withInverseRotation(
      int Function(int sx, int sy) at, int rot, int fw, int fh) {
    return switch (rot) {
      90 => (u, v) => at(v, fh - 1 - u),
      180 => (u, v) => at(fw - 1 - u, fh - 1 - v),
      270 => (u, v) => at(fw - 1 - v, u),
      _ => at,
    };
  }

  // ── Collector-only accessors ────────────────────────────────────────────
  //
  // The data collector (`lib/collector/`) has to STORE the same pixels the
  // model sees — the ROI crop is its primary artifact. These expose the
  // existing decode/crop steps verbatim so the collector cannot drift from the
  // v5 training crop by reimplementing the geometry. They add no behaviour and
  // are not called from the enrollment or attendance path.

  /// The decoded, rotated RGB image a live frame produces — i.e. exactly what
  /// [fromCameraImage] crops before it resizes.
  img.Image decodeFrame(CameraImage frame, {int rotationDegrees = 0}) {
    final rgb = _cameraImageToRgb(frame);
    return rotationDegrees == 0
        ? rgb
        : img.copyRotate(rgb, angle: rotationDegrees);
  }

  /// The crop [fromImage] would take: the landmark ROI when [palmRoi] is
  /// given, the centre square otherwise (the training-pipeline fallback).
  img.Image cropForEmbedding(img.Image src, {PalmRoi? palmRoi}) =>
      palmRoi != null ? _cropPalmRoi(src, palmRoi) : _centerCropSquare(src);

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


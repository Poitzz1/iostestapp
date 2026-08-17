import '../services/hand_detector.dart' show HandSide, HandSideLabel;

/// One enrolled palm template.
///
/// A student holds SEVERAL of these, captured under different lighting, and
/// verification takes `max(cosine(probe, template_i))`.
///
/// Measured offline on 144 real crops from 18 participants, v5, threshold
/// 0.5508:
///
///   templates   genuine   FRR      impostor   FAR
///       1        0.614    28.7%     0.032     0.00%
///       2        0.680    23.6%     0.061     0.00%
///       3        0.724    11.1%     0.077     0.00%
///
/// About 61% fewer false rejects with no measurable rise in false accepts.
///
/// THE DEPENDENCY THAT MAKES OR BREAKS IT: in that simulation the templates
/// spanned each person's lighting range BY CONSTRUCTION (crops sorted by luma,
/// then split into chunks). Three templates captured back-to-back in one room
/// are three near-identical vectors and buy exactly nothing. [enrollLumaMean]
/// exists so the spread can be verified rather than assumed — see
/// `LightingSpread` in capture_controller.dart.
class PalmTemplate {
  /// The 256-float L2-normalised vector.
  final List<double> vec;

  final HandSide handSide;
  final String modelVersion;

  /// Mean luma of the accepted frames this template was averaged from.
  ///
  /// Null for templates enrolled before illumination telemetry existed (the
  /// backfilled legacy ones). Null must never crash a spread check — an unknown
  /// lighting is not a zero lighting.
  final double? enrollLumaMean;
  final double? enrollLumaStd;

  final DateTime capturedAt;

  /// `enrollment` (captured deliberately during enrolment) or `adaptive`
  /// (promoted from a high-scoring verification). Kept distinct so adaptive
  /// templates can be analysed separately, and purged wholesale if adaptive
  /// addition turns out to be a mistake.
  final String source;

  const PalmTemplate({
    required this.vec,
    required this.handSide,
    required this.modelVersion,
    this.enrollLumaMean,
    this.enrollLumaStd,
    required this.capturedAt,
    this.source = 'enrollment',
  });

  bool get isValid => vec.length == 256;

  Map<String, dynamic> toJson() => {
        'vec': vec,
        'hand_side': handSide.label,
        'model_version': modelVersion,
        'enroll_luma_mean': enrollLumaMean,
        'enroll_luma_std': enrollLumaStd,
        'captured_at': capturedAt.toIso8601String(),
        'source': source,
      };

  factory PalmTemplate.fromJson(Map<String, dynamic> m) => PalmTemplate(
        // `vec` is the field name; `embedding` is tolerated so a hand-written
        // or backfilled document in the older shape still loads.
        vec: ((m['vec'] ?? m['embedding']) as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const [],
        handSide: HandSideLabel.fromLabel(m['hand_side'] as String? ?? 'right'),
        modelVersion: m['model_version'] as String? ?? '',
        enrollLumaMean: (m['enroll_luma_mean'] as num?)?.toDouble(),
        enrollLumaStd: (m['enroll_luma_std'] as num?)?.toDouble(),
        capturedAt:
            DateTime.tryParse(m['captured_at'] as String? ?? '') ?? DateTime.now(),
        source: m['source'] as String? ?? 'enrollment',
      );

  /// Spread of enrolment lighting across a set of templates, or null when
  /// fewer than two of them recorded a luma.
  ///
  /// This is the number that says whether multi-template enrolment is actually
  /// doing anything. A spread near zero means the templates are duplicates and
  /// the extra ones are dead weight.
  static double? lumaSpread(List<PalmTemplate> templates) {
    final l = templates
        .map((t) => t.enrollLumaMean)
        .whereType<double>()
        .toList();
    if (l.length < 2) return null;
    l.sort();
    return l.last - l.first;
  }
}


// ── §4 ADAPTIVE TEMPLATE ADDITION — OFF BY DEFAULT ──────────────────────────
//
// After a verification that scored VERY high, consider keeping the probe as an
// extra template. Standard biometric practice, and it solves migration cheaply:
// already-enrolled students accumulate lighting coverage just by using the
// system, with no re-enrolment.
//
// It is also a template-poisoning risk, so every gate below must hold:
//
//  1. score >= ADAPTIVE_THRESHOLD, which sits WELL ABOVE the verification
//     threshold (0.75 vs 0.5508). This is the important one. If the gate were
//     the verification threshold, a false accept could promote an impostor's
//     palm into the victim's template set — and from then on the impostor
//     verifies legitimately. The gap between the two thresholds is the safety
//     margin, and it must never be closed.
//  2. The probe's lighting must differ from every stored template. A near
//     duplicate adds storage and comparison cost while adding no coverage,
//     which is the failure mode this whole feature exists to avoid.
//  3. Under MAX_TEMPLATES.
//  4. Quality gates passed (implied: it reached scoring at all).
//
// Stored with source "adaptive" so these can be analysed separately from
// deliberately enrolled ones — and purged wholesale if this turns out to be a
// mistake, which is only possible because they are labelled.
//
// Controlled by config/model.adaptive_templates_enabled, default FALSE. Leave
// it off until §7's measurement supports turning it on.

const ADAPTIVE_THRESHOLD_DEFAULT = 0.75;
const ADAPTIVE_MIN_LUMA_DELTA = 15;
const MAX_TEMPLATES = 5;

/**
 * Decide whether a successful probe should become a new template, and return
 * the entry to append, or null.
 *
 * Pure and side-effect free so it can be reasoned about (and tested) without a
 * database: the caller does the write.
 */
export function adaptiveCandidate({
  enabled,
  score,
  adaptiveThreshold = ADAPTIVE_THRESHOLD_DEFAULT,
  verifyThreshold,
  templates,
  probeEmbedding,
  probeLuma,
  handSide,
  modelVersion,
}) {
  if (!enabled) return null;
  if (typeof score !== "number" || !isFinite(score)) return null;

  // The adaptive bar must be strictly above the verification bar. If a
  // misconfiguration ever brought them level, a false accept could write itself
  // into the template set — so refuse rather than trust the config.
  const bar = Math.max(adaptiveThreshold, (verifyThreshold ?? 0) + 0.15);
  if (score < bar) return null;

  if (!Array.isArray(templates) || templates.length >= MAX_TEMPLATES) return null;
  if (!Array.isArray(probeEmbedding) || probeEmbedding.length !== 256) return null;

  // Must add lighting coverage. Unknown probe luma cannot be shown to add
  // anything, so it does not qualify — silence is not evidence.
  if (typeof probeLuma !== "number" || !isFinite(probeLuma)) return null;
  const known = templates
    .map((t) => t.enroll_luma_mean)
    .filter((v) => typeof v === "number" && isFinite(v));
  if (known.length && known.some((l) => Math.abs(l - probeLuma) < ADAPTIVE_MIN_LUMA_DELTA)) {
    return null;
  }

  return {
    vec: probeEmbedding,
    hand_side: handSide ?? null,
    model_version: modelVersion,
    enroll_luma_mean: probeLuma,
    enroll_luma_std: null,
    captured_at: new Date().toISOString(),
    source: "adaptive",
  };
}

export const ADAPTIVE_DEFAULTS = {
  ADAPTIVE_THRESHOLD_DEFAULT,
  ADAPTIVE_MIN_LUMA_DELTA,
  MAX_TEMPLATES,
};

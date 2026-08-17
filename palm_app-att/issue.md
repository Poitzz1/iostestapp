# Issue: genuine pairs lose ~0.2 cosine to ordinary nuisance factors

**Status:** open — root cause not yet confirmed. Telemetry to diagnose it is now
in place (§4.4); the offline measurement in Step 1 is the next action.
**Filed:** 2026-08-16
**Updated:** 2026-08-16 — illumination telemetry added and deployed
**Component:** palm model (v5) + enrollment/verification capture path
**Severity:** high — causes silent false rejects for legitimate students
**Scope note:** filed for illumination; a second factor (out-of-plane tilt) was
then measured doing almost the same damage. Treat this as one issue — *the
operating margin is too small for normal variation* — not two.

---

## 1. The observation

One person enrolled their palm in **low light**, then verified the **same palm** in
**bright light**. The server-side 1:1 cosine comparison returned:

```
palm_score = 0.407
threshold  = 0.5508   (config/model.verification_threshold_FAR_0_1pct)
result     = rejected, decision_reason = palm_below_threshold
```

Same person, same hand, same model version. Rejected.

### 1b. A second, independent factor: palm angle

Measured the next day, **same lighting**, same person, same room:

| condition | score |
|---|---|
| phone and palm square-on (as enrolled) | **0.800** |
| phone angled up vs palm angled down | **0.607** |

A drop of **0.193** — from geometry alone, with lighting held constant. It still
passed, but with only 0.056 to spare over the 0.5508 threshold.

This is **expected behaviour of the model as shipped**, not a bug. v5's own
diagnostic over 3,210 real comparisons ranked the geometric nuisance factors:

- **in-plane rotation, r = −0.322** — this is what the v5 rotation-aligned crop
  CANCELS. It is the whole reason v5 exists.
- **out-of-plane tilt, r = −0.169** — roughly half the effect, and **nothing
  corrects it**. A crop cannot undo foreshortening.

Phone-up vs phone-down is precisely out-of-plane tilt. (It also flips the
illumination geometry — a ceiling light in front of the palm versus behind it —
so the two factors are entangled in this observation.)

### 1d. BENCH DATA, 2026-08-16 — 26 controlled runs, one subject

Measured with the in-app test bench (`/palm-lab`), one template, 26 verifies.
This supersedes the one-off observations in §1 and §1b as the primary evidence.

**Baseline noise (condition identical to template, n=4):**
`0.9226, 0.9051, 0.9126, 0.9285` -> **mean 0.9172, sd 0.0090**.

Two things follow. First, run-to-run noise is +/-0.018, so any difference above
that is real. Second, **under matched conditions this palm scores 0.917** — far
above the eval's genuine mean of 0.6279, which strongly suggests that published
figure already averages in a lot of condition mismatch (see §4.1).

**Effect sizes, worst first:**

| factor | effect | pass rate |
|---|---|---|
| facing the light (away -> toward) | **-0.279** | toward: 1/6 |
| out-of-plane tilt (dpose 0.01 -> 0.07) | **-0.29** | dpose>0.05: 0/4 |
| in-plane rotation (~7deg -> ~30deg, pose matched) | -0.095 | — |
| mean luma delta | not significant (r=-0.250) | — |

**Controlled block (lighting, phone tilt, facing all fixed; in-plane rotation
held at 24-33deg; only palm angle varied):**

```
dpose +0.010   tilt 30.3deg   score 0.8218
dpose +0.014   tilt 29.8deg   score 0.8222
dpose +0.059   tilt 30.4deg   score 0.5413
dpose +0.070   tilt 32.7deg   score 0.4996
dpose +0.072   tilt 24.5deg   score 0.5314
```

**RETRACTED: in-plane rotation is not a defect.** An earlier n=5 read suggested
`tilt_deg` correlated with score, raising the possibility that the v5
rotation-aligned crop was not doing its job. With n=26 that does not hold: the
first two rows above show **30 degrees of in-plane rotation still scoring 0.82**
when pose_ratio matches, and the binned relationship is non-monotonic (12-28deg
scores worse than 28-70deg), which is confounding rather than causation. The
~0.095 residual between the 7deg baseline and the 30deg matched-pose runs is
real but third-order — possibly resampling blur, since a template captured at
1.41deg is barely resampled while a 30deg probe is.

**Mean luma is a weak instrument — see §4.4 caveat.** The single worst failure in
the first batch (0.8931 -> 0.3838) came from turning to face the light with the
measured luma difference at **0.3 out of 99**. Every numeric illumination field
would have called those two captures identical. The tester's `facing` label
caught what six measured fields missed.

**Overall pass rate: 15/26 (58%) on the subject's own palm** — a 42% false
reject rate across ordinary in-room variation.

### 1c. Why these belong in one issue

| factor | measured score drop |
|---|---|
| cross-illumination (dark enroll / bright verify) | 0.221 |
| out-of-plane tilt (phone up / phone down) | 0.193 |
| **available margin (genuine mean − threshold)** | **0.077** |

Either factor alone is roughly **2.5×** the entire operating margin. The root
problem is not any single nuisance factor — it is that v5 leaves too little room
for the ordinary variation of a student holding a phone in a classroom.

---

## 2. Why this is serious, in numbers

From `assets/models/deploy_config.json` (`training_provenance`), v5's held-out eval:

| quantity | value |
|---|---|
| genuine mean cosine | 0.6279 |
| impostor mean cosine | 0.0475 |
| genuine/impostor gap | 0.5804 |
| AUC | 0.9915 |
| EER | 4.27 % |
| train identities | 419 |
| held-out identities | 98 |
| deployed threshold | 0.5508 |

The operating margin is **0.6279 − 0.5508 = 0.077**. That is the entire budget for
every real-world variation combined: pose, distance, skin state, camera, *and*
illumination. A genuine pair only has to lose 0.08 cosine to be rejected.

The observed score lost **0.221** against the genuine mean.

**Corroborating measurement.** An earlier on-device measurement of this model
family (recorded in the comment block at the top of
`lib/services/quality_gate.dart`) found the same asymmetry:

- same palm under **−40 % brightness** → cosine ~**0.935** (barely affected)
- same palm under **+40 % brightness** → cosine ~**0.704** (drops ~0.23), *"worse with real glare"*

The ~0.23 drop from brightening is almost exactly the 0.221 drop seen here. This
is very likely the same mechanism, not a new one.

---

## 3. What has been ruled out

Do not re-investigate these; each was checked against real data.

**Not a broken model / broken preprocessing.** A systematic preprocessing error
shifts enrollment and probe *together*, so they would still match each other. A
control user on the same build scores **0.8313** and **0.8624** on v5 — well clear
of threshold. The model, the v5 rotation-aligned crop, and the fused
preprocessing path all work.

**Not the ROI crop geometry.** `test/palm_roi_test.dart` (19 tests) pins the v5
rotation spec: every palm orientation aligns to exactly −90.000°, span is
preserved under rotation, and the centre is taken from the *rotated* landmarks.

**Not the fast preprocessing path.** `test/preprocessing_equivalence_test.dart`
(21 cases) asserts the optimised camera-plane path produces a tensor identical to
the naive decode→rotate→crop→resize reference at all 4 sensor rotations × 5 palm
angles, max element difference < 1e-4.

**Not the partial-hand bug.** A separate defect (MediaPipe extrapolating wrist and
knuckle landmarks off-frame when only fingers are visible, producing a clipped
sliver crop) was found and fixed with a containment gate
(`PalmRoi.insideFraction` / `palmPointsInFrame`, enforced in
`lib/services/capture_controller.dart`). That bug produced an *erratic* score
spread (0.21–0.86 for one person). The issue in this document is different: a
*consistent, reproducible* drop tied to a lighting change.

---

## 4. Analysis

### 4.1 Primary hypothesis: the threshold was never calibrated for cross-illumination pairs

This is the most important point for whoever picks this up.

The threshold 0.5508 was derived at FAR ~0.1 % on 98 held-out identities. The
question that matters is **how the genuine pairs in that eval were constructed**.
If genuine pairs were drawn from the same capture session — same room, same
lighting, minutes apart — which is the default for `11k_palmar_roi` and likely for
`collector_roi` too, then:

- the reported genuine mean of 0.6279 describes **same-illumination** pairs only
- cross-illumination genuine pairs were **never measured**
- 0.5508 is therefore calibrated against a distribution that does not include the
  dominant real-world nuisance factor

Under that reading, 0.407 is not an anomaly — it is an ordinary draw from a
distribution the eval never sampled. **Verify this first**, because it determines
whether the fix is a model change, a threshold change, or an enrollment protocol
change.

### 4.2 Secondary: enrollment captures one illumination and averages it

Enrollment runs 4 passes × 8 frames and averages into one template
(`lib/services/capture_controller.dart`). The passes deliberately vary **pose**
(baseline / further / closer / tilted) and verify that the pose actually changed.

They do **not** vary illumination. All 32 frames are captured back-to-back in one
place over a few seconds, so the template encodes a single lighting condition.
Averaging tightens the template around that one condition rather than
generalising across conditions — which makes it *more* brittle to a lighting
change at verification, not less.

### 4.3 The app does not control exposure (and should not, as things stand)

Two attempts were made to normalise capture lighting in-app. Both were reverted;
both are recorded in `lib/services/quality_gate.dart` so they are not retried.

**Torch.** Made the same palm stop matching itself. An LED at palm distance is a
specular hotspot, and glare is this model's worst case (§2). It converted a loud
failure ("no palm detected") into a silent one (a scan that quietly scores low).

**Exposure-compensation controller.** Worse — it deadlocked capture entirely.
The only control signal available at that point in the pipeline is mean luma over
the **whole frame**, and a palm held close against a dark background has a low
frame mean even when the palm itself is correctly lit. Chasing a target frame
mean saturates the palm long before the mean gets there, at which point the
`maxBlowoutFraction` gate rejects the frame as "too bright" — while the mean,
still short of target, tells the controller to push harder. Gate and controller
fight; nothing is ever capturable.

Doing this properly requires metering the **palm region**, not the frame. That
signal is not available where it would be needed: the ROI comes from hand
detection, which runs *after* the quality gate. Restructuring the pipeline to
meter the ROI is possible but was not attempted, and should not be attempted
before Step 1 establishes that illumination is actually the dominant term.

For now the camera's own auto-exposure — a vendor algorithm with access to the
real metering grid — is left alone.

**Implication for this issue:** enrollment and verification lighting are NOT
equalised by the app. Whatever the room and the camera's AE produce is what the
model sees. That is precisely why the telemetry in §4.4 matters.

### 4.4 Illumination telemetry — ADDED 2026-08-16 (was the blocker)

Originally this section read "no illumination telemetry exists", which is why the
issue could not be analysed from production data at all. That has now been fixed
(this was Step 2 below, done early because everything else depends on it).

**What is now recorded.** Statistics are taken over the frames that were
ACCEPTED — the ones actually averaged into the vector — so they describe the
image the model really saw, not every frame the camera produced.

On the **student document**, `enroll_illumination`:

```
frames, luma_mean, luma_std, luma_min, luma_max, blowout_mean
```

These are MEASUREMENTS of what the camera's auto-exposure settled on, not of
anything the app imposed (§4.3) — which is what makes them a faithful record of
the real operating condition.

On each **attendance record**, alongside `palm_score`:

```
probe_luma_mean, probe_luma_std, probe_blowout_mean,
enroll_luma_mean, probe_vs_enroll_luma_delta
probe_pose_ratio, probe_tilt_deg, probe_size,
enroll_pose_ratio, probe_vs_enroll_pose_ratio_delta,
probe_vs_enroll_tilt_delta, probe_vs_enroll_size_delta
```

Pose is recorded too (student doc: `enroll_pose`), for §1b.
`probe_vs_enroll_pose_ratio_delta` is the out-of-plane tilt difference — the one
that should correlate with score.

`probe_vs_enroll_tilt_delta` is deliberately a **CONTROL**: in-plane rotation is
supposed to be cancelled by the v5 crop, so it should show NO correlation. If it
does, the rotation alignment is not working, and that is a bug rather than a
nuisance factor.

**CAVEAT ADDED 2026-08-16 — read §1d before trusting this field.** Bench data
shows mean luma is a much weaker instrument than assumed: the worst observed
failure had a luma delta of 0.3 out of 99 because only the DIRECTION of the
light changed. Illumination direction is not captured by any numeric field here.
`probe_vs_enroll_pose_ratio_delta` turned out to be the stronger predictor.

`probe_vs_enroll_luma_delta` is the field this whole exercise exists for.
**Positive = the probe was brighter than the enrollment**, which is the direction
that hurts this model family most. The question "do low scores track a lighting
difference?" is now a query over real attendance data rather than a manual
reproduction.

`luma_std` matters too: a large value means the lighting moved *during* capture,
so the template is an average across conditions rather than a record of one.

All of it is diagnostic only — none of it influences the verdict.

**Caveat: existing templates have no `enroll_illumination`.** Anything enrolled
before 2026-08-16 has a null, so `probe_vs_enroll_luma_delta` will be null for
those students until they re-enroll. Expect the dataset to be thin at first.

---

## 5. What NOT to do

**Do not lower the threshold to make 0.407 pass.** This is a standing project
constraint and it is correct. The impostor mean is 0.0475, but the impostor
*distribution* has a tail; 0.5508 sits at FAR ~0.1 %. Dropping to ~0.40 to admit
this scan would raise the false-accept rate by a large and unmeasured factor, on a
system whose whole purpose is to establish that a specific person was present.
Fix the illumination gap; do not move the goalposts.

**Do not apply CLAHE (or any contrast normalisation) at inference on a hunch.**
`deploy_config.json` states plainly: *"CLAHE is train-time augmentation only — do
NOT apply at inference."* Any inference-time photometric change alters the input
distribution and must be validated offline against the held-out set before it goes
near the app.

**Do not re-add a torch.** Already tried and reverted — see the note in
`lib/services/quality_gate.dart`. An LED at palm distance is a specular hotspot,
glare is this model's documented worst case, and it made the same palm stop
matching itself.

**Do not lower `detectorConf` / `minLandmarkScore` to help low light.** Already
tried and reverted; it admitted partial hands and poisoned a template.

---

## 6. Recommended work, in order

### Step 1 — Measure the effect offline (model owner; do this first)

Everything else depends on the answer.

1. From the held-out set, construct genuine pairs **stratified by illumination
   difference**: same-lighting pairs vs deliberately cross-lighting pairs
   (synthetic gamma/exposure perturbation is acceptable as a first pass; real
   dual-lighting captures are better).
2. Report genuine-score distributions for each stratum, and re-derive the FAR
   0.1 % threshold **using cross-illumination genuine pairs included**.
3. Deliverable: a table of `genuine mean / p5 / p1` vs luma delta, and the
   FAR-0.1 % threshold under the realistic pair distribution.

If cross-illumination genuine scores really do sit near 0.40, then either the
model needs illumination-invariance work, or the enrollment protocol must change
(Step 3) — the threshold alone cannot reconcile them.

### Step 2 — Illumination telemetry — DONE 2026-08-16

Implemented and deployed; see §4.4 for the exact fields. Done first because
Steps 1, 3 and 5 all need the data.

Once enough post-2026-08-16 enrollments exist, the analysis is:

```
For attendance docs where probe_vs_enroll_luma_delta IS NOT NULL
and model_version = 'palm_256_l2_fp32_v5':
  plot palm_score against probe_vs_enroll_luma_delta
  fit separately for delta > 0 (probe brighter) and delta < 0 (probe darker)
```

The prediction from §2 is a clear negative slope on the positive-delta side and a
much flatter one on the negative side. If that holds, the cause is confirmed and
Step 5's rejection budget can be derived from the fit. If the scatter is flat,
illumination is **not** the driver and this whole line of investigation is wrong
— go back to Step 1.

Also worth checking whether high `luma_std` on either side correlates with low
scores — that would mean the lighting moved *during* capture, making the template
an average across conditions rather than a record of one.

### Step 3 — Enroll across illumination, not just pose

The enrollment pass structure already exists and already verifies that the student
complied with a per-pass instruction (`_poseVariantFor`, `_poseHint` in
`lib/services/capture_controller.dart`). Extend the same mechanism to lighting:
prompt at least one pass under a deliberately different lighting condition (e.g.
"step toward the window" / "move away from the light"), and verify it using the
measured mean luma the way pose conformance is verified today.

This widens the template's illumination coverage using machinery that is already
built and tested.

### Step 4 — Consider multi-template enrollment (larger change)

Standard biometric practice: store N templates per identity (one per condition)
and score `max(cosine(probe, tᵢ))`. Directly addresses condition mismatch without
touching the threshold. Requires a Firestore schema change
(`embedding` → `embeddings[]`), a rules change, and a `submitAttendance` change.
Only worth doing if Step 1 shows a single averaged template genuinely cannot
cover the operating range.

### Step 5 — Refuse mismatched lighting, rather than silently failing (after Step 1)

The cheapest useful mitigation, and it needs no camera control: compare the
probe's `luma_mean` against the template's `enroll_luma_mean` and refuse, with an
actionable message ("the lighting is very different from when you enrolled — move
somewhere similar"), when the delta exceeds a measured budget.

A refusal the student can act on beats a silent false reject that reads to them
as "the system says I'm not me".

Derive the budget from Step 1/Step 2 data. Do **not** guess it, and do **not**
implement this as another attempt to control the camera — see §4.3 for why two
such attempts failed.

---

## 7. Reference

### Current live configuration

```
config/model (Firestore, database literally named "default"):
  model_version                    = palm_256_l2_fp32_v5
  verification_threshold_FAR_0_1pct = 0.5508
```

Model file: `assets/models/palm_256_l2_fp32_v5.onnx`
Deploy config: `assets/models/deploy_config.json`
Project: `attcit-52e7d`, region `asia-south1`

### Key files

| path | role |
|---|---|
| `lib/services/hand_detector.dart` | landmarks, v5 rotation-aligned ROI, containment gate |
| `lib/services/preprocessing.dart` | camera planes → 224×224 NCHW tensor (fused fast path + reference) |
| `lib/services/capture_controller.dart` | capture loop, quality/liveness/pose gates, multi-pass averaging |
| `lib/services/quality_gate.dart` | brightness/blowout/sharpness gates, exposure targets |
| `lib/screens/capture_screen.dart` | camera setup, exposure normalisation controller |
| `functions/index.js` | `submitAttendance` — the only place a verdict is made |
| `test/palm_roi_test.dart` | 19 tests pinning ROI geometry + containment |
| `test/preprocessing_equivalence_test.dart` | 21 tests pinning fast path == reference |
| `lib/models/student_profile.dart` | `enrollIllumination` -> `enroll_illumination` |
| `firestore.rules` | `enroll_illumination` must stay in `studentWritableFields()` |

### Reproducing

1. Enroll in a dim room (let the exposure controller settle).
2. Verify in bright light.
3. Read `palm_score` from the newest `attendance` document.

Step 3 now also gives `probe_vs_enroll_luma_delta` — but only if the template was
enrolled on a build from 2026-08-16 or later. Re-enroll first, otherwise the
delta is null and the run tells you nothing about lighting.

Gotcha: `studentWritableFields()` in `firestore.rules` is a `hasOnly()` allowlist.
If a future field is added to the student document without being added there, the
ENTIRE enrollment write is rejected — silently, from the student's point of view.
That exact mistake has already cost this project a debugging session once.

### Standing project constraints (still in force)

- Never compare a probe against a template enrolled under a different
  `model_version` — `submitAttendance` rejects rather than scores.
- The server decides. `config/model` overrides the bundled deploy config.
- Enrollment must remain a multi-frame average; never a single shot.
- `hand_side` is stored explicitly and gated before comparison.
- This build is not to be described as production-grade.

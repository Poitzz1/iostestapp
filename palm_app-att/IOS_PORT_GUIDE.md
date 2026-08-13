# PalmPay — iOS Port Guide

Handoff doc for building out iOS support. Written for someone who has not seen
this codebase before. Read this before touching `ios/` — most of what looks
like it needs porting actually already works cross-platform; the real gaps are
narrower and listed in §5.

---

## 1. What this app is, right now

Two things live in the same Flutter project:

### A) The production app (currently switched OFF)

A palm-biometric attendance system: students enroll their palm once, then scan
it daily to mark attendance. Verification is server-side, 1:1 (not a gallery
search) — the phone sends evidence (palm embedding, Wi-Fi scan, GPS, device id)
to a Cloud Function, which fetches *that one student's* stored template, runs
one cosine comparison, and returns a verdict. The phone never decides.

**It is currently gated off.** `AppMode.productionAttendanceEnabled = false` in
[`lib/config/app_mode.dart`](lib/config/app_mode.dart) routes every enrollment
and attendance screen to a "coming soon" placeholder, for students AND
advisors. This was done because the model's real-world accuracy isn't there yet
(see §2) — the gate gets flipped back on once retraining closes that gap. All
the code is intact underneath the gate; nothing was deleted.

### B) The in-app data collector (currently the ONLY reachable feature)

A separate module (`lib/collector/`) that walks a participant through a guided
matrix of lighting/distance/angle/posture conditions, capturing real palm
photos on real phones to build the retraining dataset that (A) needs. It writes
to a **completely separate Firebase project** from production — different
credentials, different auth realm (anonymous), different database — so a bug
here can never leak into the attendance data.

Both features share the on-device ML pipeline (camera → MediaPipe hand
detection → crop → ONNX embedding) but nothing else — separate capture
controllers, separate Firebase projects, separate screens.

---

## 2. Why production is gated off

Measured on real phone photos of two people, the current model (`v4`,
`palm_256_l2_fp32.onnx`) shows **~14% false accepts**. Its confirmed weak axis
is overexposure: same-palm cosine similarity drops from ~0.94 (darkened) to
~0.70 (brightened). The collector exists to gather the real-world overexposed/
dim/angled data needed to retrain past that. Until then, shipping production
attendance as a live gate would mark wrong people present, so it's off and
advisors mark attendance manually as the pilot's existing backstop.

This matters for the port because **most of what your friend will actually run
and test on iOS right now is the collector**, not the production flow.

---

## 3. Tech stack

| Layer | Choice | iOS status |
|---|---|---|
| Framework | Flutter (Dart) | n/a |
| State | Riverpod | fine everywhere |
| On-device model | `onnxruntime` (loads `.onnx`) | ✅ has iOS FFI plugin |
| Camera | `camera` | ✅ `camera_avfoundation` backend |
| Hand/palm detection | `hand_detection` (MediaPipe-based) | ✅ declares iOS support, bundles its own `.tflite` models as package assets — no manual asset wiring needed |
| Image decode/crop | `image` (pure Dart) | ✅ platform-agnostic |
| Auth/DB/Functions/Storage | Firebase (`firebase_core`, `firebase_auth`, `cloud_firestore`, `cloud_functions`, `firebase_storage`) | ✅ all have iOS SDKs — needs iOS app **registered** per project (see §5) |
| Local persistence | `shared_preferences`, `path_provider`, `connectivity_plus` | ✅ fine |
| Wi-Fi fingerprint | `wifi_scan` | ⚠️ **iOS returns "unsupported" — see §5.1, this is the one real architectural gap** |
| GPS | `geolocator` | ✅ fine, but Info.plist needs a usage string (missing, see §5.2) |
| Device id | `device_info_plus` (used directly in `DeviceService`) | ✅ already has an iOS branch (`identifierForVendor`) |
| Haptics | `vibration` | ✅ has iOS plugin |
| 3D hand model | `model_viewer_plus` | ✅ WebView-backed, works both platforms |
| Fonts/animation | `google_fonts`, `flutter_animate` | ✅ pure Dart |

**Bottom line: the vast majority of this app is already cross-platform Flutter
code with no `Platform.isAndroid` branches.** This is not a rewrite. It's:
register Firebase iOS apps, fill in two config files, add a couple of Info.plist
keys, and deal with one real platform gap (Wi-Fi scanning).

---

## 4. Where platform-specific code actually exists

Grep for `Platform.isAndroid` / `Platform.isIOS` / `TargetPlatform` across
`lib/` — there are only three call sites in the whole app:

1. **[`lib/firebase_options.dart`](lib/firebase_options.dart)** — production
   Firebase config, branches on platform to pick Android vs iOS credentials.
   iOS branch currently exists but is a **placeholder**: it reuses the Android
   app's `appId`/`apiKey` as a fallback, which is wrong for a real build (see
   §5.3).

2. **[`lib/collector/collector_firebase_options.dart`](lib/collector/collector_firebase_options.dart)**
   — same idea for the collector's separate Firebase project. iOS is **not
   implemented at all**: it deliberately `throw`s (`UnsupportedError`) rather
   than presenting fake-looking placeholder values. See §5.4.

3. **[`lib/services/device_service.dart`](lib/services/device_service.dart)**
   — stable per-install device id for device binding. Already has a working iOS
   branch (`identifierForVendor`). No work needed here.

Everything else — capture controllers, screens, the whole collector module,
Firestore rules, Cloud Functions — is platform-agnostic Dart/JS and needs zero
changes to run on iOS.

---

## 5. What actually needs doing

### 5.1 Wi-Fi fingerprint — the one real architectural gap

`WifiScanService` wraps the `wifi_scan` package, which is how the production
attendance flow confirms a student is physically in the classroom (spec §7,
primary presence signal). **On iOS this package returns `unsupported` outright**
— Apple does not allow apps to enumerate nearby Wi-Fi access points/BSSIDs
without a special entitlement Apple grants only to specific enterprise use
cases (MDM, network config apps). There is no drop-in replacement package that
gets around this; it's an OS-level restriction, not a library gap.

The app's code already anticipates this — `WifiScanFailure.unsupported` is a
defined case, and the flow degrades rather than crashing. But architecturally,
**the Wi-Fi presence layer will simply never work on iOS**, only GPS (coarse
campus check) and session window will apply. Decide (with whoever owns the
attendance spec) whether that's acceptable for an iOS pilot, or whether the
server-side verdict logic (`submitAttendance` in `functions/index.js`) needs a
policy change for iOS clients (e.g., weight GPS + device binding more heavily
when `wifi_scan: []` arrives from an iOS device). This is a product decision,
not just an engineering one — flag it before writing iOS-specific server logic.

This only affects the production attendance flow, which is currently gated off
anyway (§2) — it does not block iOS work on the collector.

### 5.2 `Info.plist` — missing permission strings

Currently only has `NSCameraUsageDescription`. Missing, and required or the app
will silently fail/crash the moment the corresponding API is called:

- **`NSLocationWhenInUseUsageDescription`** — required by `geolocator`
  (`LocationService`, used in the production attendance flow's GPS check).
  Without this key, calling `Geolocator.getCurrentPosition()` throws instead of
  showing the OS permission dialog.
- Nothing else is needed for the collector or for camera/hand detection — no
  photo library, no microphone (camera is opened with `enableAudio: false`
  everywhere), no local network usage string is needed by `wifi_scan` since iOS
  returns unsupported before touching the network layer.

Add both keys to `ios/Runner/Info.plist` alongside the existing camera key.

### 5.3 Production Firebase project — register a real iOS app

`lib/firebase_options.dart` currently has this comment on the iOS section:

> NOTE: The Android and iOS app IDs below use the web app ID as a fallback. For
> production, register dedicated Android/iOS apps in Firebase Console and
> update the appId values with the platform-specific ones.

That's still true. In the Firebase console for project **`attcit-52e7d`**:

1. Add an iOS app, bundle id matching whatever `ios/Runner.xcodeproj` is set to
   (check `PRODUCT_BUNDLE_IDENTIFIER` — currently it's whatever the Flutter
   scaffold generated; the Android side uses `com.palmpay.palmPayEnroll`, so
   probably match that).
2. Download the generated `GoogleService-Info.plist`, drop it into
   `ios/Runner/`, and add it to the Xcode project (Runner target → Build
   Phases, or just drag it into Xcode — CocoaPods/Flutter picks it up
   automatically once it's a Runner resource).
3. Update the `ios` `FirebaseOptions` block in `firebase_options.dart` with the
   real `apiKey`/`appId` from that new registration (or regenerate the whole
   file via `flutterfire configure` — see §6).

### 5.4 Collector Firebase project — iOS not configured at all

`lib/collector/collector_firebase_options.dart` currently throws
`UnsupportedError` on iOS by design — better to fail loudly than silently
misconfigure a secondary Firebase app. To enable it:

1. In the Firebase console for the collector project **`testtt-75eb6`**,
   register an iOS app.
2. Add the generated config to the `ios` case in
   `CollectorFirebaseOptions.currentPlatform` (currently there's no `ios`
   getter at all — you'll need to add one, mirroring the `android` block).
3. Remove the `throw` for `TargetPlatform.iOS` in that same switch.

The collector's Firestore rules, Storage rules, and Cloud Function
(`linkCollectorSubject`, on the *production* project) are all backend-side and
need zero iOS-specific changes — they already work for any client.

### 5.5 The project has never been built for iOS, at all

There's no `Podfile` / `Podfile.lock` under `ios/` — this repo was developed on
Windows, which cannot build or run iOS targets at all (Xcode is macOS-only).
The `ios/` folder is the stock Flutter-generated scaffold and has never been
through `flutter build ios` or `pod install`. Expect first-build friction:
CocoaPods will need to resolve and vendor all the plugin pods for the first
time, and native build issues (deployment target conflicts between pods,
codesigning setup, etc.) are likely on the first attempt. This is normal for a
first iOS build, not a sign anything above is wrong.

Current `IPHONEOS_DEPLOYMENT_TARGET` in the Xcode project is **13.0** — check
whether `onnxruntime`/`hand_detection`/`camera`'s current iOS pod versions still
support that or need it bumped (14.0+ is a safer bet for 2025-era plugin
releases).

---

## 6. Suggested order of work

1. **Get a bare `flutter run` iOS build green first**, before touching any
   Firebase config — comment out/stub Firebase init if needed just to prove
   the Dart/native build pipeline works and CocoaPods resolves. This isolates
   "iOS build problems" from "Firebase config problems."
2. Add the two `Info.plist` keys (§5.2).
3. Register the iOS app in the **collector** Firebase project and fill in
   `CollectorFirebaseOptions.ios` (§5.4) — this is the fastest path to a fully
   working iOS feature, since the collector is the only reachable flow right
   now (§2) and has no Wi-Fi-scan dependency.
4. Run the collector end-to-end on a real iPhone: sign in → "Help improve
   recognition" → capture a session → verify a template → confirm samples
   upload. This exercises camera, MediaPipe hand detection, ONNX inference,
   Firestore/Storage — i.e., almost the entire native surface of the app —
   without touching the Wi-Fi gap at all.
5. Only then tackle the production Firebase project (§5.3) and the Wi-Fi
   presence-signal product decision (§5.1) — that flow is gated off anyway, so
   it's not blocking anything.

Consider using `flutterfire configure` (the FlutterFire CLI) once both Firebase
projects have iOS apps registered — it regenerates `firebase_options.dart`
automatically for all configured platforms in one shot, instead of hand-editing
the `FirebaseOptions` blocks. It won't touch `collector_firebase_options.dart`
(that's a hand-rolled file, not FlutterFire-generated), so that one still needs
manual editing per §5.4.

---

## 7. Reference: key files to know

```
lib/
  config/app_mode.dart              production on/off switch
  firebase_options.dart             production Firebase config (needs iOS fix, §5.3)
  services/
    wifi_scan_service.dart          Wi-Fi presence signal (iOS: unsupported, §5.1)
    device_service.dart             per-device id (iOS already works)
    hand_detector.dart              MediaPipe wrapper (cross-platform)
    preprocessing.dart              camera frame → model tensor (cross-platform)
    palm_model_service.dart         ONNX inference (cross-platform)
  collector/
    collector_firebase_options.dart collector Firebase config (iOS not implemented, §5.4)
    README.md                       full collector module documentation
    screens/                        the only screens reachable right now

ios/
  Runner/Info.plist                 needs NSLocationWhenInUseUsageDescription (§5.2)
  Runner.xcodeproj/...               deployment target 13.0, may need bumping (§5.5)
```

Also worth reading before starting: [`README.md`](README.md) (production spec
and pilot status) and [`lib/collector/README.md`](lib/collector/README.md)
(collector module deep-dive — capture protocol, live hand-assist overlay,
verification events, export tooling).

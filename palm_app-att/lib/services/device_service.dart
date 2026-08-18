import 'package:shared_preferences/shared_preferences.dart';

// Resolved at compile time: the native implementation reads an OS-issued
// identifier; the web one mints a random UUID. They are deliberately NOT
// equivalent — see [DeviceService.isOsIssuedId] and the doc comment in
// device_id_web.dart before relying on this value for anything.
import 'device_id_native.dart'
    if (dart.library.js_interop) 'device_id_web.dart';

/// Stable per-install device id for device binding (spec §7).
///
/// One registered device per student: the id is captured at enrollment
/// (`bound_device_id`) and sent with every attendance submission.
///
/// ## The guarantee is platform-dependent — check [isOsIssuedId]
///
/// **Native (Android / iOS)** — the id comes from the operating system
/// (`identifierForVendor`, Android id). Best-effort but not client-forgeable: a
/// factory reset or reinstall can rotate it, at which point the student must
/// re-enroll (which re-binds). That is an acceptable, auditable trade-off.
///
/// **Web** — there is no browser API that returns a stable hardware-tied
/// identifier, so the id is a random UUID the CLIENT generates and stores in
/// `localStorage`. It is clearable, per-browser rather than per-machine, and
/// directly writable from the page's own JS console. It supports "probably the
/// same browser as last time" and nothing stronger. Do not present it in UI
/// copy, logs, or docs as though it identified a device.
///
/// Device binding is currently logged but NOT enforced server-side. The web
/// implementation is a reason to keep it that way, not to change it.
class DeviceService {
  static const _key = 'bound_device_id';

  /// True when [deviceId] returns an OS-issued identifier (native), false when
  /// it returns a self-minted, user-clearable one (web).
  ///
  /// Anything that reasons about how much this id proves should branch on this
  /// rather than assuming the native property holds everywhere.
  bool get isOsIssuedId => deviceIdIsOsIssued;

  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_key);
    if (cached != null && cached.isNotEmpty) return cached;

    // On web this is the point the UUID is minted; caching it is what makes it
    // stable across reloads, and clearing site data is what makes it not.
    final id = await platformDeviceId();
    await prefs.setString(_key, id);
    return id;
  }
}

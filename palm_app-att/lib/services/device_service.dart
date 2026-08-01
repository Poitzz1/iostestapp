import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable per-install device id for device binding (spec §7).
///
/// One registered device per student: the id is captured at enrollment
/// (`bound_device_id`) and sent with every attendance submission; the server
/// rejects a submission whose device id doesn't match the bound one.
///
/// We use the OS-provided install/device identifier and cache it locally so it
/// stays stable across app launches. Note this is best-effort — a factory
/// reset or reinstall can rotate it, at which point the student must re-enroll
/// (which re-binds). That's an acceptable, auditable trade-off for a pilot.
class DeviceService {
  static const _key = 'bound_device_id';
  final DeviceInfoPlugin _info = DeviceInfoPlugin();

  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_key);
    if (cached != null && cached.isNotEmpty) return cached;

    final id = await _platformId();
    await prefs.setString(_key, id);
    return id;
  }

  Future<String> _platformId() async {
    try {
      if (Platform.isAndroid) {
        final a = await _info.androidInfo;
        // androidId-equivalent; stable per app-signing-key + device + user.
        return a.id;
      }
      if (Platform.isIOS) {
        final i = await _info.iosInfo;
        return i.identifierForVendor ?? 'ios-unknown';
      }
    } catch (_) {/* fall through */}
    return 'unknown-device';
  }
}

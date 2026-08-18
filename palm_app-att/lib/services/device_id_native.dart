import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

/// Native device identifier — the OS-provided install/device id.
///
/// This is the STRONG form of device binding: `identifierForVendor` on iOS and
/// the Android id are issued by the operating system and a student cannot mint
/// a new one from inside the app. See [platformDeviceId] in the web
/// counterpart for the materially weaker property the browser can offer.
Future<String> platformDeviceId() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      // androidId-equivalent; stable per app-signing-key + device + user.
      final a = await info.androidInfo;
      return a.id;
    }
    if (Platform.isIOS) {
      final i = await info.iosInfo;
      return i.identifierForVendor ?? 'ios-unknown';
    }
  } catch (_) {/* fall through */}
  return 'unknown-device';
}

/// Whether [platformDeviceId] is issued by the operating system (true) or
/// self-minted by the client (false). See the web implementation.
const bool deviceIdIsOsIssued = true;

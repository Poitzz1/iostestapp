import 'package:wifi_scan/wifi_scan.dart';

/// Result of one Wi-Fi scan attempt: the visible access points, or a reason it
/// couldn't scan (so the UI can show a specific fix, spec §9).
class WifiScanResult {
  final List<WifiAccessPointInfo> aps;
  final WifiScanFailure? failure;

  const WifiScanResult({this.aps = const [], this.failure});
  bool get ok => failure == null;
}

class WifiAccessPointInfo {
  final String bssid;
  final String ssid;
  final int rssi;
  const WifiAccessPointInfo({required this.bssid, required this.ssid, required this.rssi});

  Map<String, dynamic> toPayload() => {'bssid': bssid.toLowerCase(), 'rssi': rssi};
}

enum WifiScanFailure { unsupported, permissionDenied, locationServiceOff, cannotScan }

/// Result of an admin multi-pass fingerprint capture. Carries the reason on
/// failure — returning a bare empty list made every cause (no permission,
/// Location off, Wi-Fi off, Android scan throttling) look identical to the
/// admin, who was then told to check Wi-Fi even when Wi-Fi was fine.
class WifiFingerprintCapture {
  final List<WifiAccessPointInfo> aps;
  final WifiScanFailure? failure;

  /// How many of the requested passes actually returned access points. Fewer
  /// than requested usually means Android throttled `startScan` and we fell
  /// back to its cached results.
  final int passesWithResults;

  const WifiFingerprintCapture({
    this.aps = const [],
    this.failure,
    this.passesWithResults = 0,
  });

  bool get ok => failure == null && aps.isNotEmpty;
}

/// Wraps `wifi_scan` (spec §7 — Wi-Fi BSSID fingerprint is the PRIMARY presence
/// signal). Scans are triggered on user action, never a timer — Android
/// throttles background scans hard.
///
/// Android requires ACCESS_FINE_LOCATION + ACCESS_WIFI_STATE AND device
/// *location services* switched on (a user setting, not a permission — if off,
/// BSSID reads come back empty). Those failure modes are surfaced distinctly so
/// the UI can tell the student exactly what to turn on.
class WifiScanService {
  /// Perform a single scan and return the visible APs.
  Future<WifiScanResult> scan() async {
    final can = await WiFiScan.instance.canStartScan();
    switch (can) {
      case CanStartScan.notSupported:
        return const WifiScanResult(failure: WifiScanFailure.unsupported);
      case CanStartScan.noLocationPermissionRequired:
      case CanStartScan.noLocationPermissionDenied:
      case CanStartScan.noLocationPermissionUpgradeAccuracy:
        return const WifiScanResult(failure: WifiScanFailure.permissionDenied);
      case CanStartScan.noLocationServiceDisabled:
        return const WifiScanResult(failure: WifiScanFailure.locationServiceOff);
      case CanStartScan.failed:
        return const WifiScanResult(failure: WifiScanFailure.cannotScan);
      case CanStartScan.yes:
        break;
    }

    // `startScan` returning false is NOT fatal. Android 9+ throttles foreground
    // apps to 4 scans per 2 minutes, and a throttled call fails exactly like a
    // real error — but the platform still serves the last scan's cached results,
    // which for a stationary admin in a classroom is the same AP set. Treating
    // false as "cannot scan" is what made a second capture attempt within two
    // minutes always come back empty. So: note it, and read the cache anyway.
    final started = await WiFiScan.instance.startScan();

    // `startScan` is asynchronous on Android — the results are not ready the
    // instant it returns. Reading immediately hands back the PREVIOUS scan's
    // cache (empty on a fresh app start, which is why the very first capture
    // looked broken). Give the platform a moment to publish the new results.
    if (started) await Future.delayed(const Duration(seconds: 3));

    final can2 = await WiFiScan.instance.canGetScannedResults();
    if (can2 != CanGetScannedResults.yes) {
      return const WifiScanResult(failure: WifiScanFailure.cannotScan);
    }
    final results = await WiFiScan.instance.getScannedResults();
    final aps = results
        .where((a) => a.bssid.isNotEmpty)
        .map((a) => WifiAccessPointInfo(
              bssid: a.bssid,
              ssid: a.ssid,
              rssi: a.level,
            ))
        .toList();
    // ZERO access points is never a legitimate result. Any real building has
    // some networks visible, so an empty list means the scan itself failed —
    // Location services off (Android returns no BSSIDs), Wi-Fi off, or every
    // scan in the throttle window rejected before a cache existed.
    //
    // This previously only reported failure when `started` was also false,
    // so a scan that "succeeded" with nothing in it was passed along as a
    // valid empty scan. The caller then submitted `wifi_scan: []`, the server
    // matched 0 BSSIDs, and the student was told "you don't appear to be in
    // the classroom" — pointing at the wrong problem entirely, since the phone
    // had not seen a single network.
    if (aps.isEmpty) {
      return const WifiScanResult(failure: WifiScanFailure.cannotScan);
    }
    return WifiScanResult(aps: aps);
  }

  /// Admin fingerprint capture (spec §7): several scans a few seconds apart,
  /// keep BSSIDs seen in a majority of scans. Returns the merged AP set with a
  /// representative (median) RSSI.
  /// [scans] defaults to 3, not 4, on purpose: Android 9+ allows a foreground
  /// app only 4 `startScan` calls per 2 minutes. Spending all four left no
  /// budget for a retry, so a re-capture — the first thing anyone does when a
  /// capture looks wrong — was guaranteed to fail. Three passes still give a
  /// majority vote (2 of 3) and leave one call spare.
  Future<WifiFingerprintCapture> captureFingerprint({
    int scans = 3,
    Duration gap = const Duration(seconds: 3),
  }) async {
    final counts = <String, int>{};
    final rssis = <String, List<int>>{};
    final ssids = <String, String>{};
    var passesWithResults = 0;
    WifiScanFailure? lastFailure;

    for (var i = 0; i < scans; i++) {
      final r = await scan();
      if (!r.ok) {
        lastFailure = r.failure;
        // A blocked prerequisite (no permission, Location off, unsupported)
        // will not fix itself on the next pass — stop and report it.
        if (r.failure != WifiScanFailure.cannotScan) {
          return WifiFingerprintCapture(failure: r.failure, passesWithResults: passesWithResults);
        }
        if (i < scans - 1) await Future.delayed(gap);
        continue;
      }
      passesWithResults++;
      for (final ap in r.aps) {
        final b = ap.bssid.toLowerCase();
        counts[b] = (counts[b] ?? 0) + 1;
        (rssis[b] ??= []).add(ap.rssi);
        ssids[b] = ap.ssid;
      }
      if (i < scans - 1) await Future.delayed(gap);
    }

    if (passesWithResults == 0) {
      return WifiFingerprintCapture(
          failure: lastFailure ?? WifiScanFailure.cannotScan);
    }

    // Majority of the passes that actually produced results — not of the passes
    // requested. If throttling left us with one usable pass, requiring 2 sightings
    // would discard every AP and report "no access points" despite a good scan.
    final majority = (passesWithResults / 2).ceil();
    final kept = <WifiAccessPointInfo>[];
    counts.forEach((bssid, seen) {
      if (seen >= majority) {
        final samples = rssis[bssid]!..sort();
        final median = samples[samples.length ~/ 2];
        kept.add(WifiAccessPointInfo(bssid: bssid, ssid: ssids[bssid] ?? '', rssi: median));
      }
    });
    // Strongest first, so the admin sees the room's own APs at the top.
    kept.sort((a, b) => b.rssi.compareTo(a.rssi));
    return WifiFingerprintCapture(aps: kept, passesWithResults: passesWithResults);
  }
}

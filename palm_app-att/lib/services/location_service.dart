import 'package:geolocator/geolocator.dart';

/// GPS reading for the coarse campus sanity check (spec §7 — GPS is DEMOTED to
/// a wide-radius check, never a room-level gate). Also surfaces the
/// mock-location flag as a risk signal (logged server-side, not gated alone).
class GpsReading {
  final double lat;
  final double lng;
  final double accuracyM;
  final bool isMock;

  const GpsReading({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.isMock,
  });

  Map<String, dynamic> toPayload() => {
        'lat': lat,
        'lng': lng,
        'accuracy_m': accuracyM,
      };
}

enum LocationFailure { serviceOff, permissionDenied, permissionDeniedForever, timeout }

class LocationResult {
  final GpsReading? reading;
  final LocationFailure? failure;
  const LocationResult({this.reading, this.failure});
  bool get ok => reading != null;
}

class LocationService {
  Future<LocationResult> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const LocationResult(failure: LocationFailure.serviceOff);
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      return const LocationResult(failure: LocationFailure.permissionDenied);
    }
    if (perm == LocationPermission.deniedForever) {
      return const LocationResult(failure: LocationFailure.permissionDeniedForever);
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      return LocationResult(
        reading: GpsReading(
          lat: pos.latitude,
          lng: pos.longitude,
          accuracyM: pos.accuracy,
          isMock: pos.isMocked,
        ),
      );
    } catch (_) {
      return const LocationResult(failure: LocationFailure.timeout);
    }
  }
}

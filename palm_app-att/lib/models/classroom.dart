import 'package:cloud_firestore/cloud_firestore.dart';

/// A registered classroom and its Wi-Fi fingerprint (unified spec §8).
///
/// The Wi-Fi BSSID fingerprint is the PRIMARY presence signal (§7). GPS here
/// is a coarse campus-wide sanity check only — `campusRadiusM` is deliberately
/// generous (hundreds of metres), never a room-level gate.

/// Timestamp fields here are always written as ISO8601 strings by this app
/// and by the seed script, but never trust that blindly — see the identical
/// helper (and its backstory) in student_profile.dart.
DateTime? _coerceTimestamp(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is Timestamp) return v.toDate();
  return null;
}

class WifiAp {
  final String bssid;
  final String? ssid;
  final int? typicalRssi;

  const WifiAp({required this.bssid, this.ssid, this.typicalRssi});

  Map<String, dynamic> toMap() => {
        'bssid': bssid.toLowerCase(),
        if (ssid != null) 'ssid': ssid,
        if (typicalRssi != null) 'typical_rssi': typicalRssi,
      };

  factory WifiAp.fromMap(Map<String, dynamic> m) => WifiAp(
        bssid: (m['bssid'] as String).toLowerCase(),
        ssid: m['ssid'] as String?,
        typicalRssi: (m['typical_rssi'] as num?)?.toInt(),
      );
}

class Classroom {
  final String classroomId;
  final String? building;
  final String? room;
  final int? floor;
  final double? latitude;
  final double? longitude;
  final double campusRadiusM;
  final List<WifiAp> wifiFingerprint;
  final int minBssidMatches;
  final DateTime? updatedAt;

  const Classroom({
    required this.classroomId,
    this.building,
    this.room,
    this.floor,
    this.latitude,
    this.longitude,
    this.campusRadiusM = 300,
    this.wifiFingerprint = const [],
    this.minBssidMatches = 2,
    this.updatedAt,
  });

  bool get isFingerprinted => wifiFingerprint.isNotEmpty;

  Map<String, dynamic> toFirestore() => {
        'classroom_id': classroomId,
        if (building != null) 'building': building,
        if (room != null) 'room': room,
        if (floor != null) 'floor': floor,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        'campus_radius_m': campusRadiusM,
        'wifi_fingerprint': wifiFingerprint.map((a) => a.toMap()).toList(),
        'min_bssid_matches': minBssidMatches,
        'updated_at': (updatedAt ?? DateTime.now()).toIso8601String(),
      };

  factory Classroom.fromFirestore(Map<String, dynamic> d) => Classroom(
        classroomId: d['classroom_id'] as String,
        building: d['building'] as String?,
        room: d['room'] as String?,
        floor: (d['floor'] as num?)?.toInt(),
        latitude: (d['latitude'] as num?)?.toDouble(),
        longitude: (d['longitude'] as num?)?.toDouble(),
        campusRadiusM: (d['campus_radius_m'] as num?)?.toDouble() ?? 300,
        wifiFingerprint: ((d['wifi_fingerprint'] as List?) ?? [])
            .map((e) => WifiAp.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
        minBssidMatches: (d['min_bssid_matches'] as num?)?.toInt() ?? 2,
        updatedAt: _coerceTimestamp(d['updated_at']),
      );
}

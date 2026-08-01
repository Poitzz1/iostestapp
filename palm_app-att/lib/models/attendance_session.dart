/// An attendance window opened by an advisor for one section (spec §7, §8).
///
/// `opened_at` / `closes_at` are set from SERVER time when created; the server
/// enforces the window on every submission. The client copy is display-only.
class AttendanceSession {
  final String sessionId;
  final String classroomId;
  final String section;
  final String advisorId;
  final DateTime openedAt;
  final DateTime closesAt;
  final String status; // "open" | "closed"
  final String? rotatingCode; // optional defence-in-depth / iOS fallback

  const AttendanceSession({
    required this.sessionId,
    required this.classroomId,
    required this.section,
    required this.advisorId,
    required this.openedAt,
    required this.closesAt,
    required this.status,
    this.rotatingCode,
  });

  bool get isOpen =>
      status == 'open' && DateTime.now().isBefore(closesAt);

  factory AttendanceSession.fromFirestore(Map<String, dynamic> d, String id) {
    DateTime parseTs(dynamic v) {
      if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
      // Firestore Timestamp has a toDate(); ISO strings are also accepted for
      // sessions created client-side before a server write lands.
      try {
        return (v as dynamic).toDate() as DateTime;
      } catch (_) {
        return DateTime.tryParse(v.toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
    }

    return AttendanceSession(
      sessionId: id,
      classroomId: d['classroom_id'] as String? ?? '',
      section: d['section'] as String? ?? '',
      advisorId: d['advisor_id'] as String? ?? '',
      openedAt: parseTs(d['opened_at']),
      closesAt: parseTs(d['closes_at']),
      status: d['status'] as String? ?? 'closed',
      rotatingCode: d['rotating_code'] as String?,
    );
  }
}

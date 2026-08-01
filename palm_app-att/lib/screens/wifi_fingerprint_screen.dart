import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_theme.dart';
import '../models/classroom.dart';
import '../providers/providers.dart';
import '../services/wifi_scan_service.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Admin classroom Wi-Fi fingerprint capture (spec §7). Stand in the room,
/// enter the classroom id, and run several scans a few seconds apart.
///
/// Exactly ONE access point is registered per classroom: the scan surfaces
/// every AP it can see (in a large building that can be dozens), and the admin
/// picks the one that belongs to this room — strongest first, pre-selected.
/// Storing the whole visible set was worse than storing nothing: with
/// `min_bssid_matches: 2` against 60-odd building-wide BSSIDs, a student two
/// floors away still matched, which defeats the presence check entirely.
/// One AP means one wall-mounted radio the student must physically be near.
class WifiFingerprintScreen extends ConsumerStatefulWidget {
  const WifiFingerprintScreen({super.key});

  @override
  ConsumerState<WifiFingerprintScreen> createState() => _WifiFingerprintScreenState();
}

class _WifiFingerprintScreenState extends ConsumerState<WifiFingerprintScreen> {
  final _classroomCtrl = TextEditingController();
  Timer? _lookupDebounce;

  bool _scanning = false;
  bool _saving = false;
  bool _loadingExisting = false;

  /// Every AP the capture saw, strongest first — the candidates to choose from.
  List<WifiAccessPointInfo> _candidates = [];

  /// The single AP that will be written. Null until a capture produces one.
  WifiAccessPointInfo? _selected;

  /// The fingerprint already registered for the classroom in the id field.
  Classroom? _existing;

  String? _error;
  String? _warning;

  @override
  void initState() {
    super.initState();
    // Prefill the admin's own classroom so the saved fingerprint shows up
    // immediately rather than only after they type the room id.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final staff = await ref.read(staffProfileProvider.future);
      final id = staff?.classroomId;
      if (!mounted || id == null || id.isEmpty) return;
      _classroomCtrl.text = id;
      _loadExisting(id);
    });
  }

  @override
  void dispose() {
    _lookupDebounce?.cancel();
    _classroomCtrl.dispose();
    super.dispose();
  }

  /// Fetch whatever is already registered for [id] so the admin can see the
  /// current fingerprint before deciding to overwrite it.
  Future<void> _loadExisting(String id) async {
    if (id.isEmpty) {
      setState(() => _existing = null);
      return;
    }
    setState(() => _loadingExisting = true);
    try {
      final room = await ref.read(classroomServiceProvider).get(id);
      if (mounted) setState(() => _existing = room);
    } catch (_) {
      // A lookup failure is not worth an error banner — the admin is mid-typing
      // and the capture flow below still works.
      if (mounted) setState(() => _existing = null);
    } finally {
      if (mounted) setState(() => _loadingExisting = false);
    }
  }

  void _onClassroomChanged(String value) {
    _lookupDebounce?.cancel();
    _lookupDebounce = Timer(
      const Duration(milliseconds: 600),
      () => _loadExisting(value.trim().toUpperCase()),
    );
  }

  Future<void> _capture() async {
    setState(() {
      _scanning = true;
      _error = null;
      _warning = null;
      _candidates = [];
      _selected = null;
    });
    final result = await ref.read(wifiScanServiceProvider).captureFingerprint();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _candidates = result.aps;
      // Strongest AP is almost always the one in this room — pre-select it, but
      // leave the choice with the admin, who knows which radio is on the wall.
      _selected = result.aps.isNotEmpty ? result.aps.first : null;
      _error = switch (result.failure) {
        null => result.aps.isEmpty
            ? 'Scan succeeded but saw no access points. Move further into the '
                'room and capture again.'
            : null,
        WifiScanFailure.permissionDenied =>
          'Location permission is required to read Wi-Fi. Grant it in '
              'Settings → Apps → PalmPay → Permissions → Location.',
        WifiScanFailure.locationServiceOff =>
          'Turn on Location (the system toggle, not just the permission) — '
              'Android returns no BSSIDs while it is off.',
        WifiScanFailure.unsupported =>
          'This device cannot scan Wi-Fi. Capture the fingerprint from another '
              'phone.',
        WifiScanFailure.cannotScan =>
          'Could not scan. Turn Wi-Fi on, then wait about two minutes before '
              'retrying — Android limits an app to 4 Wi-Fi scans every 2 '
              'minutes and blocks the ones after that.',
      };
      _warning = _error == null ? _warnAbout(_selected, result) : null;
    });
  }

  /// Advisory checks on the pre-selected AP. None of these block saving — the
  /// admin is standing in the room and knows more than we do.
  String? _warnAbout(WifiAccessPointInfo? ap, WifiFingerprintCapture result) {
    if (ap == null) return null;
    if (_looksLikeHotspot(ap.ssid)) {
      return '"${ap.ssid}" looks like a personal hotspot. It will walk out of '
          'the room with its owner and take attendance with it — pick a '
          'wall-mounted campus AP instead.';
    }
    if (ap.rssi < -75) {
      return 'The strongest AP here is only ${ap.rssi} dBm. A weak radio is not '
          'seen reliably by every phone; students may be refused. Capture '
          'closer to the room\'s access point if you can.';
    }
    if (result.passesWithResults < 2) {
      return 'Only ${result.passesWithResults} scan pass returned results '
          '(Android throttling). The choice below is usable, but re-capturing '
          'in a few minutes gives more reliable signal readings.';
    }
    return null;
  }

  static bool _looksLikeHotspot(String ssid) {
    final s = ssid.toLowerCase();
    return s.contains('androidap') ||
        s.contains('iphone') ||
        s.contains('hotspot') ||
        s.contains('galaxy') ||
        s.contains('redmi') ||
        s.contains('oneplus');
  }

  Future<void> _save() async {
    final id = _classroomCtrl.text.trim().toUpperCase();
    final ap = _selected;
    if (id.isEmpty) {
      setState(() => _error = 'Enter the classroom id (e.g. C302).');
      return;
    }
    if (ap == null) {
      setState(() => _error = 'Capture a fingerprint and choose an access point first.');
      return;
    }
    // Overwriting a registered fingerprint invalidates the room for every
    // student until the new AP is verified — make it a deliberate act.
    if (_existing?.isFingerprinted ?? false) {
      final confirmed = await _confirmOverwrite(id);
      if (confirmed != true) return;
    }
    setState(() => _saving = true);
    try {
      // One AP registered, so the server threshold must be 1 — anything higher
      // is unsatisfiable and rejects the whole room.
      await ref.read(classroomServiceProvider).saveFingerprint(
            id,
            [ap],
            minBssidMatches: 1,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$id registered to ${ap.ssid.isEmpty ? ap.bssid : ap.ssid}')),
      );
      // Re-read and show the stored record rather than popping — the admin
      // asked to see the fingerprint once it is allocated.
      setState(() {
        _candidates = [];
        _selected = null;
        _warning = null;
      });
      await _loadExisting(id);
    } catch (e) {
      setState(() => _error = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool?> _confirmOverwrite(String id) {
    final current = _existing!.wifiFingerprint.first;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text('Replace $id fingerprint?', style: AppTheme.headlineMedium),
        content: Text(
          '$id is currently registered to ${current.ssid ?? '(hidden)'} '
          '(${current.bssid}). Replacing it means attendance in this room only '
          'works from the new access point.',
          style: AppTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorRed),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Classroom Wi-Fi Setup'),
      ),
      extendBodyBehindAppBar: true,
      body: ParticleBackground(
        particleCount: 20,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.spacingLg),
            children: [
              TextField(
                controller: _classroomCtrl,
                style: AppTheme.bodyLarge,
                textCapitalization: TextCapitalization.characters,
                onChanged: _onClassroomChanged,
                decoration: const InputDecoration(
                  labelText: 'Classroom ID',
                  hintText: 'C302',
                  prefixIcon: Icon(Icons.meeting_room_outlined, color: AppTheme.accentCyan),
                ),
              ),
              const SizedBox(height: AppTheme.spacingLg),
              _registeredCard(),
              const SizedBox(height: AppTheme.spacingLg),
              GlassmorphicCard(
                margin: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Stand inside the classroom, then capture.',
                        style: AppTheme.bodyMedium),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _scanning ? null : _capture,
                        icon: _scanning
                            ? const SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.wifi_find),
                        label: Text(_scanning
                            ? 'Scanning (several passes)…'
                            : 'Capture fingerprint'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentCyan,
                          foregroundColor: AppTheme.backgroundDark,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppTheme.spacingMd),
                Text(_error!, style: AppTheme.bodySmall.copyWith(color: AppTheme.errorRed)),
              ],
              if (_warning != null) ...[
                const SizedBox(height: AppTheme.spacingMd),
                Text(_warning!,
                    style: AppTheme.bodySmall.copyWith(color: AppTheme.warningAmber)),
              ],
              if (_candidates.isNotEmpty) ...[
                const SizedBox(height: AppTheme.spacingLg),
                Text('Choose this room\'s access point', style: AppTheme.headlineMedium),
                const SizedBox(height: 4),
                Text(
                  '${_candidates.length} visible · strongest first. Exactly one '
                  'is registered per classroom.',
                  style: AppTheme.labelSmall,
                ),
                const SizedBox(height: AppTheme.spacingSm),
                ..._candidates.map(_candidateTile),
                const SizedBox(height: AppTheme.spacingLg),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving || _selected == null ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'Saving…' : 'Register selected AP'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The fingerprint currently registered for the classroom in the id field.
  Widget _registeredCard() {
    final id = _classroomCtrl.text.trim().toUpperCase();
    if (id.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_loadingExisting) {
      return GlassmorphicCard(
        margin: EdgeInsets.zero,
        child: Row(
          children: [
            const SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Text('Checking $id…', style: AppTheme.bodyMedium),
          ],
        ),
      );
    }

    final room = _existing;
    if (room == null || !room.isFingerprinted) {
      return GlassmorphicCard(
        margin: EdgeInsets.zero,
        child: Row(
          children: [
            const Icon(Icons.wifi_off_outlined, size: 18, color: AppTheme.warningAmber),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                room == null
                    ? '$id is not registered yet. Capturing here will create it.'
                    : '$id has no access point registered. Attendance there is '
                        'refused with classroom_not_configured until one is set.',
                style: AppTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    final ap = room.wifiFingerprint.first;
    final extra = room.wifiFingerprint.length - 1;
    return GlassmorphicCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, size: 18, color: AppTheme.successGreen),
              const SizedBox(width: 10),
              Text('Registered access point', style: AppTheme.headlineMedium.copyWith(fontSize: 15)),
            ],
          ),
          const SizedBox(height: 10),
          Text(ap.ssid?.isNotEmpty == true ? ap.ssid! : '(hidden network)',
              style: AppTheme.bodyLarge),
          Text(ap.bssid, style: AppTheme.labelSmall),
          const SizedBox(height: 6),
          Text(
            [
              if (ap.typicalRssi != null) '${ap.typicalRssi} dBm',
              'needs ${room.minBssidMatches} match',
              if (room.updatedAt != null) 'set ${_formatDate(room.updatedAt!)}',
            ].join(' · '),
            style: AppTheme.labelSmall,
          ),
          if (extra > 0) ...[
            const SizedBox(height: 10),
            Text(
              'This room still stores $extra extra access point${extra == 1 ? '' : 's'} '
              'from an older capture. A wide fingerprint lets students match from '
              'outside the room — re-capture to replace it with a single AP.',
              style: AppTheme.bodySmall.copyWith(color: AppTheme.warningAmber),
            ),
          ],
        ],
      ),
    );
  }

  Widget _candidateTile(WifiAccessPointInfo ap) {
    final selected = _selected?.bssid == ap.bssid;
    return GestureDetector(
      onTap: () => setState(() {
        _selected = ap;
        _warning = _looksLikeHotspot(ap.ssid)
            ? '"${ap.ssid}" looks like a personal hotspot — it moves with its '
                'owner. Prefer a wall-mounted campus AP.'
            : null;
      }),
      child: GlassmorphicCard(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? AppTheme.accentCyan : AppTheme.textHint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ap.ssid.isEmpty ? '(hidden)' : ap.ssid, style: AppTheme.bodyMedium),
                  Text(ap.bssid, style: AppTheme.labelSmall),
                ],
              ),
            ),
            Text('${ap.rssi} dBm', style: AppTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) {
    final l = d.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

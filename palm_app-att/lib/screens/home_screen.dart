import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../config/app_theme.dart';
import '../models/student_profile.dart';
import '../providers/providers.dart';
import '../services/hand_detector.dart';
import '../services/parity_test.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/particle_background.dart';

/// Student home. Shows enrollment status (one palm per student) and the entry
/// point to mark attendance. Advisors/admins are routed to their own home from
/// the splash screen, so this screen is student-facing.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _delete(BuildContext context, WidgetRef ref, StudentProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text('Delete Biometric Data?', style: AppTheme.headlineMedium),
        content: Text(
          'This permanently deletes your palm template from this device and the '
          'servers. You will need to re-enroll to mark attendance.\n\n'
          'You stay on your section roster, so you can re-enroll at any time '
          'without asking your advisor to add you again.',
          style: AppTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: Colors.white.withOpacity(0.6))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorRed),
            child: const Text('Delete Data'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final svc = await ref.read(studentServiceProvider.future);
      await svc.deleteProfile(profile.studentId);
      ref.invalidate(studentProfileProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Deleted from device — syncing to cloud…')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final studentId = ref.watch(studentIdProvider) ?? 'Student';
    final profileAsync = ref.watch(studentProfileProvider);
    final parityAsync = ref.watch(parityResultProvider);

    return Scaffold(
      body: ParticleBackground(
        particleCount: 30,
        child: SafeArea(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(studentProfileProvider),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppTheme.spacingMd),
              children: [
                // Header
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Welcome,', style: AppTheme.bodyMedium),
                          Text(studentId, style: AppTheme.displayMedium),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () async {
                        await ref.read(authServiceProvider).signOut();
                        if (context.mounted) {
                          Navigator.of(context).pushReplacementNamed('/signin');
                        }
                      },
                      icon: const Icon(Icons.logout, color: AppTheme.textSecondary),
                      tooltip: 'Sign Out',
                    ),
                  ],
                ).animate().fadeIn(duration: 400.ms),

                const SizedBox(height: AppTheme.spacingLg),

                // Parity self-test warning
                parityAsync.maybeWhen(
                  data: (res) => res.status == ParityStatus.failed
                      ? _warningBanner(
                          'Model Parity Validation Failed: ${res.message}')
                      : const SizedBox.shrink(),
                  orElse: () => const SizedBox.shrink(),
                ),

                profileAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator(color: AppTheme.accentCyan)),
                  ),
                  error: (e, _) => _warningBanner('Could not load your profile: $e'),
                  data: (profile) {
                    // A template from a superseded model can't be matched, so
                    // surface it as needing re-enrollment here rather than
                    // letting it look enrolled right up until it fails.
                    final modelVersion =
                        ref.watch(deployConfigProvider).value?.modelVersion;
                    final usable = profile != null &&
                        (modelVersion == null
                            ? profile.isEnrolled
                            : profile.isUsableWith(modelVersion));
                    return usable
                        ? _enrolled(context, ref, profile)
                        : _notEnrolled(context, profile);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _notEnrolled(BuildContext context, StudentProfile? profile) {
    final section = profile?.section;
    // Enrolled, but under a superseded model — a materially different state
    // from "never enrolled", and the copy should say so.
    final stale = profile?.isEnrolled ?? false;
    return Column(
      children: [
        const SizedBox(height: AppTheme.spacingLg),
        Icon(stale ? Icons.update : Icons.fingerprint_rounded,
            size: 72, color: Colors.white.withOpacity(0.2)),
        const SizedBox(height: AppTheme.spacingMd),
        Text(stale ? 'Re-enrollment needed' : 'No palm enrolled yet',
            style: AppTheme.headlineLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          stale
              ? 'The palm recognition model was updated. Your earlier scan '
                  'can no longer be matched, so please enroll again.'
              : section != null
                  ? "You're on the roster for section $section. Enroll your palm to mark attendance."
                  : 'Enroll your palm once to enable attendance marking.',
          style: AppTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppTheme.spacingLg),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => Navigator.of(context).pushNamed('/consent'),
            icon: Icon(stale ? Icons.refresh : Icons.add_circle_outline),
            label: Text(stale ? 'Re-enroll Now' : 'Enroll Now'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentCyan,
              foregroundColor: AppTheme.backgroundDark,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ],
    ).animate().fadeIn(delay: 200.ms);
  }

  Widget _enrolled(BuildContext context, WidgetRef ref, StudentProfile profile) {
    final isLeft = profile.handSide == HandSide.left;
    final dateStr = DateFormat('MMM d, yyyy · h:mm a').format(profile.updatedAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Big "Mark Attendance" CTA — the daily action.
        AccentGlassCard(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.how_to_reg_rounded, color: AppTheme.accentCyan),
                  const SizedBox(width: 8),
                  Text('Mark Attendance',
                      style: AppTheme.headlineMedium.copyWith(fontSize: 18)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Scan your palm in class to mark yourself present.',
                style: AppTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed('/attendance'),
                icon: const Icon(Icons.front_hand_outlined),
                label: const Text('Start Attendance'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentCyan,
                  foregroundColor: AppTheme.backgroundDark,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: 150.ms).slideY(begin: 0.1),

        const SizedBox(height: AppTheme.spacingLg),

        Text('Your Enrollment', style: AppTheme.headlineLarge),
        const SizedBox(height: AppTheme.spacingSm),

        GlassmorphicCard(
          margin: EdgeInsets.zero,
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isLeft
                        ? [AppTheme.accentCyan.withOpacity(0.2), AppTheme.accentTeal.withOpacity(0.1)]
                        : [AppTheme.accentPurple.withOpacity(0.2), AppTheme.accentPink.withOpacity(0.1)],
                  ),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Transform(
                  alignment: Alignment.center,
                  transform: isLeft ? Matrix4.identity() : (Matrix4.identity()..scale(-1.0, 1.0)),
                  child: Icon(Icons.back_hand_rounded,
                      color: isLeft ? AppTheme.accentCyan : AppTheme.accentPurple, size: 28),
                ),
              ),
              const SizedBox(width: AppTheme.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${isLeft ? 'Left' : 'Right'} Palm enrolled',
                        style: AppTheme.headlineMedium.copyWith(fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('Updated $dateStr', style: AppTheme.bodySmall),
                    if (profile.assignedClassroom != null) ...[
                      const SizedBox(height: 4),
                      Text('Classroom: ${profile.assignedClassroom}',
                          style: AppTheme.bodySmall),
                    ],
                    const SizedBox(height: 6),
                    _syncBadge(profile.synced),
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(delay: 250.ms),

        const SizedBox(height: AppTheme.spacingMd),

        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pushNamed('/consent'),
                icon: const Icon(Icons.refresh),
                label: const Text('Re-enroll'),
              ),
            ),
            const SizedBox(width: AppTheme.spacingMd),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _delete(context, ref, profile),
                icon: const Icon(Icons.delete_outline, color: AppTheme.errorRed),
                label: const Text('Delete', style: TextStyle(color: AppTheme.errorRed)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppTheme.errorRed.withOpacity(0.5)),
                ),
              ),
            ),
          ],
        ).animate().fadeIn(delay: 350.ms),
      ],
    );
  }

  Widget _syncBadge(bool synced) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: (synced ? AppTheme.successGreen : AppTheme.warningAmber).withOpacity(0.15),
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(synced ? Icons.cloud_done : Icons.cloud_upload_outlined,
                size: 12, color: synced ? AppTheme.successGreen : AppTheme.warningAmber),
            const SizedBox(width: 4),
            Text(synced ? 'Synced' : 'Pending',
                style: AppTheme.labelSmall.copyWith(
                    color: synced ? AppTheme.successGreen : AppTheme.warningAmber)),
          ],
        ),
      );

  Widget _warningBanner(String msg) => Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: AppTheme.spacingMd),
        decoration: BoxDecoration(
          color: AppTheme.errorRed.withOpacity(0.1),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppTheme.errorRed.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppTheme.errorRed),
            const SizedBox(width: 12),
            Expanded(
              child: Text(msg, style: AppTheme.bodySmall.copyWith(color: AppTheme.errorRed)),
            ),
          ],
        ),
      );
}

// Basic smoke test for PalmPay Enrollment app.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:palmpay_enroll/main.dart';

void main() {
  testWidgets('PalmPay app smoke test — splash screen renders',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: PalmPayApp()),
    );

    // The splash screen should render without crashing.
    expect(find.byType(PalmPayApp), findsOneWidget);

    // The splash screen runs looping animations (flutter_animate), which keep
    // scheduling fake timers forever. Pump a few frames, then unmount the app
    // so every animation disposes and no timers are pending at teardown.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}

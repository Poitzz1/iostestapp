import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/app_theme.dart';
import 'firebase_options.dart';
import 'screens/advisor_home_screen.dart';
import 'screens/assign_student_screen.dart';
import 'screens/attendance_screen.dart';
import 'screens/capture_screen.dart';
import 'screens/consent_screen.dart';
import 'screens/enrollment_success_screen.dart';
import 'screens/hand_select_screen.dart';
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/verify_email_screen.dart';
import 'screens/wifi_fingerprint_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase initialization warning: $e. Make sure firebase_options.dart is configured.');
  }

  runApp(
    const ProviderScope(
      child: PalmPayApp(),
    ),
  );
}

class PalmPayApp extends StatelessWidget {
  const PalmPayApp({super.key});

  static final Map<String, WidgetBuilder> _routes = {
    '/': (_) => const SplashScreen(),
    '/signin': (_) => const SignInScreen(),
    '/verify-email': (_) => const VerifyEmailScreen(),
    '/home': (_) => const HomeScreen(),
    '/consent': (_) => const ConsentScreen(),
    '/hand-select': (_) => const HandSelectScreen(),
    '/capture': (_) => const CaptureScreen(),
    '/success': (_) => const EnrollmentSuccessScreen(),
    '/attendance': (_) => const AttendanceScreen(),
    '/advisor': (_) => const AdvisorHomeScreen(),
    '/assign-students': (_) => const AssignStudentScreen(),
    '/wifi-fingerprint': (_) => const WifiFingerprintScreen(),
  };

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PalmPay Attendance',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      initialRoute: '/',
      routes: _routes,
      // An unknown route name lands somewhere real rather than on a blank
      // "route not found" error page.
      onUnknownRoute: (settings) => MaterialPageRoute(
        builder: (_) => const SplashScreen(),
        settings: settings,
      ),
    );
  }
}

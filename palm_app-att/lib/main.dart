import 'package:firebase_core/firebase_core.dart';
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PalmPay Attendance',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      initialRoute: '/',
      routes: {
        '/': (context) => const SplashScreen(),
        '/signin': (context) => const SignInScreen(),
        '/verify-email': (context) => const VerifyEmailScreen(),
        '/consent': (context) => const ConsentScreen(),
        '/hand-select': (context) => const HandSelectScreen(),
        '/capture': (context) => const CaptureScreen(),
        '/success': (context) => const EnrollmentSuccessScreen(),
        '/home': (context) => const HomeScreen(),
        '/attendance': (context) => const AttendanceScreen(),
        '/advisor': (context) => const AdvisorHomeScreen(),
        '/assign-students': (context) => const AssignStudentScreen(),
        '/wifi-fingerprint': (context) => const WifiFingerprintScreen(),
      },
    );
  }
}

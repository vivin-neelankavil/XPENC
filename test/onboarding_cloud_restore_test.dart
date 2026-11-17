import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xpenc/core/theme/app_theme.dart';
import 'package:xpenc/data/database.dart';
import 'package:xpenc/data/providers.dart';
import 'package:xpenc/features/data_export/cloud_sync_service.dart';
import 'package:xpenc/features/onboarding/cloud_restore_sheet.dart';
import 'package:xpenc/features/onboarding/onboarding_screen.dart';

void main() {
  group('Onboarding cloud restore', () {
    late AppDatabase db;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase(NativeDatabase.memory());
    });
    tearDown(() => db.close());

    Future<void> pumpOnboarding(WidgetTester tester) async {
      final prefs = await SharedPreferences.getInstance();
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const OnboardingScreen()),
          GoRoute(
            path: '/dashboard',
            builder: (_, _) => const Scaffold(body: Text('dashboard')),
          ),
        ],
      );
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dbProvider.overrideWithValue(db),
            sharedPrefsProvider.overrideWithValue(prefs),
            cloudSyncServiceProvider.overrideWithValue(CloudSyncService(db, prefs)),
          ],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Restore step presents Restore from cloud and Restore from this device', (tester) async {
      await pumpOnboarding(tester);

      // Welcome -> Next -> Path choice
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Are you new to XPENC?'), findsOneWidget);

      // Choose "I already know XPENC"
      await tester.tap(find.text('I already know XPENC'));
      await tester.pumpAndSettle();

      expect(find.text('Restore your data?'), findsOneWidget);
      expect(find.text('Restore from cloud'), findsOneWidget);
      expect(find.text('Restore from this device'), findsOneWidget);

      // Scroll to ensure button is visible before tapping
      await tester.ensureVisible(find.text('Restore from cloud'));
      await tester.pumpAndSettle();

      // Tap "Restore from cloud"
      await tester.tap(find.text('Restore from cloud'));
      await tester.pumpAndSettle();

      // CloudRestoreSheet opens
      expect(find.byType(CloudRestoreSheet), findsOneWidget);
      expect(find.text('Google Drive'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);

      // Tap GitHub option
      await tester.tap(find.text('GitHub'));
      await tester.pumpAndSettle();

      expect(find.text('Restore from GitHub'), findsWidgets);
      expect(find.text('GitHub Repository'), findsOneWidget);
      expect(find.text('Fine-Grained Personal Access Token'), findsOneWidget);
    });
  });
}

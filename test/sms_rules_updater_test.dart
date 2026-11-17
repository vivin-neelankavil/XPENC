import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xpenc/data/database.dart';
import 'package:xpenc/features/message_capture/parser/sms_rules.dart';
import 'package:xpenc/features/message_capture/parser/sms_rules_updater.dart';

void main() {
  group('SmsRulesUpdater', () {
    late AppDatabase db;
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      db = AppDatabase(NativeDatabase.memory());
      SmsRulesConfig.debugUse(SmsRulesConfig.defaultConfig);
    });

    tearDown(() => db.close());

    test('checkForUpdates downloads, caches, and hot-updates rules', () async {
      final mockJson = jsonEncode({
        'version': 2,
        'bankSenderRules': [
          {'pattern': 'IPPB', 'bank': 'India Post Payments Bank'},
          {'pattern': 'NEWBNK', 'bank': 'New Community Bank'},
        ],
        'parsingRules': {
          'otpPattern': r'\b(otp)\b',
          'declinedPattern': r'\b(declined)\b',
          'promotionalPattern': r'\b(offer)\b',
          'debitPattern': r'\b(debited)\b',
          'creditPattern': r'\b(credited)\b',
          'amountPattern': r'Rs\.([0-9]+)',
          'accountHintPattern': r'XX(\d{4})',
          'availableBalancePattern': r'Bal Rs\.([0-9]+)',
          'referencePattern': r'Ref ([A-Za-z0-9]+)',
          'merchantPatterns': [r'to ([A-Za-z]+)'],
        },
      });

      final mockClient = MockClient((request) async {
        return http.Response(mockJson, 200);
      });

      final updater = SmsRulesUpdater(db, prefs);
      expect(updater.currentVersion, 1);
      expect(updater.hasCustomUpdate, isFalse);

      final result = await updater.checkForUpdates(client: mockClient);
      expect(result.updated, isTrue);
      expect(result.version, 2);
      expect(updater.currentVersion, 2);
      expect(updater.hasCustomUpdate, isTrue);

      // Verify SQLite sender_rules table has NEWBNK
      final rulesInDb = await db.watchSenderRules().first;
      expect(rulesInDb.any((r) => r.senderPattern == 'NEWBNK'), isTrue);

      // Check second time: should be already up to date
      final secondResult = await updater.checkForUpdates(client: mockClient);
      expect(secondResult.updated, isFalse);
      expect(secondResult.message, contains('already up to date'));

      // Test resetToBundled
      await updater.resetToBundled();
      expect(updater.hasCustomUpdate, isFalse);
      expect(updater.currentVersion, 1);
    });

    test('checkForUpdates handles network failures gracefully', () async {
      final errorClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final updater = SmsRulesUpdater(db, prefs);
      final result = await updater.checkForUpdates(client: errorClient);

      expect(result.updated, isFalse);
      expect(result.isError, isTrue);
      expect(result.message, contains('HTTP 404'));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:xpenc/features/more/settings_search_index.dart';

void main() {
  group('Recursive Settings Search Index', () {
    test('contains Bank-SMS auto-capture with message capture keywords', () {
      final matches = kSearchableSettingsIndex.where((s) => s.matches('message capture')).toList();
      expect(matches, isNotEmpty);
      expect(matches.any((s) => s.route == '/more/capture'), isTrue);

      final smsMatches = kSearchableSettingsIndex.where((s) => s.matches('sms')).toList();
      expect(smsMatches, isNotEmpty);
      expect(smsMatches.any((s) => s.route == '/more/capture'), isTrue);
    });

    test('finds cloud sync settings via search', () {
      final driveMatches = kSearchableSettingsIndex.where((s) => s.matches('drive')).toList();
      expect(driveMatches.any((s) => s.route == '/more/backup'), isTrue);

      final cloudMatches = kSearchableSettingsIndex.where((s) => s.matches('cloud sync')).toList();
      expect(cloudMatches.any((s) => s.route == '/more/backup'), isTrue);
    });

    test('finds security PIN and passcode settings', () {
      final pinMatches = kSearchableSettingsIndex.where((s) => s.matches('pin')).toList();
      expect(pinMatches.any((s) => s.route == '/more/settings/security'), isTrue);
    });

    test('finds currency and language settings', () {
      final curMatches = kSearchableSettingsIndex.where((s) => s.matches('currency')).toList();
      expect(curMatches.any((s) => s.route == '/more/settings/currency'), isTrue);

      final langMatches = kSearchableSettingsIndex.where((s) => s.matches('language')).toList();
      expect(langMatches.any((s) => s.route == '/more/settings/language'), isTrue);
    });
  });
}

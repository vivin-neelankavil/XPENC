import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xpenc/core/money.dart';
import 'package:xpenc/data/tables.dart';
import 'package:xpenc/features/message_capture/parser/bank_message.dart';
import 'package:xpenc/features/message_capture/parser/message_parser.dart';
import 'package:xpenc/features/message_capture/parser/sms_rules.dart';

void main() {
  group('SMS Rules from JSON', () {
    late String jsonContent;

    setUp(() {
      final file = File('assets/message_capture/sms_rules.json');
      expect(file.existsSync(), isTrue, reason: 'assets/message_capture/sms_rules.json must exist');
      jsonContent = file.readAsStringSync();
    });

    test('JSON parses successfully and contains bankSenderRules and parsingRules', () {
      final Map<String, dynamic> decoded = jsonDecode(jsonContent);
      expect(decoded.containsKey('bankSenderRules'), isTrue);
      expect(decoded.containsKey('parsingRules'), isTrue);

      final config = SmsRulesConfig.fromJson(decoded);
      expect(config.bankSenderRules.isNotEmpty, isTrue);

      // Verify known banks exist
      final banks = config.bankSenderRules.map((b) => b.pattern).toSet();
      expect(banks.contains('HDFCBK'), isTrue);
      expect(banks.contains('SBIINB'), isTrue);
      expect(banks.contains('ICICIB'), isTrue);
      expect(banks.contains('IPPB'), isTrue);
    });

    test('MessageParser functions accurately when initialized with rules parsed from JSON', () {
      final Map<String, dynamic> decoded = jsonDecode(jsonContent);
      final config = SmsRulesConfig.fromJson(decoded);
      final parser = MessageParser(config.parsingRules);

      // UPI debit
      final debitResult = parser.parse(
        RawMessage(
          body: 'Rs.750.00 debited from A/c XX4321 on 15-08-26 to VPA merchant@okhdfcbank. Avl Bal Rs.25,000.00',
          sender: 'VM-HDFCBK',
          receivedAt: DateTime(2026, 8, 15),
        ),
      );

      expect(debitResult, isA<ParsedMessage>());
      final debit = debitResult as ParsedMessage;
      expect(debit.amount, Money.fromRupees(750));
      expect(debit.direction, TxDirection.debit);
      expect(debit.accountHint, '4321');
      expect(debit.merchant, 'merchant@okhdfcbank');
      expect(debit.availableBalance, Money.fromRupees(25000));

      // Credit
      final creditResult = parser.parse(
        RawMessage(
          body: 'INR 15,000.00 credited to A/c XX9999 on 01-09-26. Avl Bal INR 40,000.00',
          sender: 'SBIINB',
          receivedAt: DateTime(2026, 9, 1),
        ),
      );

      expect(creditResult, isA<ParsedMessage>());
      final credit = creditResult as ParsedMessage;
      expect(credit.amount, Money.fromRupees(15000));
      expect(credit.direction, TxDirection.credit);
      expect(credit.accountHint, '9999');

      // OTP reject
      final otpResult = parser.parse(
        RawMessage(
          body: 'Your OTP is 123456. Do not share with anyone.',
          sender: 'VM-HDFCBK',
          receivedAt: DateTime.now(),
        ),
      );
      expect(otpResult, isA<Rejected>());
      expect((otpResult as Rejected).reason, RejectReason.otp);
    });
  });
}

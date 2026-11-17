import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bank short-code to bank name mapping rule.
class BankSenderRule {
  const BankSenderRule({
    required this.pattern,
    required this.bank,
  });

  final String pattern;
  final String bank;

  factory BankSenderRule.fromJson(Map<String, dynamic> json) {
    return BankSenderRule(
      pattern: json['pattern'] as String? ?? '',
      bank: json['bank'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    'bank': bank,
  };
}

/// Regular expression rules used by [MessageParser] to extract financial details.
class SmsParsingRules {
  SmsParsingRules({
    required this.otpPattern,
    required this.declinedPattern,
    required this.promotionalPattern,
    required this.debitPattern,
    required this.creditPattern,
    required this.amountPattern,
    required this.accountHintPattern,
    required this.availableBalancePattern,
    required this.referencePattern,
    required this.merchantPatterns,
  })  : otp = RegExp(otpPattern, caseSensitive: false),
        declined = RegExp(declinedPattern, caseSensitive: false),
        promotional = RegExp(promotionalPattern, caseSensitive: false),
        debit = RegExp(debitPattern, caseSensitive: false),
        credit = RegExp(creditPattern, caseSensitive: false),
        amount = RegExp(amountPattern, caseSensitive: false),
        accountHint = RegExp(accountHintPattern, caseSensitive: false),
        availableBalance = RegExp(availableBalancePattern, caseSensitive: false),
        reference = RegExp(referencePattern, caseSensitive: false),
        merchants = merchantPatterns
            .map((p) => p.contains('(?:to|at)')
                ? RegExp(p)
                : RegExp(p, caseSensitive: false))
            .toList();

  final String otpPattern;
  final String declinedPattern;
  final String promotionalPattern;
  final String debitPattern;
  final String creditPattern;
  final String amountPattern;
  final String accountHintPattern;
  final String availableBalancePattern;
  final String referencePattern;
  final List<String> merchantPatterns;

  final RegExp otp;
  final RegExp declined;
  final RegExp promotional;
  final RegExp debit;
  final RegExp credit;
  final RegExp amount;
  final RegExp accountHint;
  final RegExp availableBalance;
  final RegExp reference;
  final List<RegExp> merchants;

  factory SmsParsingRules.fromJson(Map<String, dynamic> json) {
    return SmsParsingRules(
      otpPattern: json['otpPattern'] as String? ?? '',
      declinedPattern: json['declinedPattern'] as String? ?? '',
      promotionalPattern: json['promotionalPattern'] as String? ?? '',
      debitPattern: json['debitPattern'] as String? ?? '',
      creditPattern: json['creditPattern'] as String? ?? '',
      amountPattern: json['amountPattern'] as String? ?? '',
      accountHintPattern: json['accountHintPattern'] as String? ?? '',
      availableBalancePattern: json['availableBalancePattern'] as String? ?? '',
      referencePattern: json['referencePattern'] as String? ?? '',
      merchantPatterns: (json['merchantPatterns'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

/// Container for all SMS rules loaded from `assets/message_capture/sms_rules.json`
/// or updated from GitHub.
class SmsRulesConfig {
  const SmsRulesConfig({
    required this.version,
    required this.bankSenderRules,
    required this.parsingRules,
  });

  final int version;
  final List<BankSenderRule> bankSenderRules;
  final SmsParsingRules parsingRules;

  static const String assetPath = 'assets/message_capture/sms_rules.json';
  static const String keyCachedJson = 'cached_sms_rules_json';

  static SmsRulesConfig? _active;

  /// The active configuration. Defaults to [defaultConfig] if not yet loaded.
  static SmsRulesConfig get active => _active ??= defaultConfig;

  /// Sets the active configuration.
  static void setActive(SmsRulesConfig config) {
    _active = config;
  }

  /// Loads configuration. Checks cached update in [prefs] first, then falls back to [path],
  /// and finally to [defaultConfig].
  static Future<void> load({
    SharedPreferences? prefs,
    String path = assetPath,
  }) async {
    // 1. Check cached updates from GitHub
    final cached = prefs?.getString(keyCachedJson);
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        _active = SmsRulesConfig.fromJson(json);
        return;
      } catch (e) {
        debugPrint('SmsRulesConfig: cached JSON corrupted ($e), falling back to asset');
      }
    }

    // 2. Load from bundled asset
    try {
      final raw = await rootBundle.loadString(path);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _active = SmsRulesConfig.fromJson(json);
    } catch (e) {
      debugPrint('SmsRulesConfig: could not load from $path ($e), using bundled defaults');
      _active = defaultConfig;
    }
  }

  /// Sets configuration directly for testing.
  @visibleForTesting
  static void debugUse(SmsRulesConfig config) {
    _active = config;
  }

  factory SmsRulesConfig.fromJson(Map<String, dynamic> json) {
    final v = json['version'] as int? ?? 1;
    final bankList = (json['bankSenderRules'] as List<dynamic>? ?? [])
        .map((e) => BankSenderRule.fromJson(e as Map<String, dynamic>))
        .toList();
    final parsing = SmsParsingRules.fromJson(
      json['parsingRules'] as Map<String, dynamic>? ?? {},
    );
    return SmsRulesConfig(
      version: v,
      bankSenderRules: bankList,
      parsingRules: parsing,
    );
  }

  /// Bundled fallback configuration matching the initial rules.
  static final SmsRulesConfig defaultConfig = SmsRulesConfig(
    version: 1,
    bankSenderRules: const [
      BankSenderRule(pattern: 'IPPB', bank: 'India Post Payments Bank'),
      BankSenderRule(pattern: 'IPPBNK', bank: 'India Post Payments Bank'),
      BankSenderRule(pattern: 'YESBNK', bank: 'Yes Bank'),
      BankSenderRule(pattern: 'HDFCBK', bank: 'HDFC Bank'),
      BankSenderRule(pattern: 'ICICIB', bank: 'ICICI Bank'),
      BankSenderRule(pattern: 'SBIINB', bank: 'State Bank of India'),
      BankSenderRule(pattern: 'SBIUPI', bank: 'State Bank of India'),
      BankSenderRule(pattern: 'AXISBK', bank: 'Axis Bank'),
      BankSenderRule(pattern: 'KOTAKB', bank: 'Kotak Mahindra Bank'),
      BankSenderRule(pattern: 'PNBSMS', bank: 'Punjab National Bank'),
    ],
    parsingRules: SmsParsingRules(
      otpPattern: r'\b(otp|one[\s-]?time[\s-]?password|verification code|do not share)\b',
      declinedPattern: r'\b(declined|failed|unsuccessful|not processed|could not be|rejected|reversal failed)\b',
      promotionalPattern: r'\b(offer|cashback offer|sale|win |congratulations|click here|apply now|lowest price|discount|loan offer|pre-?approved|t&c apply|unsubscribe)\b',
      debitPattern: r'\b(debited|debit|spent|withdrawn|withdrawal|paid|purchase|deducted|transferred to|sent to|dr\b)',
      creditPattern: r'\b(credited|credit|received|deposited|refund(ed)?|reversed|added to|cr\b)',
      amountPattern: r'(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      accountHintPattern: r'(?:a/?c(?:count)?(?:\s*no\.?)?|card(?:\s*(?:no\.?|ending|xx))?)[\s:.]*[xX*\d]*?(\d{4})\b',
      availableBalancePattern: r'(?:avl\.?\s*bal|available\s*balance|a/?c\s*bal|bal(?:ance)?)[\s:.a-z]*?(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)',
      referencePattern: r'(?:ref(?:erence)?(?:\s*(?:no|id|num))?|txn(?:\s*id)?|utr)[\s.:#no]*([A-Za-z0-9]{6,20})',
      merchantPatterns: const [
        r'\bVPA\s+([a-zA-Z0-9._-]+@[a-zA-Z]+)',
        r'\btrf\s+to\s+([A-Za-z0-9 &._-]{3,40})',
        r'\b(?:to|at)\s+([A-Z][A-Za-z0-9 &._-]{2,40}?)\s+on\b',
        r'\bat\s+([A-Za-z0-9 &._-]{3,40}?)(?:\s+on|\.|,|$)',
        r'\bto\s+([A-Za-z0-9 &._-]{3,40}?)(?:\s+on|\.|,|$)',
        r'\binfo[:\s]+([A-Za-z0-9 &._*-]{3,40})',
      ],
    ),
  );
}

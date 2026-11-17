import '../../../core/money.dart';
import '../../../data/tables.dart';
import 'bank_message.dart';
import 'sms_rules.dart';

export 'sms_rules.dart' show SmsRulesConfig, BankSenderRule, SmsParsingRules;

/// Parses Indian bank SMS/notifications on-device. Nothing leaves the phone.
///
/// Rules and patterns are loaded from the open-source configuration file
/// `assets/message_capture/sms_rules.json`.
///
/// Deliberately conservative: when in doubt it returns a low confidence (so the
/// card waits in the inbox) or rejects outright. A false *reject* costs one
/// manual entry. A false *accept* silently corrupts the ledger.
class MessageParser {
  const MessageParser([this._customRules]);

  final SmsParsingRules? _customRules;
  SmsParsingRules get _rules =>
      _customRules ?? SmsRulesConfig.active.parsingRules;

  // ── Entry point ──────────────────────────────────────────────────────────

  ParseResult parse(RawMessage msg) {
    final body = msg.body;

    if (_rules.otp.hasMatch(body)) return const Rejected(RejectReason.otp);
    if (_rules.declined.hasMatch(body)) {
      return const Rejected(RejectReason.declined);
    }

    final amount = _extractAmount(body);
    if (amount == null) {
      // The only figure present was a balance ("Your A/c bal is Rs.5,000") —
      // `_extractAmount` deliberately skips it, so say so precisely.
      if (_rules.availableBalance.hasMatch(body)) {
        return const Rejected(RejectReason.balanceOnly);
      }
      // No amount at all → promotional chatter, not a transaction.
      return _rules.promotional.hasMatch(body)
          ? const Rejected(RejectReason.promotional)
          : const Rejected(RejectReason.noAmount);
    }

    final direction = _extractDirection(body);
    if (direction == null) {
      // Has an amount but no debit/credit verb: almost always a balance
      // enquiry ("Your A/c bal is Rs.500") or an advert.
      if (_rules.availableBalance.hasMatch(body)) {
        return const Rejected(RejectReason.balanceOnly);
      }
      return _rules.promotional.hasMatch(body)
          ? const Rejected(RejectReason.promotional)
          : const Rejected(RejectReason.noDirection);
    }

    // A promo can still quote an amount ("spend Rs.500, get cashback").
    // Only reject when it has no account hint — a real txn always names one.
    final hint = _accountHintOf(body);
    if (_rules.promotional.hasMatch(body) && hint == null) {
      return const Rejected(RejectReason.promotional);
    }

    final merchant = _extractMerchant(body);
    final reference = _match(_rules.reference, body);
    final balance = _extractBalance(body);

    return ParsedMessage(
      amount: amount,
      direction: direction,
      accountHint: hint,
      merchant: merchant,
      reference: reference,
      availableBalance: balance,
      confidence: _score(
        hasHint: hint != null,
        hasMerchant: merchant != null,
        hasRef: reference != null,
        hasBalance: balance != null,
        senderLooksLikeBank: looksLikeBankSender(msg.sender),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Bank sender IDs look like `AD-IPPBNK`, `VM-HDFCBK`, `JD-SBIINB` —
  /// two letters, a dash, then an alphabetic short code. Never a phone number.
  static bool looksLikeBankSender(String sender) {
    final s = sender.trim().toUpperCase();
    if (RegExp(r'^\+?\d{6,}$').hasMatch(s)) return false; // a person
    return RegExp(r'^[A-Z]{2}-[A-Z0-9]{4,10}$').hasMatch(s) ||
        RegExp(r'^[A-Z]{4,12}$').hasMatch(s);
  }

  Money? _extractAmount(String body) {
    // Prefer the amount *not* attached to a balance phrase.
    final balanceMatch = _rules.availableBalance.firstMatch(body);
    for (final m in _rules.amount.allMatches(body)) {
      if (balanceMatch != null &&
          m.start >= balanceMatch.start &&
          m.end <= balanceMatch.end) {
        continue; // that's the balance, not the txn amount
      }
      final parsed = Money.tryParse(m.group(1)!);
      if (parsed != null && parsed.isPositive) return parsed;
    }
    return null;
  }

  Money? _extractBalance(String body) {
    final m = _rules.availableBalance.firstMatch(body);
    if (m == null) return null;
    return Money.tryParse(m.group(1)!);
  }

  /// Whichever verb appears first wins. "Rs.100 debited ... Avl Bal credited"
  /// style messages are debits.
  TxDirection? _extractDirection(String body) {
    final d = _rules.debit.firstMatch(body)?.start;
    final c = _rules.credit.firstMatch(body)?.start;
    if (d == null && c == null) return null;
    if (d == null) return TxDirection.credit;
    if (c == null) return TxDirection.debit;
    return d < c ? TxDirection.debit : TxDirection.credit;
  }

  String? _accountHintOf(String body) => _match(_rules.accountHint, body);

  String? _extractMerchant(String body) {
    for (final p in _rules.merchants) {
      final m = p.firstMatch(body);
      final raw = m?.group(1)?.trim();
      if (raw == null || raw.isEmpty) continue;
      final cleaned = raw.replaceAll(RegExp(r'[.,;]+$'), '').trim();
      // Reject things that are obviously not a name.
      if (cleaned.length < 3) continue;
      if (RegExp(r'^\d+$').hasMatch(cleaned)) continue;
      if (RegExp(r'^(your|the|a/?c|account)$', caseSensitive: false)
          .hasMatch(cleaned)) {
        continue;
      }
      return cleaned;
    }
    return null;
  }

  static String? _match(RegExp re, String body) {
    final m = re.firstMatch(body);
    final g = m?.group(1)?.trim();
    return (g == null || g.isEmpty) ? null : g;
  }

  /// Confidence rewards corroborating evidence. Amount + direction alone is
  /// only 40 — never enough to auto-post.
  int _score({
    required bool hasHint,
    required bool hasMerchant,
    required bool hasRef,
    required bool hasBalance,
    required bool senderLooksLikeBank,
  }) {
    var score = 40; // we have an amount and a direction
    if (senderLooksLikeBank) score += 20;
    if (hasHint) score += 20;
    if (hasRef) score += 10;
    if (hasBalance) score += 5;
    if (hasMerchant) score += 5;
    return score.clamp(0, 100);
  }
}

/// Bank templates shipped with the app in `assets/message_capture/sms_rules.json`.
/// Seeded into `sender_rules` on upgrade so users and community can contribute rules.
List<({String pattern, String bank})> get kSeedSenderRules =>
    SmsRulesConfig.active.bankSenderRules
        .map((r) => (pattern: r.pattern, bank: r.bank))
        .toList();

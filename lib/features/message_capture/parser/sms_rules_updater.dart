import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/database.dart';
import '../../../data/providers.dart';
import 'sms_rules.dart';

class SmsRulesUpdateResult {
  const SmsRulesUpdateResult({
    required this.updated,
    required this.message,
    this.version,
    this.newBanksCount = 0,
    this.isError = false,
  });

  final bool updated;
  final String message;
  final int? version;
  final int newBanksCount;
  final bool isError;
}

final smsRulesUpdaterProvider = Provider<SmsRulesUpdater>((ref) {
  final db = ref.watch(dbProvider);
  final prefs = ref.watch(sharedPrefsProvider);
  return SmsRulesUpdater(db, prefs);
});

/// Service that checks GitHub for the latest open-source `sms_rules.json` definitions,
/// downloads them, persists them to local device cache, and hot-updates the active parser.
class SmsRulesUpdater {
  SmsRulesUpdater(this._db, this._prefs);

  final AppDatabase _db;
  final SharedPreferences? _prefs;

  /// Primary community repository URLs for definitions (checks working branch first, then upstream).
  static const List<String> remoteUrls = [
    'https://raw.githubusercontent.com/vivin-neelankavil/XPENC/private/vivin-neelankavil/add_gdrive_sync/assets/message_capture/sms_rules.json',
    'https://raw.githubusercontent.com/PATILYASHH/XPENC/master/assets/message_capture/sms_rules.json',
  ];

  static String get remoteUrl => remoteUrls.first;

  static const String keyLastCheckedAt = 'sms_rules_last_checked_at';
  static const String keyLastUpdatedAt = 'sms_rules_last_updated_at';

  DateTime? get lastCheckedAt {
    final s = _prefs?.getString(keyLastCheckedAt);
    return s != null ? DateTime.tryParse(s) : null;
  }

  DateTime? get lastUpdatedAt {
    final s = _prefs?.getString(keyLastUpdatedAt);
    return s != null ? DateTime.tryParse(s) : null;
  }

  bool get hasCustomUpdate =>
      _prefs?.containsKey(SmsRulesConfig.keyCachedJson) ?? false;

  int get currentVersion => SmsRulesConfig.active.version;

  int get bankCount => SmsRulesConfig.active.bankSenderRules.length;

  /// Fetches the latest definitions from GitHub, validates them, and applies them.
  Future<SmsRulesUpdateResult> checkForUpdates({http.Client? client}) async {
    final httpClient = client ?? http.Client();
    try {
      http.Response? response;
      for (final url in remoteUrls) {
        try {
          final res = await httpClient
              .get(
                Uri.parse(url),
                headers: {'Accept': 'application/json', 'User-Agent': 'XPENC-App'},
              )
              .timeout(const Duration(seconds: 12));
          if (res.statusCode == 200) {
            response = res;
            break;
          }
          response ??= res;
        } catch (_) {
          continue;
        }
      }

      if (response == null || response.statusCode != 200) {
        return SmsRulesUpdateResult(
          updated: false,
          isError: true,
          message: 'Server returned HTTP ${response?.statusCode ?? 404}',
        );
      }

      final Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        return const SmsRulesUpdateResult(
          updated: false,
          isError: true,
          message: 'Received invalid JSON data from GitHub.',
        );
      }

      if (!decoded.containsKey('bankSenderRules') ||
          !decoded.containsKey('parsingRules')) {
        return const SmsRulesUpdateResult(
          updated: false,
          isError: true,
          message: 'Downloaded file is missing expected SMS rule sections.',
        );
      }

      final newConfig = SmsRulesConfig.fromJson(decoded);
      final cachedRaw = _prefs?.getString(SmsRulesConfig.keyCachedJson);

      final now = DateTime.now();
      await _prefs?.setString(keyLastCheckedAt, now.toIso8601String());

      // If identical content already cached
      if (cachedRaw == response.body && newConfig.version <= currentVersion) {
        return SmsRulesUpdateResult(
          updated: false,
          message: 'Definitions are already up to date (v${newConfig.version}).',
          version: newConfig.version,
        );
      }

      // Save to cache
      await _prefs?.setString(SmsRulesConfig.keyCachedJson, response.body);
      await _prefs?.setString(keyLastUpdatedAt, now.toIso8601String());

      // Hot-update the runtime parser configuration
      SmsRulesConfig.setActive(newConfig);

      // Upsert new bank short-codes into SQLite sender_rules table
      var newBanks = 0;
      for (final rule in newConfig.bankSenderRules) {
        final inserted = await _db.into(_db.senderRules).insert(
          SenderRulesCompanion.insert(
            senderPattern: rule.pattern,
            bankName: rule.bank,
          ),
          mode: InsertMode.insertOrIgnore,
        );
        if (inserted > 0) newBanks++;
      }

      return SmsRulesUpdateResult(
        updated: true,
        message: 'Updated definitions to v${newConfig.version}! ($newBanks new banks added)',
        version: newConfig.version,
        newBanksCount: newBanks,
      );
    } catch (e) {
      return SmsRulesUpdateResult(
        updated: false,
        isError: true,
        message: 'Could not connect to GitHub ($e)',
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// Removes custom downloaded updates and resets back to bundled asset definitions.
  Future<void> resetToBundled() async {
    await _prefs?.remove(SmsRulesConfig.keyCachedJson);
    await _prefs?.remove(keyLastUpdatedAt);
    await SmsRulesConfig.load(prefs: _prefs);
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../money.dart';
import '../platform/platform_features.dart';
import '../routing/app_router.dart';

/// One line on the Budgets widget: a category name plus its "spent / limit"
/// already formatted in the user's chosen currency — see
/// [HomeWidgetService.updateBudgetSummary].
typedef WidgetBudgetLine = ({String name, Money spent, Money limit});

/// One line on the Goals & Loans widget: name, kind ('goal' or 'loan'),
/// formatted value string, progress percent (0..100), and optional subtitle.
typedef WidgetGoalLine = ({
  String name,
  String kind,
  String value,
  int percent,
  String? subtitle,
});

/// Bridges the app to the Android home-screen widgets — see
/// `android/app/src/main/kotlin/com/yash/xpenc/` for the native side that
/// renders whatever this saves. Five widgets share this one service:
/// Balance (net worth + shortcuts), Budgets (top budgets by usage), Quick
/// Add (just the shortcuts, enlarged), This Month (income vs expense + cards
/// + net/total savings banner), and Goals & Loans (savings goals + loan balances).
///
/// There is no background refresh: like message capture, this app has no
/// background service, so a widget only updates while the app itself is
/// open (on start, and live thereafter — see `app.dart`).
///
/// Every call is a no-op where there are no widgets to drive — see
/// [PlatformFeatures.homeWidgets].
class HomeWidgetService {
  const HomeWidgetService();

  static const _balanceAndroidName = 'BalanceWidgetProvider';
  static const _budgetAndroidName = 'BudgetWidgetProvider';
  static const _quickAddAndroidName = 'QuickAddWidgetProvider';
  static const _monthSummaryAndroidName = 'MonthSummaryWidgetProvider';
  static const _goalsAndroidName = 'GoalsWidgetProvider';
  static const _extremesAndroidName = 'SpendingExtremesWidgetProvider';

  /// How many lines the Budgets widget's static layout has rows for — see
  /// `budget_widget.xml`.
  static const maxBudgetLines = 3;

  /// How many lines the Goals widget's static layout has rows for — see
  /// `goals_widget.xml`. Supports up to 3 goals + 2 loans.
  static const maxGoalLines = 6;

  Future<void> updateBalance(Money netWorth) async {
    if (!PlatformFeatures.homeWidgets) return;
    try {
      await HomeWidget.saveWidgetData<String>(
        'net_worth',
        MoneyFormat.symbol(netWorth),
      );
      await HomeWidget.updateWidget(androidName: _balanceAndroidName);
    } catch (e) {
      // A widget that fails to refresh must never take the app down with it.
      debugPrint('HomeWidgetService.updateBalance failed: $e');
    }
  }

  /// [lines] should already be capped to [maxBudgetLines] and ordered
  /// most-pressing first — this saves exactly what it's given, formatted,
  /// as JSON the native side reads with no formatting logic of its own
  /// (RemoteViews has no access to the app's currency/locale config).
  Future<void> updateBudgetSummary(List<WidgetBudgetLine> lines) async {
    if (!PlatformFeatures.homeWidgets) return;
    try {
      final json = jsonEncode([
        for (final line in lines)
          {
            'name': line.name,
            'value':
                '${MoneyFormat.symbol(line.spent)} / '
                '${MoneyFormat.symbol(line.limit)}',
          },
      ]);
      await HomeWidget.saveWidgetData<String>('budget_summary', json);
      await HomeWidget.updateWidget(androidName: _budgetAndroidName);
    } catch (e) {
      debugPrint('HomeWidgetService.updateBudgetSummary failed: $e');
    }
  }

  Future<void> updateMonthSummary(
    Money income,
    Money expense, {
    Money? totalSavings,
  }) async {
    if (!PlatformFeatures.homeWidgets) return;
    try {
      final net = income - expense;
      final netFormatted = 'Total balance: ${MoneyFormat.signed(net)}';

      await HomeWidget.saveWidgetData<String>(
        'month_income',
        MoneyFormat.symbol(income),
      );
      await HomeWidget.saveWidgetData<String>(
        'month_expense',
        MoneyFormat.symbol(expense),
      );
      await HomeWidget.saveWidgetData<String>(
        'month_net_savings',
        netFormatted,
      );
      if (totalSavings != null && !totalSavings.isZero) {
        await HomeWidget.saveWidgetData<String>(
          'month_total_savings',
          'Total saved: ${MoneyFormat.compact(totalSavings)}',
        );
      } else {
        await HomeWidget.saveWidgetData<String?>('month_total_savings', null);
      }
      await HomeWidget.updateWidget(androidName: _monthSummaryAndroidName);
    } catch (e) {
      debugPrint('HomeWidgetService.updateMonthSummary failed: $e');
    }
  }

  Future<void> updateGoalsSummary(
    List<WidgetGoalLine> lines, {
    Money? totalSaved,
    Money? totalDebt,
  }) async {
    if (!PlatformFeatures.homeWidgets) return;
    try {
      final json = jsonEncode([
        for (final line in lines)
          {
            'name': line.name,
            'kind': line.kind,
            'value': line.value,
            'percent': line.percent,
            if (line.subtitle != null) 'subtitle': line.subtitle,
          },
      ]);
      await HomeWidget.saveWidgetData<String>('goals_summary', json);
      if (totalSaved != null) {
        await HomeWidget.saveWidgetData<String>(
          'goals_total_saved',
          'Total saved: ${MoneyFormat.symbol(totalSaved)}',
        );
      }
      if (totalDebt != null) {
        await HomeWidget.saveWidgetData<String>(
          'goals_total_debt',
          'Total debt: ${MoneyFormat.symbol(totalDebt)}',
        );
      }
      await HomeWidget.updateWidget(androidName: _goalsAndroidName);
    } catch (e) {
      debugPrint('HomeWidgetService.updateGoalsSummary failed: $e');
    }
  }

  Future<void> updateSpendingExtremes({
    String? minAmount,
    String? minDate,
    String? minTag,
    int? minTxId,
    String? maxAmount,
    String? maxDate,
    String? maxTag,
    int? maxTxId,
  }) async {
    if (!PlatformFeatures.homeWidgets) return;
    try {
      if (minAmount != null) {
        await HomeWidget.saveWidgetData<String>('extremes_min_amount', minAmount);
      }
      if (minDate != null) {
        await HomeWidget.saveWidgetData<String>('extremes_min_date', minDate);
      }
      if (minTag != null) {
        await HomeWidget.saveWidgetData<String>('extremes_min_tag', minTag);
      }
      if (minTxId != null) {
        await HomeWidget.saveWidgetData<String>('extremes_min_id', minTxId.toString());
      } else {
        await HomeWidget.saveWidgetData<String?>('extremes_min_id', null);
      }

      if (maxAmount != null) {
        await HomeWidget.saveWidgetData<String>('extremes_max_amount', maxAmount);
      }
      if (maxDate != null) {
        await HomeWidget.saveWidgetData<String>('extremes_max_date', maxDate);
      }
      if (maxTag != null) {
        await HomeWidget.saveWidgetData<String>('extremes_max_tag', maxTag);
      }
      if (maxTxId != null) {
        await HomeWidget.saveWidgetData<String>('extremes_max_id', maxTxId.toString());
      } else {
        await HomeWidget.saveWidgetData<String?>('extremes_max_id', null);
      }

      await HomeWidget.updateWidget(androidName: _extremesAndroidName);
    } catch (e) {
      debugPrint('HomeWidgetService.updateSpendingExtremes failed: $e');
    }
  }

  /// Prompts the launcher to offer pinning [widget] directly to the home
  /// screen, from inside the app — Settings > Widgets' "Add to home
  /// screen" buttons. Android 8+ and launcher-dependent; callers should
  /// check [canRequestPin] first and hide the button otherwise.
  Future<void> requestPin(HomeScreenWidget widget) async {
    if (!PlatformFeatures.homeWidgets) return;
    try {
      await HomeWidget.requestPinWidget(androidName: _androidNameOf(widget));
    } catch (e) {
      debugPrint('HomeWidgetService.requestPin failed: $e');
    }
  }

  Future<bool> canRequestPin() async {
    if (!PlatformFeatures.homeWidgets) return false;
    try {
      return await HomeWidget.isRequestPinWidgetSupported() ?? false;
    } catch (_) {
      return false;
    }
  }

  static String _androidNameOf(HomeScreenWidget widget) => switch (widget) {
    HomeScreenWidget.balance => _balanceAndroidName,
    HomeScreenWidget.budgets => _budgetAndroidName,
    HomeScreenWidget.quickAdd => _quickAddAndroidName,
    HomeScreenWidget.monthSummary => _monthSummaryAndroidName,
    HomeScreenWidget.goals => _goalsAndroidName,
    HomeScreenWidget.spendingExtremes => _extremesAndroidName,
  };

  /// Call once at startup. Covers both a cold start launched *from* a
  /// widget and a tap on one while the app is already running.
  void init() {
    if (!PlatformFeatures.homeWidgets) return;
    HomeWidget.widgetClicked.listen(_handleUri);
    HomeWidget.initiallyLaunchedFromHomeWidget()
        .then(_handleUri)
        .catchError((_) {});
  }

  void _handleUri(Uri? uri) {
    if (uri == null) return;
    if (uri.host == 'goals') {
      appRouter.go('/accounts');
      return;
    }
    if (uri.host == 'tx') {
      final id = uri.queryParameters['id'];
      if (id != null) {
        appRouter.push('/transaction/$id');
      }
      return;
    }
    if (uri.host != 'add') return;
    // Only `expense`/`income` are ever sent by a widget — anything else
    // falls back to the screen's own default rather than a broken deep link.
    final type = uri.queryParameters['type'];
    appRouter.go(type == null ? '/add' : '/add?type=$type');
  }
}

/// The six preset home-screen widgets — see the doc on [HomeWidgetService].
enum HomeScreenWidget {
  balance,
  budgets,
  quickAdd,
  monthSummary,
  goals,
  spendingExtremes,
}

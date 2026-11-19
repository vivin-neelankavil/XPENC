import 'package:flutter_test/flutter_test.dart';
import 'package:xpenc/core/home_widget/home_widget_service.dart';
import 'package:xpenc/core/money.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HomeScreenWidget enum contains goals, monthSummary, and spendingExtremes', () {
    expect(HomeScreenWidget.values, contains(HomeScreenWidget.goals));
    expect(HomeScreenWidget.values, contains(HomeScreenWidget.monthSummary));
    expect(HomeScreenWidget.values, contains(HomeScreenWidget.spendingExtremes));
  });

  test('HomeWidgetService handles updateGoalsSummary, updateMonthSummary, and updateSpendingExtremes safely', () async {
    const service = HomeWidgetService();
    // In headless test environment (no native platform channel), service handles calls safely
    await service.updateMonthSummary(
      Money.fromRupees(45000),
      Money.fromRupees(18250),
      totalSavings: Money.fromRupees(150000),
    );

    await service.updateSpendingExtremes(
      minAmount: '₹100.00',
      minDate: '30 Jul 2026 15:46',
      minTag: '# Coffee',
      minTxId: 1,
      maxAmount: '₹5,000.00',
      maxDate: '30 Jul 2026 15:46',
      maxTag: '# Food',
      maxTxId: 2,
    );

    await service.updateGoalsSummary(
      [
        (
          name: 'Emergency Fund',
          kind: 'GOAL',
          value: '₹1,50,000 / ₹2,00,000',
          percent: 75,
          subtitle: '75% funded',
        ),
        (
          name: 'Car Loan',
          kind: 'LOAN',
          value: '₹3,20,000 left',
          percent: 40,
          subtitle: '40% paid',
        ),
      ],
      totalSaved: Money.fromRupees(150000),
      totalDebt: Money.fromRupees(320000),
    );
  });
}

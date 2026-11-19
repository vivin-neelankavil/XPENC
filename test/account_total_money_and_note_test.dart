import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xpenc/core/money.dart';
import 'package:xpenc/core/theme/app_theme.dart';
import 'package:xpenc/core/widgets/app_surfaces.dart';
import 'package:xpenc/data/database.dart';
import 'package:xpenc/data/providers.dart';
import 'package:xpenc/data/tables.dart';
import 'package:xpenc/features/accounts/account_detail_screen.dart';
import 'package:xpenc/features/accounts/edit_account_sheet.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [dbProvider.overrideWithValue(db)],
        child: MaterialApp(theme: AppTheme.light, home: screen),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  }

  Future<int> addTestAccount({
    required String name,
    required Money openingBalance,
    bool includeInTotalMoney = true,
    String? note,
  }) {
    return db.addAccount(
      name: name,
      type: AccountType.bank,
      colorValue: 0xFF1E88E5,
      iconKey: 'bank',
      openingBalance: openingBalance,
      includeInTotalMoney: includeInTotalMoney,
      note: note,
    );
  }

  test('default includeInTotalMoney is true and note is null', () async {
    final id = await db.addAccount(
      name: 'Default Bank',
      type: AccountType.bank,
      colorValue: 0xFF1E88E5,
      iconKey: 'bank',
      openingBalance: Money.fromRupees(100),
    );

    final account = (await db.watchAccounts().first).firstWhere((a) => a.id == id);
    expect(account.includeInTotalMoney, isTrue);
    expect(account.note, isNull);
  });

  test('account excluded from Total money does not affect Net Worth', () async {
    // Default seeded Cash account has balance 0.
    final regularBank = await addTestAccount(
      name: 'Checking',
      openingBalance: Money.fromRupees(500),
      includeInTotalMoney: true,
      note: 'Main account',
    );

    final secretLocker = await addTestAccount(
      name: 'Locker Cash',
      openingBalance: Money.fromRupees(1000),
      includeInTotalMoney: false,
      note: 'Locker #42 PIN: 9876',
    );

    // Verify initial values
    // Net worth must count ALL accounts: 500 + 1000 = 1500
    expect(await db.watchNetWorth().first, Money.fromRupees(1500));

    // Total money must ONLY count accounts with includeInTotalMoney == true: 500
    expect(await db.watchTotalMoney().first, Money.fromRupees(500));

    // Check notes
    final regular = (await db.watchAccounts().first).firstWhere((a) => a.id == regularBank);
    final locker = (await db.watchAccounts().first).firstWhere((a) => a.id == secretLocker);
    expect(regular.note, 'Main account');
    expect(locker.note, 'Locker #42 PIN: 9876');
    expect(locker.includeInTotalMoney, isFalse);

    // Now include locker in Total money
    await db.setAccountIncludeInTotalMoney(secretLocker, true);
    expect(await db.watchTotalMoney().first, Money.fromRupees(1500));
    expect(await db.watchNetWorth().first, Money.fromRupees(1500));

    // Exclude checking from Total money
    await db.setAccountIncludeInTotalMoney(regularBank, false);
    expect(await db.watchTotalMoney().first, Money.fromRupees(1000));
    expect(await db.watchNetWorth().first, Money.fromRupees(1500));

    // Update note
    await db.updateAccountNote(secretLocker, 'Updated Locker Note: PIN 1234');
    final updatedLocker = (await db.watchAccounts().first).firstWhere((a) => a.id == secretLocker);
    expect(updatedLocker.note, 'Updated Locker Note: PIN 1234');

    // Clear note
    await db.updateAccountNote(secretLocker, '');
    final clearedLocker = (await db.watchAccounts().first).firstWhere((a) => a.id == secretLocker);
    expect(clearedLocker.note, isNull);
  });

  testWidgets('EditAccountSheet can toggle includeInTotalMoney and edit note', (tester) async {
    late AccountRow account;
    await tester.runAsync(() async {
      final id = await addTestAccount(
        name: 'Vault',
        openingBalance: Money.fromRupees(2000),
        includeInTotalMoney: true,
        note: 'Initial Note',
      );
      account = (await db.watchAccounts().first).firstWhere((a) => a.id == id);
    });

    await pump(tester, Scaffold(body: EditAccountSheet(account: account)));
    expect(tester.takeException(), isNull);

    // Verify initial values
    expect(find.text('Include in Total money'), findsOneWidget);
    expect(find.text('Initial Note'), findsOneWidget);

    // Toggle "Include in Total money" switch
    final switchTile = find.ancestor(
      of: find.text('Include in Total money'),
      matching: find.byType(AppSwitchListTile),
    );
    await tester.ensureVisible(switchTile);
    await tester.tap(switchTile);
    await tester.pump();

    // Edit note
    final noteField = find.widgetWithText(TextField, 'Initial Note');
    await tester.ensureVisible(noteField);
    await tester.enterText(noteField, 'Locker Code: 7788');
    await tester.pump();

    // Tap Save button
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    // Verify DB updated
    late AccountRow saved;
    await tester.runAsync(() async {
      saved = (await db.watchAccounts().first).firstWhere((a) => a.id == account.id);
    });
    expect(saved.includeInTotalMoney, isFalse);
    expect(saved.note, 'Locker Code: 7788');
    await unmount(tester);
  });

  testWidgets('AccountDetailScreen shows Note card and excluded chip', (tester) async {
    late int id;
    await tester.runAsync(() async {
      id = await addTestAccount(
        name: 'Secret Safe',
        openingBalance: Money.fromRupees(1500),
        includeInTotalMoney: false,
        note: 'Safe combination: 12-34-56',
      );
    });

    await pump(tester, AccountDetailScreen(accountId: id));
    expect(tester.takeException(), isNull);

    // Excluded chip should be shown in header
    expect(find.text('Excluded from Total money'), findsOneWidget);

    // Note card should be visible
    expect(find.text('Note'), findsOneWidget);
    expect(find.text('Safe combination: 12-34-56'), findsOneWidget);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    await unmount(tester);
  });

  test('watchAssetsAndLiabilities respects totalMoneyOnly flag', () async {
    await addTestAccount(
      name: 'Main Bank',
      openingBalance: Money.fromRupees(5000),
      includeInTotalMoney: true,
    );
    await addTestAccount(
      name: 'Provident Fund',
      openingBalance: Money.fromRupees(10000),
      includeInTotalMoney: false,
    );

    final totalParts =
        await db.watchAssetsAndLiabilities(totalMoneyOnly: true).first;
    expect(totalParts.assets, Money.fromRupees(5000));
    expect(totalParts.assets - totalParts.liabilities, await db.watchTotalMoney().first);

    final netWorthParts =
        await db.watchAssetsAndLiabilities(totalMoneyOnly: false).first;
    expect(netWorthParts.assets, Money.fromRupees(15000));
    expect(netWorthParts.assets - netWorthParts.liabilities, await db.watchNetWorth().first);
  });

  test('goal and loan can be excluded from Total money without affecting Net worth', () async {
    final bank = await addTestAccount(
      name: 'Salary Bank',
      openingBalance: Money.fromRupees(10000),
    );
    expect(await db.watchTotalMoney().first, Money.fromRupees(10000));

    // Add a goal excluded from Total money
    final goalId = await db.addGoal(
      name: 'PPF',
      targetAmount: Money.fromRupees(50000),
      colorValue: 0xFF1E88E5,
      iconKey: 'savings',
      includeInTotalMoney: false,
    );
    // Fund the goal from the bank: 2000 rupees
    await db.addTransaction(
      type: TxType.transfer,
      amount: Money.fromRupees(2000),
      accountId: bank,
      toAccountId: goalId,
      date: DateTime.now(),
    );

    // Bank now has 8000, Goal has 2000.
    // Net worth still has all: 8000 + 2000 = 10000
    expect(await db.watchNetWorth().first, Money.fromRupees(10000));
    // Total money only has Bank: 8000 (Goal is excluded)
    expect(await db.watchTotalMoney().first, Money.fromRupees(8000));

    // Add a loan excluded from Total money
    final loanId = await db.addLoan(
      name: 'Car Loan',
      principal: Money.fromRupees(5000),
      colorValue: 0xFFE53935,
      iconKey: 'loan',
      includeInTotalMoney: false,
    );
    // Net worth counts the loan (-5000): 10000 - 5000 = 5000
    expect(await db.watchNetWorth().first, Money.fromRupees(5000));
    // Total money does not count the loan (-5000): still 8000
    expect(await db.watchTotalMoney().first, Money.fromRupees(8000));

    // Toggle goal back into Total money
    await db.setAccountIncludeInTotalMoney(goalId, true);
    // Total money now includes Goal (2000): 8000 + 2000 = 10000
    expect(await db.watchTotalMoney().first, Money.fromRupees(10000));
    // Net worth remains 5000
    expect(await db.watchNetWorth().first, Money.fromRupees(5000));

    // Toggle loan back into Total money
    await db.setAccountIncludeInTotalMoney(loanId, true);
    // Total money now includes Loan (-5000): 10000 - 5000 = 5000
    expect(await db.watchTotalMoney().first, Money.fromRupees(5000));
    expect(await db.watchNetWorth().first, Money.fromRupees(5000));
  });
}


import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xpenc/data/database.dart';
import 'package:xpenc/data/providers.dart';
import 'package:xpenc/features/tags/tags_screen.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Widget buildTestWidget() {
    return ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
      ],
      child: const MaterialApp(
        home: TagsScreen(),
      ),
    );
  }

  testWidgets('renders search box and filters tags in TagsScreen', (tester) async {
    await db.addTag(name: 'Groceries', colorValue: 0xFF2563EB);
    await db.addTag(name: 'Rent', colorValue: 0xFF16A34A);
    await db.addTag(name: 'Green Tea', colorValue: 0xFF0D9488);

    await tester.pumpWidget(buildTestWidget());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Green Tea'), findsOneWidget);

    // Enter search query "gr"
    await tester.enterText(find.byType(TextField), 'gr');
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Green Tea'), findsOneWidget);
    expect(find.text('Rent'), findsNothing);

    // Enter search query with no match
    await tester.enterText(find.byType(TextField), 'gym');
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsNothing);
    expect(find.text('Rent'), findsNothing);
    expect(find.text('Green Tea'), findsNothing);
    expect(find.text('No tags matching "gym"'), findsOneWidget);
    expect(find.text('Create "gym"'), findsOneWidget);

    // Tap Create "gym" and verify editor sheet opens with "gym" prefilled
    await tester.tap(find.text('Create "gym"'));
    await tester.pumpAndSettle();

    expect(find.text('gym'), findsWidgets);
    expect(find.text('Save'), findsOneWidget);

    // Close sheet
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Clear search
    await tester.tap(find.byIcon(Icons.clear_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('Green Tea'), findsOneWidget);
    expect(find.text('gym'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

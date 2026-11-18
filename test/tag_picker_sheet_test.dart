import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xpenc/data/database.dart';
import 'package:xpenc/data/providers.dart';
import 'package:xpenc/features/tags/tag_picker_sheet.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Widget buildSheet({Set<int> initial = const {}}) {
    return ProviderScope(
      overrides: [dbProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Scaffold(
          body: TagPickerSheet(initiallySelected: initial),
        ),
      ),
    );
  }

  testWidgets('displays existing tags and New tag option', (tester) async {
    await db.addTag(name: 'Travel', colorValue: 0xFF16A34A);
    await tester.pumpWidget(buildSheet());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('New tag'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('creates a new tag and selects it', (tester) async {
    await db.addTag(name: 'Groceries', colorValue: 0xFF2563EB);
    await tester.pumpWidget(buildSheet());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Tap the '+' button near Done
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Expect dialog to appear
    expect(find.byType(TagEditorDialog), findsOneWidget);

    // Enter name
    await tester.enterText(find.byType(TextField), 'Vacation');
    await tester.pump();

    // Tap Add button
    await tester.tap(find.text('Add'));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Dialog should be dismissed
    expect(find.byType(TagEditorDialog), findsNothing);

    // New tag should exist in DB and show on sheet as selected
    final allTags = await db.select(db.tags).get();
    expect(allTags.any((t) => t.name == 'Vacation'), isTrue);
    expect(find.text('Vacation'), findsOneWidget);

    // Verify it is selected
    final vacationChip = tester.widget<FilterChip>(
      find.ancestor(
        of: find.text('Vacation'),
        matching: find.byType(FilterChip),
      ),
    );
    expect(vacationChip.selected, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

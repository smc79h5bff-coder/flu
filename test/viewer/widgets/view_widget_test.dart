import 'package:docdiff/features/diff/domain/diff_entry.dart';
import 'package:docdiff/features/diff/domain/diff_operation.dart';
import 'package:docdiff/features/diff/domain/diff_result.dart';
import 'package:docdiff/features/viewer/presentation/widgets/diff_only_view.dart';
import 'package:docdiff/features/viewer/presentation/widgets/diff_stats_bar.dart';
import 'package:docdiff/features/viewer/presentation/widgets/merged_view.dart';
import 'package:docdiff/features/viewer/presentation/widgets/side_by_side_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 4-entry diff covering all operations (equal/insert/delete/replace).
DiffResult _smallDiff() => DiffResult(
      entries: [
        DiffEntry(operation: DiffOperation.equal, text: 'same'),
        DiffEntry(
            operation: DiffOperation.insert,
            text: 'added',
            newText: 'added'),
        DiffEntry(
            operation: DiffOperation.delete,
            text: 'gone',
            oldText: 'gone'),
        DiffEntry(
          operation: DiffOperation.replace,
          text: 'new',
          oldText: 'old',
          newText: 'new',
          similarity: 0.7,
        ),
      ],
      engineType: DiffEngineType.line,
    );

/// Deterministic stress diff with 4-entry cycle × [repeats].
/// Each cycle contributes: 1 equal + 1 insert(3 chars) + 1 delete(3 chars)
/// + 1 replace(old=3, new=3). All entries same length per op for stable math.
DiffResult _stressDiff(int repeats) {
  final entries = <DiffEntry>[];
  for (var i = 0; i < repeats; i++) {
    entries.add(DiffEntry(operation: DiffOperation.equal, text: 'eq-$i'));
    entries.add(DiffEntry(
        operation: DiffOperation.insert, text: 'ins', newText: 'ins'));
    entries.add(DiffEntry(
        operation: DiffOperation.delete, text: 'del', oldText: 'del'));
    entries.add(DiffEntry(
      operation: DiffOperation.replace,
      text: 'rep',
      oldText: 'old',
      newText: 'rep',
    ));
  }
  return DiffResult(entries: entries, engineType: DiffEngineType.line);
}

void main() {
  group('MergedView', () {
    testWidgets('renders all 4 entries with correct symbols', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MergedView(result: _smallDiff())),
      ));

      expect(find.text('same', findRichText: true), findsOneWidget);
      expect(find.text('added', findRichText: true), findsOneWidget);
      expect(find.text('gone', findRichText: true), findsOneWidget);
      expect(find.text('new', findRichText: true), findsOneWidget);
      // Symbol column for diff ops.
      expect(find.text('+'), findsOneWidget);
      expect(find.text('-'), findsOneWidget);
      expect(find.text('~'), findsOneWidget);
    });

    testWidgets('renders large stress diff (400 entries) without error',
        (tester) async {
      final result = _stressDiff(100);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MergedView(result: result)),
      ));
      // ListView is lazy — only initial viewport items render.
      // First equal entry should be visible.
      expect(find.text('eq-0', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DiffOnlyView', () {
    testWidgets('filters out equal entries, keeps diff entries',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffOnlyView(result: _smallDiff())),
      ));

      // 'same' is equal → filtered out.
      expect(find.text('same'), findsNothing);
      // Diff entries survive.
      expect(find.text('added'), findsOneWidget);
      expect(find.text('gone'), findsOneWidget);
      expect(find.text('new'), findsOneWidget);
    });

    testWidgets('renders large diff (300 non-equal entries)', (tester) async {
      final result = _stressDiff(100);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffOnlyView(result: result)),
      ));
      // 400 entries → 300 non-equal. Should not crash.
      expect(find.byType(DiffOnlyView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('SideBySideView', () {
    testWidgets('left pane shows equal+delete, right pane shows equal+insert',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SideBySideView(result: _smallDiff())),
      ));

      // 'same' (equal) appears in BOTH cells.
      expect(find.text('same'), findsNWidgets(2));
      // 'gone' (delete) → left cell only.
      expect(find.text('gone'), findsOneWidget);
      // 'added' (insert) → right cell only.
      expect(find.text('added'), findsOneWidget);
      // 'new' (replace new text) → right cell; its old text 'old' is on left.
      expect(find.text('new'), findsOneWidget);
    });

    testWidgets('renders large diff (400 entries) in dual panes',
        (tester) async {
      final result = _stressDiff(100);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SideBySideView(result: result)),
      ));
      // equal entries appear in both panes → first one twice.
      expect(find.text('eq-0'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('DiffStatsBar', () {
    testWidgets('displays exact counts for small diff', (tester) async {
      // _smallDiff math:
      //   added   = insert('added'=5) + replace('new'=3)  = 8
      //   deleted = delete('gone'=4)  + replace('old'=3)  = 7
      //   modified = 1 (replace)
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: _smallDiff())),
      ));

      expect(find.text('+8'), findsOneWidget);
      expect(find.text('-7'), findsOneWidget);
      expect(find.text('~1'), findsOneWidget);
      expect(find.text('line'), findsOneWidget); // engineType label
    });

    testWidgets('displays exact counts for stress diff (100 cycles)',
        (tester) async {
      // Each cycle: ins(3) + del(3) + rep(old=3,new=3)
      //   added   = 100*3 + 100*3 = 600
      //   deleted = 100*3 + 100*3 = 600
      //   modified = 100
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: _stressDiff(100))),
      ));

      expect(find.text('+600'), findsOneWidget);
      expect(find.text('-600'), findsOneWidget);
      expect(find.text('~100'), findsOneWidget);
    });

    testWidgets('stress diff 1000 cycles (4000 entries)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: _stressDiff(1000))),
      ));

      expect(find.text('+6000'), findsOneWidget);
      expect(find.text('-6000'), findsOneWidget);
      expect(find.text('~1000'), findsOneWidget);
    });
  });
}

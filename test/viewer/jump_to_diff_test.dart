import 'package:docdiff/features/diff/domain/diff_entry.dart';
import 'package:docdiff/features/diff/domain/diff_operation.dart';
import 'package:docdiff/features/diff/domain/diff_result.dart';
import 'package:docdiff/features/viewer/presentation/diff_viewer_screen.dart';
import 'package:docdiff/features/viewer/presentation/providers/diff_viewer_providers.dart';
import 'package:docdiff/features/viewer/presentation/widgets/merged_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 30-entry diff: non-equal (insert) at indices 0, 10, 20 → 3 diffs total.
/// Indices 0–~11 fit in the default 800×600 test viewport (after AppBar +
/// stats bar + segmented button consume the top ~150 px).
DiffResult _testDiff() {
  final entries = <DiffEntry>[];
  for (var i = 0; i < 30; i++) {
    if (i == 0 || i == 10 || i == 20) {
      entries.add(DiffEntry(
        operation: DiffOperation.insert,
        text: 'DIFF-$i',
        newText: 'DIFF-$i',
      ));
    } else {
      entries.add(DiffEntry(operation: DiffOperation.equal, text: 'eq-$i'));
    }
  }
  return DiffResult(entries: entries, engineType: DiffEngineType.line);
}

Widget _wrap(DiffResult diff) => ProviderScope(
      overrides: [diffResultProvider.overrideWith((ref) => Future.value(diff))],
      child: const MaterialApp(home: DiffViewerScreen()),
    );

void main() {
  group('Position indicator (AppBar)', () {
    testWidgets('initial state shows 0/3', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();
      expect(find.text('0/3'), findsOneWidget);
    });

    testWidgets('tap next advances 1/3 → 2/3 → 3/3', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();

      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('3/3'), findsOneWidget);
    });

    testWidgets('tap next at last wraps to first (1/3)', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('next-diff')));
        await tester.pump();
      }
      expect(find.text('3/3'), findsOneWidget);

      // 4th tap should wrap.
      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('tap prev at start wraps to last (3/3)', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();
      expect(find.text('0/3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('prev-diff')));
      await tester.pump();
      expect(find.text('3/3'), findsOneWidget);
    });

    testWidgets('prev after next goes back one step', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();

      // Advance to 2/3
      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);

      // Prev → 1/3
      await tester.tap(find.byKey(const Key('prev-diff')));
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);
    });
  });

  group('Scroll behavior on jump', () {
    testWidgets('offscreen diff entry becomes visible after jump',
        (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();

      // DIFF-20 is at entry index 20 → ~720 px down. Default viewport
      // (after AppBar + stats bar + segmented button) shows entries
      // 0 through ~11, so DIFF-20 is offscreen.
      expect(find.text('DIFF-20', findRichText: true), findsNothing);

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('next-diff')));
        await tester.pumpAndSettle();
      }

      // After jumping to the 3rd diff (entry 20), animateTo scrolls the
      // viewport. ListView renders the visible items, including DIFF-20.
      expect(find.text('DIFF-20', findRichText: true), findsOneWidget);
    });

    testWidgets('first diff entry still visible after first jump',
        (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();

      // First diff at index 0 → DIFF-0 visible initially.
      expect(find.text('DIFF-0', findRichText: true), findsOneWidget);

      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pumpAndSettle();
      // Jumped to index 0 (still top), so still visible.
      expect(find.text('DIFF-0', findRichText: true), findsOneWidget);
    });
  });

  group('Swipe gestures', () {
    testWidgets('fling left → next diff', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();
      expect(find.text('0/3'), findsOneWidget);

      // Velocity 1000 px/s exceeds the 300 px/s threshold in
      // GestureDetector.onHorizontalDragEnd.
      await tester.fling(
          find.byType(MergedView), const Offset(-400, 0), 1000);
      await tester.pump();

      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('fling right at start → prev wraps to last', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();
      expect(find.text('0/3'), findsOneWidget);

      // Velocity 1000 px/s exceeds the 300 px/s threshold.
      await tester.fling(
          find.byType(MergedView), const Offset(400, 0), 1000);
      await tester.pump();

      expect(find.text('3/3'), findsOneWidget);
    });

    testWidgets('fling left twice advances 2 positions', (tester) async {
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();

      await tester.fling(
          find.byType(MergedView), const Offset(-400, 0), 1000);
      await tester.pump();
      await tester.fling(
          find.byType(MergedView), const Offset(-400, 0), 1000);
      await tester.pump();

      expect(find.text('2/3'), findsOneWidget);
    });

    testWidgets('fling with low velocity does NOT trigger jump',
        (tester) async {
      // Velocity threshold is 300 px/s. A 100px move over 1000ms is
      // 100 px/s — below threshold.
      await tester.pumpWidget(_wrap(_testDiff()));
      await tester.pump();
      expect(find.text('0/3'), findsOneWidget);

      await tester.timedDrag(find.byType(MergedView),
          const Offset(-100, 0), const Duration(seconds: 1));
      await tester.pump();

      // Sub-threshold fling → no jump, position unchanged.
      expect(find.text('0/3'), findsOneWidget);
    });
  });

  group('Edge cases', () {
    testWidgets('all-equal diff: no diffs to jump to (0/0)', (tester) async {
      final noDiffs = DiffResult(
        entries: [
          DiffEntry(operation: DiffOperation.equal, text: 'a'),
          DiffEntry(operation: DiffOperation.equal, text: 'b'),
        ],
        engineType: DiffEngineType.line,
      );

      await tester.pumpWidget(_wrap(noDiffs));
      await tester.pump();

      expect(find.text('0/0'), findsOneWidget);

      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('0/0'), findsOneWidget);
    });

    testWidgets('single diff: next stays at 1/1 with wrap', (tester) async {
      final singleDiff = DiffResult(
        entries: [
          DiffEntry(operation: DiffOperation.equal, text: 'eq'),
          DiffEntry(
              operation: DiffOperation.insert, text: 'X', newText: 'X'),
          DiffEntry(operation: DiffOperation.equal, text: 'eq2'),
        ],
        engineType: DiffEngineType.line,
      );

      await tester.pumpWidget(_wrap(singleDiff));
      await tester.pump();

      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);

      // Next wraps around (single diff).
      await tester.tap(find.byKey(const Key('next-diff')));
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);
    });
  });
}

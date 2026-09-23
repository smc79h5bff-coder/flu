import 'package:docdiff/features/diff/application/char_diff_engine.dart';
import 'package:docdiff/features/diff/application/line_diff_engine.dart';
import 'package:docdiff/features/diff/domain/diff_operation.dart';
import 'package:docdiff/features/diff/domain/diff_result.dart';
import 'package:docdiff/features/viewer/presentation/widgets/diff_stats_bar.dart';
import 'package:docdiff/features/viewer/presentation/widgets/merged_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Realistic large-TXT scenario: 1000 lines, every 20th line changed.
/// Original  = L0000, L0001, ..., L0999
/// Modified  = CHGED0000, L0001, CHGED0020, L0021, ..., L0999
/// All line texts are fixed-length for deterministic char counts.
(String original, String modified) _largeTxtPair(int lines,
    {int everyNth = 20}) {
  final orig = List.generate(
      lines, (i) => 'L${i.toString().padLeft(4, '0')}').join('\n');
  final mod = List.generate(lines, (i) {
    if (i % everyNth == 0) {
      return 'CHGED${i.toString().padLeft(4, '0')}';
    }
    return 'L${i.toString().padLeft(4, '0')}';
  }).join('\n');
  return (orig, mod);
}

void main() {
  group('Large TXT diff — line-level', () {
    testWidgets('1000 lines, 50 changes render without error',
        (tester) async {
      final pair = _largeTxtPair(1000);
      final result = const LineDiffEngine().compute(pair.$1, pair.$2);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MergedView(result: result)),
      ));

      // First viewport should show the very first delete + insert pair
      // (line 0 is changed since 0 % 20 == 0).
      expect(find.text('L0000', findRichText: true), findsOneWidget); // deleted
      expect(find.text('CHGED0000', findRichText: true),
          findsOneWidget); // inserted
      expect(tester.takeException(), isNull);
    });

    testWidgets('stats bar shows exact counts for 1000-line scenario',
        (tester) async {
      final pair = _largeTxtPair(1000);
      final result = const LineDiffEngine().compute(pair.$1, pair.$2);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: result)),
      ));

      // 50 changed lines × (delete 'L####' = 5 chars, insert 'CHGED####' = 9 chars)
      expect(find.text('+450'), findsOneWidget); // 50 × 9
      expect(find.text('-250'), findsOneWidget); // 50 × 5
      expect(find.text('~0'), findsOneWidget); // line diff produces no replace
    });

    testWidgets('stats bar handles 5000-line stress', (tester) async {
      final pair = _largeTxtPair(5000, everyNth: 50);
      final result = const LineDiffEngine().compute(pair.$1, pair.$2);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: result)),
      ));

      // 5000 / 50 = 100 changed lines.
      //   added   = 100 × 9 = 900
      //   deleted = 100 × 5 = 500
      expect(find.text('+900'), findsOneWidget);
      expect(find.text('-500'), findsOneWidget);
      expect(find.text('~0'), findsOneWidget);
    });

    testWidgets('identical large TXT yields all-equal diff', (tester) async {
      final text = List.generate(1000, (i) => 'line $i').join('\n');
      final result = const LineDiffEngine().compute(text, text);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: result)),
      ));

      expect(find.text('+0'), findsOneWidget);
      expect(find.text('-0'), findsOneWidget);
      expect(find.text('~0'), findsOneWidget);
    });

    testWidgets('wholly inserted large TXT', (tester) async {
      final text = List.generate(500, (i) => 'NEW $i').join('\n');
      final result = const LineDiffEngine().compute('', text);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: result)),
      ));

      // Each 'NEW i' line: 'NEW 0'=5, 'NEW 9'=5, 'NEW 10'=6, ..., 'NEW 499'=7
      // Total chars: 10×5 + 90×6 + 400×7 = 50 + 540 + 2800 = 3390
      expect(find.text('+3390'), findsOneWidget);
      expect(find.text('-0'), findsOneWidget);
      expect(find.text('~0'), findsOneWidget);
    });
  });

  group('Large TXT diff — char-level', () {
    testWidgets('1000-char text with single insertion', (tester) async {
      final original = 'a' * 1000;
      final modified = 'a' * 500 + 'X' + 'a' * 500;
      final result = const CharDiffEngine().compute(original, modified);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: result)),
      ));

      expect(find.text('+1'), findsOneWidget);
      expect(find.text('-0'), findsOneWidget);
      expect(find.text('~0'), findsOneWidget);
    });

    testWidgets('2000-char text with 100-char swap in the middle',
        (tester) async {
      final original = 'a' * 1000 + 'b' * 100 + 'a' * 900;
      final modified = 'a' * 1000 + 'c' * 100 + 'a' * 900;
      final result = const CharDiffEngine().compute(original, modified);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: result)),
      ));

      // diff-match-patch typically yields: equal(1000 a) + delete(100 b)
      // + insert(100 c) + equal(900 a).
      expect(find.text('+100'), findsOneWidget);
      expect(find.text('-100'), findsOneWidget);
      expect(find.text('~0'), findsOneWidget);
    });

    testWidgets('merged view renders 1000-char diff without error',
        (tester) async {
      final original = 'a' * 500 + 'b' * 50 + 'a' * 450;
      final modified = 'a' * 500 + 'B' * 50 + 'a' * 450;
      final result = const CharDiffEngine().compute(original, modified);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MergedView(result: result)),
      ));

      expect(tester.takeException(), isNull);
      expect(find.byType(MergedView), findsOneWidget);
    });
  });

  group('Large TXT diff — full pipeline (preprocess → diff → render)', () {
    testWidgets('preprocessed whitespace noise does not skew diff',
        (tester) async {
      // Simulate two TXT files that differ only in trailing whitespace,
      // which the norm_ws / trim_line rules should normalize away.
      final rawOriginal = 'line1   \n  line2  \n  line3';
      final rawModified = 'line1\nline2\nline3';
      // Without preprocessing, line diff would flag all 3 lines as changed.
      // After trim_line they should match.
      final originalClean =
          rawOriginal.replaceAll(RegExp(r'^[ \t]+|[ \t]+$', multiLine: true), '');
      final modifiedClean =
          rawModified.replaceAll(RegExp(r'^[ \t]+|[ \t]+$', multiLine: true), '');

      final result =
          const LineDiffEngine().compute(originalClean, modifiedClean);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffStatsBar(result: result)),
      ));

      expect(find.text('+0'), findsOneWidget);
      expect(find.text('-0'), findsOneWidget);
      expect(find.text('~0'), findsOneWidget);
    });

    testWidgets('large diff with mixed insert/delete/equal renders', (tester) async {
      // 300-line scenario: every 3rd line inserted, every 5th deleted.
      final original =
          List.generate(300, (i) => i % 5 == 0 ? 'rm-$i' : 'keep-$i').join('\n');
      final modified = List.generate(300, (i) {
        if (i % 3 == 0) return 'add-$i';
        return i % 5 == 0 ? 'replaced-$i' : 'keep-$i';
      }).join('\n');
      final result = const LineDiffEngine().compute(original, modified);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MergedView(result: result)),
      ));

      expect(tester.takeException(), isNull);
      // Verify diff actually produced some changes.
      expect(result.entries.any((e) => e.operation == DiffOperation.insert),
          isTrue);
      expect(result.entries.any((e) => e.operation == DiffOperation.delete),
          isTrue);
      expect(result.entries.any((e) => e.operation == DiffOperation.equal),
          isTrue);
    });
  });
}

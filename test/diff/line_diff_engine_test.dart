import 'dart:math';

import 'package:docdiff/features/diff/application/line_diff_engine.dart';
import 'package:docdiff/features/diff/domain/diff_operation.dart';
import 'package:docdiff/features/diff/domain/diff_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LineDiffEngine', () {
    final engine = const LineDiffEngine();

    test('identical lines → all equal', () {
      final r = engine.compute('a\nb\nc', 'a\nb\nc');
      expect(r.entries.every((e) => e.operation == DiffOperation.equal),
          isTrue);
      expect(r.stats.added, 0);
      expect(r.stats.deleted, 0);
    });

    test('appended line shows up as insert', () {
      final r = engine.compute('a\nb\nc', 'a\nb\nc\nd');
      expect(r.stats.added, 1); // 'd' line
      expect(
        r.entries.any((e) =>
            e.operation == DiffOperation.insert && e.text == 'd'),
        isTrue,
      );
    });

    test('removed line shows up as delete', () {
      final r = engine.compute('a\nb\nc', 'a\nc');
      expect(r.stats.deleted, 1); // 'b' line removed
      expect(
        r.entries.any((e) =>
            e.operation == DiffOperation.delete && e.text == 'b'),
        isTrue,
      );
    });

    test('line replacement emits del+insert pair', () {
      final r = engine.compute('a\nb\nc', 'a\nB\nc');
      expect(r.stats.deleted, 1);
      expect(r.stats.added, 1);
    });

    test('empty both sides → no entries', () {
      final r = engine.compute('', '');
      expect(r.entries, isEmpty);
    });

    test('engineType is line', () {
      final r = engine.compute('x', 'y');
      expect(r.engineType.name, 'line');
    });
  });

  // Hirschberg must return the *same* LCS as the classic table — the number of
  // equal lines must equal the true LCS length. Guards the O(m·n)-space→
  // O(m+n)-space rewrite against regressions.
  group('Hirschberg matches reference LCS', () {
    final engine = const LineDiffEngine();

    int refLcs(List<String> a, List<String> b) {
      final m = a.length, n = b.length;
      final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
      for (var i = m - 1; i >= 0; i--) {
        for (var j = n - 1; j >= 0; j--) {
          dp[i][j] = a[i] == b[j]
              ? dp[i + 1][j + 1] + 1
              : (dp[i + 1][j] > dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
        }
      }
      return dp[0][0];
    }

    final rng = Random(42);
    int eqCount(DiffResult r) => r.entries
        .where((e) => e.operation == DiffOperation.equal)
        .fold(0, (s, e) => s + e.text.split('\n').length);

    test('random inputs', () {
      const alphabet = ['x', 'y', 'z', 'a'];
      for (var trial = 0; trial < 30; trial++) {
        final m = rng.nextInt(20), n = rng.nextInt(20);
        final a = List.generate(m, (_) => alphabet[rng.nextInt(alphabet.length)]);
        final b = List.generate(n, (_) => alphabet[rng.nextInt(alphabet.length)]);
        final r = engine.compute(a.join('\n'), b.join('\n'));
        expect(eqCount(r), refLcs(a, b),
            reason: 'trial $trial: $a vs $b -> ${r.entries.map((e)=>e.operation.name)}');
      }
    });

    test('two large identical docs do not OOM (linear space)', () {
      final big = List.generate(5000, (i) => '第${i}行内容重复文本');
      final r = engine.compute(big.join('\n'), big.join('\n'));
      expect(r.entries.every((e) => e.operation == DiffOperation.equal), isTrue);
    });
  });
}

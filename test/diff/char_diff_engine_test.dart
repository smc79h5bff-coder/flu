import 'package:docdiff/features/diff/application/char_diff_engine.dart';
import 'package:docdiff/features/diff/domain/diff_operation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CharDiffEngine', () {
    final engine = const CharDiffEngine();

    test('identical text yields single equal entry', () {
      final r = engine.compute('hello', 'hello');
      expect(r.entries, hasLength(1));
      expect(r.entries.first.operation, DiffOperation.equal);
      expect(r.entries.first.text, 'hello');
      expect(r.stats.added, 0);
      expect(r.stats.deleted, 0);
    });

    test('detects pure insertion', () {
      final r = engine.compute('abc', 'abxc');
      expect(r.stats.added, 1); // 'x'
      expect(r.stats.deleted, 0);
      expect(
        r.entries.any(
          (e) => e.operation == DiffOperation.insert && e.text == 'x',
        ),
        isTrue,
      );
    });

    test('detects pure deletion', () {
      final r = engine.compute('abcd', 'acd');
      expect(r.stats.added, 0);
      expect(r.stats.deleted, 1);
      expect(
        r.entries.any(
          (e) => e.operation == DiffOperation.delete && e.text == 'b',
        ),
        isTrue,
      );
    });

    test('replace == insert + delete pair', () {
      final r = engine.compute('cat', 'cot');
      expect(r.stats.deleted, 1);
      expect(r.stats.added, 1);
    });

    test('empty original → all inserted', () {
      final r = engine.compute('', 'xyz');
      expect(r.stats.added, 3);
      expect(r.stats.deleted, 0);
    });

    test('empty modified → all deleted', () {
      final r = engine.compute('xyz', '');
      expect(r.stats.deleted, 3);
      expect(r.stats.added, 0);
    });

    test('engineType is char', () {
      final r = engine.compute('a', 'b');
      expect(r.engineType.name, 'char');
    });
  });
}

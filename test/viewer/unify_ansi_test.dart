import 'package:docdiff/features/viewer/presentation/providers/diff_viewer_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('unifyToAnsi', () {
    test('ANSI-representable text is returned unchanged', () {
      const s = 'Hello 世界 abc 123';
      expect(unifyToAnsi(s), s);
    });

    test('ASCII/GBK text is not modified (no false-positive)', () {
      const s = '纯中文GBK文本。';
      expect(unifyToAnsi(s), s);
    });

    test('characters outside GBK are dropped', () {
      // Emoji / 生僻扩展字符在 GBK 中通常不可表示，应被删除。
      const src = '正常中文😀测试';
      final out = unifyToAnsi(src);
      expect(out.contains('\u{1F600}'), isFalse);
      expect(out.contains('正常中文'), isTrue);
      expect(out.contains('测试'), isTrue);
    });
  });
}
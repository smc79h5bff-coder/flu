import 'package:docdiff/features/viewer/presentation/providers/diff_viewer_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('applyDiffIgnores', () {
    test('lineEndings normalizes CRLF and CR to LF', () {
      const src = 'a\r\nb\rc\n';
      expect(applyDiffIgnores(src, lineEndings: true), 'a\nb\nc\n');
    });

    test('whitespace strips all whitespace characters', () {
      const src = 'hello  world\n\tfoo\n bar ';
      expect(applyDiffIgnores(src, whitespace: true), 'helloworld\nfoo\nbar');
    });

    test('emptyLines drops blank/whitespace-only lines', () {
      const src = 'a\n\n   \n\t\nb';
      expect(applyDiffIgnores(src, emptyLines: true), 'a\nb');
    });

    test('combination applies lineEndings then whitespace then emptyLines',
        () {
      const src = 'a \r\n\r\n  b\t\r\n';
      expect(
        applyDiffIgnores(
          src,
          whitespace: true,
          emptyLines: true,
          lineEndings: true,
        ),
        'a\nb',
      );
    });

    test('no flags returns the input unchanged', () {
      const src = 'a  b \n\nc';
      expect(applyDiffIgnores(src), src);
    });
  });
}
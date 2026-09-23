import 'package:docdiff/features/preprocessing/application/preprocessing_service.dart';
import 'package:docdiff/features/preprocessing/domain/preprocessing_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreprocessingService (built-in defaults)', () {
    final svc = PreprocessingService();

    test('norm_eol: \\r\\n and \\r become \\n', () {
      expect(svc.apply('a\r\nb\rc', isOriginal: true), 'a\nb\nc');
    });

    test('norm_ws: collapses runs of spaces/tabs', () {
      expect(svc.apply('a   b\t\tc', isOriginal: true), 'a b c');
    });

    test('trim_line: strips leading/trailing whitespace per line', () {
      expect(svc.apply('  a  \n  b  ', isOriginal: true), 'a\nb');
    });

    test('all defaults combine in order: norm_eol → norm_ws → trim_line', () {
      expect(
        svc.apply('a  \r\n  b   c  ', isOriginal: true),
        'a\nb c',
      );
    });
  });

  group('PreprocessingService (user rules)', () {
    test('user rule applied after built-ins', () {
      final svc = PreprocessingService(
        userRules: const [
          PreprocessingRule(
            id: 'mask_date',
            name: 'mask date',
            findPattern: r'\d{4}-\d{2}-\d{2}',
            replaceWith: '<DATE>',
          ),
        ],
      );
      expect(
        svc.apply('today is 2024-01-01', isOriginal: true),
        'today is <DATE>',
      );
    });

    test('rule scope original-only does not fire for modified', () {
      final svc = PreprocessingService(
        userRules: const [
          PreprocessingRule(
            id: 'r',
            name: 'r',
            findPattern: r'foo',
            replaceWith: 'FOO',
            scope: RuleScope.originalOnly,
          ),
        ],
      );
      expect(svc.apply('foo bar', isOriginal: true), 'FOO bar');
      expect(svc.apply('foo bar', isOriginal: false), 'foo bar');
    });

    test('disabled rule is skipped', () {
      final svc = PreprocessingService(
        userRules: const [
          PreprocessingRule(
            id: 'r',
            name: 'r',
            findPattern: r'foo',
            replaceWith: 'FOO',
            enabled: false,
          ),
        ],
      );
      expect(svc.apply('foo bar', isOriginal: true), 'foo bar');
    });

    test('>20 active rules throws PreprocessingException', () {
      final rules = List.generate(
        21,
        (i) => PreprocessingRule(
          id: 'r$i',
          name: 'r$i',
          findPattern: 'x$i',
          replaceWith: 'Y',
        ),
      );
      final svc = PreprocessingService(userRules: rules);
      expect(
        () => svc.apply('payload', isOriginal: true),
        throwsA(isA<PreprocessingException>()),
      );
    });

    test('invalid regex in findPattern throws FormatException', () {
      // Service wraps RegExp; malformed pattern surfaces FormatException.
      final svc = PreprocessingService(
        userRules: const [
          PreprocessingRule(
            id: 'bad',
            name: 'bad',
            findPattern: r'(unclosed',
            replaceWith: '',
          ),
        ],
      );
      expect(
        () => svc.apply('payload', isOriginal: true),
        throwsA(isA<FormatException>()),
      );
    });

    test('back-reference \$1 expands to first group', () {
      final svc = PreprocessingService(
        userRules: const [
          PreprocessingRule(
            id: 'swap',
            name: 'swap',
            findPattern: r'(\w+)@(\w+)',
            replaceWith: r'$2/$1',
          ),
        ],
      );
      expect(
        svc.apply('user@example', isOriginal: true),
        'example/user',
      );
    });
  });
}

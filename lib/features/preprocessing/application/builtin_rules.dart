import '../domain/preprocessing_rule.dart';

/// Built-in preprocessing rules from PRD §2 Module 3.2.
/// Default-on set: norm_eol, norm_ws, trim_line.
class BuiltinRules {
  const BuiltinRules._();

  static List<PreprocessingRule> all() => const [
        PreprocessingRule(
          id: 'norm_eol',
          name: '统一换行',
          findPattern: r'\r\n|\r',
          replaceWith: '\n',
          enabled: true,
          isBuiltin: true,
        ),
        PreprocessingRule(
          id: 'norm_ws',
          name: '折叠多余空白',
          findPattern: r'[ \t]{2,}',
          replaceWith: ' ',
          enabled: true,
          isBuiltin: true,
        ),
        PreprocessingRule(
          id: 'trim_line',
          name: '去行首尾空白',
          findPattern: r'^[ \t]+|[ \t]+$',
          replaceWith: '',
          enabled: true,
          isBuiltin: true,
        ),
        PreprocessingRule(
          id: 'norm_quote',
          name: '中英文引号统一',
          findPattern: r'[""“”]',
          replaceWith: '"',
          enabled: false,
          isBuiltin: true,
        ),
        PreprocessingRule(
          id: 'norm_comma',
          name: '逗号空格归一',
          findPattern: r'[,，] +',
          replaceWith: '，',
          enabled: true,
          isBuiltin: true,
        ),
        PreprocessingRule(
          id: 'ignore_case',
          name: '忽略大小写',
          findPattern: r'(.+)',
          replaceWith: '\$1', // post-processed in service: lowercase
          enabled: false,
          isBuiltin: true,
        ),
        PreprocessingRule(
          id: 'norm_number',
          name: '全角数字转半角',
          findPattern: r'[０-９]',
          replaceWith: '0', // service applies per-match mapping
          enabled: false,
          isBuiltin: true,
        ),
      ];
}

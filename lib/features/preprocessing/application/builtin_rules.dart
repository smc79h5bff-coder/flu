import '../domain/preprocessing_rule.dart';

/// 内置规则。原「忽略项」那 8 条已并入这里，不再有单独的忽略体系。
///
/// 默认开：norm_eol / norm_ws / trim_line /
///         ig_invisible / ig_ws / ig_empty
///
/// 注：所有涉及空白匹配的规则都把全角空格 U+3000 一并纳入，
/// 否则中文文本里行首的行首缩进（两个全角空格）不会被清理，
/// 会导致看着一样的两行被判为"全红"。
class BuiltinRules {
  const BuiltinRules._();

  static List<PreprocessingRule> all() => const [
        // ============ 通用规范化 ============
        PreprocessingRule(
          id: 'norm_eol',
          name: '统一换行符',
          findPattern: r'\r\n|\r',
          replaceWith: '\n',
          enabled: true,
          isBuiltin: true,
          helpText: r'\r\n 和 \r 都换成 \n。',
        ),
        PreprocessingRule(
          id: 'norm_ws',
          name: '折叠多余空白',
          findPattern: r'[ \t\u3000]{2,}',
          replaceWith: ' ',
          enabled: false,
          isBuiltin: true,
          helpText: r'连续空格/Tab/全角空格压成一个空格。',
        ),
        PreprocessingRule(
          id: 'trim_line',
          name: '去行首尾空白',
          findPattern: r'^[ \t\u3000]+|[ \t\u3000]+$',
          replaceWith: '',
          enabled: true,
          isBuiltin: true,
          helpText: r'删掉每行首尾的空格、Tab、全角空格。',
        ),
        PreprocessingRule(
          id: 'norm_quote',
          name: '中英文引号统一',
          findPattern: r'[""“”]',
          replaceWith: '"',
          enabled: false,
          isBuiltin: true,
          helpText: r'中文左右引号统一成英文直引号 "。',
        ),
        PreprocessingRule(
          id: 'half_to_full', // 建议不动，避免开关状态被重置
          name: '全角字母数字转半角',
          script: 'fullToHalf',
          enabled: true,
          isBuiltin: true,
          helpText: r'全角数字和英文字母转成半角。',
        ),
        PreprocessingRule(
          id: 'en_punct_to_cn',
          name: '忽略标点符号',
          script: 'enPunctToCn',
          enabled: true,
          isBuiltin: true,
          helpText: r'统一标点，方便对比。',
        ),

        // ============ 原「忽略项」搬入 ============
        PreprocessingRule(
          id: 'ig_invisible',
          name: '忽略不可见字符',
          findPattern:
              r'[\u00A0\u00AD\u200B-\u200F\u202A-\u202E\u202F\u2060-\u2064\u2066-\u2069\uFEFF]',
          replaceWith: '',
          enabled: true,
          isBuiltin: true,
          helpText: r'删掉零宽空格、BOM 等看不见的字符。',
        ),
        PreprocessingRule(
          id: 'ig_ws',
          name: '删掉空白符号',
          findPattern: r'[ \t\u3000]+',
          replaceWith: '',
          enabled: true,
          isBuiltin: true,
          helpText: r'删掉所有空格、Tab 和全角空格。',
        ),
        PreprocessingRule(
          id: 'ig_empty',
          name: '删掉空行',
          script: 'dropEmptyLines',
          enabled: true,
          isBuiltin: true,
          helpText: r'删掉一个字符都没有的空行。',
        ),
        PreprocessingRule(
          id: 'ig_num',
          name: '忽略纯数字（数字改为占位符）',
          findPattern: r'[0-9]+',
          replaceWith: '<NUM>',
          enabled: false,
          isBuiltin: true,
          helpText: r'连续数字替换成 <NUM> 占位符。',
        ),
        PreprocessingRule(
          id: 'ig_case',
          name: '大写全转成小写',
          script: 'lowercase',
          enabled: false,
          isBuiltin: true,
          helpText: r'所有英文大写字母转成小写。',
        ),
        PreprocessingRule(
          id: 'ig_ansi',
          name: '统一编码 ANSI',
          script: 'unifyAnsi',
          enabled: false,
          isBuiltin: true,
          helpText: r'删掉 GBK 无法表示的字符（如 emoji）。',
        ),
      ];

  /// 会改动行数的内置规则 id。UI 用它决定是否提醒用户。
  static const Set<String> lineChangingIds = {'ig_empty'};
}

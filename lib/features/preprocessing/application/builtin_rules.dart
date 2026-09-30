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
          name: '统一换行',
          findPattern: r'\r\n|\r',
          replaceWith: '\n',
          enabled: true,
          isBuiltin: true,
          implType: '正则',
          implDetail: r'查找：\r\n|\r' '\n替换：\n',
        ),
        PreprocessingRule(
          id: 'norm_ws',
          name: '折叠多余空白',
          findPattern: r'[ \t\u3000]{2,}',
          replaceWith: ' ',
          enabled: true,
          isBuiltin: true,
          implType: '正则',
          implDetail: r'查找：[ \t\u3000]{2,}' '\n替换：一个半角空格',
        ),
        PreprocessingRule(
          id: 'trim_line',
          name: '去行首尾空白',
          findPattern: r'^[ \t\u3000]+|[ \t\u3000]+$',
          replaceWith: '',
          enabled: true,
          isBuiltin: true,
          implType: '正则',
          implDetail:
              r'查找：^[ \t\u3000]+|[ \t\u3000]+$' '\n替换：（空）',
        ),
        PreprocessingRule(
          id: 'norm_quote',
          name: '中英文引号统一',
          findPattern: r'[""“”]',
          replaceWith: '"',
          enabled: false,
          isBuiltin: true,
          implType: '正则',
          implDetail: r'查找：[""“”]' '\n替换：英文直引号 "',
        ),
        PreprocessingRule(
          id: 'half_to_full',
          name: '半角转全角',
          script: 'halfToFull',
          enabled: false,
          isBuiltin: true,
          implType: '代码',
          implDetail: '逐字符 unicode 映射：\n'
              '半角 U+0021~007E → 加 0xFEE0\n'
              '半角空格 U+0020 → U+3000',
          replacementType: 'warn',
          replacementDetail: '正则能做，但要写 95 个字符的映射，'
              '非常长，不建议',
        ),
        PreprocessingRule(
          id: 'en_punct_to_cn',
          name: '忽略标点符号',
          script: 'enPunctToCn',
          enabled: false,
          isBuiltin: true,
          implType: '代码',
          implDetail: '逐字符查表替换\n映射表约 11 对',
          replacementType: 'ok',
          replacementDetail: '正则：逐条 replaceAll，'
              '如 ,→， .→。 !→！ 等\n'
              '性能：大致相当',
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
          implType: '正则',
          implDetail: r'查找：[\u00A0\u00AD\u200B-\u200F'
              r'\u202A-\u202E\u202F\u2060-\u2064'
              r'\u2066-\u2069\uFEFF]'
              '\n替换：（空）',
        ),
        PreprocessingRule(
          id: 'ig_ws',
          name: '删掉空白符号',
          findPattern: r'[ \t\u3000]+',
          replaceWith: '',
          enabled: true,
          isBuiltin: true,
          implType: '正则',
          implDetail: r'查找：[ \t\u3000]+' '\n替换：（空）',
        ),
        PreprocessingRule(
          id: 'ig_empty',
          name: '删掉空行',
          script: 'dropEmptyLines',
          enabled: true,
          isBuiltin: true,
          implType: '代码',
          implDetail: "text.split('\\n')\n"
              "    .where((l) => l.isNotEmpty)\n"
              "    .join('\\n')",
          replacementType: 'ok',
          replacementDetail: r'正则：\n{2,} → \n' '\n'
              '性能：大致相当',
          replacementNote: '正则改写必须用 {2,}，'
              '写 \\n\\n 会漏掉 3 个以上连续换行',
        ),
        PreprocessingRule(
          id: 'ig_num',
          name: '忽略纯数字（数字改为占位符）',
          findPattern: r'[0-9]+',
          replaceWith: '<NUM>',
          enabled: false,
          isBuiltin: true,
          implType: '正则',
          implDetail: r'查找：[0-9]+' '\n替换：<NUM>',
        ),
        PreprocessingRule(
          id: 'ig_case',
          name: '大写全转成小写',
          script: 'lowercase',
          enabled: false,
          isBuiltin: true,
          implType: '代码',
          implDetail: 'text.toLowerCase()',
          replacementType: 'impossible',
          replacementDetail: '正则只能匹配和替换，'
              '不能把字符变大写或小写',
        ),
        PreprocessingRule(
          id: 'ig_ansi',
          name: '统一编码 ANSI',
          script: 'unifyAnsi',
          enabled: false,
          isBuiltin: true,
          implType: '代码',
          implDetail: 'GBK 编解码：\n'
              '1. GBK 编码再解码，能无损还原则保留\n'
              '2. 否则逐字符判断，GBK 无法表示的删掉',
          replacementType: 'impossible',
          replacementDetail: '需要调 GBK 编解码器，正则做不到',
        ),
      ];

  /// 会改动行数的内置规则 id。UI 用它决定是否提醒用户。
  static const Set<String> lineCountChangingIds = {'ig_empty'};
}

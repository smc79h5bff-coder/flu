/// One find/replace rule applied before diff.
class PreprocessingRule {
  const PreprocessingRule({
    required this.id,
    required this.name,
    this.findPattern = '',
    this.replaceWith = '',
    this.scope = RuleScope.both,
    this.enabled = true,
    this.isBuiltin = false,
    this.script,
    // ====== 查找词 3 开关 ======
    this.findRegex = true,
    this.findEscape = false,
    this.findDollar = true,
    // ====== 替换词 3 开关 ======
    this.replaceRegex = false,
    this.replaceEscape = false,
    this.replaceDollar = true,
  });

  final String id;
  final String name;

  final String findPattern;
  final String replaceWith;

  final RuleScope scope;
  final bool enabled;
  final bool isBuiltin;

  /// 特殊脚本标识。非空时忽略上面所有字段，走内置脚本。
  /// 支持的标识：'lowercase'、'dropEmptyLines'、'unifyAnsi'
  final String? script;

  // ==================== 6 个处理开关 ====================
  // 全部关闭 = 纯字符串匹配 + 纯字符串替换。

  /// 查找词按正则解析。关 → 字面匹配。
  final bool findRegex;

  /// 查找词里的 \n \r \t \\ \0 还原成真字符。
  final bool findEscape;

  /// 查找词里的 $ 保留正则行尾锚点含义。
  /// 关 → 把 $ 转义成字面 \$。
  final bool findDollar;

  /// 替换词里的 \1 \2 按捕获组引用展开。
  final bool replaceRegex;

  /// 替换词里的 \n \r \t \\ \0 还原成真字符。
  final bool replaceEscape;

  /// 替换词里的 $1 $2 按捕获组引用展开。
  final bool replaceDollar;

  PreprocessingRule copyWith({
    String? name,
    String? findPattern,
    String? replaceWith,
    RuleScope? scope,
    bool? enabled,
    String? script,
    bool? findRegex,
    bool? findEscape,
    bool? findDollar,
    bool? replaceRegex,
    bool? replaceEscape,
    bool? replaceDollar,
  }) =>
      PreprocessingRule(
        id: id,
        name: name ?? this.name,
        findPattern: findPattern ?? this.findPattern,
        replaceWith: replaceWith ?? this.replaceWith,
        scope: scope ?? this.scope,
        enabled: enabled ?? this.enabled,
        isBuiltin: isBuiltin,
        script: script ?? this.script,
        findRegex: findRegex ?? this.findRegex,
        findEscape: findEscape ?? this.findEscape,
        findDollar: findDollar ?? this.findDollar,
        replaceRegex: replaceRegex ?? this.replaceRegex,
        replaceEscape: replaceEscape ?? this.replaceEscape,
        replaceDollar: replaceDollar ?? this.replaceDollar,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'findPattern': findPattern,
        'replaceWith': replaceWith,
        'scope': scope.name,
        'enabled': enabled,
        'isBuiltin': isBuiltin,
        if (script != null) 'script': script,
        'findRegex': findRegex,
        'findEscape': findEscape,
        'findDollar': findDollar,
        'replaceRegex': replaceRegex,
        'replaceEscape': replaceEscape,
        'replaceDollar': replaceDollar,
      };

  factory PreprocessingRule.fromJson(Map<String, dynamic> j) =>
      PreprocessingRule(
        id: j['id'] as String,
        name: j['name'] as String,
        findPattern: j['findPattern'] as String? ?? '',
        replaceWith: j['replaceWith'] as String? ?? '',
        scope: RuleScope.values.firstWhere(
          (s) => s.name == j['scope'],
          orElse: () => RuleScope.both,
        ),
        enabled: j['enabled'] as bool? ?? true,
        isBuiltin: j['isBuiltin'] as bool? ?? false,
        script: j['script'] as String?,
        findRegex: j['findRegex'] as bool? ?? true,
        findEscape: j['findEscape'] as bool? ?? false,
        findDollar: j['findDollar'] as bool? ?? true,
        replaceRegex: j['replaceRegex'] as bool? ?? false,
        replaceEscape: j['replaceEscape'] as bool? ?? false,
        replaceDollar: j['replaceDollar'] as bool? ?? true,
      );
}

enum RuleScope { both, originalOnly, modifiedOnly }

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
    // ====== 查找侧 3 开关 ======
    this.findRegex = true,
    this.findLiteral = false,
    this.findEscape = false,
    // ====== 替换侧 4 开关 ======
    this.replaceDollar = true,
    this.replaceBackslash = false,
    this.replaceLiteral = false,
    this.replaceEscape = false,
  });

  final String id;
  final String name;
  final String findPattern;
  final String replaceWith;
  final RuleScope scope;
  final bool enabled;
  final bool isBuiltin;

  /// 特殊脚本标识。非空时忽略上面所有字段，走内置脚本。
  final String? script;

  // ==================== 7 个处理开关 ====================

  /// 查找词按正则解析。与 [findLiteral] 互斥，必须有一个为 true。
  final bool findRegex;

  /// 查找词按字面匹配。与 [findRegex] 互斥，必须有一个为 true。
  final bool findLiteral;

  /// 查找词里的 \n \r \t \\ \0 还原成真字符再匹配。
  final bool findEscape;

  /// 替换词里的 $1 $2 按捕获组引用展开。
  final bool replaceDollar;

  /// 替换词里的 \1 \2 按捕获组引用展开。
  final bool replaceBackslash;

  /// 替换词按字面输出（不展开引用）。
  /// 与 [replaceDollar] / [replaceBackslash] 互斥，三者至少开一个。
  final bool replaceLiteral;

  /// 替换词里的 \n \r \t \\ \0 还原成真字符再输出。
  final bool replaceEscape;

  PreprocessingRule copyWith({
    String? name,
    String? findPattern,
    String? replaceWith,
    RuleScope? scope,
    bool? enabled,
    String? script,
    bool? findRegex,
    bool? findLiteral,
    bool? findEscape,
    bool? replaceDollar,
    bool? replaceBackslash,
    bool? replaceLiteral,
    bool? replaceEscape,
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
        findLiteral: findLiteral ?? this.findLiteral,
        findEscape: findEscape ?? this.findEscape,
        replaceDollar: replaceDollar ?? this.replaceDollar,
        replaceBackslash: replaceBackslash ?? this.replaceBackslash,
        replaceLiteral: replaceLiteral ?? this.replaceLiteral,
        replaceEscape: replaceEscape ?? this.replaceEscape,
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
        'findLiteral': findLiteral,
        'findEscape': findEscape,
        'replaceDollar': replaceDollar,
        'replaceBackslash': replaceBackslash,
        'replaceLiteral': replaceLiteral,
        'replaceEscape': replaceEscape,
      };

  factory PreprocessingRule.fromJson(Map<String, dynamic> j) {
    // 兼容旧字段名（老版本用过 findDollar / replaceRegex）。
    final oldReplaceRegex = j['replaceRegex'] as bool?;
    return PreprocessingRule(
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
      findLiteral: j['findLiteral'] as bool? ?? false,
      findEscape: j['findEscape'] as bool? ?? false,
      replaceDollar: j['replaceDollar'] as bool? ?? true,
      replaceBackslash:
          j['replaceBackslash'] as bool? ?? oldReplaceRegex ?? false,
      replaceLiteral: j['replaceLiteral'] as bool? ?? false,
      replaceEscape: j['replaceEscape'] as bool? ?? false,
    );
  }
}

enum RuleScope { both, originalOnly, modifiedOnly }

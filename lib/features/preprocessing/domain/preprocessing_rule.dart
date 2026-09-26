/// 规则类型。决定这条规则走哪条执行路径。
enum RuleKind {
  /// 查找替换（7 开关 + 正则/字面）。
  replace,

  /// 预置功能。用 presetId 选功能，params 传参数。
  preset,

  /// JS 脚本。用 jsScript 里的 JS 代码处理文本。
  js,
}

extension RuleKindX on RuleKind {
  String get label => switch (this) {
        RuleKind.replace => '查找替换',
        RuleKind.preset => '预置功能',
        RuleKind.js => 'JS 脚本',
      };
}

/// One find/replace rule applied before diff.
class PreprocessingRule {
  const PreprocessingRule({
    required this.id,
    required this.name,
    this.kind = RuleKind.replace,
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
    // ====== preset 用 ======
    this.presetId,
    this.params = const {},
    // ====== js 用 ======
    this.jsScript,
  });

  final String id;
  final String name;

  /// 规则类型。老数据缺这个字段时按 replace 处理。
  final RuleKind kind;

  final String findPattern;
  final String replaceWith;
  final RuleScope scope;
  final bool enabled;
  final bool isBuiltin;

  /// 特殊脚本标识。仅用于内置规则（lowercase / dropEmptyLines / unifyAnsi）。
  /// kind == replace 且非空时，优先走内置脚本。
  final String? script;

  // ==================== 7 个处理开关（kind == replace 时用） ====================

  final bool findRegex;
  final bool findLiteral;
  final bool findEscape;
  final bool replaceDollar;
  final bool replaceBackslash;
  final bool replaceLiteral;
  final bool replaceEscape;

  // ==================== preset 用 ====================

  /// 预置功能 ID。kind == preset 时非空。
  /// 例如 'lineFilter'、'trimLines'、'removeEmptyLines'。
  final String? presetId;

  /// 预置功能的参数。key 和含义由 presetId 对应的实现决定。
  final Map<String, String> params;

  // ==================== js 用 ====================

  /// JS 脚本源码。kind == js 时非空。
  /// 脚本约定：最后表达式的值作为处理结果；text 是输入文本变量。
  final String? jsScript;

  PreprocessingRule copyWith({
    String? name,
    RuleKind? kind,
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
    String? presetId,
    Map<String, String>? params,
    String? jsScript,
  }) =>
      PreprocessingRule(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
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
        presetId: presetId ?? this.presetId,
        params: params ?? this.params,
        jsScript: jsScript ?? this.jsScript,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
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
        if (presetId != null) 'presetId': presetId,
        if (params.isNotEmpty) 'params': params,
        if (jsScript != null) 'jsScript': jsScript,
      };

  factory PreprocessingRule.fromJson(Map<String, dynamic> j) {
    // 兼容旧字段名。
    final oldReplaceRegex = j['replaceRegex'] as bool?;
    final oldFindDollar = j['findDollar'] as bool?;

    // 老数据没有 kind 字段。有 script 或 findPattern 非空 → replace。
    RuleKind kind;
    final kindName = j['kind'] as String?;
    if (kindName != null) {
      kind = RuleKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => RuleKind.replace,
      );
    } else {
      kind = RuleKind.replace;
    }

    // params：JSON 里是 Map<String, dynamic>，转成 Map<String, String>。
    Map<String, String> params = const {};
    final rawParams = j['params'];
    if (rawParams is Map) {
      params = {
        for (final e in rawParams.entries)
          e.key.toString(): e.value?.toString() ?? '',
      };
    }

    return PreprocessingRule(
      id: j['id'] as String,
      name: j['name'] as String,
      kind: kind,
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
      // 旧版 findDollar 没了，迁移过来当 findRegex 的一部分，忽略即可。
      replaceDollar: j['replaceDollar'] as bool? ?? true,
      replaceBackslash:
          j['replaceBackslash'] as bool? ?? oldReplaceRegex ?? false,
      replaceLiteral: j['replaceLiteral'] as bool? ?? false,
      replaceEscape: j['replaceEscape'] as bool? ?? false,
      presetId: j['presetId'] as String?,
      params: params,
      jsScript: j['jsScript'] as String?,
    );
  }
}

enum RuleScope { both, originalOnly, modifiedOnly }

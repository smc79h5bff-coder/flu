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
  });

  final String id;
  final String name;

  /// 普通查找替换规则用这两个字段。
  final String findPattern;
  final String replaceWith;

  final RuleScope scope;
  final bool enabled;
  final bool isBuiltin;

  /// 特殊脚本标识。非空时忽略 findPattern/replaceWith，走内置脚本。
  /// 支持的标识：'lowercase'、'dropEmptyLines'、'unifyAnsi'
  final String? script;

  PreprocessingRule copyWith({
    String? name,
    String? findPattern,
    String? replaceWith,
    RuleScope? scope,
    bool? enabled,
    String? script,
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
      );
}

enum RuleScope { both, originalOnly, modifiedOnly }

/// One find/replace rule applied before diff.
/// PRD §2 Module 3.3.
class PreprocessingRule {
  const PreprocessingRule({
    required this.id,
    required this.name,
    required this.findPattern,
    required this.replaceWith,
    this.scope = RuleScope.both,
    this.enabled = true,
    this.isBuiltin = false,
  });

  final String id;
  final String name;

  /// Raw regex source (PCRE subset, Dart RegExp compatible).
  final String findPattern;

  /// Replacement string. Supports `$1`, `$2` back-references.
  final String replaceWith;
  final RuleScope scope;
  final bool enabled;
  final bool isBuiltin;

  PreprocessingRule copyWith({
    String? name,
    String? findPattern,
    String? replaceWith,
    RuleScope? scope,
    bool? enabled,
  }) =>
      PreprocessingRule(
        id: id,
        name: name ?? this.name,
        findPattern: findPattern ?? this.findPattern,
        replaceWith: replaceWith ?? this.replaceWith,
        scope: scope ?? this.scope,
        enabled: enabled ?? this.enabled,
        isBuiltin: isBuiltin,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'findPattern': findPattern,
        'replaceWith': replaceWith,
        'scope': scope.name,
        'enabled': enabled,
        'isBuiltin': isBuiltin,
      };

  factory PreprocessingRule.fromJson(Map<String, dynamic> j) =>
      PreprocessingRule(
        id: j['id'] as String,
        name: j['name'] as String,
        findPattern: j['findPattern'] as String,
        replaceWith: j['replaceWith'] as String,
        scope: RuleScope.values.firstWhere(
          (s) => s.name == j['scope'],
          orElse: () => RuleScope.both,
        ),
        enabled: j['enabled'] as bool? ?? true,
        isBuiltin: j['isBuiltin'] as bool? ?? false,
      );
}

/// Which document the rule applies to.
enum RuleScope { both, originalOnly, modifiedOnly }

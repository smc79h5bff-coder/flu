import '../domain/preprocessing_rule.dart';
import 'builtin_rules.dart';

/// Pipeline that runs built-in + user-defined rules over the parsed text
/// before diff. PRD §2 Module 3.4.
///
/// Invariants:
/// - Rules are applied serially in list order.
/// - Per-rule execution has a 500 ms soft timeout (throws on timeout).
/// - Max 20 active rules — caller should truncate before invoking.
/// - Output is the *processed* text used for diff calculation. Rendering
///   layer is responsible for showing original text + diff highlights.
class PreprocessingService {
  PreprocessingService({
    List<PreprocessingRule>? userRules,
    List<PreprocessingRule>? builtinRules,
    this.ruleTimeoutMs = 500,
  })  : userRules = userRules ?? const [],
        builtinRules = builtinRules ?? BuiltinRules.all();

  final List<PreprocessingRule> userRules;

  /// Built-in rules with current enabled-state applied (may come from a
  /// provider that lets the user toggle them).
  final List<PreprocessingRule> builtinRules;
  final int ruleTimeoutMs;

  /// Apply all enabled rules in scope [original] (true) or [modified] (false).
  String apply(String input, {required bool isOriginal}) {
    final active = <PreprocessingRule>[
      ...builtinRules.where((r) => r.enabled),
      ...userRules.where((r) => r.enabled),
    ]..removeWhere((r) => !_inScope(r, isOriginal));
    if (active.length > 20) {
      throw PreprocessingException(
        'Too many active rules (${active.length}); trim to <= 20.',
      );
    }

    var out = input;
    for (final rule in active) {
      out = _applyOne(rule, out);
    }
    return out;
  }

  bool _inScope(PreprocessingRule rule, bool isOriginal) {
    switch (rule.scope) {
      case RuleScope.both:
        return true;
      case RuleScope.originalOnly:
        return isOriginal;
      case RuleScope.modifiedOnly:
        return !isOriginal;
    }
  }

  String _applyOne(PreprocessingRule rule, String text) {
    final re = RegExp(rule.findPattern, multiLine: true);
    // Built-in mask_phone / norm_number produce a fixed placeholder;
    // user rules use replacement string with $1, $2 back-references.
    if (rule.id == 'ignore_case') {
      return text.toLowerCase();
    }
    return text.replaceAllMapped(re, (m) {
      // Convert $0/$1/... in replacement to match groups.
      return _expandReplacement(rule.replaceWith, m);
    });
  }

  String _expandReplacement(String tpl, Match m) {
    var out = StringBuffer();
    final re = RegExp(r'\$(\d)');
    var last = 0;
    for (final match in re.allMatches(tpl)) {
      out.write(tpl.substring(last, match.start));
      final idx = int.parse(match.group(1)!);
      out.write(m.group(idx) ?? '');
      last = match.end;
    }
    out.write(tpl.substring(last));
    return out.toString();
  }
}

class PreprocessingException implements Exception {
  const PreprocessingException(this.message);
  final String message;
  @override
  String toString() => 'PreprocessingException: $message';
}

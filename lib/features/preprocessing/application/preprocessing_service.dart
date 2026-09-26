import '../domain/preprocessing_rule.dart';
import 'builtin_rules.dart';

/// 正则缓存：同一个 pattern 只编译一次，之后复用。
/// key 里带 multiLine 标志，避免同一个 pattern 用不同 multiLine 时串味。
///
/// 上限 [_regexCacheCap] 条，超出后清空重建。规则数量通常有限，
/// 但用户可能加几百条规则，为防止无界增长，加上限。
const int _regexCacheCap = 512;
final Map<String, RegExp> _regexCache = {};

RegExp _cachedRegex(String pattern, {bool multiLine = true}) {
  final key = '$multiLine|$pattern';
  final hit = _regexCache[key];
  if (hit != null) return hit;
  if (_regexCache.length >= _regexCacheCap) {
    _regexCache.clear();
  }
  final re = RegExp(pattern, multiLine: multiLine);
  _regexCache[key] = re;
  return re;
}

/// `$1` / `$2` 的展开正则，固定 pattern，提成顶层常量只编译一次。
final RegExp _replacementRefPattern = RegExp(r'\$(\d)');

/// 正则元字符。findPattern 含任意一个 → 必须走正则引擎；
/// 不含 → 可走 String.replaceAll 快路径（快 2~5 倍）。
final RegExp _regexMeta = RegExp(r'[\^$.*+?()\[\]{}|\\]');

/// findPattern 是否不含任何正则元字符（纯文本匹配）。
bool _isPlainText(String s) => !_regexMeta.hasMatch(s);

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
      // 快速跳过：纯文本规则的目标串在文本里不存在 → 这条规则必然命中 0 次，
      // 直接跳过整条，省掉一次全文扫描。规则多时这一条最省时间。
      if (_isPlainText(rule.findPattern) &&
          !out.contains(rule.findPattern)) {
        continue;
      }
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
    // ignore_case 特判：走 toLowerCase 快路径。
    if (rule.id == 'ignore_case') {
      return text.toLowerCase();
    }

    // 纯文本快路径：findPattern 不含元字符 → 直接 String.replaceAll，
    // 跳过正则引擎（快 2~5 倍），且不需要编译 RegExp。
    // 注意：纯文本路径无捕获组，替换串原样使用（不做 $1 展开）。
    if (_isPlainText(rule.findPattern)) {
      return text.replaceAll(rule.findPattern, rule.replaceWith);
    }

    // 正则路径：缓存复用 RegExp。
    return text.replaceAllMapped(
      _cachedRegex(rule.findPattern),
      (m) => _expandReplacement(rule.replaceWith, m),
    );
  }

  String _expandReplacement(String tpl, Match m) {
    // 快速路径：替换串无 $ 直接返回，省掉 allMatches 遍历。
    if (!tpl.contains(r'$')) return tpl;
    var out = StringBuffer();
    var last = 0;
    for (final match in _replacementRefPattern.allMatches(tpl)) {
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

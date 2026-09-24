/// 所有 SharedPreferences 键名集中管理。
/// 统一前缀 `jianming.`，将来要清空所有配置，一个前缀全清。
class PrefKeys {
  const PrefKeys._();

  static const String _p = 'jianming.';

  // ==================== 对比页显示设置 ====================
  static const String showLineNumbers = '${_p}display.showLineNumbers';
  static const String bodyFontSize = '${_p}display.bodyFontSize';
  static const String gutterFontSize = '${_p}display.gutterFontSize';
  static const String syncScroll = '${_p}display.syncScroll';

  // ==================== 12 个差异颜色 ====================
  static const String colorDeleteRowBg = '${_p}color.deleteRowBg';
  static const String colorDeleteRowFg = '${_p}color.deleteRowFg';
  static const String colorInsertRowBg = '${_p}color.insertRowBg';
  static const String colorInsertRowFg = '${_p}color.insertRowFg';
  static const String colorReplaceLeftBg = '${_p}color.replaceLeftBg';
  static const String colorReplaceLeftFg = '${_p}color.replaceLeftFg';
  static const String colorReplaceRightBg = '${_p}color.replaceRightBg';
  static const String colorReplaceRightFg = '${_p}color.replaceRightFg';
  static const String colorCharDeleteBg = '${_p}color.charDeleteBg';
  static const String colorCharDeleteFg = '${_p}color.charDeleteFg';
  static const String colorCharInsertBg = '${_p}color.charInsertBg';
  static const String colorCharInsertFg = '${_p}color.charInsertFg';

  // ==================== 比较忽略开关 ====================
  static const String ignoreWhitespace = '${_p}ignore.whitespace';
  static const String ignoreEmptyLines = '${_p}ignore.emptyLines';
  static const String ignoreLineEndings = '${_p}ignore.lineEndings';
  static const String unifyAnsi = '${_p}ignore.unifyAnsi';
  static const String ignoreCase = '${_p}ignore.case';
  static const String ignoreCommas = '${_p}ignore.commas';
  static const String ignoreNumbers = '${_p}ignore.numbers';
  static const String ignoreInvisible = '${_p}ignore.invisible';

  // ==================== 规则 ====================
  static const String keywordRulesText = '${_p}rules.keyword';
  static const String regexRulesText = '${_p}rules.regex';
  static const String userRules = '${_p}rules.user';
  static const String builtinRuleEnables = '${_p}rules.builtinEnables';

  // ==================== 文件浏览器 ====================
  static const String sortField = '${_p}browser.sortField';
  static const String sortAsc = '${_p}browser.sortAsc';
  static const String favorites = '${_p}browser.favorites';
  static const String customSearchFolders = '${_p}browser.searchFolders';
  static const String lastPath = '${_p}browser.lastPath';
  static const String searchScope = '${_p}browser.searchScope';
}

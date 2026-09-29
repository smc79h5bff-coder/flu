/// 所有 SharedPreferences 键名集中管理。
/// 统一前缀 `jianming.`，将来要清空所有配置，一个前缀全清。
class PrefKeys {
  const PrefKeys._();

  static const String _p = 'jianming.';

  static const String comparisonNotes = 'comparison_notes';

  // ==================== 对比页显示设置 ====================
  static const String showLineNumbers = '${_p}display.showLineNumbers';
  static const String bodyFontSize = '${_p}display.bodyFontSize';
  static const String gutterFontSize = '${_p}display.gutterFontSize';
  static const String syncScroll = '${_p}display.syncScroll';
static const String contextFontSize = '${_p}display.contextFontSize';
  static const String defaultViewMode = '${_p}viewer.defaultViewMode';
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

  // ==================== 规则 ====================
  static const String keywordRulesText = '${_p}rules.keyword';
  static const String regexRulesText = '${_p}rules.regex';
  static const String userRules = '${_p}rules.user';
  static const String builtinRuleEnables = '${_p}rules.builtinEnables';
  static const String ruleFlagHelp = '${_p}rules.flagHelp';
  static const String ruleOrder = '${_p}rules.order';

  /// 规则表（普通文字）的详细说明（用户可编辑，为空表示用默认）。
  static const String keywordRulesHelp = '${_p}rules.keywordHelp';

  /// 规则表（支持正则）的详细说明（用户可编辑，为空表示用默认）。
  static const String regexRulesHelp = '${_p}rules.regexHelp';

  // ==================== 对比页按钮栏 ====================
  static const String toolbarRules = '${_p}toolbar.rules';
  static const String toolbarOrder = '${_p}toolbar.order';

  /// 按钮独立颜色：Map<ruleId, {bg, fg, border}>。
  static const String toolbarButtonColors = '${_p}toolbar.buttonColors';

  // ==================== 查找 / 搜索历史 ====================
  static const String findHistory = '${_p}viewer.findHistory';
  static const String browserSearchHistory = '${_p}browser.searchHistory';

  // ==================== 文件浏览器 ====================
  static const String sortField = '${_p}browser.sortField';
  static const String sortAsc = '${_p}browser.sortAsc';
  static const String favorites = '${_p}browser.favorites';
  static const String customSearchFolders = '${_p}browser.searchFolders';
  static const String lastPath = '${_p}browser.lastPath';
  static const String searchScope = '${_p}browser.searchScope';
}

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
// 跨行块视图的上下文行数（0 = 仅差异块）
static const groupedContextLines = 'groupedContextLines';
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
// 跨行块视图专属颜色
static const colorGroupedEqualIgnoringWsBg = 'colorGroupedEqualIgnoringWsBg';
static const colorGroupedWsHighlight = 'colorGroupedWsHighlight';
static const colorGroupedFindYellow = 'colorGroupedFindYellow';
static const colorGroupedFindPink = 'colorGroupedFindPink';
  // ==================== 规则 ====================
  static const String keywordRulesText = '${_p}rules.keyword';
  static const String regexRulesText = '${_p}rules.regex';
  static const String userRules = '${_p}rules.user';
  static const String builtinRuleEnables = '${_p}rules.builtinEnables';
  static const String ruleFlagHelp = '${_p}rules.flagHelp';
  static const String ruleOrder = '${_p}rules.order';
  static const String builtinRuleNameOverrides =
      '${_p}rules.builtinNameOverrides';

  static const String builtinRuleHidden = '${_p}rules.builtinHidden';

  /// 规则表（普通文字）的详细说明（用户可编辑，为空表示用默认）。
  static const String keywordRulesHelp = '${_p}rules.keywordHelp';

  /// 规则表（支持正则）的详细说明（用户可编辑，为空表示用默认）。
  static const String regexRulesHelp = '${_p}rules.regexHelp';

  // ==================== 对比页按钮栏 ====================
  static const String toolbarRules = '${_p}toolbar.rules';
  static const String toolbarOrder = '${_p}toolbar.order';
  // ==================== 行编辑器按钮栏 ====================
  static const String lineEditorRules = '${_p}lineEditor.rules';
  static const String lineEditorOrder = '${_p}lineEditor.order';
  static const String lineEditorButtonColors =
      '${_p}lineEditor.buttonColors';
  /// 按钮独立颜色：Map<ruleId, {bg, fg, border}>。
  static const String toolbarButtonColors = '${_p}toolbar.buttonColors';

  // ==================== 查找 / 搜索历史 ====================
  static const String findHistory = '${_p}viewer.findHistory';
  static const String browserSearchHistory = '${_p}browser.searchHistory';
static const String searchSortField = 'jianming.browser.searchSortField';
static const String searchSortAsc = 'jianming.browser.searchSortAsc';
  static const String searchBoxMode = 'jianming.browser.searchBoxMode';
static const String filterDepth = 'jianming.browser.filterDepth';
  // ==================== 文件浏览器 ====================
  static const String sortField = '${_p}browser.sortField';
  static const String recentMoveTargets = '${_p}browser.recentMoveTargets';
  static const String sortAsc = '${_p}browser.sortAsc';
  static const String favorites = '${_p}browser.favorites';
  static const String customSearchFolders = '${_p}browser.searchFolders';
  static const String lastPath = '${_p}browser.lastPath';
  static const String searchScope = '${_p}browser.searchScope';
  static const String fileOpenMode = '${_p}browser.fileOpenMode';
static const String browserSettingsHelp = 'jianming.browser.settingsHelp';
  // ==================== 文件浏览器 · 标记 ====================
  /// 标记模式下点击文件时是否弹颜色面板。
  static const String browserMarkShowPicker = '${_p}browser.markShowPicker';

  /// 标记默认颜色（ARGB int 十进制字符串）。
  static const String browserMarkDefaultColor = '${_p}browser.markDefaultColor';

  /// 标记默认不透明度（0.01~1.0）。
  static const String browserMarkDefaultOpacity = '${_p}browser.markDefaultOpacity';

  /// 标记预设色（ARGB int 十进制字符串，逗号分隔）。
  static const String browserMarkPresetColors = '${_p}browser.markPresetColors';

  /// 收藏的文件（持久化）。
  static const String fileBookmarks = '${_p}browser.fileBookmarks';

  /// 收藏列表弹窗里路径显示模式：filenameOnly / oneLinePath / fullPath。
  static const String browserBookmarkDisplayMode =
      '${_p}browser.bookmarkDisplayMode';

  /// 搜索框是否收起。false = 展开（默认），true = 收起。
  /// 记住用户上次的选择，重启后恢复。
  static const String browserSearchBarCollapsed =
      '${_p}browser.searchBarCollapsed';

  // ==================== 文件浏览器 · 视图 ====================
  /// 是否网格模式。false = 列表（默认），true = 网格。
  static const String browserGridMode = '${_p}browser.gridMode';

  /// 网格模式下是否显示文件大小。
  static const String browserGridShowSize = '${_p}browser.gridShowSize';

  /// 网格模式下是否显示修改时间。
  static const String browserGridShowTime = '${_p}browser.gridShowTime';

  // ---- 4 个字号（范围 1~38） ----

  /// 列表模式：文件名字号。
  static const String browserFontListName = '${_p}browser.fontListName';

  /// 列表模式：大小/时间字号。
  static const String browserFontListMeta = '${_p}browser.fontListMeta';

  /// 网格模式：文件名字号。
  static const String browserFontGridName = '${_p}browser.fontGridName';

  /// 网格模式：大小/时间字号。
  static const String browserFontGridMeta = '${_p}browser.fontGridMeta';

  // ---- 滚动条 ----

  /// 文件浏览器右侧滚动条宽度（像素）。
  static const String browserScrollbarWidth =
      '${_p}browser.scrollbar.width';

  /// 滚动条轨道颜色（ARGB int 十进制）。
  static const String browserScrollbarTrackColor =
      '${_p}browser.scrollbar.trackColor';

  /// 滚动条轨道透明度（0~1，叠加在 trackColor 上）。
  static const String browserScrollbarTrackOpacity =
      '${_p}browser.scrollbar.trackOpacity';

  /// 滚动条滑块颜色（ARGB int 十进制）。
  static const String browserScrollbarThumbColor =
      '${_p}browser.scrollbar.thumbColor';

  /// 滚动条滑块透明度（0~1，叠加在 thumbColor 上）。
  static const String browserScrollbarThumbOpacity =
      '${_p}browser.scrollbar.thumbOpacity';

  // ---- 上翻页按钮 ----

  static const String browserPageUpEnabled =
      '${_p}browser.pageUp.enabled';
  static const String browserPageUpColor =
      '${_p}browser.pageUp.color';
  static const String browserPageUpOpacity =
      '${_p}browser.pageUp.opacity';
  static const String browserPageUpSize =
      '${_p}browser.pageUp.size';
  static const String browserPageUpSquare =
      '${_p}browser.pageUp.square';
  static const String browserPageUpX =
      '${_p}browser.pageUp.x';
  static const String browserPageUpY =
      '${_p}browser.pageUp.y';

  // ---- 下翻页按钮 ----

  static const String browserPageDownEnabled =
      '${_p}browser.pageDown.enabled';
  static const String browserPageDownColor =
      '${_p}browser.pageDown.color';
  static const String browserPageDownOpacity =
      '${_p}browser.pageDown.opacity';
  static const String browserPageDownSize =
      '${_p}browser.pageDown.size';
  static const String browserPageDownSquare =
      '${_p}browser.pageDown.square';
  static const String browserPageDownX =
      '${_p}browser.pageDown.x';
  static const String browserPageDownY =
      '${_p}browser.pageDown.y';

  // ---- 搜索结果列表 ----

  /// 搜索结果页是否显示第二行（大小 + 时间）。
  static const String browserSearchShowMeta =
      '${_p}browser.search.showMeta';

  /// 搜索结果页是否显示第三行（路径）。
  static const String browserSearchShowPath =
      '${_p}browser.search.showPath';

  /// 搜索结果页文件名字号。
  static const String browserSearchFontName =
      '${_p}browser.search.fontName';

  /// 搜索结果页 meta / path 字号。
  static const String browserSearchFontMeta =
      '${_p}browser.search.fontMeta';
}

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';

/// 文件浏览器排序字段。
enum SortField { name, modified, size }

/// 搜索范围。
enum SearchScope { currentRecursive, custom }

/// 点击文本文件时的打开方式。
enum FileOpenMode {
  /// 阅读器：分页翻页，看小说用。
  reader,

  /// 旧编辑器：单个大 TextField，功能全，大文件卡。
  editor,

  /// 行编辑器：ListView.builder 虚拟化，大文件流畅。
  lineEditor,

  /// 每次弹窗问一次。
  ask,
}

final fileOpenModeProvider =
    NotifierProvider<FileOpenModeNotifier, FileOpenMode>(
  FileOpenModeNotifier.new,
);

class FileOpenModeNotifier extends EnumPrefNotifier<FileOpenMode> {
  FileOpenModeNotifier()
      : super(
          key: PrefKeys.fileOpenMode,
          values: FileOpenMode.values,
          initial: FileOpenMode.reader,
        );
}

/// 排序方式（持久化）。
final sortFieldProvider =
    NotifierProvider<SortFieldNotifier, SortField>(SortFieldNotifier.new);

class SortFieldNotifier extends EnumPrefNotifier<SortField> {
  SortFieldNotifier()
      : super(
          key: PrefKeys.sortField,
          values: SortField.values,
          initial: SortField.name,
        );
}

/// 排序方向（持久化）。
final sortAscProvider =
    NotifierProvider<SortAscNotifier, bool>(SortAscNotifier.new);

class SortAscNotifier extends BoolPrefNotifier {
  SortAscNotifier() : super(key: PrefKeys.sortAsc, initial: true);
}

/// 收藏夹目录（持久化）。
final favoritesProvider =
    NotifierProvider<FavoritesNotifier, List<String>>(FavoritesNotifier.new);

class FavoritesNotifier extends StringListPrefNotifier {
  FavoritesNotifier() : super(key: PrefKeys.favorites);

  bool contains(String path) => state.contains(path);

  void toggle(String path) {
    if (state.contains(path)) {
      update(state.where((p) => p != path).toList());
    } else {
      update([...state, path]);
    }
  }

  void remove(String path) {
    update(state.where((p) => p != path).toList());
  }
}

/// 最近移动/复制到的目录（持久化）。
final recentMoveTargetsProvider =
    NotifierProvider<RecentMoveTargetsNotifier, List<String>>(
  RecentMoveTargetsNotifier.new,
);

class RecentMoveTargetsNotifier extends StringListPrefNotifier {
  RecentMoveTargetsNotifier() : super(key: PrefKeys.recentMoveTargets);

  static const int _max = 10;

  void add(String path) {
    if (path.isEmpty) return;
    final next = <String>[path, ...state.where((s) => s != path)];
    if (next.length > _max) next.removeRange(_max, next.length);
    update(next);
  }

  void remove(String path) {
    update(state.where((s) => s != path).toList());
  }
}

/// 自定义搜索文件夹（持久化）。
final customSearchFoldersProvider =
    NotifierProvider<CustomSearchFoldersNotifier, List<String>>(
  CustomSearchFoldersNotifier.new,
);

class CustomSearchFoldersNotifier extends StringListPrefNotifier {
  CustomSearchFoldersNotifier() : super(key: PrefKeys.customSearchFolders);

  void setAll(List<String> folders) => update(List<String>.from(folders));
}

/// 上次浏览的路径（持久化）。
final lastPathProvider =
    NotifierProvider<LastPathNotifier, String>(LastPathNotifier.new);

class LastPathNotifier extends StringPrefNotifier {
  LastPathNotifier() : super(key: PrefKeys.lastPath);
}

/// 搜索范围（持久化）。
final searchScopeProvider =
    NotifierProvider<SearchScopeNotifier, SearchScope>(
  SearchScopeNotifier.new,
);

class SearchScopeNotifier extends EnumPrefNotifier<SearchScope> {
  SearchScopeNotifier()
      : super(
          key: PrefKeys.searchScope,
          values: SearchScope.values,
          initial: SearchScope.currentRecursive,
        );
}

// ==================== 搜索历史（持久化） ====================

/// 上限 30 条，去重（最新在前）。
final browserSearchHistoryProvider =
    NotifierProvider<BrowserSearchHistoryNotifier, List<String>>(
  BrowserSearchHistoryNotifier.new,
);

class BrowserSearchHistoryNotifier extends StringListPrefNotifier {
  BrowserSearchHistoryNotifier()
      : super(key: PrefKeys.browserSearchHistory);

  static const int _max = 30;

  void add(String q) {
    if (q.trim().isEmpty) return;
    final next = <String>[q, ...state.where((s) => s != q)];
    if (next.length > _max) next.removeRange(_max, next.length);
    update(next);
  }

  void remove(String q) {
    update(state.where((s) => s != q).toList());
  }
}

// ==================== 视图 · 网格模式（持久化） ====================

/// 是否网格模式。false = 列表（默认），true = 网格。
final browserGridModeProvider =
    NotifierProvider<BrowserGridModeNotifier, bool>(
  BrowserGridModeNotifier.new,
);

class BrowserGridModeNotifier extends BoolPrefNotifier {
  BrowserGridModeNotifier()
      : super(key: PrefKeys.browserGridMode, initial: false);
}

// ==================== 视图 · 网格显示内容（持久化） ====================

/// 网格模式是否显示文件大小。
final browserGridShowSizeProvider =
    NotifierProvider<BrowserGridShowSizeNotifier, bool>(
  BrowserGridShowSizeNotifier.new,
);

class BrowserGridShowSizeNotifier extends BoolPrefNotifier {
  BrowserGridShowSizeNotifier()
      : super(key: PrefKeys.browserGridShowSize, initial: true);
}

/// 网格模式是否显示修改时间。
final browserGridShowTimeProvider =
    NotifierProvider<BrowserGridShowTimeNotifier, bool>(
  BrowserGridShowTimeNotifier.new,
);

class BrowserGridShowTimeNotifier extends BoolPrefNotifier {
  BrowserGridShowTimeNotifier()
      : super(key: PrefKeys.browserGridShowTime, initial: true);
}

// ==================== 视图 · 字号（持久化） ====================
//
// 全部范围 1~38。写入时 clamp。
// 用 double 存储（支持将来小数），显示时取整。

/// 列表模式：文件名字号。
final browserFontListNameProvider =
    NotifierProvider<BrowserFontListNameNotifier, double>(
  BrowserFontListNameNotifier.new,
);

class BrowserFontListNameNotifier extends DoublePrefNotifier {
  BrowserFontListNameNotifier()
      : super(key: PrefKeys.browserFontListName, initial: 15);

  void set(double v) => update(v.clamp(1.0, 38.0));
}

/// 列表模式：大小/时间字号。
final browserFontListMetaProvider =
    NotifierProvider<BrowserFontListMetaNotifier, double>(
  BrowserFontListMetaNotifier.new,
);

class BrowserFontListMetaNotifier extends DoublePrefNotifier {
  BrowserFontListMetaNotifier()
      : super(key: PrefKeys.browserFontListMeta, initial: 11);

  void set(double v) => update(v.clamp(1.0, 38.0));
}

/// 网格模式：文件名字号。
final browserFontGridNameProvider =
    NotifierProvider<BrowserFontGridNameNotifier, double>(
  BrowserFontGridNameNotifier.new,
);

class BrowserFontGridNameNotifier extends DoublePrefNotifier {
  BrowserFontGridNameNotifier()
      : super(key: PrefKeys.browserFontGridName, initial: 14);

  void set(double v) => update(v.clamp(1.0, 38.0));
}

/// 网格模式：大小/时间字号。
final browserFontGridMetaProvider =
    NotifierProvider<BrowserFontGridMetaNotifier, double>(
  BrowserFontGridMetaNotifier.new,
);

class BrowserFontGridMetaNotifier extends DoublePrefNotifier {
  BrowserFontGridMetaNotifier()
      : super(key: PrefKeys.browserFontGridMeta, initial: 11);

  void set(double v) => update(v.clamp(1.0, 38.0));
}

// ==================== 搜索结果排序（独立于浏览排序） ====================
//
// 只管"搜索结果列表"的顺序，不动文件浏览器本身。
// 和 sortFieldProvider / sortAscProvider 完全独立，互不影响。

final searchSortFieldProvider =
    NotifierProvider<SearchSortFieldNotifier, SortField>(
  SearchSortFieldNotifier.new,
);

class SearchSortFieldNotifier extends EnumPrefNotifier<SortField> {
  SearchSortFieldNotifier()
      : super(
          key: PrefKeys.searchSortField,
          values: SortField.values,
          initial: SortField.name,
        );
}

final searchSortAscProvider =
    NotifierProvider<SearchSortAscNotifier, bool>(
  SearchSortAscNotifier.new,
);

class SearchSortAscNotifier extends BoolPrefNotifier {
  SearchSortAscNotifier()
      : super(key: PrefKeys.searchSortAsc, initial: true);
}

// ==================== 浏览器设置 · 说明文档（Tab 化） ====================

class BrowserHelpTab {
  const BrowserHelpTab({
    required this.id,
    required this.title,
    required this.content,
  });

  final String id;
  final String title;
  final String content;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
      };

  factory BrowserHelpTab.fromJson(Map<String, dynamic> j) => BrowserHelpTab(
        id: j['id'] as String? ??
            'tab_${DateTime.now().microsecondsSinceEpoch}',
        title: j['title'] as String? ?? '未命名',
        content: j['content'] as String? ?? '',
      );

  BrowserHelpTab copyWith({String? title, String? content}) => BrowserHelpTab(
        id: id,
        title: title ?? this.title,
        content: content ?? this.content,
      );
}

final browserSettingsHelpProvider =
    NotifierProvider<BrowserSettingsHelpNotifier, List<BrowserHelpTab>>(
  BrowserSettingsHelpNotifier.new,
);

class BrowserSettingsHelpNotifier
    extends PersistentNotifier<List<BrowserHelpTab>> {
  @override
  String get key => PrefKeys.browserSettingsHelp;

  @override
  List<BrowserHelpTab> get defaultValue => defaultBrowserHelpTabs();

  @override
  List<BrowserHelpTab> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    final tabs = list
        .map((e) => BrowserHelpTab.fromJson(e as Map<String, dynamic>))
        .toList();
    return tabs.isEmpty ? defaultBrowserHelpTabs() : tabs;
  }

  @override
  String encode(List<BrowserHelpTab> value) =>
      jsonEncode(value.map((e) => e.toJson()).toList());

  void setAll(List<BrowserHelpTab> tabs) => update(List.from(tabs));
}

// ==================== 默认 Tab 内容 ====================

List<BrowserHelpTab> defaultBrowserHelpTabs() => const [
      BrowserHelpTab(id: 'general', title: '通用', content: _helpGeneral),
      BrowserHelpTab(id: 'browser', title: '浏览器', content: _helpBrowser),
      BrowserHelpTab(id: 'diff', title: '对比页', content: _helpDiff),
      BrowserHelpTab(id: 'reader', title: '阅读页', content: _helpReader),
    ];

const String _helpGeneral = r'''
【怎么对比两份文档】

  1. 进文件浏览器，找到两份文件所在的目录
  2. 长按第一个文件 → 进入选择模式
  3. 点第二个文件，把它也选上
  4. 底部"对比"按钮亮起，点它开始对比

【各页面的关系】

  浏览器  ──── 选两个文件，点对比 ────▶  对比页
                                          ▲
  阅读器  ──── 从浏览器点文本文件进入     │
  行编辑器 ─── 从阅读器菜单进入 ─────────┘
                                          ▲
                                    对比页可进
                                    "编辑对比中的两个文档"
                                    （双栏编辑页）

【支持的文件格式】

  · TXT（任意编码）
  · DOCX（Office Open XML）
  · PDF（暂未实现，选 PDF 会提示）

【支持的编码（自动识别）】

  UTF-8 / UTF-8 BOM / UTF-16 LE / UTF-16 BE /
  GBK / GB18030 / Big5 / Shift-JIS / ASCII

  识别错了，可以在阅读器菜单 → 编码 里手动改。

【多份文件批量处理】

  阅读器可以一次打开一整个目录里的所有文本文件。
  点"上一文件 / 下一文件"切换，进度自动保存。
  删文件后自动跳下一个，删光自动返回浏览器。

【配置导入导出】

  菜单 → 导出配置 / 导入配置，把全部设置存成一个 JSON。
  导入后需要重启 App 才生效。

  导入不会覆盖这几项：
    · 浏览器收藏夹
    · 最近移动记录
    · 搜索范围、当前路径、排序方式
    · 查找历史
    · 按钮颜色

  这些是设备/路径相关的，换设备没意义。
''';

const String _helpBrowser = r'''
【长按藏着什么】

  · 长按顶部标题          → 弹"跳转到目录"，粘路径直接跳
  · 长按任一文件 / 文件夹  → 进选择模式
  · 选择模式下长按另一项   → 区间全选
                             （第一次按的是起点，第二次是终点）

【顶栏两个图标是干嘛的】

  · 星标 = 收藏 / 取消收藏【当前目录】
    不是收藏选中的文件——这是最容易搞错的地方。

  · tune（旋钮）= 进"比较设置"
    跟浏览器本身没关系，是给对比页用的预处理规则。

【网格模式 vs 列表模式】

  列表模式：zip 可以就地展开
  网格模式：不能展开，点 zip 直接交给系统 App

  网格模式三条视觉规则：

    · 打不开的文件格子底色是灰的
      包括图片、视频、音乐、压缩包这类非文本文件

    · 超过 3 MB 的文本文件，后缀名变浅灰
      提醒"这文件大，打开会慢"

    · 大文本文件名主体加粗，后缀变灰，对比明显

【底部按钮什么时候亮】

  选 2 个  → 对比、MD5对比
  选 1 个  → 属性、重命名、复制路径、打开方式、导出清单
  选 1+ 个 → 分享、移动、复制、删除

  特殊限制：
    · 文件夹不能"打开方式"
    · zip 内文件不能 重命名 / 移动 / 复制 / 删除

【搜索范围两种颜色】

  当前目录及子目录  → 黄系（#D8C775 底 / #B79800 强调）
  自定义范围        → 蓝系（#93D6F0 底 / #009EDD 强调）

  颜色会同时影响：
    · 搜索按钮的底色
    · 搜索按钮的图标
    · 输入框的边框
    · 光标颜色
    · 右侧历史/清空图标

  输入框有字时搜索按钮才能点，没字时是灰的。

【"管理搜索范围"弹窗：一行四个区域，点法不同】

  ┌───┬────┬──────────┬───┐
  │ ☑ │ 📁 │  文件夹名 │ > │
  └───┴────┴──────────┴───┘
    ↑    ↑        ↑       ↑
   只勾  只勾    进目录   永远进
   不进  不进    (区间模式下    目录
                 变成选起/终点)

  具体：
    · 点最左边勾选框       → 只勾选 / 取消，不进目录
    · 点文件夹图标         → 同勾选框
    · 点文件夹名字         → 默认进目录
                             开了区间模式后变成选起点/终点
    · 点最右边 > 箭头      → 永远进目录，不受区间模式影响

【区间选择三步】

  1. 点底部"区间"胶囊按钮（变蓝）
  2. 点起点行的【名字】（不是勾选框，不是箭头）
  3. 点终点行的【名字】

  中间的所有文件夹一次全部勾上，自动退出区间模式。

  中间改主意：再点一次"区间"按钮退出。

  注意：
    · 只对当前屏幕可见的行生效
    · 勾一部分后可以进别的目录继续勾
    · 最后点"确定"保存全部

【其他按钮】

  全选：勾/取消当前这一层的所有子文件夹
       只影响当前层，不影响已勾选的其他目录

  已勾选 N 个 · 查看：
       列出所有已勾选，可单条移除

  顶部路径框 + 箭头：
       粘贴完整路径直接跳

  顶部 ↑ 按钮：返回上一级

【压缩包】

  列表模式点 zip → 就地展开
  展开后搜索栏下方出现蓝条："已展开 N 个 · 全部收起"

  以下情况不展开，直接交系统 App：
    · 加密的 zip（读文件头就能判断，不解压）
    · 超过 50 MB 的 zip
    · 7z / rar / dzip / iso / tz / gz / pdf / doc / docx / epub
      这些是"强制系统选择器"的格式，不弹二选一菜单

【搜索的边界】

  · 自动跳过 /Android/data 和 /Android/obb
    （Android 11+ 这两目录读不到，避免无意义报错）
  · 最多 500 条结果
  · 输入框右边 🕘 是搜索历史（可删）
  · 扫描时搜索栏下方会出现"取消"按钮，可中断

【搜索结果排序是独立的】

  "搜索结果排序"只影响结果列表的顺序，
  不会影响文件浏览器本身按什么排。

  搜索设置弹窗里改完立刻重排，不用重扫。

【图标颜色（按扩展名分组）】

  蓝色 = 文本文件（.txt / .md / .json 等）
         和压缩包（.zip / .tar / .tar.gz / .tgz）

  橙色 = 图片 / 视频 / 音频 / 二进制

  灰色 = 其它

  选中边框颜色：
    列表模式      紫描边
    搜索结果      粉描边
    网格模式      粉底 + 紫框

【菜单里的"当前目录信息"】

  不是简单列文件。算的是：

    · 总项数
    · 文件夹数 / 文件数
    · 总大小（【不含子目录】，标注清楚防止误解）
    · 最大文件、最新文件、最旧文件
    · 当前排序、显示模式
    · 类型分布（放最底部）

  惰性 stat 期间（size 还没填上）会标"部分未统计"。

【技术细节】

  · 目录缓存：LRU，200 条上限，按"路径+排序+方向"分 key。
    切回之前的目录秒开。

  · 隐藏文件过滤：名字以 `.` 开头的文件和目录，永远不显示，
    无开关。

  · 打开 zip 时会修复乱码文件名：
    老 Windows / WinRAR 打的 zip，文件名是 GBK 字节但没设
    UTF-8 标记位。archive 包默认按 latin1 解会乱码。
    这里按 latin1 反推回字节，再试 UTF-8、GBK。

  · tar 自己解析（不用 archive 包的 TarDecoder），
    多了文件名编码回退：UTF-8 → GBK → latin1。
    支持 ustar prefix 和 GNU LongName。

  · 目录加载三阶段：
    1. list 拿文件名（无 size/mtime）→ 立即回调 UI
    2. 分批 stat（每批 500 个）→ 边 stat 边回调
    3. 全部完成 → 最终回调
''';

const String _helpDiff = r'''
【顶栏箭头的长按行为】

  这四个看起来像普通点击的按钮，长按有另一套行为：

    · 上一处差异（↑箭头）→ 长按跳文档【最开头】
    · 下一处差异（↓箭头）→ 长按跳文档【最结尾】
    · 自绘翻屏按钮 ↑↓    → 长按也是跳文档头/尾

  点击是"跳到上一处/下一处差异"或"上下翻一屏"。

【切视图会弹窗问你跳哪】

  不是直接切。有搜索时提供"跳到我搜的那个词"；
  没搜索时提供：
    · 停在我现在看的地方（屏幕第 1 / 2 / 3 行）
    · 屏幕顶部再往上一点
    · 跳到文件最开头

  不弹这个窗的话，切视图后位置会乱，找不到刚才看的地方。
  用了搜索时优先显示"跳到我搜的那个词"。

【替换先攒缓存，不立刻生效】

  "替换当前"和"全部替换"都只是改缓存，屏幕暂时不变。
  要【点"应用并刷新"】才真正重算。

  好处：连续替换多个词时，不用每次等重算。
  改完最后点一次"应用并刷新"，一次生效，速度快很多。

  关闭查找栏时如果还有没应用的替换，会弹窗三选一：
    取消 / 放弃 / 应用并关闭。

【查找栏的选项】

  查左侧 / 查右侧：至少要开一个
                   关掉某一侧就不在那一侧查找替换

  正则：开启后查找串按正则解析，替换串里能用 $1 $2
       长按"正则"按钮打开正则速查页

  忽略大小写：A 和 a 视为相同

  整词：只匹配完整英文单词，【对中文无效】

【替换串的展开规则】

  正则开启时：
    $0 = 整个匹配到的内容
    $1 $2 = 捕获组

  正则关闭时：
    按字面替换，$ 和 \ 不当特殊符号

【按钮栏（视图切换下方）】

  · 点按钮     → 弹窗选这条规则用在哪侧（左/右/两侧）
  · 长按按钮   → 编辑这条规则
  · + 图标     → 新建按钮
  · 排序图标   → 拖动排序，也可以在这里给按钮设颜色
  · 按钮颜色   → 每个按钮可单独设背景色、文字色、边框色

  按钮栏左边是自定义按钮，可左右滑动。
  右边两个固定：新建、排序。

【长按任意一行】

  弹"编辑此行"。可以改左右任一侧内容，改完立即重算。
  位置会自动保持在原来附近。

  长按的判定：
    · 有配对（左删右增）→ 两侧都能改
    · 纯增行 → 只改右侧
    · 纯删行 → 只改左侧
    · 相同行 → 左右都能改

【导出差异 = 导出"独有片段"，不是完整行】

  做的是字符级比对。一个词、一句话可能被切开，
  只把"变化的那几个字"拿出来。

  同一行有两处改动，会输出两行。
  例：
    左：今天我回来是要吃饭的。
    右：明天我回来是要吃饭的。
    左侧导出：今
    右侧导出：明

  想看完整句子的对照，请回对比页用"并排"或"合并"视图。

  导出的 txt 文件里带一段说明头，说明每一行是什么。

【显示设置里的 12 种颜色】

  不是随便列的。成对区分：

    整行底 + 整行字：
      左独有行 / 右独有行 / 被改行左 / 被改行右   = 8 种

    行内底 + 行内字：
      删字 / 增字   = 4 种

  点色块可改，支持拖色板或直接输入 #RRGGBB。

  差异颜色会影响：
    · 差异行 + 上下文视图
    · 仅差异行视图
    · 并排视图
    · 合并视图

【三个点菜单里的其他项】

  · 编辑对比中的 2 个文档    → 进双栏编辑页
  · 导出差异为 txt           → 选导出左边还是右边
  · 删除左边 / 右边文件       → 从磁盘删，弹窗显示路径、大小、时间
  · 显示设置                 → 行号、字号、12 种颜色
  · 比较设置                 → 规则管理
  · 不换行                   → 超长行不折行，各半屏里左右滑
  · 诊断                     → 性能、文件、耗时、历史
  · 横屏 / 竖屏              → 切换方向
  · 默认打开视图             → 下次进对比页默认用哪个视图

【不换行模式】

  只对"合并"（上下）视图生效，需要左右横向滑动。
  并排视图本来就是两栏，各自处理。

  开启后会计算最长行的宽度，撑开横向滚动区。

【编码不同的黄横幅】

  两份文件编码不同时出现。
  已经分别解码后对比，不用管。

【诊断】

  三个点 → 诊断。四个开关：

    · 性能  → 最近一次 diff 的耗时与行数
    · 文件  → 两份文件的行数、特殊字符统计、前 20 行预览
    · 耗时  → 本次渲染各阶段的耗时明细
    · 历史  → 本次会话的操作记录

  开了之后才能点进去看。平时不用开，排查问题才用。

【技术细节】

  · Diff 算法：
    先用公共前后缀剥掉两端，剩下的中间部分：
      · 唯一行数 < 6000 → 用 diff_match_patch 的位运算加速
        （把行号编码成 PUA 字符，一个字符代表一行）
      · 唯一行数 ≥ 6000 → 用耐心 diff
        先找"两边都只出现一次"的行当锚点，把问题切成小块
        对小说这类每行几乎唯一的文本，比 Myers 快 100 倍

  · 跑在独立 isolate 里（compute），主线程不卡。

  · 行高表：按"内容指纹 + 版本 + 视图 + 屏幕宽 + 字号 + ..." 做 key
    缓存 8 张表，LRU 淘汰。1 万行 ≈ 320KB。

  · 高亮匹配在页级做 Aho-Corasick 一次扫描，按页缓存。
''';

const String _helpReader = r'''
【翻页手势】

  分页模式：
    · 点屏幕              → 下一页
    · 从左往右滑          → 上一页

  滚动模式：
    · 点屏幕              → 往下滚一屏
    · 左右滑              → 上下换屏

【菜单热区】

  默认在屏幕顶部正中一条横带。点了才出菜单——
  这个位置不显眼，容易忘记。

  可以在设置里调它的：
    · 位置（X / Y，0-1 相对屏幕）
    · 大小（宽 / 高，0-1）
    · 颜色、透明度、边框粗细
    · 是否在阅读页画出来

  关掉"显示"后照样能点，只是不画出来。

  样式有两种：整块填色 / 分界线
  分界线模式：贴屏幕边的边框不画（比如热区贴顶时只画下边）

【长按选字】

  按住 400ms 才进入选字。太快松开只是普通点击（翻页）。

  选中后出现两个梯形手柄，可以拖大/拖小范围。
  拖动时上方显示放大镜。

  手柄贴到屏幕底部时会翻到文字上方，避免飘出屏幕。

【色块：点 vs 长按】

  · 点色块     → 用这个色块的高亮（对当前选中文字）
  · 长按色块   → 编辑这个色块（改颜色 / 改名字）

  长按是隐藏入口，容易忘。

  色块支持纯色和上下渐变两种。

【高亮 Tab 的 checklist 图标】

  点击和长按行为不一样：

    · 点击  → 进选择模式（批量删除、批量移入分组）
    · 长按  → 弹"高亮卡片显示设置"
              目前有"显示书名"（在卡片底部显示所属书名）

【高亮卡片 / 书签条目的长按】

  · 高亮卡片：点进编辑，长按进选择
  · 书签条目：点进编辑，长按进选择

  都可以区间选择（跟浏览器里一样：第一次起点，第二次终点）。

【筛选弹窗】

  显示范围两种：

    · 仅本书
    · 全部书籍（第一次加载会慢一下，因为要读所有书的高亮）

  勾选要看的分组，全选 / 管理分组。

【渐变高亮】

  卡片里按实际换行拆成多段，每段独立渐变。
  不是一整块渐变盖过去。

  为什么：渐变是"上到下"的，如果一整块盖过去，
  换行后每行的高度不一样，渐变会被拉长。

  实际渲染：把关键词按实际换行位置切成多行，
  每一行单独渲染一个渐变块。

【搜索页的返回按钮 ≠ 跳转】

  · 点【返回箭头】 = 关闭搜索（清空当前搜索状态），不跳转
  · 点【具体结果行】 = 跳转到那一处

  容易搞错：想跳转要点结果行，别点返回。

【搜索半开条】

  跳转后浮在底部约 10% 高度：
    ↑ N/M ↓ 展开 ✕

  点"展开"回搜索页。
  点 ↑↓ 上下切换结果。
  点 ✕ 关闭搜索状态。

【搜索历史】

  搜索页右上"历史"入口，或者跳转前输入框回车也会记住。
  历史项可以加星标（收藏），收藏项排序时永远在最上面。
  非收藏项最多 100 条。

【上下文件按钮】

  切文件前会自动保存当前进度。
  有提示条显示"第 N/M 个 · 文件名"。

  进度是按【字符偏移】保存的，不是页码。
  因为行号会因字体大小变，字符偏移不变。

【删除文件】

  删完自动跳下一个。删的是目录里最后一个 → 自动返回浏览器。
  删掉的路径会传给浏览器，浏览器从缓存里同步移除。

【浮动按钮】

  三个：上一文件（默认右上）、下一文件（默认右下）、
  删除文件（默认左下）。

  都可以在设置里单独调：
    · 样式：纯色圆 / 圆环
    · 颜色、透明度、大小
    · 位置（X / Y，0-1 相对屏幕）

  选中文字时，浮动按钮会自动淡出到 0，
  不然会盖住底部操作栏。

【安全边距可以填负数】

  分页模式下：
    · 正数：多留白，内容整体往里推
    · 0：贴边
    · 负数：榨空间——多显示一行，但可能裁掉首尾行

  滚动模式下负数按 0 处理。

  范围 -400 ~ +400 像素。

【设置面板里的预览图】

  右上角有个小预览。点它可以放大看，不是装饰。

  预览会实时反映所有参数的改动。

【菜单里的其他项】

  · 进度    → 打开滑块直接跳百分比
  · 查找    → 进全屏搜索页
  · 加书签  → 当前页首加一条
  · 书签与高亮 → 进管理页
  · 行编辑  → 进行编辑器
  · 编码    → 手动指定编码（自动检测错了时用）
  · 导出加载日志 → 导出本次会话日志
  · 设置    → 打开阅读设置面板
  · 关闭文件 → 返回浏览器

  菜单顶部的文件名 / 路径：
    长按路径可以复制。

【高亮管理页的分组】

  分组是全局共享的（所有书共用一套分组）。
  色块可以设一个"默认分组"，用这个色块加的高亮自动进那个组。

  删除分组时问：
    · 保留高亮，变未分组
    · 连同高亮一起删除

【技术细节】

  · 分页算法：所有行高统一成"单行高"的整数倍。
    分页时以"1 个显示行"为最小单位塞，塞不下就换页。
    每页底部最多留 1 行空白。

  · 超长行会拆成多个渲染单元，每个单元最多 1 行高。

  · 分页先"秒开"：start() 同步估算分页，立即显示。
    后台精修已停用——
      精修只在屏幕有新帧时推进，静止看书几乎不跑；
      每次翻页会偷偷跑 2ms，长期耗电；
      对纯中文小说，估算和精确值差异 < 1 行。

  · 编码检测优先级：
    UTF-8 BOM → UTF-16 BOM → UTF-16 无 BOM 启发式 →
    UTF-8 严格 → GBK → Big5 → Shift-JIS → unknown

    无 BOM 的 UTF-16 检测：看字节的奇/偶位有多少个 0x00。
    ASCII 字符在 UTF-16 里高位字节是 0x00。

  · GBK / Big5 / Shift-JIS 解码：
    小文件一次性解；大文件用 stateful 流式解码器分块，
    解码器自身缓存跨块半个字符。
    任何异常整体回退到逐块独立 decode，绝不闪退。

  · 高亮匹配在页级做 Aho-Corasick 一次扫描。
    正则高亮单独处理，按页面文本匹配，跨行匹配丢弃。

  · 高亮按页缓存，翻回来直接命中。
    改高亮时（增删改）会清空页级缓存。

  · 渐变背景测量用 TextPainter 单例 + LRU 缓存。
    和渲染走同一套 spans 结构，避免单 span 和
    多 span 的 shaping 断点差异导致渐变偏移 1~3 像素。
''';


// ==================== 搜索框行为（搜索 / 过滤） ====================

enum SearchBoxMode { search, filter }

final searchBoxModeProvider =
    NotifierProvider<SearchBoxModeNotifier, SearchBoxMode>(
  SearchBoxModeNotifier.new,
);

class SearchBoxModeNotifier extends EnumPrefNotifier<SearchBoxMode> {
  SearchBoxModeNotifier()
      : super(
          key: PrefKeys.searchBoxMode,
          values: SearchBoxMode.values,
          initial: SearchBoxMode.search,
        );
}

// ==================== 过滤深度 ====================

/// 过滤深度：往下钻几层。0 = 只当前层。范围 0~9。
final filterDepthProvider =
    NotifierProvider<FilterDepthNotifier, int>(FilterDepthNotifier.new);

class FilterDepthNotifier extends PersistentNotifier<int> {
  @override
  String get key => PrefKeys.filterDepth;

  @override
  int get defaultValue => 1;

  @override
  int decode(String raw) => int.tryParse(raw) ?? 1;

  @override
  String encode(int value) => value.toString();

  void set(int v) => update(v.clamp(0, 9));
}


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
## 怎么对比两份文档

1. 进文件浏览器，找到两份文件所在的目录
2. 单击左侧图标(列表模式下) / 长按选中第一个文件 → 进入选择模式
3. 单击第二个文件，把它也选上
4. 底部「对比」按钮亮起，单击开始对比

## 各页面的关系

| 页面 | 如何进入 | 能做什么 |
|------|---------|---------|
| 浏览器 | 打开 App | 选文件、对比、管理文件 |
| 对比页 | 浏览器选 2 个文件点「对比」 | 查看差异、查找替换 |
| 阅读器 | 浏览器点击文本文件 | 阅读文件、向上/下跳转文件、删除文件 |
| 行编辑器 | 浏览器设置 →「行编辑器」 | 按行编辑大文件 |

## 阅读器支持的编码（自动识别）

`UTF-8` · `UTF-8 BOM` · `UTF-16 LE` · `UTF-16 BE` ·
`GBK` · `GB18030` · `Big5` · `Shift-JIS` · `ASCII`

如果识别错了，可以在**阅读器菜单 →「编码」**里手动改。

## 多份文件批量处理

阅读器可以一次打开**一整个目录里的所有文本文件**。

- 单击「上一文件悬浮按钮 / 下一文件悬浮按钮」切换
- 阅读进度自动保存
- 若点击删除按钮，删文件后，阅读器里的内容自动显示下一个文件内容
- 目录里所有文件删光后，自动返回文件浏览器

## APP配置导入导出

菜单 → **导出配置 / 导入配置**。

> **导入后需要重启 App 才生效。**


''';

const String _helpBrowser = r'''
## 长按藏着什么

- 长按**顶部标题** → 弹「跳转到目录」，可粘路径直接跳过去
- 单击左侧图标 / 长按**任一文件 / 文件夹** → 进选择模式
- 在**选择模式下**长按另一项 → 区间全选

## 顶栏两个图标是干嘛的

- **星星** = 收藏 / 取消收藏 **当前目录**
  （不是收藏选中的文件——这是最容易搞错的地方）
- **设置** = 进「对比规则设置」
  （跟浏览器本身没关系，对比文件时处理文本的规则）
- **三个点** = 打开更多菜单

## 网格模式 vs 列表模式

| 模式 | zip 就地展开 | 点 zip 行为 |
|------|:-----------:|-----------|
| 列表 | ✅ 支持 | 就地展开 |
| 网格 | ❌ 不支持 | 交给系统 App |

网格模式的显示规则：

- **打不开的文件**格子底色是灰的
  包括图片、视频、音乐、压缩包这类非文本文件
- **超过 3 MB 的文本文件**，后缀名变浅灰
  提醒"这文件大，打开可能会慢"

特殊限制：

- 文件夹不能使用"打开方式"
- zip 内文件不能 重命名 / 移动 / 复制 / 删除

## 三种搜索模式的颜色

| 范围 | 色调 |
|------|------|
| 当前目录及子目录 | 黄色系 |
| 自定义范围 | 蓝色系 |
| 过滤 | 红色系 |

## 「搜索设置」 - 「管理搜索范围」弹窗：一行四个区域

每行长这样：

```

[☑] [📁]  文件夹名  [>]

```

| 点击位置 | 行为 |
|---------|------|
| 最左边勾选框[☑] | 只勾选 / 取消，不进目录 |
| 文件夹图标[📁] | 只勾选 / 取消，不进目录 |
| 文件夹名字 | 默认进目录；但开了区间模式后，变成选起点/终点 |
| 最右边 `>` 箭头 | 永远进目录，不受区间模式影响 |

## 文件夹如何进行区间选择

1. 点底部「**区间**」胶囊按钮（变蓝）
2. 点**起点行的文件夹名字**
3. 点**终点行的文件夹名字**

中间的所有文件夹一次全部勾上，自动退出区间模式。

- 中间改主意：再点一次「区间」按钮退出
- 勾一部分后可以进别的目录继续勾
- 最后点「确定」保存全部

## 其他按钮

**全选** —— 勾/取消当前这一层的所有子文件夹
（只影响当前层，不影响已勾选的其他目录）

**已勾选 N 个 · 查看** —— 列出所有已勾选，可单条移除

**顶部路径框 + 箭头** —— 粘贴完整路径，点击右侧箭头直接跳

**顶部左上的 ↑ 按钮** —— 返回上一级

## 压缩包

列表模式点 zip → 就地展开。
展开后搜索栏下方出现蓝条：`已展开 N 个 · 全部收起`

以下情况**不展开**，直接交系统 App：

- **加密的 zip**（读文件头就能判断，不解压）
- **超过 50 MB 的 zip**
- **7z / rar / dzip / iso / tz / gz / pdf / doc / docx / epub**
  点击这些格式的文件，会弹"系统的打开方式选择器"

## 搜索的边界

- 自动跳过 `/Android/data` 和 `/Android/obb`
  （Android 11+ 这两目录读不到，避免无意义报错）
- 最多 500 条结果
- 输入框右边 🕘 是搜索历史（可单条删）
- 扫描时搜索栏下方会出现「取消」按钮，可中断

## 搜索结果排序是独立的

「搜索结果排序」只影响结果列表的顺序，
**不会影响文件浏览器本身按什么排序**。

搜索设置弹窗里改完立刻重排，不用重扫。

## 图标颜色（按扩展名分组）

| 颜色 | 类型 |
|------|------|
| 蓝 | 文本文件（.txt / .md / .json 等）和压缩包（.zip / .tar / .tar.gz / .tgz） |
| 橙 | 图片 / 视频 / 音频 / 二进制 |
| 灰 | 其它 |

## 菜单里的「当前目录信息」

不是简单列文件。算的是：

- 总项数
- 文件夹数 / 文件数
- 总大小（**不含子目录**，标注清楚防止误解）
- 最大文件、最新文件、最旧文件
- 当前排序、显示模式
- 类型分布（放最底部）

> 惰性 stat 期间（size 还没填上）会标"部分未统计"。

## 技术细节

**目录缓存**

LRU，200 条上限，按"路径+排序+方向"分 key。切回之前的目录秒开。


''';

const String _helpDiff = r'''
## 顶栏按钮

| 按钮 | 点击 | 长按 |
|------|------|------|
| 上一处差异（↑箭头） | 跳到上一处差异 | 跳文档**最开头** |
| 下一处差异（↓箭头） | 跳到下一处差异 | 跳文档**最结尾** |

## 替换先攒缓存，不立刻生效

「替换当前」和「全部替换」都只是**改缓存，屏幕暂时不变**。
要**点「应用并刷新」**才真正重算。

好处：连续替换多个词时，不用每次等重算。
改完最后点一次「应用并刷新」，一次生效，速度快很多。

关闭查找栏时如果还有没应用的替换，会弹窗三选一（取消、放弃、应用并关闭）

## 查找栏的选项

**左侧 / 右侧 / 两侧**

查找哪侧文件的内容。

**正则 / 忽略大小写 / 整词**

正则按钮开启后查找串按正则解析，替换串里能用 `$1` `$2`。
长按"正则"按钮，可打开正则速查页。

整词开启后，只匹配完整英文单词，**对中文无效**，搜索中文时不要开启。

## 替换串的展开规则

| 模式 | 展开方式 |
|------|---------|
| 正则开启 | `$0` = 整个匹配；`$1 $2` = 捕获组 |
| 正则关闭 | 按字面替换，`$` 和 `\` 不当特殊符号 |

## 视图tab

长按“跨行块”，弹出菜单可设置上下文数量。

## 自定义快捷操作按钮栏（视图tab下方）

- **点击按钮** → 选择这条规则用在哪侧（左/右/两侧）
- **长按按钮** → 编辑这条规则
- **+ 图标** → 新建一个按钮
- **排序图标** → 拖动排序，也可以在这里删除按钮，更改按钮样式

## 显示设置里，可以开启显示悬浮按钮。

向上 / 向下翻页悬浮按钮和顶栏第2个第3个按钮功能一样。

## 对比页长按左侧 / 右侧文件任意一行

弹「编辑此行」。可以改左右任一侧内容，改完立即重算。
位置会自动保持在原来附近。

## 导出差异为txt = 导出「独有片段」，不是完整行

做的是**字符级比对**。一个词、一句话可能被切开，
只把"变化的那几个字"拿出来。

同一行有两处改动，会输出两行。

**例：**

```

左：今天我回来是要吃饭的。
右：明天我回来是要吃饭的。
左侧导出：今
右侧导出：明

```

> 想看完整句子的对照，请回对比页用「并排」或「合并」视图。

导出的 txt 文件里带一段说明头，说明每一行是什么。



''';

const String _helpReader = r'''
## 翻页手势

**分页模式**

- 点屏幕 → 下一页
- 从左往右滑 → 上一页

**滚动模式**

- 点屏幕 → 往下滚一屏
- 左右滑 → 上下换屏

## 菜单热区

可以在设置里调它的：

- 位置（X / Y， 相对屏幕）
- 大小（宽 / 高，0-1）
- 颜色、透明度、边框粗细
- 是否在阅读页画出来

> 关掉"显示"后照样能点，只是不画出来。

## 长按选字

按住 **400ms** 才进入选字。太快松开只是普通点击（翻页）。

选中后出现两个手柄，可以拖大/拖小范围。

> 手柄贴到屏幕底部时会翻到文字上方，避免飘出屏幕。

## 长按选中文字后弹出的色块：点 vs 长按

| 操作 | 效果 |
|------|------|
| 点色块 | 用这个色块的高亮（对当前选中文字） |
| 长按色块 | 编辑这个色块（改颜色 / 改名字） |

## 高亮 Tab 的 checklist 图标

点击和长按行为不一样：

| 操作 | 效果 |
|------|------|
| 点击 | 进选择模式（批量删除、批量移入分组） |
| 长按 | 弹「高亮卡片显示设置」（目前有"显示书名"） |

## 筛选弹窗

显示范围两种：

- **仅本书**
- **全部书籍**（第一次加载会慢一下，因为要读所有书的高亮）

勾选要看的分组，全选 / 管理分组。

## 阅读搜索页的返回按钮 ≠ 跳转

- 点 **【返回箭头】** = 关闭搜索（清空当前搜索状态），**不跳转**
- 点 **【具体结果行】** = 跳转到那一处

> 容易搞错：想跳转要点结果行，别点返回。

## 搜索半开条

跳转后浮在底部约 10% 高度：

```

↑ N/M ↓ 展开 ✕

```

- 点「展开」回搜索页
- 点 ↑↓ 上下切换结果
- 点 ✕ 关闭搜索状态

## 搜索历史

搜索页右上「历史」入口，或者跳转前输入框回车也会记住。

历史项可以**加星标（收藏）**，收藏项排序时永远在最上面。
非收藏项最多 100 条。

## 上下文件按钮

切文件前会自动保存当前进度。
有提示条显示「第 N/M 个 · 文件名」。

> 进度是按 **字符偏移** 保存的，不是页码。
> 因为行号会因字体大小变，字符偏移不变。

## 删除文件

删完自动跳下一个。删的是目录里最后一个 → 自动返回浏览器。
删掉的路径会传给浏览器，浏览器从缓存里同步移除。

## 浮动按钮

三个：

- 上一文件（默认右上）
- 下一文件（默认右下）
- 删除文件（默认左下）

都可以在设置里单独调：

- 样式：纯色圆 / 圆环
- 颜色、透明度、大小
- 位置（X / Y，相对屏幕）

## 安全边距可以填负数

分页模式下：

| 值 | 效果 |
|----|------|
| 正数 | 多留白，内容整体往里推 |
| 0 | 贴边 |
| 负数 | 榨空间——多显示一行，但可能裁掉首尾行 |

> 滚动模式下负数按 0 处理。

范围 **-400 ~ +400** 像素。

## 设置面板里的预览图

右上角有个小预览。**点它可以放大看**，不是装饰。

预览会实时反映所有参数的改动。

## 菜单里的其他项

| 菜单项 | 作用 |
|--------|------|
| 进度 | 打开滑块直接跳百分比 |
| 查找 | 进全屏搜索页 |
| 加书签 | 当前页首加一条 |
| 书签与高亮 | 进管理页 |
| 行编辑 | 进行编辑器 |
| 编码 | 手动指定编码（自动检测错了时用） |
| 导出加载日志 | 导出本次会话日志 |
| 设置 | 打开阅读设置面板 |
| 关闭文件 | 返回浏览器 |

> 菜单顶部的**文件名 / 路径**：
> 长按路径可以复制。




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

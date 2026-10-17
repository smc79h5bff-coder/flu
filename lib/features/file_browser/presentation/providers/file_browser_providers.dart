
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
| 行编辑器 | 浏览器设置 →「行编辑器」 | 点两个行号，选中连续行进行操作 |

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

## 顶栏图标是干嘛的

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

## 高级搜索
高级搜索使用说明

适用范围：文件浏览器 搜索框里的右侧三角形

一、它是干什么的

主输入框里输入关键词，只能"要什么"。
高级搜索让你额外加两条限制：

· 同时：必须也出现的词
· 排除：不能出现的词
· 或者：命中其中一个就行

两者叠加，筛选更精准。

二、怎么打开

点搜索框右侧的三角形图标，弹出条件面板。

· 向左 ◁ / ◀：面板折叠中
· 向下 ▽ / ▼：面板已展开
· 空心：还没有条件
· 实心：已经有条件了

面板展开后，点面板外的任意位置（或再点一次三角形）即可收起。


三、什么时候自动筛，什么时候要手动点

过滤模式（搜索栏左边图标是漏斗）：

· 三角形空心（无条件）：主输入框边打边筛，实时。
· 三角形实心（有条件）：主输入框打什么都不会自动筛，需要手动触发。
  · 点搜索框下方的「筛选」胶囊，或
  · 在主输入框里按回车

搜索模式（搜索栏左边图标是放大镜）：

· 一直是手动，不管空心实心。
· 点放大镜、点胶囊「搜索」，或按回车触发。

为什么要区分？因为条件越多，每打一个字重算一遍越慢。所以有条件时默认改手动，你打完再点一次，一次算完。



四、条件和关键词怎么叠加

规则：主输入框里的词，等价于一条"或者"条件。

整体判断顺序：

先看"或者"：至少命中一个
再叠加"同时"：全部都要命中
最后叠加"排除"：一个都不能出现

举例：

主输入框 或者 同时 排除 结果
唐家三少 （无） 第 广告 文件名同时含"唐家三少"和"第"，且不含"广告"
唐家三少 斗破 （无） （无） 文件名含"唐家三少"或"斗破"
唐家三少 斗破 第 广告 （含"唐家三少"或"斗破"）且含"第"且不含"广告"

注意：主输入框和"或者"条件是同一类，是二选一的关系。"同时"和"排除"才是叠加在它们上面的。


五、三种条件怎么选

类型 含义 举例
或者 命中其中一个就行 或"斗破"、或"斗罗"、或"武动"，三个命中任意一个即可
同时 必须都出现 同时含"第"、同时含"章"，说明只看"第X章"格式的行
排除 一个都不能出现 排除"广告"、排除"推广"，把带广告字样的文件全挡掉

典型组合：主输入框"唐家三少" + 排除"同人" → 只看唐家三少的原创文件。



六、清空

两种清空，效果不同：

· 面板里的「🗑 清空条件」：把条件全部删掉，面板不关闭，你还能继续加新条件。
· 搜索框下方胶囊「清空」：把条件全部删掉，同时收起面板，回到实时模式（过滤模式下马上自动重筛）。

清空之后，三角形从实心变回空心。如果你的主输入框还有字，过滤模式会立即按主输入框重新筛一遍，不用你再敲。


七、几个常用场景

场景 1：找特定作者的正版文件


主输入框：唐家三少
排除：同人


→ 只看唐家三少的原创文件，同人作品全部隐藏。

场景 2：一堆文件里找"第X章"格式的行


主输入框：第
同时：章


→ 文件名必须同时含"第"和"章"。

场景 3：多个作者一起筛


或者：斗破
或者：斗罗
或者：武动
排除：广告


→ 这三个关键词命中任意一个，且不带广告字样。

场景 4：只要这一批文件里特定的几个


主输入框：（空）
或者：第1章
或者：第2章
或者：第3章


→ 主输入框可以空着。打开高级面板加条件，点「筛选」或「搜索」即可。搜索栏的 hint 会提示"已启用高级条件，点「筛选」/「搜索」生效"。



八、常见问题

Q：为什么我打了字列表没动？
A：因为你有条件，现在是手动模式。点「筛选」胶囊或按回车。

Q：为什么我删了条件列表还是没动？
A：删条件本身不触发筛，还要点一次「筛选」/「搜索」，或按回车。或者点胶囊「清空」，它会立即重筛。

Q：三角形颜色为什么不一样？
A：子目录搜索是黄色，自定义范围是蓝色，过滤模式是黑色。只是提示你当前在哪种模式，不影响功能。

Q：条件输入框里按回车能筛选吗？
A：不能。条件框支持多行，回车是换行。要触发筛选，请回到主输入框按回车，或点按钮。

Q：从 A 目录切到 B 目录，条件还在吗？
A：不在了。切目录会自动清空条件，回到实时模式，避免拿着旧条件筛新目录。


##高级搜索使用说明（以过滤模式为主）

适用范围：文件浏览器搜索栏 → 右侧三角形
本文默认讲过滤模式（搜索栏左边图标是漏斗）。搜索模式的不同之处在最后一节单独标出。



一、高级搜索能干什么

主输入框里输入关键词，只能"要什么"。
高级搜索让你额外加两类限制：

· 同时：文件名还必须也出现这个词
· 排除：文件名不能出现这个词

叠加起来筛得更准。



二、三角形图标怎么读

图标 含义
◁ 空心向左 面板折叠，没有条件
◀ 实心向左 面板折叠，有条件
▽ 空心向下 面板展开，没有条件
▼ 实心向下 面板展开，有条件

· 方向表示面板开没开：向左 = 收起，向下 = 展开
· 空心 / 实心表示有没有条件：空心 = 没有，实心 = 有
· 颜色只是跟随当前模式（过滤模式是黑色），不影响功能



三、过滤模式的两套行为：看三角形是空心还是实心

这是最容易忘的地方。过滤模式下，三角形空心还是实心，决定了主输入框打字会不会自动筛。

空心（没有高级条件）→ 实时

主输入框打一个字，列表就筛一次，边打边看。

· 不需要点任何按钮
· 回车只是收起键盘，不触发额外操作

实心（有高级条件）→ 手动

主输入框打什么，列表都不会自动动。要手动触发：

· 点搜索框下方的 「筛选」胶囊，或
· 在主输入框里按回车

条件越多，每打一个字重算越慢，所以有条件时默认改手动，打完再点一次。



四、主输入框有字时，怎么用

1. 主输入框输入"唐家三少"
2. 点三角形展开面板
3. 点「＋ 添加条件」→ 选「排除」→ 输入"同人"
4. 点面板底部大按钮「筛选」
5. 面板收起，三角形变实心，下方出现胶囊 [筛选] [清空]
6. 列表显示：含"唐家三少"且不含"同人"的文件

之后：

· 想改条件 → 点三角形展开，改完再点「筛选」
· 想换关键词 → 改主输入框，然后点胶囊「筛选」或按回车
· 想全部清掉 → 点胶囊「清空」



五、主输入框为空时，怎么用

完全可以只用高级条件，主输入框空着不影响。

1. 主输入框保持空
2. 点三角形展开面板
3. 添加条件，比如「同时 第」+「排除 广告」
4. 点面板底部「筛选」
5. 列表显示：文件名同时含"第"且不含"广告"的文件

此时主输入框的提示文字会变成：


已启用高级条件，点「筛选」生效


提醒你"空输入框是正常的，条件在生效"。

之后想再筛：点胶囊「筛选」或展开面板改条件。


六、四种组合一览

主输入框 高级条件 结果
空 无 不过滤，全部显示（实时）
有字 无 只按关键词筛（实时）
空 有 只按条件筛（手动点筛选）
有字 有 关键词 + 条件一起筛（手动点筛选）

只要条件非空，就是手动。 有没有字都一样。


七、条件和关键词怎么叠加

主输入框里的词，等价于一条"或者"条件。整体判断：


先看"或者"：至少命中一个（主输入框的词也算一条"或者"）
再叠加"同时"：全部都要命中
最后叠加"排除"：一个都不能出现


举例：

主输入框 或者 同时 排除 结果
唐家三少 （无） 第 广告 含"唐家三少"且含"第"且不含"广告"
唐家三少 斗破 （无） （无） 含"唐家三少"或"斗破"
（空） 第1章 （无） 广告 含"第1章"且不含"广告"



八、清空条件

两个地方都能清，效果不同：

位置 清完后面板 清完后的列表
面板里的「🗑 清空条件」 保持展开，可以继续加 不动（还是手动）
搜索框下方胶囊「清空」 收起 立即按主输入框重筛

清完后三角形从实心变回空心。主输入框若有字，胶囊「清空」会让列表立刻按关键词重筛，不用再敲。



九、常用场景

只看某作者的正版


主输入框：唐家三少
排除：同人


只看"第X章"格式的行


主输入框：（空）
同时：第
同时：章


多个作者一起看，排除广告


主输入框：（空）
或者：斗破
或者：斗罗
或者：武动
排除：广告



十、常见问题

Q：为什么我打了字列表没动？
A：三角形是实心 = 有条件 = 手动模式。点胶囊「筛选」或按回车。

Q：我删了条件，列表怎么还是旧的？
A：删条件本身不触发筛。点胶囊「筛选」/「清空」，或按回车。

Q：主输入框空着，能筛吗？
A：能。加条件后点「筛选」。hint 会提示"已启用高级条件，点「筛选」生效"。

Q：条件输入框里按回车能筛吗？
A：不能。条件框支持多行，回车是换行。触发筛选用主输入框的回车，或点按钮。

Q：切到别的目录，条件还在吗？
A：不在了。切目录自动清空条件，回实时。

Q：点三角形会触发筛选吗？
A：不会。三角形只管面板开合。筛选靠胶囊或回车。



十一、搜索模式有什么不同

搜索模式（左边图标是放大镜）的行为：

· 不管空心实心，都是手动。点放大镜、点胶囊「搜索」、或按回车才搜。
· 胶囊文字是「搜索」而不是「筛选」。
· 面板底部大按钮文字是「搜索」。
· 其余（条件叠加规则、清空、切目录清空）与过滤模式一致。

记住一句话：过滤模式看三角形空心/实心决定自动还是手动；搜索模式一律手动。



十二、一句话总结

过滤模式：三角形空心 → 边打边筛；三角形实心 → 打完点「筛选」或回车。条件可以单独用，主输入框空着也行。胶囊「清空」回实时。


''';

const String _helpDiff = r'''
## 对比页 - 顶栏与视图

**顶栏从左到右**：

- 关闭对比页
- 向上翻页
- 向下翻页
- **↑**：跳到上一处差异。长按它跳到文档最开头
- **↓**：跳到下一处差异。长按它跳到文档最结尾
- 打开查找 / 替换
- 更多操作

**视图切换**（顶栏下方四个 tab）：

- 只显示差异行 + 上下各 2 行
- 只显示有变化的行，不带上下文
- **跨行块**：非按行对比，可看到换行的差异。长按可设置上下文数量
- **上下**：显示全文。原版 / 修改版交错单栏显示

## 对比页 - 查找与替换

**入口**：对比页顶栏

**查找**：

- 输入关键词后，命中的字变黄
- 当前停在哪一处，那一处变粉色
- 第三行最右侧的上箭头 / 下箭头：在命中之间来回跳
- 第一行最右侧的历史按钮：可以看以前搜过什么，可删除某条

**替换**：

- 在「替换为」框里填替换内容。留空 = 删掉
- **替换当前**：只换当前这一处
- **全部替换**：一次替换完所有命中
- 「替换当前」和「全部替换」都只是**改缓存，屏幕暂时不变**。
- 攒完之后点「应用并刷新」，才真正生效并重新对比左右两个文档。
  连续替换好多个词时，先攒着，等最后一次应用，比每次等对比重算快得多
- 如果只想在一侧文件里替换，点击左侧 / 右侧按钮
- 关闭查找栏时如果有没应用的替换，会询问：取消 / 放弃 / 应用并关闭

替换串的展开规则
| 模式 | 展开方式 |
|------|---------|
| 正则开启 | `$0` = 整个匹配；`$1 $2` = 捕获组 |
| 正则关闭 | 按字面替换，`$` 和 `\` 不当特殊符号 |

**高级搜索选项**：

- **正则**：开启后查找串按正则解析，替换串里能用 `$1` `$2`。
  长按「正则」按钮打开正则速查页
- **忽略大小写**：`A` 和 `a` 视为相同
- **整词**：只匹配完整英文单词，对中文无效。搜索中文时不要打开

> 任意一个选项开启之后，命中的结果暂时不会显示黄色 / 粉色背景高亮。

**小提示**：

> 前两个视图只搜屏幕上可见内容。后两个视图是搜索全文内容（包括跨行块被隐藏的相同部分）。

## 对比页 - 自定义按钮栏

在视图 tab 下面有一条按钮栏，可以放你自己常用的文本操作。

- 点 **+** 新建一个快捷操作按钮，填好规则后它就出现在按钮栏里
- **点击按钮**：弹出小菜单，问你这条规则要用到哪一侧（左 / 右 / 两侧）
- **长按按钮**：编辑这条规则
- 点右侧的「排序」图标：拖动排序，删除按钮，改按钮样式

> 按钮栏左边一排是自定义按钮，可以左右滑动。右边两个固定：新建、排序。

## 对比页 - 长按某一行

长按任意一行，可编辑此行，直接改这一行的内容，改完点确定。

编辑后会立即生效（会重算对比）。位置会自动保持在原来附近。


## 对比页 - 更多操作

**显示设置里，可以开启显示悬浮按钮。**

向上 / 向下翻页悬浮按钮和顶栏第2个第3个按钮功能一样。

### 对比规则设置相关

先约好：

```
a1 = 你导入的左边原始文件，永远不变
b1 = 你导入的右边原始文件，永远不变

A2 = 你第一次进对比页，屏幕上看到的左边（此时文本已被规则处理一遍）
B2 = 你第一次进对比页，屏幕上看到的右边（此时文本已被规则处理一遍）

A3、A4、A5 = 你在左边改过之后，屏幕上看到的左边
B3、B4、B5 = 右边同理
```

一句话：**小写 a、b 是原始文件；大写 A、B 是屏幕上看到的**。


#### 你改规则之前，屏幕上的样子

1. 点对比 → 屏幕左 A2、右 B2
2. 长按编辑修改左边某行 → 屏幕左 A3、右 B2
3. 查找替换改左边 → 屏幕左 A4、右 B2

此时为：左 A4，右 B2。
如果再点击右上角三个点 → 进入对比规则设置。

#### 返回时会发生什么？有三种情况

**【情况 1】只看看，没动任何开关，返回** → 对比页无变化



**【情况 2】关掉一个开关（或加了一条规则），返回**

系统发现规则跟进去前不一样了，弹一个窗：

- 点「取消」 → 弹窗关掉，人还在比较设置页，可以继续改
- 点「确定返回」 → 退出比较设置，回到对比页。
  屏幕闪一下「正在计算」，然后：
  - 左边 A4 过一遍规则 → 变 A5
  - 右边 B2 过一遍规则 → 变 B3

**【情况 3】改了，又改回去了，返回** → 无变化

#### 返回时，如果有变动，所有开着的规则从头到尾全跑一遍

- 你新增 / 新打开的那条 → 跑
- 内置规则（原来开着的）→ 也跑
- 批处理（普通文字） → 也跑
- 批处理（支持正则） → 也跑

> 一条不落，按你设的顺序，从头跑到尾。
> 不是只跑你动的那条。

#### 比规则设置有两个入口，但其实是“同一个房间”

比较设置有两个门进，里面是同一个房间、同一台加工机。

| 从哪个门进 | 改完返回后 |
|-----------|-----------|
| 文件浏览器（还没对比） | 加工机存好了，下次点对比才用 |
| 对比页（正在对比） | 弹窗确认后，当场重算 |

**文件浏览器那个门**：

你还在文件列表，还没点对比。改了加工机，返回，屏幕上还是文件列表，看不到任何变化。加工机先放着。等你点了对比，才拿它加工 a1、b1。

> 一句话：先存着，下次用。

**对比页那个门**：

你正看着 A4、B2。改了加工机，返回。先弹窗问你确认（见「情况 2」），点确定后才重算：

- 左边 A4 → A5
- 右边 B2 → B3

> 一句话：存了，确认后马上用。

**为什么不一样？**

- 文件浏览器：你还没进对比，没内容可加工，只能「存着」
- 对比页：你正在看内容，有东西可加工，所以「马上算」

> 加工机是同一台，改的也是它。区别只在什么时候用。

#### 记住这三句就够了

1. 比较设置只管加工机，不碰文件
2. 屏幕上看到的，永远是「过完加工机」的样子
3. 换了加工机，左右两边都重新过一遍，所有规则全跑，不是只跑你改的那条规则


## 内置规则

> 每条规则可开关。  
> 长按一条规则的名字 / 详情，可以重命名 / 隐藏这条规则。  
> 隐藏类似删除，以后不会再显示。

**执行顺序**：规则从上到下依次跑。前面改了文本，后面看到的就是改后的。

比如「删掉空行」排到最前面，后面所有规则看到的都是删过空行的版本，行号也变了。一般别把它拖到最前面。


## 批量处理（普通文字）

**用途**：一次塞几百个要删除或替换的词（比如各种群号网站水印）。

每行一条，两种格式：

```
xxx              ← 删掉 xxx
xxx->=>yyy       ← 把 xxx 换成 yyy
```


**查找串**是普通文字匹配，不把任何字符当正则，填什么就匹配什么。不支持转义，就是字面匹配，写 `\n` 就匹配文中相邻的「反斜杠和n」。
**替换串**里才认下面这几个转义：

| 转义 | 含义 |
|------|------|
| `\n` | 换行 |
| `\r` | 回车 |
| `\t` | Tab |
| `\\` | 反斜杠 |
| `\0` | 空字符 |

- 同一位置多条命中时，写在上面（行号靠前）的优先匹配
- 替换产生的新文本不再被后面的规则处理
- **替换串不支持** 正则、捕获组、`$1` 引用。只支持上面5个。

编辑器底部显示「共 N 行」，改过没保存会标「未保存」。编辑器顶部有一条提示，点开可以看详细说明，也可以自己改。底部有「测试区」，展开后输入一段文字，实时看处理结果。

### 详细解释

**查找串（`->=>` 左边）——不支持转义**

- 写 `\n` → 匹配「反斜杠 + n」两个字面字符，不是换行
- 写 `\s` → 匹配「反斜杠 + s」两个字面字符，不是空白
- 写 `\\` → 匹配「两个反斜杠」，不是「一个反斜杠」

> 一句话：查找串里的 `\` 就是个普通字符，你写啥就是啥。

**替换串（`->=>` 右边）——支持 5 个转义**

只认这几个：

| 你写 | txt文本里变成 |
|------|------|
| `\n` | 换行 |
| `\r` | 回车 |
| `\t` | Tab |
| `\\` | 一个反斜杠 |
| `\0` | 空字符（U+0000） |

其它的（比如 `\s`、`\d`、`\w`）不认，原样输出「反斜杠 + 那个字母」。

| 转义 | 为什么支持 |
|------|-----------|
| `\n` | 换行没法直接敲 |
| `\r` | 回车没法直接敲 |
| `\t` | Tab 键被界面吃掉了 |
| `\0` | 键盘上没这个键 |
| `\\` | 上面用了 `\` 做转义，得有个办法输出 `\` 本身 |


## 批处理（支持正则）

格式同上，但**查找串是正则表达式**：

```
xxx              ← 找到 xxx 就删掉
xxx->=>yyy       ← 找到 xxx 替换成 yyy
```

替换串里可以用 `$1`、`$2` 引用捕获组。
比如查找 `(\d+)-(\d+)`，替换 `$2-$1`，就能把 `12-34` 变成 `34-12`。

正则里 转义是真生效的：

| 转义 | 含义 |
|------|------|
| `\n` | 换行 |
| `\s` | 空白 |
| `\d` | 数字 |
| `\w` | 字母数字下划线 |

**执行方式**：严格按行顺序，从上到下依次执行。  
前一条的结果，就是后一条的输入。  
替换产生的新文本会被后面的规则处理。

> 改一条会立刻影响下一条，跟普通文字批处理不同。

非法正则会被跳过，不影响其它行。


**举例对比**
假设你想删除文本里所有的反斜杠：

**批处理（普通文字）**：

- 查找：`\`　替换：`留空` → ✅ 能删掉反斜杠
- 但如果你想删「反斜杠 + n」这两个字符：
  查找：`\n`（敲一个反斜杠一个 n）　替换：`留空` → ✅ 匹配这两个字面字符

**批处理（支持正则）**：

- 查找：`\\`　替换：`留空` → ✅ 删一个反斜杠（正则里 `\\` 表示一个字面反斜杠）

总结如下
| 项目 | 普通文字表 | 正则表 |
|------|:---------:|:-----:|
| 支持正则 | ❌ | ✅ |
| 查找串支持反斜杠转义 | ❌（原样当字面字符） | ✅（`\n` `\d` `\s` 等） |
| 替换串支持反斜杠转义 | ✅（只 5 个：`\n` `\r` `\t` `\\` `\0`） | ✅（同左） |



## 虽然支持正则，但两边的本质不同

- **查找串**：交给「正则引擎」，它按正则语法解释
- **替换串**：不交给正则引擎，它按模板语法解释（字面 + 引用 + 5 个转义）

> 所以它俩是两套规则，别指望「长得一样就意思一样」。

## 用一张表对比

| 你写 | 在查找串里 | 在替换串里 |
|------|-----------|-----------|
| `\d` | 匹配「任意一个数字」 | 输出「反斜杠 + d」两个字符 |
| `\w` | 匹配「字母数字下划线」 | 输出 `\w` 两个字面字符 |
| `\s` | 匹配「任意空白」 | 输出 `\s` 两个字面字符 |
| `\n` | 匹配「一个换行」 | 输出「一个换行」 |
| `\t` | 匹配「一个 Tab」 | 输出「一个 Tab」 |
| `\\` | 匹配「一个反斜杠」 | 输出「一个反斜杠」 |
| `.` | 匹配「任意一个字符」 | 输出「一个点号」 |
| `[abc]` | 匹配「a、b、c 中的一个」 | 输出 `[abc]` 五个字面字符 |
| `+` | 量词（前一个重复 1 次以上） | 输出「一个加号」 |
| `$1` | 匹配「行尾 + 数字 1」 | 引用第 1 个捕获组 |
| `$0` | 匹配「行尾 + 数字 0」 | 引用整个匹配内容 |

## 看出关键了吗

**替换串认三类东西**：

1. `$0` `$1` `$2` … → 捕获组引用（只有正则批处理的替换串才认）
2. `\n` `\r` `\t` `\\` `\0` → 5 个转义（跟普通文字批处理的替换串一样）
3. 其它所有字符 → 原样输出

**查找串认两类东西**：

1. 正则语法（`.` `\d` `[]` `()` `+` `*` `?` 等等）
2. 正则里的转义（`\n` `\t` `\\` `\d` `\w` `\s` 等）

## 最容易踩的坑

### 坑 1：`\d` 在两边意思完全不同

你想把「所有数字」替换成 `\d`（以为能输出「任意数字」）：

```
查找：\d+
替换：\d
```

- 你以为：把 `123` 变成「任意数字」
- 实际：把 `123` 变成字面字符 `\d`

> 因为替换串不认 `\d` 这个转义，它以为你要输出两个字面字符。

【注意】
在替换串里，引用分两种：

- `$0` = 整个匹配到的内容（不需要括号）
- `$1` `$2` … = 第 N 个捕获组的内容（需要括号）

所以「把数字替换成数字」这个需求，看你想干嘛：

### 情况 A：想让数字原样不动

那这条规则根本不用写。没变化的东西不需要替换。

### 情况 B：想给数字套个壳，但数字本身保留

比如把 `123` 变成 `<123>`：

**方法 1：用 `$0`，不用括号**

```
查找：\d+
替换：<$0>
```

`$0` 就是「刚才匹配到的整段」，也就是 `123`。

**方法 2：用捕获组**

```
查找：(\d+)
替换：<$1>
```

`$1` 是第一个括号里捕获的内容，也是 `123`。

> 两种结果一模一样，方法 1 更简单，不用写括号。

### 情况 C：想引用匹配内容的一部分

这种情况**必须**用捕获组。比如把 `12-34` 变成 `34-12`：

```
查找：(\d+)-(\d+)
替换：$2-$1
```

这里 `$1` 是 `12`，`$2` 是 `34`，换成 `34-12`。

> 这种场景 `$0` 帮不上忙——`$0` 是整个 `12-34`，你没法把它拆开重排。

### 情况 D：想让数字变成「别的东西」

比如把所有数字换成 `N`：

```
查找：\d+
替换：N
```

这不需要引用，直接写字面 `N` 就行。

## 什么场景必须用捕获组

只要你需要「把匹配到的内容拆开，重新排列、部分保留」，就必须用捕获组。

例子：

- `12-34` → `34-12`（对调）
- `张 三` → `三张`（换位置）
- `2024-01-01` → `2024年01月01日`（在数字中间插字）
  - 查找：`(\d+)-(\d+)-(\d+)`
  - 替换：`$1年$2月$3日`

误区
- 如果是「替换结果里要出现原来的数字」——得用引用（`$0` 或 `$1`）
- 但不是「非用捕获组不可」——`$0` 也能引用整个匹配，不用写括号

> 想引用匹配到的内容 → 用 `$0`（整段）或 `$1` `$2`（括号捕获的片段）

总结
| 你的需求 | 用什么 |
|---------|--------|
| 替换结果里要用「整个匹配」 | `$0` |
| 替换结果里要用「匹配中的某一段」 | `$1` `$2`（需要括号） |
| 替换结果里只用固定文字 | 直接写，不用引用 |
> 所以——**捕获组不是「用来引用数字」，而是「用来引用匹配内容里分出来的小组」。要引用整段，`$0` 就够。**


### 坑 2：想输出反斜杠，两边写法不同

想匹配并输出一个反斜杠：

```
查找：\\
替换：\\
```

- 查找串的 `\\`：正则里，`\\` 表示「一个字面反斜杠」✅
- 替换串的 `\\`：转义里，`\\` 也表示「一个字面反斜杠」✅

> 巧了，两边都是 `\\`，结果一样。这是少数两边写法一致的。

## 为什么会这样设计

- 查找的任务是「描述一个模式」，必须是正则语法，不然没法表达「数字」「空白」这些概念
- 替换的任务是「生成一段文本」，必须是「能确定输出的字符」，不可能输出「任意数字」这种模糊的东西

> 所以从设计上，两边注定不一样。

## 总结

| 问 | 答 |
|------|----|
| 查找串和替换串支持的东西一样吗 | 不一样 |
| 查找串认什么 | 正则语法 + 正则转义（`\d` `\w` `\s` `\n` `.` `[]` `()` `+` 等等） |
| 替换串认什么 | `$0` `$1` `$2` 引用 + 5 个转义（`\n` `\r` `\t` `\\` `\0`）+ 其它原样输出 |
| 会不会混 | 会，尤其 `\d` `\w` `\s` 这三个在替换串里就是字面字符 |

 `\d` `\w` `\s` 在替换串里
替换串里没有"匹配类"的概念。
原因很简单：\d 的意思是"某一种数字"，这是描述一个范围，不是描述一个确定字符。替换是"你要输出什么"，必须是确定的东西。你没法"输出任意一个数字"——到底是几？

所以 \d \w \s 这类"匹配类"，在替换串里没地位，一律当字面字符。


## 自定义规则（7 个开关）

点列表底部「新建规则」，或者长按列表里已有的自定义规则编辑。
可以选三种类型：**查找替换**、**预置功能**、**JS 脚本**。

选「查找替换」时，有 7 个开关：

**查找侧（三选一）**：

- 支持正则：按正则解析
- 仅字面匹配：特殊符号当普通字符
- 支持转义：把 `\n` `\r` `\t` `\\` `\0` 还原成真字符再找

**替换侧（至少开一个）**：

- `$1 $2` 引用：替换串里用 `$1` `$2` 引用捕获组
- `\1 \2` 引用：同上，另一种写法
- 仅字面输出：不展开引用，原样输出
- 支持转义：把 `\n` `\r` `\t` `\\` `\0` 还原成真字符再输出

**作用范围（三选一）**：

- 两侧文件：左右都应用
- 仅左侧文件
- 仅右侧文件

> 长按任意开关的标签，可以看它详细说明。说明还能自己改。

**互斥规则**：

- 查找侧三个里，必须开且只开一个（支持正则 / 仅字面）
- 替换侧三个里，至少开一个（`$1`引用 / `\1`引用 / 仅字面输出）

## 预置功能清单

预置功能是写好的现成操作，选一个填参数就行，不用自己写规则。

**行操作**：

- 按关键词过滤行：保留或删除含指定关键词的行
- 截取第 N 到第 M 行
- 删除空行 / 删除纯空白行
- 加行号 / 非空行加行号
- 行首尾去空白 / 只去行首 / 只去行尾
- 合并所有行为一行

**字符替换**：

- 删除所有出现的字符串
- 替换所有出现的字符串

**空白处理**：

- 删除所有空格 / 删除所有 Tab / 删除所有空白
- 删除所有标点 / 删除所有数字 / 删除所有英文 / 删除所有非中文
- 删除不可见字符
- 连续空白折叠成一个空格
- 连续换行折叠成一个 / 连续 N 换行折成 M 个
- 连续点号折成省略号
- 删除行尾多余空格

**大小写与全半角**：

- 小写转大写
- 全角转半角 / 半角转全角 / 全角空格转半角
- Tab 转 N 个空格 / N 个空格转 Tab

**标点转换**：

- 中文标点转英文 / 英文标点转中文
- 中文引号统一（几种样式可选）

**数字**：

- 数字替换成占位符
- 中文数字转阿拉伯（一二三 → 123）
- 阿拉伯数字转中文（123 → 一二三 / 一百二十三）

**Unicode**：

- 规范化 Unicode（NFC）



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

> 关掉"显示"后照样能点，点击弹出菜单，只是不画出来。


## 长按选中文字后弹出的色块：点 vs 长按

| 操作 | 效果 |
|------|------|
| 点色块 | 用这个色块的高亮（对当前选中文字） |
| 长按色块 | 编辑这个色块（改颜色 / 改名字） |

## 高亮 Tab 的 多选图标（最右边的图标）

点击和长按行为不一样：

| 操作 | 效果 |
|------|------|
| 点击 | 进选择模式（批量删除、批量移入分组） |
| 长按 | 弹「高亮卡片显示设置」（目前有"显示书名"） |

## 筛选（右边第2个图标）

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

历史项可以**加收藏**，收藏项排序时永远在最上面。
非收藏项最多 100 条。

## 上下文件按钮

切文件前会自动保存当前进度。
有提示条显示「第 N/M 个 · 文件名」。


## 删除文件

删完自动跳下一个。删的是目录里最后一个 → 自动返回浏览器。
删掉的路径会传给浏览器，浏览器从缓存里同步移除。

## 浮动按钮三个：

- 上一文件
- 下一文件
- 删除文件

都可以在设置里单独调样式。

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

## 菜单

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

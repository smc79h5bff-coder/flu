import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用说明页（合并后的唯一入口）。
///
/// 带 Tab，支持 `initialTabId` 指定打开哪个 Tab。
/// 整页可编辑，编辑后保存到本地，重启后仍在。
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, this.initialTabId});

  /// 如果给出，打开后自动切换到 id 匹配的 Tab。
  final String? initialTabId;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen>
    with SingleTickerProviderStateMixin {
  static const String _prefKey = 'help_screen_tabs_v3';

  List<_HelpTab> _tabs = const [];
  bool _loaded = false;
  bool _editing = false;

  // ★ 从 `late final` 改成 `late`。
  //
  //   `late final` 字段**只能赋值一次**。之前的代码是：
  //     initState 里赋值（第 1 次）
  //     _loadContent 里 dispose 旧 + 赋值（第 2 次）→ 抛 LateInitializationError
  //     catch 里再赋值（第 3 次）→ 又抛
  //
  //   结果：_loadContent 从读 prefs 到设置 tabs 的所有代码都白做，
  //   用户自定义的 tab 全部丢失，_loaded 可能一直是 false → 永远转圈。
  //
  //   改成 `late` 后，_loadContent 里可以正常 dispose 旧的、创建新的。
  late TabController _tabCtrl;

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _contentCtrl = TextEditingController();

  // 字号缩放（阅读时双指可缩放）
  static const double _baseFontSize = 13.5;
  static const double _minScale = 0.5;
  static const double _maxScale = 3.0;
  double _fontScale = 1.0;

  final Map<int, Offset> _touches = <int, Offset>{};
  double _pinchStartDistance = 0;
  double _pinchStartScale = 1.0;

  // ==============================================================
  // MarkdownStyleSheet 缓存
  // ==============================================================
  //
  // flutter_markdown 的 MarkdownBody 内部有缓存，判断条件是：
  //   if (oldWidget.styleSheet != widget.styleSheet || oldWidget.data != widget.data)
  // MarkdownStyleSheet 没有重写 ==，所以 != 是引用比较。
  // 每次 build 都 return 新对象 → 引用永远不同 → 每次都重新解析 markdown。
  MarkdownStyleSheet? _cachedSheet;
  double _cachedSheetFontSize = 0;
  ColorScheme? _cachedSheetScheme;

  // ==============================================================
  // 默认 Tab 内容（精简重写，口语化，不写底层技术细节）
  // ==============================================================

  static List<_HelpTab> _defaultTabs() => const [
        _HelpTab(
          id: 'general',
          title: '通用',
          content: _helpGeneral,
        ),
        _HelpTab(
          id: 'browser',
          title: '浏览器',
          content: _helpBrowser,
        ),
        _HelpTab(
          id: 'diff_viewer',
          title: '对比页',
          content: _helpDiffViewer,
        ),
        _HelpTab(
          id: 'comparison_rules',
          title: '对比规则设置',
          content: _helpComparisonRules,
        ),
        _HelpTab(
          id: 'reader',
          title: '阅读页',
          content: _helpReader,
        ),
      ];

  // ==============================================================
  // 默认文本（精简重写版）
  // ==============================================================

  static const String _helpGeneral = r'''
## 怎么对比两份文档

**方式一**（推荐）：
1. 进文件浏览器，找到那两个文件
2. 单击左边图标 / 长按 → 进入选择模式
3. 再单击第二个文件
4. 底部「对比」按钮亮起，点一下开始

**方式二**：搜索文件，在搜索结果页里直接选两份对比

## 各页面是干嘛的

| 页面 | 怎么进 | 能做什么 |
|------|--------|----------|
| 浏览器 | 打开 App | 选文件、对比、管理文件 |
| 对比页 | 浏览器选 2 个文件点「对比」 | 看差异、查找替换、改规则 |
| 阅读页 | 浏览器点文本文件 | 读文件、上下切换、删文件 |

## 编码识别

自动识别：UTF-8、UTF-16、GBK、GB18030、Big5、Shift-JIS、ASCII……

如果识别错了，在**阅读页菜单 →「编码」**里手动改。

## 批量阅读整个目录

阅读页可以一次打开一个目录里所有文本文件：
- 悬浮按钮切换"上一文件 / 下一文件"
- 阅读进度自动保存
- 删掉当前文件后自动跳到下一个
- 目录空了自动回文件浏览器

## 导入导出配置

更多菜单 → **导出配置 / 导入配置**。导入后需要重启 App 才生效。
''';

  static const String _helpBrowser = r'''
## 长按藏着什么

- **长按顶部标题** → 弹「跳转到目录」，粘路径就能直接跳
- **单击文件左边图标 / 长按任一文件** → 进入选择模式
- 在选择模式下**长按另一项** → 区间全选（起点到终点一次性勾上）

## 顶栏四个图标

从左到右：

1. 返回上一级
2. 搜索（只在搜索栏折叠时显示）
3. ⭐ **收藏 / 取消收藏「当前目录」**——不是收藏文件！
4. ⚙ **对比规则设置**——跟浏览器本身没关系，是对比时处理文本的规则
5. ⋮ **更多菜单**

## 搜索的几种颜色

| 范围 | 色调 |
|------|------|
| 当前目录及子目录 | 黄色系 |
| 自定义范围 | 蓝色系 |
| 过滤 | 红色系 |

## 搜索有几个坑要注意

- 自动跳过 `/Android/data` 和 `/Android/obb`（Android 不让读，避免无意义报错）
- 最多返回 500 条结果
- 输入框右边 🕘 是搜索历史，可单条删除
- 扫描时搜索栏下会出现「取消」按钮，可以中断

## zip 压缩包

列表模式点 zip → **就地展开**，展开后搜索栏下方出现蓝条：`已展开 N 个 · 全部收起`

**以下情况不展开**，直接交给系统 App 打开：
- 加密的 zip
- 超过 50 MB 的 zip
- 7z / rar / pdf / doc / epub 等

## 收藏是目录，不是文件

星星图标收藏的是你当前所在的目录，**不是选中的文件**——这是最容易搞错的地方。
''';

  static const String _helpDiffViewer = r'''
## 顶栏（对比页最上面一排按钮）

从左到右：

1. 返回（退出对比）
2. ↑↑ 向上翻页（长按跳到文档开头）
3. ↓↓ 向下翻页（长按跳到文档结尾）
4. ↑ 上一处差异（长按跳到开头）
5. ↓ 下一处差异（长按跳到结尾）
6. 🔍 打开查找 / 替换
7. ⋮ 更多操作

## 视图切换（顶栏下面一排 tab）

| Tab | 显示内容 |
|-----|----------|
| 只看差异（带上下文） | 变化行 + 上下各 2 行，最快看清哪里改了 |
| 只看差异（纯净） | 只显示变化的行，不带上下文 |
| 跨行块 | 非按行对比，能看到"换行导致的差异" |
| 全文上下 | 左在上，右在下，完整文本 |
| 全文并排 | 左在左，右在右，并排看 |

长按"跨行块"或点它右边的 ⚙ 可以设置上下文数量。

## 查找 / 替换

入口：顶栏倒数第二个图标。

**查找**：命中的字变黄，当前停在哪一处变粉色。底部的 ↓ ↑ 在命中的结果间来回跳。右上角 🕘 看搜索历史。

**替换**：
- 「替换为」框留空 = 删掉
- **替换当前**：只换这一处
- **全部替换**：一次换完所有命中

> 攒着，别每次都重算。连续替换多个词时，先攒好几次，等最后一次点「应用并刷新」，比每次等对比重算快得多。

> 高级搜索选项（正则、忽略大小写、整词）开了之后，结果暂时不会显示黄/粉高亮。

## 自定义快捷操作按钮栏

在视图 tab 下面那条按钮栏：
- **点 +** 新建一个快捷操作按钮
- **点按钮** → 弹菜单，选改左 / 改右 / 两侧都改
- **长按按钮** → 编辑这条规则
- 右侧的「排序」图标 → 拖动排序、删除按钮、改按钮样式

## 长按某一行

长按任意一行 → 弹出来直接改这一行的文字，改完点确定立刻生效。

## 更多操作（顶栏更多菜单）

- **导出差异为 txt**
- **删除左边文件 / 右边文件**（不想对比了可以删一边）
- **显示设置**：字号、是否换行、要不要显示悬浮翻页按钮
- **对比规则设置**：改洗文本的规则（见单独的 Tab 说明）
- **查看完整差异（左右分开）**：把所有变化列出来，能快速定位
''';

  static const String _helpComparisonRules = r'''
## 它到底是干嘛的？

一句话：**对比之前，先跑一串规则把文本"洗一遍"，然后才开始算差异。**

比如你下载了一堆带水印的文本，直接对比的话，水印也会被算成"差异"。
你就在规则里开一条"删掉带「XXX水印」的行"，规则洗完之后水印没了，再去对比——屏幕上看到的就是干净的版本。

## 两条进规则设置的路，差别在哪？

| 从哪进 | 改完返回后 |
|--------|-----------|
| 文件浏览器（还没点对比） | 规则存起来，下次点对比才用 |
| 对比页（正在看对比） | 弹窗确认后，立刻重算，左右两边一起用新规则洗一遍 |

**为什么不一样？** 浏览器里还没内容可洗，只能"先存着"；对比页里已经有内容了，改了规则就能"马上看效果"。

## 改规则时要知道的三个事实

1. **屏幕上看到的，永远是"洗完之后"的样子**。你直接改对比页里某一行的字，改完之后规则还会再过一遍——如果你改的字又被后面的规则改掉了，那屏幕上会"回退"，这是正常的。
2. **所有规则一起跑，不是只跑你刚改的那条**。你新加一条或关掉一条，返回重算时，内置规则、批处理表、自定义规则、JS 脚本——按顺序，从头跑到尾。
3. **规则从上到下按顺序跑，前面改的后面能看到**。比如"删掉空行"排在最前面，那后面的所有规则看到的都是删过空行的版本——行号也会跟着变。一般别把删空行拖到最前面。

## 规则有哪些种

### 内置规则

就是屏幕上那一排开关。每条可以开/关，长按可以重命名或隐藏。从上到下按顺序跑。

### 批量处理表（普通文字）

一次塞几百个词，每行一条：

```
xxx              ← 删掉 xxx
xxx->=>yyy       ← 把 xxx 换成 yyy
```

**填什么匹配什么**——就是字面匹配，不把任何字符当正则。
同一位置多条命中时，上面的优先匹配。

### 批量处理表（支持正则）

格式和上面一样，但查找串按正则解析，替换串里可以用 `$1` `$2` 引用捕获组。
比上面慢，但能处理复杂匹配。

### 自定义规则（查找替换 / 预置功能 / JS 脚本）

点击列表底部「新建规则」，三种类型任选：

- **查找替换**：选正则还是字面匹配，作用范围左 / 右 / 两侧
- **预置功能**：写好的现成操作（过滤行、去空白、加行号、大小写转换、全半角转换……填参数就行）
- **JS 脚本**：写几行 JS 处理整段文本（例子：去掉空行、去掉重复行、每行前加行号）

JS 比原生规则慢，大文本时尽量排在最后。
''';

  static const String _helpReader = r'''
## 怎么进阅读页

在文件浏览器里点任意一个文本文件。

## 编码错了怎么办

点阅读页菜单 → **编码**，手动选正确的编码。支持 UTF-8、GBK、GB18030、Big5、Shift-JIS 等。

## 上一文件 / 下一文件悬浮按钮

默认关。去**显示设置**里开。悬浮按钮可以自由拖动位置。

## 批量阅读整个目录

阅读页可以一次打开一个目录里所有文本文件，悬浮按钮切换上下一个文件。
删掉当前文件后自动跳到下一个，全部删完自动回浏览器。

## 阅读进度自动保存

下次打开同一个文件时会回到上次看到的位置。
''';

  // ==============================================================
  // 模型
  // ==============================================================

  static const _fontFamilyMonospace = 'monospace';

  // ==============================================================
  // 生命周期
  // ==============================================================

  @override
  void initState() {
    super.initState();
    // length 从 0 改成 1：TabController 本身不 assert length>0，
    // 但 TabBar 渲染时有 assert(tabsLen == controller.length)。
    // 现在恰好因为 _loaded=false 时不渲染 TabBar 躲过去，属于运气。
    // 改成 1 更稳。后面 _loadContent 会 dispose 掉重新创建。
    _tabCtrl = TabController(length: 1, vsync: this);
    _loadContent();
  }

  Future<void> _loadContent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final defaults = _defaultTabs();
      final saved = prefs.getString(_prefKey);

      List<_HelpTab> tabs;
      if (saved != null && saved.isNotEmpty) {
        tabs = _loadPersisted(defaults, saved);
        if (tabs.isEmpty) tabs = defaults;
      } else {
        tabs = defaults;
      }

      // v1 / v2 的 key 早就不用了，clean 动作放这没意义。
      // remove 不存在的 key 不触发磁盘写，但每次启动跑一遍纯属浪费。

      int initialIdx = 0;
      final target = widget.initialTabId;
      if (target != null) {
        final idx = tabs.indexWhere((t) => t.id == target);
        if (idx >= 0) initialIdx = idx;
      }

      if (!mounted) return;
      _tabs = tabs;
      _tabCtrl.dispose();
      _tabCtrl = TabController(
        length: tabs.length,
        vsync: this,
        initialIndex: initialIdx.clamp(0, tabs.length - 1),
      );

      setState(() => _loaded = true);
    } catch (_) {
      // 任何异常（SharedPreferences 卡、TabController dispose 抛、Markdown 渲染前置问题）
      // 都兜底显示默认 Tab，绝不让 UI 永远卡在 loading。
      if (!mounted) return;
      _tabs = _defaultTabs();
      // 直接覆盖，不调 dispose——try 块里可能已经 dispose 过了，二次 dispose 会再抛。
      _tabCtrl = TabController(
        length: _tabs.length,
        vsync: this,
      );
      setState(() => _loaded = true);
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, _serializeTabs());
  }

  String _serializeTabs() {
    return _tabs.map((t) {
      final safeContent = t.content.replaceAll('\t', '\\t');
      return '${t.id}|${t.title}|$safeContent';
    }).join('\n\n__HELP_TAB_SPLIT__\n\n');
  }

  static List<_HelpTab> _loadPersisted(List<_HelpTab> defaults, String saved) {
    try {
      final chunks = saved.split('\n\n__HELP_TAB_SPLIT__\n\n');
      final result = <_HelpTab>[];
      for (final c in chunks) {
        final idx = c.indexOf('|');
        if (idx < 0) continue;
        final id = c.substring(0, idx);
        final rest = c.substring(idx + 1);
        final idx2 = rest.indexOf('|');
        if (idx2 < 0) continue;
        final title = rest.substring(0, idx2);
        final content = rest.substring(idx2 + 1).replaceAll('\\t', '\t');
        result.add(_HelpTab(id: id, title: title, content: content));
      }
      if (result.isEmpty) return defaults;
      return result;
    } catch (_) {
      return defaults;
    }
  }

  Future<void> _resetToDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认内容？'),
        content: const Text('当前所有 Tab（包括你改过的、新建的）会被替换成默认内容。\n此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final defaults = _defaultTabs();
    setState(() {
      _tabs = defaults;
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: defaults.length, vsync: this);
    });
    await _persist();
  }

  // ==============================================================
  // Tab 管理
  // ==============================================================

  Future<void> _createTab() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建 Tab'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Tab 名',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;

    final newTab = _HelpTab(
      id: 'user_${DateTime.now().microsecondsSinceEpoch}',
      title: name.trim(),
      content: '',
    );
    final next = [..._tabs, newTab];
    setState(() {
      _tabs = next;
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: next.length, vsync: this);
      _tabCtrl.index = next.length - 1;
    });
    await _persist();
    _enterEdit();
  }

  Future<void> _renameCurrent() async {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return;
    final ctrl = TextEditingController(text: _tabs[idx].title);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名 Tab'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final next = List<_HelpTab>.from(_tabs);
    next[idx] = next[idx].copyWith(title: name.trim());
    setState(() => _tabs = next);
    await _persist();
  }

  Future<void> _deleteCurrent() async {
    if (_tabs.length <= 1) {
      _snack('至少保留一个 Tab');
      return;
    }
    final idx = _tabCtrl.index;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除「${_tabs[idx].title}」？'),
        content: const Text('此 Tab 的内容会一并删除，无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final next = List<_HelpTab>.from(_tabs)..removeAt(idx);
    final newIdx = idx >= next.length ? next.length - 1 : idx;
    setState(() {
      _tabs = next;
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: next.length, vsync: this);
      _tabCtrl.index = newIdx;
    });
    await _persist();
  }

  // ==============================================================
  // 编辑
  // ==============================================================

  void _enterEdit() {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return;
    final t = _tabs[idx];
    _titleCtrl.text = t.title;
    _contentCtrl.text = t.content;
    setState(() => _editing = true);
  }

  void _cancelEdit() {
    setState(() => _editing = false);
  }

  Future<void> _saveEdit() async {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _snack('Tab 名不能为空');
      return;
    }
    final next = List<_HelpTab>.from(_tabs);
    next[idx] = next[idx].copyWith(title: title, content: _contentCtrl.text);
    setState(() {
      _tabs = next;
      _editing = false;
    });
    await _persist();
    _snack('已保存');
  }

  // ==============================================================
  // 字号缩放
  // ==============================================================

  void _onPointerDown(PointerDownEvent e) {
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 2) {
      _pinchStartDistance = _distanceBetweenTouches();
      _pinchStartScale = _fontScale;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length != 2 || _pinchStartDistance <= 0) return;
    final d = _distanceBetweenTouches();
    if (d <= 0) return;
    final next = (_pinchStartScale * d / _pinchStartDistance).clamp(_minScale, _maxScale);
    if ((next - _fontScale).abs() < 0.01) return;
    setState(() => _fontScale = next);
  }

  void _onPointerEnd(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2) _pinchStartDistance = 0;
    if (_touches.isEmpty) setState(() {});
  }

  double _distanceBetweenTouches() {
    final pts = _touches.values.toList(growable: false);
    if (pts.length < 2) return 0;
    return (pts[0] - pts[1]).distance;
  }

  void _resetFontScale() {
    if ((_fontScale - 1.0).abs() < 0.01) {
      _snack('已经是默认字号');
      return;
    }
    setState(() => _fontScale = 1.0);
    _snack('字号已重置');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    // 主动清缓存，让 GC 早回收。
    _cachedSheet = null;
    _cachedSheetScheme = null;
    super.dispose();
  }

  // ==============================================================
  // build
  // ==============================================================

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final s = Theme.of(context).colorScheme;
    final idx = _tabCtrl.index;
    final currentTab = (idx >= 0 && idx < _tabs.length) ? _tabs[idx] : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? '编辑 · ${_titleCtrl.text}' : '使用说明'),
        actions: _editing
            ? [
                TextButton(onPressed: _cancelEdit, child: const Text('取消')),
                FilledButton(onPressed: _saveEdit, child: const Text('保存')),
              ]
            : [
                IconButton(
                  tooltip: '重置字号（双指可缩放）',
                  icon: const Icon(Icons.format_size),
                  onPressed: _resetFontScale,
                ),
                TextButton(onPressed: _enterEdit, child: const Text('编辑当前 Tab')),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    switch (v) {
                      case 'create':
                        await _createTab();
                      case 'rename':
                        await _renameCurrent();
                      case 'delete':
                        await _deleteCurrent();
                      case 'reset':
                        await _resetToDefault();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'create', child: Text('新建 Tab')),
                    const PopupMenuItem(value: 'rename', child: Text('重命名当前 Tab')),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: _tabs.length > 1,
                      child: const Text('删除当前 Tab'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'reset', child: Text('恢复默认 Tab')),
                  ],
                ),
              ],
      ),
      body: Column(
        children: [
          // TabBar
          Container(
            color: s.surface,
            child: TabBar(
              controller: _tabCtrl,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final t in _tabs) Tab(text: t.title),
              ],
            ),
          ),
          const Divider(height: 1),
          // 内容 / 编辑器
          Expanded(
            child: _editing ? _buildEditor() : _buildContent(s, currentTab),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Tab 名',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _contentCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 13.5, height: 1.5, fontFamily: _fontFamilyMonospace),
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                contentPadding: const EdgeInsets.all(12),
                hintText: '在这里编辑说明（支持 Markdown 语法：# 标题、**加粗**、- 列表、> 引用、| 表格）……',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ColorScheme s, _HelpTab? tab) {
    if (tab == null) return const SizedBox.shrink();
    if (tab.content.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('（此 Tab 还没有内容。点右上角"编辑当前 Tab"写点什么。）'),
      );
    }

    final pinching = _touches.length >= 2;

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: SelectionArea(
        child: Scrollbar(
          thumbVisibility: true,
          child: SingleChildScrollView(
            physics: pinching ? const NeverScrollableScrollPhysics() : null,
            padding: const EdgeInsets.all(16),
            // ★ selectable: false —— 外层已经包了 SelectionArea。
            //   Markdown(selectable: true) 内部会再包一层 SelectionArea，
            //   Android 上双层需要构建两遍选区几何，几百个 widget 叠加起来
            //   能慢到秒级。只保留外层，功能不变（整页仍可长按选中复制）。
            child: Markdown(
              data: tab.content,
              selectable: false,
              styleSheet: _buildMarkdownStyleSheet(s, _baseFontSize * _fontScale),
            ),
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _buildMarkdownStyleSheet(ColorScheme s, double fontSize) {
    if (_cachedSheet != null &&
        _cachedSheetFontSize == fontSize &&
        identical(s, _cachedSheetScheme)) {
      return _cachedSheet!;
    }
    final sheet = MarkdownStyleSheet(
      h1: TextStyle(fontSize: fontSize * 1.48, fontWeight: FontWeight.bold, height: 1.5),
      h2: TextStyle(fontSize: fontSize * 1.26, fontWeight: FontWeight.bold, height: 1.5),
      h3: TextStyle(fontSize: fontSize * 1.11, fontWeight: FontWeight.w600, height: 1.5),
      p: TextStyle(fontSize: fontSize, height: 1.65),
      listBullet: TextStyle(fontSize: fontSize, height: 1.65),
      listIndent: 20,
      strong: const TextStyle(fontWeight: FontWeight.bold),
      em: const TextStyle(fontStyle: FontStyle.italic),
      code: TextStyle(
        fontSize: fontSize * 0.96,
        fontFamily: _fontFamilyMonospace,
        backgroundColor: s.surfaceVariant.withValues(alpha: 0.4),
      ),
      codeblockDecoration: BoxDecoration(
        color: s.surfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquote: TextStyle(fontSize: fontSize * 0.96, color: s.onSurfaceVariant, height: 1.6),
      blockquoteDecoration: BoxDecoration(
        color: s.surfaceVariant.withValues(alpha: 0.35),
        border: Border(left: BorderSide(color: s.primary, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      tableBorder: TableBorder.all(color: s.outlineVariant, width: 0.5),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      tableHead: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold),
      tableBody: TextStyle(fontSize: fontSize, height: 1.5),
      // ★ 不设 tableColumnWidth，让 flutter_markdown 用默认的 FlexColumnWidth。
      //   IntrinsicColumnWidth 需要两次 layout（intrinsic 预演 + 正常布局），
      //   表格越多、单元格越多越慢。去掉后显示效果几乎一样，
      //   只是列宽改成"平均分配"而不是"按内容自适应"。
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: s.outlineVariant, width: 0.5)),
      ),
    );
    _cachedSheet = sheet;
    _cachedSheetFontSize = fontSize;
    _cachedSheetScheme = s;
    return sheet;
  }
}

// ==============================================================
// Tab 数据类
// ==============================================================

class _HelpTab {
  const _HelpTab({
    required this.id,
    required this.title,
    required this.content,
  });

  final String id;
  final String title;
  final String content;

  _HelpTab copyWith({String? title, String? content}) => _HelpTab(
        id: id,
        title: title ?? this.title,
        content: content ?? this.content,
      );
}

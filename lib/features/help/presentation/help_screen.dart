import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用说明页。
/// 整页可编辑，编辑后保存到本地，重启后仍在。
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  static const String _prefKey = 'help_screen_content_v1';

  static const String _defaultContent = r'''
使用说明（本页可编辑：右上角"编辑"→ 改完后"保存"）

━━━━━━━━━━━━━━━━━
内置规则（长按规则名可重命名/隐藏）
━━━━━━━━━━━━━━━━━

每条规则可开关。
长按一条规则的名字/详情，可以重命名/隐藏这条规则。

执行顺序：规则从上到下依次跑。前面改了文本，后面看到的就是改后的。
比如"删掉空行"排到最前面，后面所有规则看到的都是删过空行的版本，行号也变了。
一般别把它拖到最前面。

━━━━━━━━━
批处理（普通文字）
━━━━━━━━━

用途：一次塞几百个要删除或替换的词（比如各种群号网站水印）。

每行一条，两种格式：

    xxx              ← 删掉 xxx
    xxx->=>yyy       ← 把 xxx 换成 yyy

普通文字匹配，不把任何字符当正则，填什么就匹配什么。

查找串里不写转义，写 \n 就匹配文中相邻的"反斜杠和n"。
只有替换串里才认这几个转义：
  \n → 换行
  \r → 回车
  \t → Tab
  \\ → 反斜杠
  \0 → 空字符

同一位置多条命中时，写在上面（行号靠前）的优先匹配。

替换产生的新文本不再被后面的规则处理。

不支持的：正则、捕获组、$1 引用。

编辑器底部显示"共 N 行"，改过没保存会标"未保存"。
编辑器顶部有一条提示，点开可以看详细说明，也可以自己改。
底部有"测试区"，展开后输入一段文字，实时看处理结果。

【详细解释】
查找串（->=> 左边）——不支持转义

写 \n → 匹配"反斜杠 + n"两个字面字符，不是换行。
写 \s → 匹配"反斜杠 + s"两个字面字符，不是空白。
写 \\ → 匹配"两个反斜杠"，不是"一个反斜杠"。

一句话：查找串里的 \ 就是个普通字符，你写啥就是啥。

替换串（->=> 右边）——支持 5 个转义

只认这几个：

你写 变成
\n  换行
\r  回车
\t  Tab
\\  一个反斜杠
\0  空字符（U+0000）

其它的（比如 \s、\d、\w）不认，原样输出"反斜杠 + 那个字母"。

转义 为什么支持
\n  换行没法直接敲
\r  回车没法直接敲
\t  Tab 键被界面吃掉了
\0  键盘上没这个键
\\  上面用了 \ 做转义，得有个办法输出 \ 本身

━━━━━━━━━
批处理（支持正则）
━━━━━━━━━

格式和关键词一样，但查找串是正则表达式：

    xxx              ← 匹配 xxx 就删掉
    xxx->=>yyy       ← 匹配 xxx 替换成 yyy

替换串里可以用 $1、$2 引用捕获组。
比如查找 (\d+)-(\d+)，替换 $2-$1，就能把 12-34 变成 34-12。

正则里转义是真生效的：
  \n → 换行   \s → 空白   \d → 数字   \w → 字母数字下划线

执行方式：严格按行顺序，从上到下依次执行。
前一条的结果，就是后一条的输入。
替换产生的新文本会被后面的规则处理。

改一条会立刻影响下一条，跟关键词块不同。

非法正则会跳过，不影响其它行。

举例对比

假设你想删除文本里所有的反斜杠：

· 普通文字表：
  · 查找：\　替换：留空 → ✅ 能删掉反斜杠
  
  但如果你想删"反斜杠 + n"这两个字符：
    查找：\n（敲一个反斜杠一个 n）　替换：留空 → ✅ 匹配这两个字面字符

· 正则表：
  · 查找：\\　替换：留空 → ✅ 删一个反斜杠（正则里 \\ 表示一个字面反斜杠）

总结

项目 普通文字表 正则表
支持正则 ❌ ✅
查找串支持反斜杠转义 ❌（原样当字面字符） ✅（\n \d \s 等）
替换串支持反斜杠转义 ✅（只 5 个：\n \r \t \\ \0） ✅（同左）


━━━━━━━━━━━━━━━━━━━━━
自定义规则（长按规则名可编辑/重命名/删除）
━━━━━━━━━━━━━━━━━━━━━

点列表底部"新建规则"，或者编辑列表里已有的自定义规则编辑。
可以选三种类型：查找替换、预置功能、JS 脚本。

选"查找替换"时，有 7 个开关：

查找侧（三选一）：
  · 支持正则：按正则解析。
  · 仅字面匹配：特殊符号当普通字符。
  · 支持转义：把 \n \r \t \\ \0 还原成真字符再找。

替换侧（至少开一个）：
  · $1 $2 引用：替换串里用 $1 $2 引用捕获组。
  · \1 \2 引用：同上，另一种写法。
  · 仅字面输出：不展开引用，原样输出。
  · 支持转义：把 \n \r \t \\ \0 还原成真字符再输出。

作用范围（三选一）：
  · 两侧文件：左右都应用
  · 仅左侧文件
  · 仅右侧文件

长按任意开关的标签，可以看它详细说明。说明还能自己改。

互斥规则：
  查找侧三个里，必须开且只开一个（支持正则 / 仅字面）。
  替换侧三个里，至少开一个（$1引用 / \1引用 / 仅字面输出）。


━━━━━━━━━━━━━
自定义规则里预置功能清单
━━━━━━━━━━━━━

预置功能是写好的现成操作，选一个填参数就行，不用自己写规则。

行操作：
  · 按关键词过滤行：保留或删除含指定关键词的行
  · 截取第 N 到第 M 行
  · 删除空行 / 删除纯空白行
  · 加行号 / 非空行加行号
  · 行首尾去空白 / 只去行首 / 只去行尾
  · 合并所有行为一行

字符替换：
  · 删除所有出现的字符串
  · 替换所有出现的字符串

空白处理：
  · 删除所有空格 / 删除所有 Tab / 删除所有空白
  · 删除所有标点 / 删除所有数字 / 删除所有英文 / 删除所有非中文
  · 删除不可见字符
  · 连续空白折叠成一个空格
  · 连续换行折叠成一个 / 连续 N 换行折成 M 个
  · 连续点号折成省略号
  · 删除行尾多余空格

大小写与全半角：
  · 小写转大写
  · 全角转半角 / 半角转全角 / 全角空格转半角
  · Tab 转 N 个空格 / N 个空格转 Tab

标点转换：
  · 中文标点转英文 / 英文标点转中文
  · 中文引号统一（几种样式可选）

数字：
  · 数字替换成占位符
  · 中文数字转阿拉伯（一二三 → 123）
  · 阿拉伯数字转中文（123 → 一二三 / 一百二十三）

Unicode：
  · 规范化 Unicode（NFC）


━━━━━
JS 脚本
━━━━━

如果你懂一点编程，可以写 JavaScript 处理文本。

  · 有一个变量 text，是整段输入。
  · 最后一行写你的处理结果，作为输出。
  · 想调试可以用 console.log。

例子（在编辑器里点"示例"能看到更多）：

  去掉空行：
    text.split('\n').filter(l => l.trim()).join('\n')

  去掉重复行：
    [...new Set(text.split('\n'))].join('\n')

  每行前加行号：
    text.split('\n').map((l, i) => `${i + 1}. ${l}`).join('\n')

  只保留含"第X章"的行：
    text.split('\n').filter(l => /^第\d+章/.test(l)).join('\n')

注意：JS 比原生规则慢，大文本时尽量把 JS 规则排到最后。

━━━━━━━━━
对比规则设置相关
━━━━━━━━━

先约好：

  a1 = 你导入的左边原始文件，永远不变
  b1 = 你导入的右边原始文件，永远不变

  A2 = 你第一次进对比页，屏幕上看到的左边
  B2 = 你第一次进对比页，屏幕上看到的右边

  A3、A4、A5 = 你在左边改过之后，屏幕上看到的左边
  B3、B4、B5 = 右边同理

一句话：小写 a、b 是原始文件；大写 A、B 是屏幕上看到的。

    屏幕上看到的 = 原始文件（或你的改动）再过一遍规则


● 你改规则之前，屏幕上的样子

  1. 点对比        → 屏幕左 A2、右 B2
  2. 长按改左边某行  → 屏幕左 A3、右 B2
  3. 查找替换改左边  → 屏幕左 A4、右 B2

  现在：左 A4，右 B2。你点三个点 → 进比较设置。

● 返回时会发生什么？看三种情况

【情况 1】只看看，没动任何开关，返回

  无变化。

【情况 2】关掉一个开关（或加了一条规则），返回

  系统发现规则跟进去前不一样了，弹一个窗：

  点"取消" → 弹窗关掉，人还在比较设置页，可以继续改。
  点"确定返回" → 退出比较设置，回到对比页。
      屏幕闪一下"正在计算"，然后：
      左边 A4 过一遍规则 → 变 A5
      右边 B2 过一遍规则 → 变 B3

【情况 3】改了，又改回去了，返回

  无反应


● 返回时，所有开着的规则从头到尾全跑一遍：
    · 你新加/新关的那条 → 跑
    · 内置规则（原来开着的）→ 也跑
    · 关键词表 → 也跑
    · 正则表 → 也跑

  一条不落，按你设的顺序，从头跑到尾。
  不是只跑你动的那条。

──────────────

● 两个入口，同一个房间

  比较设置有两个门进，里面是同一个房间、同一台加工机。

  从哪个门进          改完返回后
  文件浏览器（还没对比） 加工机存好了，下次点对比才用
  对比页（正在对比）    弹窗确认后，当场重算，立刻看到新的对比结果

  【文件浏览器那个门】
    你还在文件列表，还没点对比。
    改了加工机，返回，屏幕上还是文件列表，看不到任何变化。
    加工机先放着。等你点了对比，才拿它加工 a1、b1。
    一句话：先存着，下次用。

  【对比页那个门】
    你正看着 A4、B2。改了加工机，返回。
    先弹窗问你确认（见"情况 2"），点确定后才重算：
      左边 A4 → A5
      右边 B2 → B3
    一句话：存了，确认后马上用。

  为什么不一样？
    · 文件浏览器：你还没进对比，没内容可加工，只能"存着"。
    · 对比页：你正在看内容，有东西可加工，所以"马上算"。

  加工机是同一台，改的也是它。区别只在什么时候用。

──────────────

● 记住这三句就够了

  1. 比较设置只管加工机，不碰文件。
  2. 屏幕上看到的，永远是"过完加工机"的样子。
  3. 换了加工机，左右两边都重新过一遍，所有规则全跑，
     不是只跑你改的那条规则。
     

''';

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _editing = false;
  bool _loaded = false;

  static const double _baseFontSize = 13.5;
  static const double _minScale = 0.5;
  static const double _maxScale = 3.0;

  double _fontScale = 1.0;

  final Map<int, Offset> _touches = <int, Offset>{};

  double _pinchStartDistance = 0;
  double _pinchStartScale = 1.0;

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  Future<void> _loadContent() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (!mounted) return;
    setState(() {
      _controller.text = saved ?? _defaultContent;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, _controller.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存')),
    );
    setState(() => _editing = false);
  }

  Future<void> _resetToDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认内容？'),
        content: const Text('当前修改将丢失，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    if (!mounted) return;
    setState(() {
      _controller.text = _defaultContent;
    });
  }

  void _onPointerDown(PointerDownEvent e) {
    _touches[e.pointer] = e.localPosition;
    if (_touches.length == 2) {
      _pinchStartDistance = _distanceBetweenTouches();
      _pinchStartScale = _fontScale;
      setState(() {});
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length != 2 || _pinchStartDistance <= 0) return;
    final d = _distanceBetweenTouches();
    if (d <= 0) return;
    final next =
        (_pinchStartScale * d / _pinchStartDistance).clamp(_minScale, _maxScale);
    if ((next - _fontScale).abs() < 0.01) return;
    setState(() => _fontScale = next);
  }

  void _onPointerEnd(PointerEvent e) {
    final removed = _touches.remove(e.pointer) != null;
    if (!removed) return;
    if (_touches.length < 2) _pinchStartDistance = 0;
    if (_touches.isEmpty) {
      setState(() {});
    }
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
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final readFontSize = _baseFontSize * _fontScale;
    final pinching = _touches.length >= 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('使用说明'),
        actions: [
          if (_editing) ...[
            TextButton(
              onPressed: () => setState(() => _editing = false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
          ] else ...[
            IconButton(
              tooltip: '重置字号（阅读时双指可缩放）',
              icon: const Icon(Icons.format_size),
              onPressed: _resetFontScale,
            ),
            TextButton(
              onPressed: () => setState(() => _editing = true),
              child: const Text('编辑'),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'reset') _resetToDefault();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reset', child: Text('恢复默认内容')),
              ],
            ),
          ],
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _editing
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      fontFamily: 'monospace',
                    ),
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      contentPadding: const EdgeInsets.all(12),
                      hintText: '在这里编辑使用说明……',
                    ),
                  ),
                )
              : Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerEnd,
                  onPointerCancel: _onPointerEnd,
                  child: SelectionArea(
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      interactive: true,
                      thickness: 11,
                      radius: const Radius.circular(5),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: pinching
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        padding: const EdgeInsets.only(
                          left: 16,
                          right: 24,
                          top: 16,
                          bottom: 24,
                        ),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: s.surfaceVariant.withOpacity(0.35),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _controller.text,
                            style: TextStyle(
                              fontSize: readFontSize,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
    );
  }
}

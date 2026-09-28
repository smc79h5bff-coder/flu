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

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
一、怎么对比两份文档
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

打开 App 就是文件浏览器，里面能看到手机里的文件夹和文件。

步骤：
  1. 进入两份文件所在的文件夹。
  2. 长按第一个文件，进入多选模式（文件左边出现方框）。
  3. 点第二个文件，把它也选上。
  4. 底部出现"对比"按钮，点它，开始对比。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
二、文件浏览器
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

进入文件夹：点任意文件夹进入，左上角 ← 返回上一级。
预览文件：点非文本文件 → 打开预览页（只读，最多显示前 100 KB）。
打开文本：点文本类文件 → 进入编辑器（可以改、可以存）。
多选：长按任意文件或文件夹，进入多选模式。
新建文件夹：右下角浮动按钮。
搜索：顶部搜索框，输入关键词后点搜索按钮或回车。

顶部标题栏那行有这些：
  · 长按标题 → 弹出"跳转到目录"，可粘贴完整路径直接跳。
    粘贴的是文件路径时，会自动跳到那个文件所在的目录。
  · 星形图标 → 收藏 / 取消收藏当前目录。
  · 齿轮图标 → 打开比较设置。
  · 三个点 → 刷新、排序方式、已收藏目录。

面包屑导航：标题栏下方那行，显示当前路径，点任意一级跳过去。

排序：按名称 / 修改时间 / 大小，可升序或降序。

文件图标颜色：
  · 蓝色 = 文本类文件（能打开、能编辑）
  · 橙色 = 二进制文件（图片、视频、压缩包等）
  · 灰色 = 不确定类型

文件夹图标是黄色的。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
三、搜索文件
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

搜索：顶部搜索框输入关键词，点搜索按钮或回车开始。
搜索范围：长按左侧搜索按钮 → 弹出菜单：
  · 当前目录及子目录
  · 自定义范围（只在勾选过的文件夹里找）
  · 管理已勾选文件夹

自定义范围怎么设：
  1. 长按搜索按钮 → 选"管理已勾选文件夹"。
  2. 浏览目录，点文件夹左边的方框勾选。
  3. 可以勾多个。底部显示"已勾选 N 个"，点"查看"能看到清单。
  4. 确定后，搜索时只扫这些目录。

搜索结果：
  · 最多显示 500 个。
  · 点结果可打开预览；长按进入多选。
  · 扫描时自动跳过 /Android/data 和 /Android/obb。

取消搜索：点搜索框右侧的 ✕，或点搜索状态栏的"取消"。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
四、多选后的操作
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

选中文件后，底部会出现操作栏：

  · 对比：选中恰好 2 个文件时可用，开始对比。
  · 属性：看单个文件的大小、时间、路径。只能选 1 个时用。
  · 复制路径：把完整路径复制到剪贴板。只能选 1 个时用。
  · MD5：选中恰好 2 个文件时可用，算两个文件的 MD5 并对比是否相同。
  · 重命名：只能选 1 个时用。
  · 移动：把选中的文件 / 文件夹挪到别的目录。
  · 复制：把选中的文件 / 文件夹复制到别的目录。
  · 删除：从磁盘删掉，删前会弹确认。

长按某个文件或文件夹也能进入多选，不用先点。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
五、对比页 - 顶栏与视图
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

顶栏从左到右：
  · ↑：跳到上一处差异。长按它跳到文档最开头。
  · ↓：跳到下一处差异。长按它跳到文档最结尾。
  · 放大镜：打开查找 / 替换栏。
  · 更多操作。

视图切换（顶栏下方四个按钮）：
  · 差异上下文行：差异行 + 上下各 2 行。默认这个。
  · 纯差异：只显示变化的行，不带上下文。
  · 并排：左右两栏逐行对齐，同一个逻辑行左右对照。
  · 合并：原版 / 修改版交错单栏显示。

切视图时会弹窗问你切过去之后要跳到哪个位置：
  · 如果正在搜索，会提供"跳到我搜的那个词"。
  · 否则提供"屏幕第 1 / 2 / 3 行"、"屏幕顶部再往上一点"、"跳到文件最开头"。
  · 这样切换视图后不会迷失位置。

顶部横幅：
  · 差异少于 6 处时：粉色横幅显示"共 N 处差异"，完全相同就显示"两份文档完全相同"。
  · 两份文件编码不同时：黄色横幅提示。
  · 删过左 / 右文件时：红色横幅提示（内容只在内存里，没写盘）。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
六、对比页 - 查找与替换
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：对比页顶栏放大镜。

查找：
  · 输入关键词后，命中的字变浅黄。
  · 停手一下， 上 / 下箭头、替换按钮才会亮。
  · 当前停在哪一处，那一处变粉色加粗。
  · 上一处 / 下一处：在命中之间来回跳。
  · 历史按钮：可以看以前搜过什么，可删除某条。

替换：
  · 在"替换为"框里填替换内容。留空 = 删掉。
  · 替换当前：只换当前这一处。
  · 全部替换：一次换完所有命中。
  · 替换不会立刻生效，先攒在缓存里。
  · 攒完之后点"应用并刷新"，才真正生效并重新对比。
    连续替换好几个词时，先攒着最后一次应用，比每次等重算快得多。
  · 关闭查找栏时如果有没应用的替换，会问你：取消 / 放弃 / 应用并关闭。

选项：
  · 查左侧 / 查右侧：至少开一个。关掉某一侧就不在那一侧查找替换。
  · 正则：开启后查找串按正则解析，替换串里能用 $1 $2。
    长按"正则"按钮打开正则速查页。
  · 忽略大小写：A 和 a 视为相同。
  · 整词：只匹配完整英文单词，对中文无效。

小提示：
  · 如果当前视图搜不到，但别的视图里有，顶部会提示你切过去。
  · 长按任意按钮都能看到它的说明。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
七、对比页 - 自定义按钮栏
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

在视图切换下面有一条按钮栏，可以放你自己常用的规则。

  · 点 + 新建一个按钮，填好规则后它就出现在栏里。
  · 点按钮：弹出小菜单，问你这条规则要用到哪一侧（左 / 右 / 两侧）。
  · 长按按钮：编辑这条规则。
  · 点右侧的"排序"图标：拖动排序，也可以在这里给按钮设颜色。
  · 设颜色：每个按钮都能单独设背景色、文字色、边框色。
    不设就用默认（白底黑字）。
  · 删除按钮：在排序弹窗里点删除图标。

按钮栏左边一排是自定义按钮，可以左右滑动。右边两个固定：新建、排序。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
八、对比页 - 长按某一行
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

长按任意一行，弹出菜单：
  · 复制左边此行
  · 复制右边此行
  · 编辑此行：直接改这一行的内容，改完点确定。

编辑后会立即生效（会重算对比）。位置会自动保持在原来附近。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
九、对比页 - 更多操作
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

点顶栏三个点，弹出菜单：

  · 编辑对比中的 2 个文档：进入双栏编辑页（后面单独说）。
  · 导出差异为 txt：选导出左边还是右边。
      导出的内容 = 这一侧"独有的差异片段"，逐行列出。
  · 删除左边文件 / 删除右边文件：从磁盘删除。
      删前显示路径、大小、时间，防止删错。
  · 显示设置：行号、字号、12 种差异颜色（后面详细说）。
  · 比较设置：进去管理预处理规则。
  · 不换行：开启后超长行不折行，可以在各自半屏里左右滑动查看。
  · 两栏同步滚动：并排视图下，左右两栏上下一起滚 / 各自滚。
  · 性能面板：显示上次对比的耗时信息，平时不用开。
  · 横屏 / 竖屏：切成横屏方便并排看长文。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十、显示设置
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：对比页三个点 → 显示设置。

可调项：
  · 显示行号（开 / 关）
  · 正文字号（拖动滑块）
  · 行号字号（拖动滑块）
  · 12 种差异颜色：
      左文件独有行 · 整行底色 / 文字颜色
      右文件独有行 · 整行底色 / 文字颜色
      被改行（左） · 整行底色 / 文字颜色
      被改行（右） · 整行底色 / 文字颜色
      行内删掉的字 · 底色 / 文字颜色
      行内新增的字 · 底色 / 文字颜色
    点色块可以改，支持拖色板或直接输入 #RRGGBB。

所有显示设置都会保存，下次打开还是这个样。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十一、比较设置 - 规则列表
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口两个：
  · 文件浏览器右上角齿轮 → 比较设置
  · 对比页三个点 → 比较设置

这个页面列着一堆规则，从上到下依次执行。

列表里有三类东西，可以混在一起排：
  1. 单条规则：一条一条的开关，可拖动排序。
     内置规则只能开关，不能改不能删。
     自定义规则可以开关、编辑、删除。
  2. 普通文字规则表：一整块文本，一行一条，普通文字匹配。
  3. 正则规则表：一整块文本，一行一条，按正则匹配。

排序：按住左侧的拖动手柄上下拖。

页面上方那条提示可以点，可以记笔记。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十一附、比较设置相关
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
  对比页（正在对比）    弹窗确认后，当场重算，立刻看到新结果

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
     不是只跑你改的那条。
     
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十二、内置规则
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

只能开关，不能删除。

执行顺序：规则从上到下依次跑。前面改了文本，后面看到的就是改后的。
比如"删掉空行"排到最前面，后面所有规则看到的都是删过空行的版本，行号也变了。
一般别把它拖到最前面。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十三、规则表（普通文字）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用途：一次塞几百个要删除或替换的词（比如各种群号网站水印）。

每行一条，两种格式：

    xxx              ← 删掉 xxx
    xxx->=>yyy       ← 把 xxx 换成 yyy

普通文字匹配，不把任何字符当正则，填什么就匹配什么。

查找串里不写转义，写 \n 就匹配文中的"反斜杠和n"。
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


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十四、规则表（支持正则）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

格式和关键词一样，但查找串是正则表达式：

    xxx              ← 匹配 xxx 就删掉
    xxx->=>yyy       ← 匹配 xxx 替换成 yyy

替换串里可以用 $1、$2 引用捕获组。
比如查找 (\d+)-(\d+)，替换 $2-$1，就能把 12-34 变成 34-12。

正则里转义是真生效的：
  \n → 换行   \s → 空白   \d → 数字   \w → 字母数字下划线

执行方式：严格按行顺序，从上到下依次执行。
前一条的结果，就是后一条的输入。

改一条会立刻影响下一条，跟关键词块不同。

非法正则会跳过，不影响其它行。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十五、自定义规则（7 个开关）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

点列表底部"新建规则"，或者长按列表里已有的自定义规则编辑。
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


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十六、预置功能清单
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十七、JS 脚本
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

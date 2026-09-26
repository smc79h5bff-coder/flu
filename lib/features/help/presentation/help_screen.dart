import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用说明页。
/// 整页可编辑，编辑后保存到本地，重启后仍在。
///
/// 本页不使用任何 Icon，全部用普通文字符号，避免打包后图标缺失。
/// 阅读态支持双指捏合缩放字号，右上角小图标一键重置。
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
一、浏览文件、选中两个开始对比
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

进入文件夹：点任意文件夹进入；左上角 ← 返回上一级。
预览文件：点文件 → 打开预览页（只读，最多显示前 100 KB）。
进入多选：长按任意文件或文件夹。
多选下勾选：点一下切换勾选状态。
选中 2 个文件后：底部出现「对比」按钮，点击开始。
其它按钮：底部还有 属性 / 复制路径 / MD5 / 重命名 / 移动 / 复制 / 删除。
新建文件夹：右下角浮动按钮。

提示：对比的是两份文件，谁先选谁是"左边"，后选的自动是"右边"。
支持 txt / docx 以及常见文本类扩展名（md、log、json、代码等）；图片 / 音视频 / 压缩包 / PDF 等二进制格式会提示"暂不支持"。

【隐藏技巧】
· 长按顶部标题栏 → 跳转目录（可粘贴完整路径，粘的是文件路径会自动跳到所在目录）。
· 面包屑导航（标题栏下方那行）可点击跳回上层目录。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
二、搜索文件
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

搜索：顶部搜索框输入关键词，点搜索按钮或回车开始。
搜索范围：长按搜索按钮 → 弹出菜单选「当前目录及子目录」或「自定义范围」。
自定义范围：选「管理已勾选文件夹」勾选若干目录，搜索时只扫这些目录。
取消：点搜索框右侧的 ✕ 清空，或点搜索状态栏的「取消」中止。

搜索结果最多显示 500 个；点击结果可打开预览，长按可进入多选。
扫描时自动跳过 /Android/data 和 /Android/obb 目录。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
三、长按操作速查
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

App 里有很多长按触发的小功能，集中列在这里。

【文件浏览器】
· 长按顶部标题栏：弹出"跳转到目录"对话框。可粘贴完整路径直接跳转；粘贴的是文件路径会自动跳到该文件所在目录。
· 长按搜索按钮：弹出搜索范围菜单——当前目录及子目录 / 自定义范围 / 管理已勾选文件夹。
· 长按任意文件或文件夹：进入多选模式。
· 长按搜索结果：进入多选模式。

【对比页】
· 长按查找栏"正则"按钮：打开正则帮助页（正则速查）。
· 长按"忽略大小写"：弹提示"开启后 A 和 a 视为相同"。
· 长按"整词"：弹提示"只匹配完整单词，对中文无效"。
· 长按任意一行：弹出菜单——复制左边此行 / 复制右边此行 / 编辑此行。

【通用】
· 长按文字：帮助页、正则帮助页里的所有文字都可以长按选中复制（含代码块）。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
四、比较设置总览
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口一：文件浏览器右上角齿轮 → 「比较设置」。
入口二：对比页右下角 ⋮ → 「比较设置」。

页面上是一个统一的规则列表，**从上到下依次执行**。可以按住左侧手柄上下拖动任意一项，调整执行顺序。列表里有三类东西：

1. 单条规则：每条一个开关，可拖动排序。内置规则（标 🔒）只能开关，自定义规则可开关、编辑、删除。
2. 关键词规则：一整块文本，一行一条，普通文字匹配。
3. 正则规则：一整块文本，一行一条，按正则表达式匹配。

三样东西混在同一个列表里，可以随意穿插。比如把关键词块拖到某两条单条规则中间，它就那个位置执行。

应用顺序：完全由列表顺序决定，从上到下。
所有设置本地保存，重启后仍生效。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
五、单条规则（内置 + 自定义）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

内置规则：开发者写死的一组规则，只有开关，不能改不能删。标 🔒。
自定义规则：点列表底部"新建规则"新建。填规则名、查找正则、替换串，选作用范围（两份 / 仅原文 / 仅修改版）。每条带开关，可编辑、可删除。

内置规则里现在有这么几条（原「忽略项」已并入这里，不再单独存在）：

  统一换行                     \r\n|\r → \n
  折叠多余空白                 [ \t]{2,} → 空格
  去行首尾空白                 行首/行尾的空白删掉
  中英文引号统一                中英文引号统一成 "
  逗号空格归一                 逗号后的多个空格压成一个
  忽略不可见字符                删除零宽空格、BOM 等
  删掉空白符号                 空格和 Tab 全删掉
  删掉空行                     纯空行删掉（会改行数，注意顺序）
  忽略逗号                     逗号全删掉
  忽略纯数字                   连续数字变成 <NUM>
  大写全转成小写               A 和 a 视为相同
  统一编码 ANSI                非 ANSI 字符删掉，慎用

关于执行顺序：规则从上到下依次跑。前面改了文本，后面看到的就是改后的文本。比如"删掉空行"排到最前，后面所有规则看到的都是删过空行的版本，行号也会跟着变。一般情况下别把它拖到最前面。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
六、关键词规则（批量删除/替换）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用途：一次塞几百个要删除或替换的词（比如"xx小说网"、"xx整理"）。
每行一条，格式：

    xxx              ← 删掉 xxx
    xxx->=>yyy       ← 把 xxx 换成 yyy

普通文字匹配：不把任何字符当正则，填什么就匹配什么。
替换串支持转义：\n \r \t \\ \0 会被还原成真正的控制字符。
性能优势：一次扫描命中所有词（Aho-Corasick），规则再多也不变慢。
不支持：正则、捕获组、$1 引用。替换串里的 $1 会原样输出。

示例：

    xx小说网
    xx整理
    第一版->=>第二版
    摘要->=>概要

编辑器底部显示"共 N 行"，未保存时会标注"未保存"。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
七、正则规则（高级匹配）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

格式和关键词一样，但匹配串是正则表达式：

    xxx              ← 匹配 xxx 就删掉
    xxx->=>yyy       ← 匹配 xxx 替换成 yyy

捕获组：替换串里用 $1、$2 引用正则中的括号内容，如 (\d+) 对应 $1。
非法正则：会被跳过，不影响其它行。
纯文本 find：不含正则元字符的自动走 String.replaceAll 快路径，目标串不存在时直接跳过。

常用正则写法见下一节速查表。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
八、正则速查表（想写什么，查这里）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

— 数字 —
    \d              任意一位数字 0-9
    \d+             连续数字（如 123）
    \d{3}           正好 3 位数字
    \d{2,5}         2 到 5 位数字
    [０-９]          全角数字
    \d+\.\d+        小数（如 3.14）

— 英文 —
    [a-zA-Z]        任意一个英文字母
    [a-z]           小写字母
    [A-Z]           大写字母
    [a-zA-Z]+       连续英文字母
    \w              字母、数字或下划线
    [a-zA-Z]{4,}    4 个以上连续字母（如英文单词）

— 中文 —
    [一-龥]         任意一个常用汉字
    [一-龥]+        连续汉字
    [\u4e00-\u9fa5]  同 [一-龥]，更完整写法

— 空白 —
    \s              任意空白（空格 / Tab / 换行）
    \S              任意非空白
    [ \t]           空格或 Tab
    \n              换行
    \r              回车
    ^\s*$           空行（整行只有空白）

— 标点 —
    ，。！？；：       中文标点（直接在 [ ] 里列出来）
    [,;:!?]         英文标点（! ? 在正则里是特殊字符，放在 [ ] 里就是普通字符）
    「」『』""''     中文引号
    [.。…⋯]{2,}      连续 2 个以上点号/省略号

— 量词 —
    *               前面出现 0 次或多次
    +               前面出现 1 次或多次
    ?               前面出现 0 次或 1 次
    {n}             正好 n 次
    {n,}            至少 n 次
    {n,m}           n 到 m 次

— 位置 —
    ^               行首
    $               行尾
    \b              单词边界

— 组合 —
    [...]           括号里任选一个
    [^...]          除了括号里的任意字符
    a|b             a 或 b
    (...)           分组，替换串里用 $1 引用
    .               任意字符（不含换行）

— 常见完整例子 —
    \d{4}-\d{2}-\d{2}      日期 2024-01-01
    \d{11}                 11 位数字（如手机号）
    [a-zA-Z0-9._%-]+@[a-zA-Z0-9.-]+  邮箱
    https?://\S+           网址
    <[^>]+>                 HTML 标签
    第\d+章                 "第1章"、"第23章"


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
九、常用正则组合（直接抄）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

把下面任意一行粘到"正则规则"编辑器里就能用。

— 标点归一 —
    [.。…⋯]{2,}->=>…        连续点号→省略号
    (\r?\n)[\r\n]+->=>$1    连续换行只留一个
    …{2,}->=>…              连续省略号压成一个
    [,，]{2,}->=>，          连续逗号归一

— 删内容 —
    <[^>]+>                 删掉 HTML 标签
    https?://\S+            删掉网址
    \d+                     删掉所有数字
    第\d+章.*               删掉"第N章"开头整行
    ^\s*$                   删掉纯空行

— 清空白 —
    ^[ \t]+                 删掉每行开头空格/Tab
    [ \t]+$                 删掉每行结尾空格/Tab
    [ \t]+->=>              多个空格/Tab压成一个空格
    \n{3,}->=>\n\n          连续空行只留一个空行

— 替换 —
    \d+->=>N                数字换成字母 N
    “->=>"                  中文左引号→英文引号
    ”->=>"                  中文右引号→英文引号
    ，->=>,                  中文逗号→英文逗号
    。->=>.                  中文句号→英文句号

— 组合示例（批量清洗小说） —
    [.。…⋯]{2,}->=>…
    (\r?\n)[\r\n]+->=>$1
    [ \t]+->=> 
    ^\s*$
    xx小说网
    xx整理

上面这一组：点号归一 + 换行归一 + 空格归一 + 删空行 + 删两处水印。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十、特殊字符怎么写
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

替换串里，这些转义会被还原：

    \n   → 换行
    \r   → 回车
    \t   → 制表符 (Tab)
    \\   → 一个反斜杠 \
    \0   → 空字符（NUL）

例：

    第\d+章->=>\n          每章前加换行
    分隔线->=>\n\n        换成两个换行
    制表位->=>\t           换成 Tab
    反斜线->=>\\           换成 \ 一个字符

注意事项：
· 匹配串里不写转义：要匹配真正的换行，正则里写 \n 或 [\r\n]。
· 其它 \x：未被识别的（如 \d、\w）原样保留，不报错。
· 字面反斜杠：想替换成 "\n" 这两个字符（而不是换行），写 \\n。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十一、自定义规则与内置规则的差别
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

两者都在同一个列表里，都能开关、能拖动排序。差别只有：

· 内置规则：开发者写死，标 🔒，不能改内容、不能删。
· 自定义规则：能新建、编辑、删除。

什么时候用自定义规则？
· 只对左侧（原版）或右侧（修改版）生效 → 内置和关键词/正则块做不到。
· 需要临时停用某一条 → 关键词/正则规则要删行，自定义规则拨开关即可。
· 需要 $1 捕获组展开 → 关键词规则不支持，正则规则也不支持，只有自定义规则支持（走 PreprocessingService 的 _expandReplacement）。

注意：关键词块和正则块内部虽然也是"很多条替换"，但整块只有一条命，不能单独关掉块里某一行。想单独控制就拆出来用自定义规则。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十二、对比页
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

顶栏从左到右：
· ↑：跳到上一处差异。
· ↓：跳到下一处差异。
· 放大镜：打开查找/替换栏。
· ⋮：更多操作（编辑文档、导出差异、删除左/右文件、显示设置、比较设置、开启/关闭不换行、开启/关闭两栏同步滚动、性能面板、横屏）。

视图切换（顶栏下方四个按钮）：
· 差异上下文行（默认）：差异行 + 上下各 2 行上下文。
· 纯差异：只显示发生变化的行，不带上下文。
· 并排：左右双栏逐行对齐，同一逻辑行左右对照。
· 合并：原版/修改版交错单栏显示。

切换视图时会弹一个对话框，问你切过去后要跳到哪个位置：
· 如果正在搜索，会提供"跳到我搜的那个词"。
· 否则提供"屏幕第 1 / 2 / 3 行"、"屏幕顶部再往上一点"、"跳到文件最开头"。

顶部横幅：
· 差异少于 6 处时：显示"共 N 处差异"或"两份文档完全相同"。
· 两份文件编码不同时：黄色横幅提示。
· 删除过左/右文件时：红色横幅提示（内容仅内存保留）。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十三、查找 / 替换
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：对比页顶栏放大镜。

查找：
· 输入关键词：实时高亮当前视图里所有命中，默认浅黄；当前停留的一处为粉色加粗。
· 上一个 / 下一个：在命中之间跳转。
· 范围：四种视图都支持。
· 差异视图搜不到时：若全量里有命中，顶部会弹提示，引导切到并排/合并视图。

替换：
· 替换为：在输入框填替换内容。留空 = 删掉。
· 替换当前 / 全部替换：替换命中处（进缓存，不立即生效）。
· 应用并刷新：右下角按钮，点一下才真正生效、重新对比。连续替换多个词时先攒着，最后一次应用，速度快很多。
· 关闭查找：若有未应用的替换，会弹窗问"取消 / 放弃 / 应用并关闭"。

选项：
· 查左侧 / 查右侧：至少开一个。关掉某一侧就不在那一侧查找/替换。
· 正则：开启后查找串按正则解析，替换串支持 $1 $2。长按"正则"按钮打开正则帮助。
· 忽略大小写：A 和 a 视为相同。
· 整词：只匹配完整英文单词，对中文无效。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十四、导出差异
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：对比页 ⋮ →「导出差异为 txt」。
选择左右：弹出选择"导出左边文件的差异处"或"导出右边文件的差异处"。
只导一侧：一次只导一个 txt；想两个都导就点两次，分别选左边、右边。
导出内容：把每处差异中"该侧独有的片段"逐行列出。

示例：左边"我爱中国" 右边"我爱中国啊"
→ 导出左边：无；导出右边：啊
示例：左边"abc123" 右边"abc456"
→ 导出左边：123；导出右边：456


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十五、编辑与保存
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：对比页 ⋮ →「编辑对比中的 2 个文档」，进入逐行对齐双栏编辑页。
两侧都能改：左栏是原版，右栏是修改版。
查找/替换：右上角放大镜：查找高亮、上一处/下一处、替换当前、全部替换；"正则:开/关"按钮切换正则模式。
保存：右上角"保存"。一律"另存为"，弹系统对话框选位置，绝不覆盖原文件。两份文件会依次弹出两次保存对话框，请分别选位置。

提示：编辑会先写入内存，点"保存"才落盘为新文件。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十六、显示设置
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：对比页 ⋮ →「显示设置」。
可调项：行号显示 / 隐藏、正文字号、行号字号、12 种差异颜色。
差异颜色：左文件独有行、右文件独有行、被改行（左/右）、行内删掉的字、行内新增的字——各有底色和文字颜色。

所有显示设置都会保存，重启后仍生效。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十七、横屏切换
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：对比页 ⋮ →「切换到横屏」，长文并排对照更舒适。
切回竖屏：同一个菜单项会变成"切换到竖屏"。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十八、提示
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

默认配色：红色=左文件独有，绿色=右文件独有，浅粉=被改行（左），浅绿=被改行（右）。
查找命中：浅黄高亮 + 加粗；当前停留的一处是粉色。
所有规则、开关、颜色、字号——全部本地保存，重启后仍生效。
本页所有文字可长按选中复制（含代码块）。
本页阅读时支持双指捏合缩放字号，右上角小图标一键重置为默认。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【开发】十九、规则分布与修改入口
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

想改某条规则，照这张表找文件。每一条都列出：定义在哪、应用在哪、UI 在哪、存储在哪。

▶ 单条规则（内置 + 自定义合并）

【数据结构】
  preprocessing/domain/preprocessing_rule.dart → PreprocessingRule
  字段：id / name / findPattern / replaceWith / scope / enabled / isBuiltin / script

【内置规则定义】
  preprocessing/application/builtin_rules.dart → BuiltinRules.all()
  原「忽略项」的 8 条已并入这里，不再单独存在

【应用】
  preprocessing/application/preprocessing_service.dart → applyOneRule(text, rule)
  一条规则的执行入口：
    - 有 script → switch (script) 分支（lowercase / dropEmptyLines / unifyAnsi）
    - 无 script 且 findPattern 是纯文本 → 走 String.replaceAll 快路径
    - 否则 → 走正则 replaceAllMapped，支持 $1 展开

【执行顺序】
  import_providers.dart → ruleOrderProvider
  存储 key = PrefKeys.ruleOrder
  元素是：单条规则 id / __block_keyword__ / __block_regex__
  改顺序：拖动列表项 → setAll(newList)

【合并列表】
  import_providers.dart → ruleByIdProvider（id → 规则）
  内置 + 自定义都在这个 map 里

【内置开关存储】
  import_providers.dart → builtinRuleEnablesProvider（Map<String,bool>）
  key = PrefKeys.builtinRuleEnables

【自定义规则存储】
  import_providers.dart → userRulesProvider（List<PreprocessingRule>）
  key = PrefKeys.userRules（JSON 序列化）

【UI】
  comparison_settings_screen.dart → ComparisonSettingsScreen
  单条规则渲染：_buildSingleTile
  拖动：ReorderableListView.builder + ReorderableDragStartListener
  新建/编辑弹窗：_RuleEditorDialog


▶ 关键词规则（一整块文本）

【存储】
  import_providers.dart → keywordRulesTextProvider
  key = PrefKeys.keywordRulesText

【解析】
  import_providers.dart → _parseKeywordRules(rulesText)
  按行 split，每行 trim：
    含 ->=> → 拆成 (find, replace)
    不含    → 整行进 deletions 列表
  结果装进 _ParsedKeywordRules
  deleteAc：删除类的 Aho-Corasick
  replaceAc：替换类的 Aho-Corasick

【缓存】
  _keywordRulesCache（按 rulesText 作 key）
  cap 16，超了 clear

【应用】
  import_providers.dart → applyKeywordRules(text, rulesText)
  1. 先跑 builtinWatermarks（写死水印词库，_watermarkAc）
  2. 再跑 deleteAc.replaceAll(out)  一次扫描
  3. 再跑 replaceAc.replaceAll(out) 一次扫描

【AC 实现】
  preprocessing/application/aho_corasick.dart → AhoCorasick
  语义：最长优先、非重叠、一次扫描 O(n+m)

【编辑器 UI】
  replace_rules_screen.dart（isRegex: false）
  整页 TextField + 顶部说明 + 底部行数


▶ 正则规则（一整块文本）

【存储】
  import_providers.dart → regexRulesTextProvider
  key = PrefKeys.regexRulesText

【解析】
  import_providers.dart → _parseRegexRules(rulesText)
  每条判断 _isPlainText(find)：
    true  → 纯文本，走 String.replaceAll 快路径
    false → 正则，走 _cachedRegex

【缓存】
  _regexRulesCache（按 rulesText 作 key）cap 16
  _regexCache（按 pattern 作 key）cap 512

【应用】
  import_providers.dart → applyRegexRules(text, rulesText)
  for (final r in rules)：
    if (r.isPlain)：
      if (!out.contains(r.find)) continue
      out = out.replaceAll(r.find, r.replace)
    else：
      try { out = out.replaceAll(_cachedRegex(r.find), r.replace) }
      catch (_) {}

【元字符判断】
  import_providers.dart → _regexMeta
  RegExp(r'[\^$.*+?()\[\]{}|\\]')
  _isPlainText(s) = !_regexMeta.hasMatch(s)

【编辑器 UI】
  replace_rules_screen.dart（isRegex: true）


▶ 处理管线完整顺序

  原始文本 raw
    │
    ├─→ 按 ruleOrderProvider 里的顺序遍历：
    │     遇到单条规则 id → applyOneRule
    │     遇到 __block_keyword__ → applyKeywordRules
    │     遇到 __block_regex__ → applyRegexRules
    │
    └─→ 输出 preprocessedOriginal / preprocessedModified
          ↓
          diffResultProvider → _computeInWorker
          （PUA 路径 uniqueCount <= 6000 或 Myers 路径）

  改任意一条规则、改开关、改原文、importRevision++ → 整条管线重跑


▶ 显示设置 & 差异颜色

【显示设置】diff_viewer_providers.dart
  showLineNumbersProvider   显示行号，默认 true
  bodyFontSizeProvider      正文字号，默认 14.0
  gutterFontSizeProvider    行号字号，默认 11.0
  syncScrollProvider        两栏同步滚动，默认 true

【非持久化开关】diff_viewer_providers.dart
  viewModeProvider
  noWrapProvider
  showPerfOverlayProvider

【12 个差异颜色】diff_viewer_providers.dart
  deleteRowBg / deleteRowFg         左文件独有行
  insertRowBg / insertRowFg         右文件独有行
  replaceLeftBg / replaceLeftFg     被改行（左）
  replaceRightBg / replaceRightFg   被改行（右）
  charDeleteBg / charDeleteFg       行内删掉的字
  charInsertBg / charInsertFg       行内新增的字

【diff 算法参数】diff_viewer_providers.dart
  _puaLimit = 6000
  _myersMaxD = 5000


▶ 存储 key 总表（PrefKeys）

前缀：jianming.（PrefKeys._p）

【对比页显示设置】
  jianming.display.showLineNumbers
  jianming.display.bodyFontSize
  jianming.display.gutterFontSize
  jianming.display.syncScroll

【12 个差异颜色】
  jianming.color.deleteRowBg / deleteRowFg
  jianming.color.insertRowBg / insertRowFg
  jianming.color.replaceLeftBg / replaceLeftFg
  jianming.color.replaceRightBg / replaceRightFg
  jianming.color.charDeleteBg / charDeleteFg
  jianming.color.charInsertBg / charInsertFg

【规则】
  jianming.rules.keyword（String）
  jianming.rules.regex（String）
  jianming.rules.user（JSON）
  jianming.rules.builtinEnables（JSON Map）
  jianming.rules.order（\u0000 分隔的 id 列表）

【文件浏览器】
  jianming.browser.sortField / sortAsc / favorites
  jianming.browser.searchFolders / lastPath / searchScope

【笔记】
  comparison_notes（注意这个没有前缀）

【不持久化】
  originalRawTextProvider / modifiedRawTextProvider
  originalFileNameProvider / modifiedFileNameProvider
  originalFilePathProvider / modifiedFilePathProvider
  originalEncodingProvider / modifiedEncodingProvider
  importRevisionProvider / selectedSourceProvider
  viewModeProvider / noWrapProvider / showPerfOverlayProvider
  lastDiffPerfProvider


▶ 快速定位

改单条规则定义       → builtin_rules.dart → BuiltinRules.all()
加单条规则脚本类型   → preprocessing_service.dart → applyOneRule 里 switch
改规则执行顺序存储   → import_providers.dart → ruleOrderProvider
改关键词解析语法     → import_providers.dart → _parseKeywordRules
改正则解析语法       → import_providers.dart → _parseRegexRules
改关键词应用流程     → import_providers.dart → applyKeywordRules
改正则应用流程       → import_providers.dart → applyRegexRules
改自定义规则默认值   → import_providers.dart → UserRulesNotifier.defaultValue
改 diff 算法参数     → diff_viewer_providers.dart → _puaLimit / _myersMaxD
改 diff 主流程       → diff_viewer_providers.dart → diffResultProvider
改 12 个颜色默认值   → diff_viewer_providers.dart → 各 xxxBgProvider / xxxFgProvider 的 initial
改字号默认值         → diff_viewer_providers.dart → BodyFontSizeNotifier 等
改比较设置页 UI      → comparison_settings_screen.dart
改关键词/正则编辑器  → replace_rules_screen.dart


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【开发】二十、什么能用代码代替替换
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

下面这些操作，用一行代码能顶几十条甚至几百条替换规则。看之前先想一件事：
· 能用纯文本表达、互相不依赖 → 关键词规则（1 遍扫描）
· 需要正则、不依赖前一条 → 正则规则（逐条扫描）
· 需要代码逻辑 → script 字段或硬编码

【A】字符串 API —— 正则做不到或很难做

■ 大小写转换
  text.toLowerCase()               整段转小写
  text.toUpperCase()               整段转大写
  一行顶 26 条字母替换，且覆盖所有语言
  正则做不到。现有 ig_case 就是 script: lowercase

■ 去首尾空白
  text.trim()          去整段首尾空白
  text.trimLeft()      去开头空白
  text.trimRight()     去结尾空白
  trim 连全角空格 U+3000、NBSP 都算，比正则 ^[ \t]+ 更全

■ 按行切分 / 合并
  text.split('\n')                 切成行列表
  lines.join('\n')                 拼回文本

■ 去重复行
  text.split('\n').toSet().toList()
  正则做不到

■ 行排序 / 倒序
  lines..sort()                              字典序排列
  lines.reversed.join('\n')                 整篇行倒序
  正则做不到

■ 行过滤
  lines.where((l) => l.contains('关键词')).join('\n')
  lines.where((l) => !l.contains('广告')).join('\n')
  lines.where((l) => l.length > 5).join('\n')
  正则做不到

■ 加行号
  lines.asMap().entries.map((e) => '${e.key+1}. ${e.value}').join('\n')
  正则做不到

■ 去掉空行（含纯空格行）
  lines.where((l) => l.trim().isNotEmpty).join('\n')
  现有 ig_empty 就是 script: dropEmptyLines

【B】正则一条顶很多条

■ Unicode 分类过滤（Dart 需 unicode: true）
  RegExp(r'\p{L}', unicode: true)   所有字母
  RegExp(r'\p{N}', unicode: true)   所有数字
  RegExp(r'\p{P}', unicode: true)   所有标点
  RegExp(r'\p{C}', unicode: true)   所有控制/不可见字符

  例：删所有不可见字符
    text.replaceAll(RegExp(r'\p{C}', unicode: true), '')

■ 保留字母数字
  text.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')

■ 多行模式（^ 和 $ 匹配每行）
  RegExp(r'^[ \t]+', multiLine: true)
  RegExp(r'[ \t]+$', multiLine: true)

【C】码位运算（正则做不到）

■ 全角转半角
  String.fromCharCodes(text.runes.map((c) {
    if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;
    if (c == 0x3000) return 0x20;
    return c;
  }))

■ 半角转全角
  String.fromCharCodes(text.runes.map((c) {
    if (c >= 0x21 && c <= 0x7E) return c + 0xFEE0;
    if (c == 0x20) return 0x3000;
    return c;
  }))

■ 统一编码 ANSI
  逐字符 gbk.encode，能还原的才保留
  现有 ig_ansi 就是 script: unifyAnsi

【D】需要引包的（正则绝对做不到）

■ NFC / NFD 归一化
  import 'package:unicode/unicode.dart';
  text.nfc() / text.nfd() / text.nfkc()

■ Grapheme 切分
  import 'package:characters/characters.dart';
  text.characters.length

■ 简繁转换
  import 'package:opencc/opencc.dart';
  OpenCC.s2t(text) / OpenCC.t2s(text)

■ 拼音
  import 'package:pinyin/pinyin.dart';
  PinyinHelper.getPinyinE(text)

■ 编码转换
  base64Encode(utf8.encode(text))
  Uri.encodeComponent(text)
  const HtmlEscape().convert(text)

■ 哈希摘要
  import 'package:crypto/crypto.dart';
  md5.convert(utf8.encode(text)).toString()
  sha256.convert(utf8.encode(text)).toString()

【E】决策口诀

  纯文本、互相不依赖     → 关键词规则（Aho-Corasick，1 遍扫描）
  需要正则、不依赖前一条 → 正则规则
  需要正则、$1 捕获组    → 自定义规则
  只对左/右侧生效        → 自定义规则（带 scope）
  临时单独关某一条       → 自定义规则（带开关）
  行操作 / 码位运算      → script 字段（applyOneRule 里加 case）
''';

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _editing = false;
  bool _loaded = false;

  // ==================== 双指缩放字号 ====================

  /// 基准字号（阅读态、缩放系数为 1 时）。
  static const double _baseFontSize = 13.5;
  static const double _minScale = 0.5;
  static const double _maxScale = 3.0;

  /// 当前缩放系数。
  double _fontScale = 1.0;

  /// 正在触碰屏幕的指针位置（用于算两指距离）。
  final Map<int, Offset> _touches = <int, Offset>{};

  /// 捏合开始时的两指距离、缩放系数。
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
      setState(() {}); // 让 ScrollView 的 physics 立即切换
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
      setState(() {}); // 恢复滚动
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
                        // 双指捏合时禁用滚动，避免和缩放打架。
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

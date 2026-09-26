import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用说明页。
/// 整页可编辑，编辑后保存到本地，重启后仍在。
///
/// 本页不使用任何 Icon，全部用普通文字符号，避免打包后图标缺失。
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

列表从上到下：
1. 关键词规则：一整块文本，每行一条，普通文字匹配，不把字符当正则。
2. 正则规则：一整块文本，每行一条，按正则表达式匹配，支持 $1 分组引用。
3. 自定义规则：一条条带开关的规则，可指定只对左/右侧生效，可单独停用。
4. 内置规则：开发者写死的一组规则，只提供开关。
5. 忽略项：一排开关，点一下立即生效，消除无关差异。

应用顺序：内置规则 → 自定义规则 → 关键词规则 → 正则规则。
所有设置本地保存，重启后仍生效。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
五、关键词规则（批量删除/替换）
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
六、正则规则（高级匹配）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

格式和关键词一样，但匹配串是正则表达式：

    xxx              ← 匹配 xxx 就删掉
    xxx->=>yyy       ← 匹配 xxx 替换成 yyy

捕获组：替换串里用 $1、$2 引用正则中的括号内容，如 (\d+) 对应 $1。
非法正则：会被跳过，不影响其它行。
纯文本 find：不含正则元字符的自动走 String.replaceAll 快路径，目标串不存在时直接跳过。

常用正则写法见下一节速查表。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
七、正则速查表（想写什么，查这里）
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
八、常用正则组合（直接抄）
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
九、特殊字符怎么写
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
十、自定义规则与内置规则
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

入口：比较设置页。

自定义规则：点"新建规则"，填规则名、查找正则、替换串，选作用范围（两份 / 仅原文 / 仅修改版）。每条带一个开关，可单独启用/停用。
内置规则：统一换行、折叠多余空白、去行首尾空白、中英文引号统一、逗号空格归一、忽略大小写、全角数字转半角。右侧开关可勾选启用。

什么时候用自定义规则？
· 只对左侧（原版）或右侧（修改版）生效 → 关键词/正则规则做不到。
· 需要临时停用某一条 → 关键词/正则规则要删行，自定义规则拨开关即可。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
十一、忽略项
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

用于消除无关差异，点开关立即生效：

· 删掉空白符号：去掉空格 / Tab 后比较。
· 删掉空行：删除纯空行后再比较。
· 统一换行符：统一 \r\n / \r / \n 三种换行格式。
· 大写全转成小写：A 和 a 视为相同。
· 忽略纯数字：连续数字（如 123）视为占位符 <NUM>。
· 忽略不可见字符：删除零宽空格、方向控制、BOM、软连字符、NBSP 等看不见的字符。
· 统一编码 ANSI：非 ANSI 字符（Emoji、生僻字）会被删除。开启会丢失内容，慎用。

注意：导入页底部也有一小块同样的开关（只列了 4 个常用项），两处联动，改哪个都一样。


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
关键词规则、正则规则、自定义规则、内置规则开关、忽略项、显示设置——全部本地保存，重启后仍生效。
本页所有文字可长按选中复制（含代码块）。


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【开发】十九、规则分布与修改入口
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

想改某条规则，照这张表找文件。每一条都列出：定义在哪、应用在哪、UI 在哪、存储在哪。

▶ 忽略项（当前 8 条）

【定义】
  diff_viewer_providers.dart
  → defaultIgnoreRules()  返回 List<PreprocessingRule>
  字段：id / name / findPattern / replaceWith / script / enabled

【应用】
  diff_viewer_providers.dart
  → applyDiffIgnores(String text, Map<String,bool> enables)
  遍历 defaultIgnoreRules()，enabled 为 true 就执行：
    - 有 script → 走 switch (script) 里的分支
    - 无 script → out.replaceAll(RegExp(findPattern, multiLine: true), replaceWith)

【查询某条是否开着】
  diff_viewer_providers.dart
  → isIgnoreOn(enables, id)

【启用状态存储】
  diff_viewer_providers.dart
  → ignoreRuleEnablesProvider（Map<String,bool>，持久化）
  → IgnoreRuleEnablesNotifier.setOne(id, enabled)
  key = PrefKeys.ignoreRuleEnables（pref_keys.dart）

【比较设置页 UI】
  comparison_settings_screen.dart
  → _ignoreSubtitles（每条 id 的副标题，Map<String,String>）
  → build 里 for (final r in defaultIgnoreRules()) _switchTile(...)
    完全自动生成，不用手写

【导入页 UI】
  import_screen.dart
  → _importScreenIgnoreIds = {ig_ws, ig_empty, ig_nl, ig_ansi}
    只显示这几个（导入页空间小，不放全部）
  → _importIgnoreSubtitles（导入页的副标题）

【归一化行号映射】
  diff_viewer_providers.dart
  → rawLineForNormalizedLine(raw, normalizedLine, ignoreEnables)
    读 ig_ws / ig_empty / ig_invisible 三个开关判断行号偏移
    被 diff_viewer_screen.dart 两处调用：
      _applyRawChanges() 和 _replaceRawLine()

【当前 8 条的 id 和实现】
  ig_nl         正则  \r\n|\r  →  \n
  ig_invisible  正则  [\u00A0\u00AD\u200B-\u200F...] → 空
  ig_ws         正则  [ \t]+ → 空
  ig_empty      script  dropEmptyLines
  ig_comma      正则  [,，] → 空
  ig_num        正则  [0-9]+ → <NUM>
  ig_case       script  lowercase
  ig_ansi       script  unifyAnsi

【加新脚本类型】
  1. defaultIgnoreRules() 加一条带 script: '新标识' 的规则
  2. applyDiffIgnores 的 switch (script) 加 case '新标识': ...


▶ 内置规则（当前 7 条）

【定义】
  preprocessing/application/builtin_rules.dart
  → BuiltinRules.all()  返回 List<PreprocessingRule>

【应用】
  preprocessing/application/preprocessing_service.dart
  → PreprocessingService.apply(input, isOriginal)
  合并逻辑：
    active = [...]builtinRules.where(enabled) + ...userRules.where(enabled)
    active.removeWhere(scope 不匹配 isOriginal 的)
    if (active.length > 20) throw PreprocessingException
    逐条 out = _applyOne(rule, out)

【单条应用】
  preprocessing_service.dart → _applyOne(rule, text)
  三条分支：
    1. rule.id == 'ignore_case' → text.toLowerCase()  【特判】
    2. _isPlainText(findPattern) → text.replaceAll(find, replace)  【快路径】
    3. 其它 → text.replaceAllMapped(_cachedRegex(find), 展开 $1 $2)

【正则缓存】
  preprocessing_service.dart → _cachedRegex(pattern, multiLine)
  顶层 _regexCache，cap 512，超了 clear

【启用状态存储】
  import_providers.dart
  → builtinRuleEnablesProvider（Map<String,bool>，持久化）
  → BuiltinRuleEnablesNotifier.setOne(id, enabled)
  key = PrefKeys.builtinRuleEnables
  → builtinRulesWithStateProvider（合并出带启用状态的列表）

【UI】
  comparison_settings_screen.dart
  → for (final r in builtinRules) _ruleTile(...)

【当前 7 条的 id 和实现】
  norm_eol        \r\n|\r           → \n      默认开
  norm_ws         [ \t]{2,}          → " "     默认开
  trim_line       ^[ \t]+|[ \t]+$   → 空      默认开
  norm_quote      ["“”]          → "      默认关
  norm_comma      [,，] +            → ，      默认开
  ignore_case     特判 toLowerCase()              默认关
  norm_number     [０-９]             → 0      默认关（这条实际是坏的）

【注意】
  ignore_case 和 norm_number 走特判。
  改它们的 id 会让特判失效，只能改 name / enabled。


▶ 自定义规则（用户新建）

【数据结构】
  preprocessing/domain/preprocessing_rule.dart → PreprocessingRule
  字段：id / name / findPattern / replaceWith / scope / enabled / isBuiltin / script

【作用范围】
  RuleScope 枚举：both / originalOnly / modifiedOnly

【存储】
  import_providers.dart
  → userRulesProvider（List<PreprocessingRule>，持久化）
  → UserRulesNotifier
    .add(rule) / .updateRule(rule) / .remove(id) / .toggle(id)
    .importFromJson(list)
  key = PrefKeys.userRules（JSON 序列化）

【应用】
  同内置规则，一起进 PreprocessingService.apply()
  顺序：内置规则先跑（BuiltinRules.all() 在前），自定义规则后跑
  合并后 active.length > 20 会抛异常

【UI】
  comparison_settings_screen.dart
  → _ruleTile(context, ref, rule, builtin: false)
  → _RuleEditorDialog（新建规则弹窗）
    字段：规则名 / 查找正则 / 替换串 / 作用范围
  保存前会 try RegExp(find) 校验，非法则弹 SnackBar

【默认值】
  import_providers.dart → UserRulesNotifier.defaultValue
  当前是 const []（空列表）
  想让新用户自带示例规则，在这里填


▶ 关键词规则（一整块文本）

【存储】
  import_providers.dart
  → keywordRulesTextProvider（String，持久化）
  → KeywordRulesTextNotifier extends StringPrefNotifier
  key = PrefKeys.keywordRulesText

【解析】
  import_providers.dart → _parseKeywordRules(rulesText)
  按行 split，每行 trim：
    含 ->=> → 拆成 (find, replace)，进 replacements 列表
    不含    → 整行进 deletions 列表（会被删掉）
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
  preprocessing/application/aho_corasick.dart
  → AhoCorasick(patterns, replacements)
  → .replaceAll(text)
  语义：最长优先、非重叠、一次扫描 O(n+m)

【写死水印】
  import_providers.dart → builtinWatermarks
  一个 const List<String>，当前是空
  填进去的词会跟关键词规则一起生效，但不受用户编辑
  顶层 _watermarkAc 只建一次，永不重建

【转义还原】
  import_providers.dart → _unescapeReplacement(s)
  只处理 4 种：\n \r \t \0 和 \\
  其它 \x 原样保留

【编辑器 UI】
  replace_rules_screen.dart（isRegex: false）
  整页 TextField + 顶部说明 + 底部行数
  保存时 update(ctrl.text) + importRevision++

【性能特征】
  不论多少条规则，全文扫 2 遍（删除类 + 替换类）
  比正则规则逐条扫快一个数量级
  不支持正则、不支持 $1 捕获组、不链式触发


▶ 正则规则（一整块文本）

【存储】
  import_providers.dart
  → regexRulesTextProvider（String，持久化）
  → RegexRulesTextNotifier extends StringPrefNotifier
  key = PrefKeys.regexRulesText

【解析】
  import_providers.dart → _parseRegexRules(rulesText)
  按行 split，每行 trim：
    含 ->=> → 拆成 (find, replace)
    不含    → find = 整行，replace = 空（删掉）
  每条判断 _isPlainText(find)：
    true  → 纯文本，走 String.replaceAll 快路径
    false → 正则，走 _cachedRegex
  结果：List<_ParsedRegexRule>(find, replace, isPlain)

【缓存】
  _regexRulesCache（按 rulesText 作 key）
  cap 16，超了 clear
  _regexCache（按 pattern 作 key）
  cap 512，超了 clear

【应用】
  import_providers.dart → applyRegexRules(text, rulesText)
  for (final r in rules)：
    if (r.isPlain)：
      if (!out.contains(r.find)) continue   ← 目标串不存在直接跳过
      out = out.replaceAll(r.find, r.replace)
    else：
      try { out = out.replaceAll(_cachedRegex(r.find), r.replace) }
      catch (_) {}   ← 非法正则忽略，不影响其它行

【元字符判断】
  import_providers.dart → _regexMeta
  RegExp(r'[\^$.*+?()\[\]{}|\\]')
  _isPlainText(s) = !_regexMeta.hasMatch(s)

【不支持 $1 展开】
  这条管线里替换串原样输出
  想要 $1 捕获组？只能走自定义规则（PreprocessingService 里有 _expandReplacement）

【编辑器 UI】
  replace_rules_screen.dart（isRegex: true）
  同关键词规则编辑器，只是顶部说明不同


▶ 处理管线完整顺序

  原始文本 raw
    │
    ├─→ ① PreprocessingService.apply()
    │      内置规则 + 自定义规则
    │      import_providers.dart → preprocessedOriginalProvider
    │
    ├─→ ② applyKeywordRules()
    │      关键词规则（Aho-Corasick）
    │      import_providers.dart
    │
    ├─→ ③ applyRegexRules()
    │      正则规则（逐条 replaceAll）
    │      import_providers.dart
    │
    ├─→ ④ applyDiffIgnores()
    │      忽略项（列表式遍历）
    │      diff_viewer_providers.dart → diffResultProvider
    │
    └─→ ⑤ _computeInWorker()
           真正的 diff 计算（isolate 里跑）
           PUA 路径（uniqueCount <= 6000）或 Myers 路径

  ① ② ③ 在 preprocessedOriginalProvider / preprocessedModifiedProvider 里
  ④ ⑤ 在 diffResultProvider 里

  每改一条规则、改一个忽略开关、改一份原文 → 整条管线重跑
  importRevision++ 也会触发重跑


▶ 显示设置 & 差异颜色

【显示设置】diff_viewer_providers.dart
  showLineNumbersProvider   显示行号，默认 true
  bodyFontSizeProvider      正文字号，默认 14.0
  gutterFontSizeProvider    行号字号，默认 11.0
  syncScrollProvider        两栏同步滚动，默认 true

【非持久化开关】diff_viewer_providers.dart
  viewModeProvider          当前视图（merged / sideBySide / diffOnly / diffOnlyPlain）
  noWrapProvider            不换行，默认 false（关 App 复位）
  showPerfOverlayProvider   性能面板，默认 false（关 App 复位）

【12 个差异颜色】diff_viewer_providers.dart
  deleteRowBg / deleteRowFg         左文件独有行
  insertRowBg / insertRowFg         右文件独有行
  replaceLeftBg / replaceLeftFg     被改行（左）
  replaceRightBg / replaceRightFg   被改行（右）
  charDeleteBg / charDeleteFg       行内删掉的字
  charInsertBg / charInsertFg       行内新增的字
  各用 ColorPrefNotifier，key 在 PrefKeys 里

【diff 算法参数】diff_viewer_providers.dart 顶部
  _puaLimit = 6000      唯一行数 ≤ 这个值走 PUA 编码路径（快）
  _myersMaxD = 5000     Myers 最大编辑距离，超过退化

【UI 入口】
  显示设置面板：diff_viewer_screen.dart → _DisplaySettingsSheet
  入口：更多菜单 → 显示设置


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

【忽略项】
  jianming.ignore.ruleEnables（Map<String,bool>）
  （旧的 ignore.whitespace 等 key 保留但不再用）

【规则】
  jianming.rules.keyword（String）
  jianming.rules.regex（String）
  jianming.rules.user（JSON）
  jianming.rules.builtinEnables（JSON Map）

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

改忽略项             → diff_viewer_providers.dart → defaultIgnoreRules()
改内置规则           → preprocessing/application/builtin_rules.dart → BuiltinRules.all()
加忽略项脚本类型     → diff_viewer_providers.dart → applyDiffIgnores 里 switch
加内置特判           → preprocessing_service.dart → _applyOne
改关键词解析语法     → import_providers.dart → _parseKeywordRules
改正则解析语法       → import_providers.dart → _parseRegexRules
改关键词应用流程     → import_providers.dart → applyKeywordRules
改正则应用流程       → import_providers.dart → applyRegexRules
改关键词默认文本     → import_providers.dart → KeywordRulesTextNotifier 的 initial
改正则默认文本       → import_providers.dart → RegexRulesTextNotifier 的 initial
改自定义规则默认值   → import_providers.dart → UserRulesNotifier.defaultValue
改规则上限（20 条）  → preprocessing_service.dart → apply() 里 if (active.length > 20)
改 diff 算法参数     → diff_viewer_providers.dart → _puaLimit / _myersMaxD
改 diff 主流程       → diff_viewer_providers.dart → diffResultProvider
改 12 个颜色默认值   → diff_viewer_providers.dart → 各 xxxBgProvider / xxxFgProvider 的 initial
改字号默认值         → diff_viewer_providers.dart → BodyFontSizeNotifier 等
改忽略项副标题       → comparison_settings_screen.dart → _ignoreSubtitles
改导入页显示的忽略项 → import_screen.dart → _importScreenIgnoreIds
改导入页忽略项副标题 → import_screen.dart → _importIgnoreSubtitles


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【开发】二十、什么能用代码代替替换
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

下面这些操作，用一行代码能顶几十条甚至几百条替换规则。看之前先想一件事：
· 能用纯文本表达、互相不依赖 → 关键词规则（1 遍扫描）
· 需要正则、不依赖前一条 → 正则规则（逐条扫描）
· 需要代码逻辑 → script 字段或硬编码

【A】字符串 API —— 正则做不到或很难做

■ 大小写转换
  text.toLowerCase()               整段转小写（全 Unicode）
  text.toUpperCase()               整段转大写
  text[0].toUpperCase() + text.substring(1)   首字母大写
  一行顶 26 条字母替换，且覆盖法语、德语、希腊、俄语等所有语言
  正则做不到。现有 ig_case 就是 script: lowercase

■ 去首尾空白
  text.trim()          去整段首尾空白
  text.trimLeft()      去开头空白
  text.trimRight()     去结尾空白
  trim 连全角空格 U+3000、NBSP 都算，比正则 ^[ \t]+ 更全

■ 按行切分 / 合并
  text.split('\n')                 切成行列表
  lines.join('\n')                 拼回文本
  可以配合下面所有行级操作一起用

■ 去重复行
  text.split('\n').toSet().toList()   去掉内容重复的行
  正则做不到。它需要跨行记住"这行出现过没有"

■ 行排序 / 倒序
  lines..sort()                              字典序排列
  lines..sort((a,b)=>b.length.compareTo(a.length))   按长度排
  lines.reversed.join('\n')                 整篇行倒序
  lines.shuffle()                            打乱
  正则做不到

■ 行过滤
  lines.where((l) => l.contains('关键词')).join('\n')    只留含某词的行
  lines.where((l) => !l.contains('广告')).join('\n')   去掉含某词的行
  lines.where((l) => l.length > 5).join('\n')           去掉太短的行
  lines.where((l) => l.length < 500).join('\n')         去掉太长的行
  正则做不到

■ 加行号
  lines.asMap().entries.map((e) => '${e.key+1}. ${e.value}').join('\n')
  正则做不到（正则无法生成递增编号）

■ 去掉空行（含纯空格行）
  lines.where((l) => l.trim().isNotEmpty).join('\n')
  正则 ^\s*$ 处理多行空行不干净，尤其头尾。写代码更彻底
  现有 ig_empty 就是 script: dropEmptyLines

■ 填充 / 截断
  text.padLeft(10, '0')     左填充到 10 位
  text.padRight(10, ' ')    右填充
  text.substring(0, 100)     截前 100 字符

【B】正则一条顶很多条

■ Unicode 分类过滤（Dart 需 unicode: true）
  RegExp(r'\p{L}', unicode: true)   所有字母（中英日韩希腊俄…）
  RegExp(r'\p{N}', unicode: true)   所有数字（阿拉伯、中文、罗马…）
  RegExp(r'\p{P}', unicode: true)   所有标点
  RegExp(r'\p{S}', unicode: true)   所有符号（含 emoji）
  RegExp(r'\p{Z}', unicode: true)   所有分隔符（空格类）
  RegExp(r'\p{M}', unicode: true)   所有组合符
  RegExp(r'\p{C}', unicode: true)   所有控制/不可见字符

  例：删所有不可见字符
    text.replaceAll(RegExp(r'\p{C}', unicode: true), '')
  一条顶现在那个硬编码的 _invisibleChars 那一大串 \u00A0\u00AD\u200B...

■ 保留字母数字
  text.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
  删掉所有标点、符号、emoji、控制字符

■ 多行模式（^ 和 $ 匹配每行）
  RegExp(r'^[ \t]+', multiLine: true)   每行开头的空白
  RegExp(r'[ \t]+$', multiLine: true)   每行结尾的空白
  multiLine: true 是关键，不加的话 ^ 只匹配整段开头

■ 空白折叠
  RegExp(r'\s+')       所有空白（空格/Tab/换行）
  RegExp(r'[ \t]+')    空格和 Tab
  RegExp(r'[^\S\n]+')  空格和 Tab 但不碰换行

■ 连续字符压缩
  RegExp(r'\n{3,}')      3 个以上换行
  RegExp(r'[.。…⋯]+')    连续点号/省略号
  RegExp(r'[,，]{2,}')   连续逗号

■ 后向引用（匹配重复）
  RegExp(r'(\w+)\s+\1')   匹配连续重复的词

■ 命名捕获组
  RegExp(r'(?<year>\d{4})-(?<month>\d{2})')
  匹配后 m.namedGroup('year')

【C】码位运算（正则做不到）

■ 全角转半角
  String.fromCharCodes(text.runes.map((c) {
    if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;
    if (c == 0x3000) return 0x20;  // 全角空格
    return c;
  }))
  覆盖数字、字母、标点，全 Unicode 完整映射
  现有 norm_number 就是这条（但代码里是坏的，只转了 0）

■ 半角转全角
  String.fromCharCodes(text.runes.map((c) {
    if (c >= 0x21 && c <= 0x7E) return c + 0xFEE0;
    if (c == 0x20) return 0x3000;
    return c;
  }))

■ 统一编码 ANSI（去掉无法转 GBK 的字符）
  逐字符 gbk.encode，能还原的才保留
  现有 ig_ansi 就是 script: unifyAnsi（在 diff_viewer_providers.dart）

【D】需要引包的（正则绝对做不到）

■ NFC / NFD 归一化（é 的两种编码统一）
  import 'package:unicode/unicode.dart';
  text.nfc()   规范组合
  text.nfd()   规范分解
  text.nfkc()  兼容分解（①→1，㈱→(株)）
  同一字符不同编码长得一样但码位不同，归一化后统一

■ Grapheme 切分（用户感知字符）
  import 'package:characters/characters.dart';
  text.characters.length   按"用户感知字符"计数
  处理 emoji、组合字、印地语连字
  text.length 在很多语言里不等于 text.characters.length

■ 简繁转换
  import 'package:opencc/opencc.dart';
  OpenCC.s2t(text)   简 → 繁
  OpenCC.t2s(text)   繁 → 简

■ 拼音
  import 'package:pinyin/pinyin.dart';
  PinyinHelper.getPinyinE(text)     汉字 → 拼音
  PinyinHelper.getShortPinyin(text) 汉字 → 首字母

■ 中文分词（jieba 类）
  需要第三方包

■ 编码转换
  base64Encode(utf8.encode(text))     Base64 编码
  utf8.decode(base64Decode(b64))     Base64 解码
  Uri.encodeComponent(text)          URL 编码
  Uri.decodeComponent(enc)           URL 解码
  const HtmlEscape().convert(text)   HTML 实体编码
  const HtmlUnescape().convert(text) HTML 实体解码

■ 哈希摘要
  import 'package:crypto/crypto.dart';
  md5.convert(utf8.encode(text)).toString()
  sha256.convert(utf8.encode(text)).toString()

【E】需要写函数（几十行，做一次就够）

■ 中文数字 ↔ 阿拉伯数字
  "一二三" ↔ "123"、"壹贰叁" ↔ "123"
  需要字典 + 位权处理

■ 罗马数字互转
  "IV" ↔ 4、"MCMLXXXIV" ↔ 1984

■ 进制转换
  int.parse('ff', radix: 16)     十六进制 → 十进制
  255.toRadixString(16)          十进制 → 十六进制
  int.parse('1010', radix: 2)    二进制

■ 科学计数法
  double.parse('1.5e10')         字符串 → 数字

■ 千分位
  1234567.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (m) => '${m[1]},',
  )

■ 词频统计
  final words = text.split(RegExp(r'\s+'));
  final freq = <String, int>{};
  for (final w in words) freq[w] = (freq[w] ?? 0) + 1;
  然后按 freq 排序输出

■ 停用词过滤
  一个 const List<String> stopwords，逐行逐词 replaceAll
  也可以放关键词规则里（词多的话 AC 更快）

【F】决策口诀

  纯文本、互相不依赖     → 关键词规则（Aho-Corasick，1 遍扫描，最快）
  需要正则、不依赖前一条 → 正则规则（逐条 replaceAll）
  需要正则、$1 捕获组    → 自定义规则（PreprocessingService 里有 _expandReplacement）
  只对左/右侧生效        → 自定义规则（带 scope）
  临时单独关某一条       → 自定义规则（带开关）
  行操作 / 码位运算      → script 字段（applyDiffIgnores 里加 case）
  两处都保留？           → 两个列表各跑各的时机，别合并

【G】转换示例

■ 原文正则：把 3 个以上连续换行压成 2 个
  RegExp(r'\n{3,}') → '\n\n'
  能拆成规则吗：能。findPattern + replaceWith 就能表达

■ 原文正则：去掉所有 HTML 标签
  RegExp(r'<[^>]+>') → ''
  能拆成规则吗：能

■ 原文正则：把 "2024-01-01" 换成 "2024年01月01日"
  RegExp(r'(\d{4})-(\d{2})-(\d{2})') → '$1年$2月$3日'
  能拆成规则吗：只有自定义规则支持（正则规则和关键词规则不支持 $1）

■ 原文代码：全段转小写
  text.toLowerCase()
  能拆成规则吗：不能。必须写 script 或在 applyDiffIgnores 里加 case

■ 原文代码：去掉重复行
  text.split('\n').toSet().join('\n')
  能拆成规则吗：不能。必须写 script


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
【开发】二十一、全部可用代码替代的替换
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

把 Dart 里所有能替代"查找+替换"的操作都列出来。每条标注：正则能不能做、能不能写成规则、是否需要引包。

一、大小写
  text.toLowerCase()                  全小写（全 Unicode）
  text.toUpperCase()                  全大写
  text[0].toUpperCase() + text.substring(1)  首字母大写
  line.split(' ').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join(' ')  Title Case

  正则能做：否
  能写成规则：否（除非加 script）

二、空白处理
  text.trim()                          整段去首尾空白
  text.trimLeft()                      去开头空白
  text.trimRight()                     去结尾空白
  text.replaceAll(' ', '')             删普通空格
  text.replaceAll('\t', '')            删 Tab
  text.replaceAll(RegExp(r'\s+'), '')   删所有空白
  text.replaceAll(RegExp(r'\s+'), ' ')  所有空白折叠成一个空格
  text.replaceAll(RegExp(r'[^\S\n]+'), ' ')  折叠空格但不碰换行
  text.replaceAll('\t', '    ')          Tab → 4 空格
  text.replaceAll('    ', '\t')          4 空格 → Tab
  text.replaceAll('\u00A0', ' ')        NBSP → 普通空格
  text.replaceAll('\u3000', ' ')        全角空格 → 普通空格
  text.replaceAll(RegExp(r'^[ \t]+', multiLine: true), '')  每行开头空白
  text.replaceAll(RegExp(r'[ \t]+$', multiLine: true), '')  每行结尾空白

  正则能做：多数能
  能写成规则：能（findPattern + replaceWith）
  例外：trim 家族（比正则更全，覆盖全角空格）

三、行级操作
  text.split('\n')                    切成行
  lines.join('\n')                    拼回
  lines.toSet().toList()               去重复行
  lines.toSet().join('\n')            去重复行并拼回
  lines..sort()                        字典序排
  lines..sort((a,b)=>b.length.compareTo(a.length))  按长度排
  lines.reversed.toList()              行倒序
  lines.shuffle()                      打乱
  lines.where((l) => l.trim().isNotEmpty).toList()   去空行
  lines.where((l) => l.contains('关键词')).toList()  只留含某词
  lines.where((l) => !l.contains('广告')).toList()   去掉含某词
  lines.where((l) => l.length > 5).toList()          去太短
  lines.where((l) => l.length < 500).toList()        去太长
  lines.map((l) => '  $l').join('\n')               每行加缩进
  lines.map((l) => l.substring(4)).join('\n')       去掉每行前 4 字符
  lines.map((l) => l.trimRight()).join('\n')        每行去尾空白
  lines.asMap().entries.map((e)=>'${e.key+1}. ${e.value}').join('\n')  加行号
  lines.take(10).join('\n')           只留前 10 行
  lines.skip(10).join('\n')           跳过前 10 行
  lines.takeWhile((l) => l.isNotEmpty) 到空行停
  lines.where((l) => l.startsWith('#')).toList()   只留注释行
  lines.where((l) => !l.startsWith('//')).toList() 去注释行

  正则能做：绝大多数不能
  能写成规则：不能（需要 script）

四、查找替换的变体（不止 replaceAll）
  text.replaceAll('a', 'b')                 替换所有
  text.replaceFirst('a', 'b')               替换第一个
  text.replaceRange(0, 5, 'xxx')            按位置替换
  text.replaceAllMapped(RegExp(r'\d+'), (m) => '${int.parse(m[0]!)*2}')  匹配后计算
  text.replaceFirstMapped(RegExp(r'\d+'), (m) => '${int.parse(m[0]!)+1}')  第一个匹配后计算

  正则能做：能
  能写成规则：replaceAll 能；replaceFirst 不能；Mapped 不能（需 script）

五、正则相关
  RegExp(r'\p{L}', unicode: true)        所有字母（中英日韩希腊俄）
  RegExp(r'\p{N}', unicode: true)        所有数字
  RegExp(r'\p{P}', unicode: true)        所有标点
  RegExp(r'\p{S}', unicode: true)        所有符号（含 emoji）
  RegExp(r'\p{Z}', unicode: true)        所有分隔符
  RegExp(r'\p{M}', unicode: true)        组合符
  RegExp(r'\p{C}', unicode: true)        控制/不可见

  RegExp(r'[^\p{L}\p{N}]', unicode: true)  只留字母数字

  text.replaceAll(RegExp(r'\n{3,}'), '\n\n')  3 个以上换行压 2 个
  text.replaceAll(RegExp(r'[.。…]+'), '…')     连续点号压省略号
  text.replaceAll(RegExp(r'[,，]{2,}'), '，')   连续逗号归一
  text.replaceAll(RegExp(r'[ \t]+'), ' ')      空格 Tab 折叠
  text.replaceAll(RegExp(r'^\s*$', multiLine: true), '')  删空行（不彻底）
  text.replaceAll(RegExp(r'<[^>]+>'), '')      删 HTML 标签
  text.replaceAll(RegExp(r'https?://\S+'), '') 删网址

  text.replaceAllMapped(RegExp(r'(\d+)'), (m) => 'X${m[1]}X')  包住数字

  正则能做：能
  能写成规则：多数能；带回调的不行（需 script）
  注意：正则规则里替换串不支持 $1（不支持捕获组展开）
        只有自定义规则支持 $1

六、判断类（用于条件逻辑）
  text.isEmpty                          是否空串
  text.isNotEmpty                       是否非空
  text.startsWith('xxx')                是否以某串开头
  text.endsWith('xxx')                  是否以某串结尾
  text.contains('xxx')                  是否含某串
  text.contains(RegExp(r'\d+'))         是否含正则模式
  text == 'xxx'                         是否等于
  text.compareTo('xxx') == 0            是否等于（大小写敏感）
  text.toLowerCase() == other.toLowerCase()  忽略大小写相等

  正则能做：等价的有 contains(RegExp) / startsWith(RegExp)
  能写成规则：不能（判断不产生替换）

七、提取类
  text.substring(0, 10)                            前 10 字符
  text.substring(text.length - 5)                  后 5 字符
  text.split(',').first                            第一个元素
  text.split(',').last                             最后一个元素
  text.split(',').take(3).join(',')                前 3 个
  RegExp(r'\d+').firstMatch(text)?.group(0)      第一个数字串
  RegExp(r'\d+').allMatches(text).map((m) => m.group(0))  所有数字串
  RegExp(r'(?<year>\d{4})-(?<m>\d{2})').firstMatch(text)?.namedGroup('year')  命名组
  text.indexOf('关键词')                           位置
  text.lastIndexOf('关键词')
  RegExp(r'\w+').allMatches(text).length          词数

  正则能做：能
  能写成规则：不能（提取不产生替换）

八、生成类
  text.padLeft(10, '0')                左填充到 10 位
  text.padRight(10, ' ')               右填充
  text * 3                             重复 3 次
  'abc' + text + 'xyz'                 前后加东西
  List.filled(10, text).join(',')      重复 10 次用逗号连
  '\n' * 3                            生成 3 个换行

  正则能做：否（生成不依赖查找）
  能写成规则：否

九、码位运算
  // 全角 → 半角
  String.fromCharCodes(text.runes.map((c) {
    if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;
    if (c == 0x3000) return 0x20;
    return c;
  }))

  // 半角 → 全角
  String.fromCharCodes(text.runes.map((c) {
    if (c >= 0x21 && c <= 0x7E) return c + 0xFEE0;
    if (c == 0x20) return 0x3000;
    return c;
  }))

  // 字符码位
  text.codeUnitAt(0)                   第 0 字符码位
  text.runes.first                     第一个码点
  String.fromCharCode(0x4E2D)          码位 → 字符

  // 字符遍历
  for (final rune in text.runes) { ... }       按码点
  for (final ch in text.characters) { ... }    按用户感知（需 characters 包）

  正则能做：否（正则不能做算术）
  能写成规则：否（除非 script）

十、编码相关
  utf8.encode(text)                        字符串 → UTF-8 字节
  utf8.decode(bytes)                       字节 → 字符串
  latin1.decode(bytes) / latin1.encode(s)  Latin-1
  gbk.encode(text) / gbk.decode(bytes)     GBK（需包）
  base64Encode(utf8.encode(text))          Base64 编码
  utf8.decode(base64Decode(b64))           Base64 解码
  Uri.encodeComponent(text)                URL 编码
  Uri.decodeComponent(enc)                 URL 解码
  Uri.encodeFull(text) / Uri.decodeFull(text)  整 URL
  const HtmlEscape().convert(text)         HTML 实体编码
  const HtmlUnescape().convert(text)       HTML 实体解码

  正则能做：Base64/URL/HTML 有对应模式，但不如内置函数
  能写成规则：否（需 script）

十一、数字处理
  int.parse('123')                     字符串 → 整数
  double.parse('3.14')                 字符串 → 浮点
  int.parse('ff', radix: 16)           十六进制
  int.parse('1010', radix: 2)          二进制
  255.toRadixString(16)                → 'ff'
  255.toRadixString(2)                 → '11111111'
  double.parse('1.5e10')               科学计数
  1234567.toString()                   整数 → 字符串
  3.14.toStringAsFixed(2)              → '3.14'

  // 千分位
  1234567.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (m) => '${m[1]},',
  )

  // 补零
  5.toString().padLeft(3, '0')         → '005'

  正则能做：部分能
  能写成规则：简单的能；进制/千分位需 script

十二、日期时间
  DateTime.parse('2024-01-01')         字符串 → 日期
  dt.toIso8601String()                 日期 → ISO
  dt.year / .month / .day / .hour / .minute / .second
  '${dt.year}年${dt.month}月${dt.day}日'    中文格式

  // 格式转换
  '2024-01-01'.replaceAll('-', '/')    → '2024/01/01'
  '2024/01/01'.replaceAll('/', '-')    → '2024-01-01'

  // 补零
  dt.month.toString().padLeft(2, '0')  → '01'

  正则能做：简单格式转换能
  能写成规则：简单格式能；解析/补零需 script

十三、哈希摘要
  import 'package:crypto/crypto.dart';
  md5.convert(utf8.encode(text)).toString()      32 位十六进制
  sha1.convert(utf8.encode(text)).toString()     40 位
  sha256.convert(utf8.encode(text)).toString()   64 位

  正则能做：否
  能写成规则：否（需 script）

十四、排序比较
  list..sort()                                      默认排序
  list..sort((a,b) => a.compareTo(b))               升序
  list..sort((a,b) => b.compareTo(a))               降序
  list..sort((a,b) => a.length.compareTo(b.length)) 按长度
  list..sort((a,b) => a.toLowerCase().compareTo(b.toLowerCase()))  忽略大小写

  // 自定义比较：按数字
  list..sort((a,b) => int.parse(a).compareTo(int.parse(b)))

  正则能做：否
  能写成规则：否（需 script）

十五、集合操作
  lines.toSet().toList()               去重
  lines.toSet().join('\n')            去重并拼
  set.toList()..sort()                 去重后排序
  set.length                           去重后数量
  a.union(b)                           并集
  a.intersection(b)                    交集
  a.difference(b)                      差集

  正则能做：否
  能写成规则：否（需 script）

十六、拼接格式化
  'text: $x'                           字符串插值
  '${a}+${b}=${a+b}'                   表达式
  list.join(',')                       列表拼接
  list.join('\n')                      用换行拼
  'a' * 5                              → 'aaaaa'
  '\n' * 3                             → '\n\n\n'

  正则能做：否
  能写成规则：否

十七、Unicode 归一化（需包）
  import 'package:unicode/unicode.dart';
  text.nfc()     规范组合
  text.nfd()     规范分解
  text.nfkc()    兼容分解（①→1，㈱→(株)，Ⅳ→IV）
  text.nfkd()    兼容分解（更激进的 NFKD）

  用途：é 有两种编码（单码位 / e + 组合符），视觉一样但 diff 会判成不同。归一化后统一。

  正则能做：否
  能写成规则：否（需 script）

十八、Grapheme 切分（需包）
  import 'package:characters/characters.dart';
  text.characters.length              用户感知字符数
  text.characters.first               第一个字符
  text.characters.toList()            切分成列表

  用途：emoji、组合字、印地语连字、家庭 emoji 等
  在 text.length 里可能算 1~7 个 UTF-16 码元

  正则能做：否
  能写成规则：否（需 script）

十九、中文相关（需包）
  // 简繁
  import 'package:opencc/opencc.dart';
  OpenCC.s2t(text)                    简 → 繁
  OpenCC.t2s(text)                    繁 → 简

  // 拼音
  import 'package:pinyin/pinyin.dart';
  PinyinHelper.getPinyinE(text)       汉字 → 拼音
  PinyinHelper.getShortPinyin(text)   汉字 → 拼音首字母

  // 中文分词
  需第三方包（jieba 类）

  正则能做：否
  能写成规则：否（需 script）

二十、正则高级用法
  RegExp(r'(?<name>\d+)')             命名捕获组
  RegExp(r'(?:abc)')                   非捕获组
  RegExp(r'(?=abc)')                   前瞻
  RegExp(r'(?!abc)')                   负前瞻
  RegExp(r'(?<=abc)')                  后顾
  RegExp(r'(?<!abc)')                  负后顾
  RegExp(r'\b')                        单词边界（英文有效）
  RegExp(r'^', multiLine: true)        每行开头
  RegExp(r'$', multiLine: true)        每行结尾
  RegExp(r'(?i)abc')                   忽略大小写（Dart 用参数 caseSensitive: false）

  RegExp(r'(.)\1')                     反向引用（连续重复字符）
  RegExp(r'(\w+)\s+\1')                重复的词

  正则能做：能
  能写成规则：正则规则里能表达，但替换串不支持 $1（需自定义规则）

二十一、其它零碎
  text.codeUnits.length                码元数（≠ 字符数）
  text.runes.length                    码点数
  text.length                          UTF-16 单元数
  text.isEmpty                         是否空
  text.hashCode                         哈希值
  text.compareTo(other)                 比较
  text.codeUnitAt(i)                    第 i 个码元
  String.fromCharCodes([72, 105])       → 'Hi'
  text.toString()                       对象 → 字符串
  int.parse(text) / double.parse(text)  字符串 → 数字

  正则能做：否
  能写成规则：否

【汇总】决策流程

拿到一个操作，问自己：

1. 是纯文本查找替换吗？
   是 → 关键词规则（Aho-Corasick，1 遍扫描最快）

2. 需要正则吗？
   是 → 正则规则（逐条 replaceAll）
   需要 $1 捕获组 → 自定义规则

3. 只对左/右侧生效？
   是 → 自定义规则（scope）

4. 需要独立开关？
   是 → 自定义规则或内置规则

5. 是"忽略差异"而非"改文本"？
   是 → 忽略项

6. 是行操作 / 码位运算 / 集合操作 / 需要引包？
   是 → script 字段
      （在 applyDiffIgnores 的 switch 里加 case，
        或给 PreprocessingRule 加 script 分支）

7. 是判断 / 提取 / 生成 而不是替换？
   是 → 规则系统表达不了，只能写 script

一句话：能表达式化的，就放规则；需要运算或逻辑的，写 script。
''';

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _editing = false;
  bool _loaded = false;

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

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;

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
              : SelectionArea(
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    interactive: true,
                    thickness: 11,
                    radius: const Radius.circular(5),
                    child: SingleChildScrollView(
                      controller: _scrollController,
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
                          style: const TextStyle(
                            fontSize: 13.5,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
    );
  }
}

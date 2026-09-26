import 'package:flutter/material.dart';

/// 使用说明：覆盖文件浏览与搜索、关键词/正则规则、正则速查、
/// 比较设置、对比页、查找/替换、长按操作、隐藏技巧、
/// 编辑/保存、显示设置、横屏等全部功能。
/// 整页文字可长按选中复制。
///
/// 本页不使用任何 Icon，全部用普通文字符号，避免打包后图标缺失。
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    

    Widget section(String title, List<Widget> children) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              for (final w in children)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: w,
                ),
            ],
          ),
        ),
      );
    }

    Widget line(String text, {bool bold = false}) => Text(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(fontWeight: bold ? FontWeight.w600 : null),
        );

    Widget step(String head, String body) => RichText(
          text: TextSpan(
            style: Theme.of(context).textTheme.bodyMedium,
            children: [
              TextSpan(
                text: head,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: body),
            ],
          ),
        );

    Widget code(String text) => Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: s.surfaceVariant.withOpacity(0.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.5,
              fontFamily: 'monospace',
            ),
          ),
        );

return Scaffold(
  appBar: AppBar(title: const Text('使用说明')),
  body: SelectionArea(
    child: Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      interactive: true,
      thickness: 11,
      radius: const Radius.circular(5),
        thumbColor: Colors.grey.shade600,   
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.only(
          left: 16,
          right: 24,
          top: 16,
          bottom: 16,
        ),
        children: [
            // ============ 一、浏览与对比 ============
            section('一、浏览文件、选中两个开始对比', [
              step('进入文件夹：', '点任意文件夹进入；左上角 ← 返回上一级。'),
              step('预览文件：', '点文件 → 打开预览页（只读，最多显示前 100 KB）。'),
              step('进入多选：', '长按任意文件或文件夹。'),
              step('多选下勾选：', '点一下切换勾选状态。'),
              step('选中 2 个文件后：', '底部出现「对比」按钮，点击开始。'),
              step('其它按钮：', '底部还有 属性 / 复制路径 / MD5 / 重命名 / 移动 / 复制 / 删除。'),
              step('新建文件夹：', '右下角浮动按钮。'),
              const SizedBox(height: 6),
              line('提示：对比的是两份文件，谁先选谁是"左边"，后选的自动是"右边"。'),
              line('支持 txt / docx 以及常见文本类扩展名（md、log、json、代码等）；'
                  '图片 / 音视频 / 压缩包 / PDF 等二进制格式会提示"暂不支持"。'),
              const SizedBox(height: 6),
              line('【隐藏技巧】', bold: true),
              line('· 长按顶部标题栏 → 跳转目录（可粘贴完整路径，粘的是文件路径会自动跳到所在目录）。'),
              line('· 面包屑导航（标题栏下方那行）可点击跳回上层目录。'),
            ]),

            // ============ 二、搜索文件 ============
            section('二、搜索文件', [
              step('搜索：', '顶部搜索框输入关键词，点搜索按钮或回车开始。'),
              step('搜索范围：', '长按搜索按钮 → 弹出菜单选「当前目录及子目录」或「自定义范围」。'),
              step('自定义范围：', '选「管理已勾选文件夹」勾选若干目录，搜索时只扫这些目录。'),
              step('取消：', '点搜索框右侧的 ✕ 清空，或点搜索状态栏的「取消」中止。'),
              const SizedBox(height: 6),
              line('搜索结果最多显示 500 个；点击结果可打开预览，长按可进入多选。'),
              line('扫描时自动跳过 /Android/data 和 /Android/obb 目录。'),
            ]),

            // ============ 三、长按操作速查 ============
            section('三、长按操作速查', [
              line('App 里有很多长按触发的小功能，集中列在这里。', bold: true),
              const SizedBox(height: 8),

              line('【文件浏览器】', bold: true),
              step('长按顶部标题栏：',
                  '弹出"跳转到目录"对话框。可粘贴完整路径直接跳转；'
                  '粘贴的是文件路径会自动跳到该文件所在目录。'),
              step('长按搜索按钮：',
                  '弹出搜索范围菜单——当前目录及子目录 / 自定义范围 / 管理已勾选文件夹。'),
              step('长按任意文件或文件夹：', '进入多选模式。'),
              step('长按搜索结果：', '进入多选模式。'),

              const SizedBox(height: 8),
              line('【对比页】', bold: true),
              step('长按查找栏"正则"按钮：', '打开正则帮助页（正则速查）。'),
              step('长按"忽略大小写"：', '弹提示"开启后 A 和 a 视为相同"。'),
              step('长按"整词"：', '弹提示"只匹配完整单词，对中文无效"。'),
              step('长按任意一行：', '弹出菜单——复制左边此行 / 复制右边此行 / 编辑此行。'),

              const SizedBox(height: 8),
              line('【通用】', bold: true),
              step('长按文字：',
                  '帮助页、正则帮助页里的所有文字都可以长按选中复制（含代码块）。'),
            ]),

            // ============ 四、比较设置总览 ============
            section('四、比较设置总览', [
              line('入口一：文件浏览器右上角齿轮 → 「比较设置」。', bold: true),
              line('入口二：对比页右下角 ⋮ → 「比较设置」。', bold: true),
              const SizedBox(height: 6),
              line('列表从上到下：'),
              step('1. 关键词规则：', '一整块文本，每行一条，普通文字匹配，不把字符当正则。'),
              step('2. 正则规则：', '一整块文本，每行一条，按正则表达式匹配，支持 $1 分组引用。'),
              step('3. 自定义规则：', '一条条带开关的规则，可指定只对左/右侧生效，可单独停用。'),
              step('4. 内置规则：', '开发者写死的一组规则，只提供开关。'),
              step('5. 忽略项：', '一排开关，点一下立即生效，消除无关差异。'),
              const SizedBox(height: 6),
              line('应用顺序：内置规则 → 自定义规则 → 关键词规则 → 正则规则。'),
              line('所有设置本地保存，重启后仍生效。'),
            ]),

            // ============ 五、关键词规则 ============
            section('五、关键词规则（批量删除/替换）', [
              line('用途：一次塞几百个要删除或替换的词（比如"xx小说网"、"xx整理"）。'),
              line('每行一条，格式：'),
              code('xxx              ← 删掉 xxx\n'
                  'xxx->=>yyy       ← 把 xxx 换成 yyy'),
              const SizedBox(height: 6),
              step('普通文字匹配：', '不把任何字符当正则，填什么就匹配什么。'),
              step('替换串支持转义：', r'\n \r \t \\ \0 会被还原成真正的控制字符。'),
              step('性能优势：', '一次扫描命中所有词（Aho-Corasick），规则再多也不变慢。'),
              step('不支持：', '正则、捕获组、$1 引用。替换串里的 $1 会原样输出。'),
              const SizedBox(height: 4),
              line('示例：'),
              code('xx小说网\n'
                  'xx整理\n'
                  '第一版->=>第二版\n'
                  '摘要->=>概要'),
              line('编辑器底部显示"共 N 行"，未保存时会标注"未保存"。'),
            ]),

            // ============ 六、正则规则 ============
            section('六、正则规则（高级匹配）', [
              line('格式和关键词一样，但匹配串是正则表达式：'),
              code(r'xxx              ← 匹配 xxx 就删掉' '\n'
                  r'xxx->=>yyy       ← 匹配 xxx 替换成 yyy'),
              const SizedBox(height: 6),
              step('捕获组：', r'替换串里用 $1、$2 引用正则中的括号内容，如 (\d+) 对应 $1。'),
              step('非法正则：', '会被跳过，不影响其它行。'),
              step('纯文本 find：', '不含正则元字符的自动走 String.replaceAll 快路径，'
                  '目标串不存在时直接跳过。'),
              line('常用正则写法见下一节速查表。'),
            ]),

            // ============ 七、正则速查表 ============
            section('七、正则速查表（想写什么，查这里）', [
              line('— 数字 —', bold: true),
              code(r'\d              任意一位数字 0-9' '\n'
                  r'\d+             连续数字（如 123）' '\n'
                  r'\d{3}           正好 3 位数字' '\n'
                  r'\d{2,5}         2 到 5 位数字' '\n'
                  r'[０-９]          全角数字' '\n'
                  r'\d+\.\d+        小数（如 3.14）'),

              const SizedBox(height: 8),
              line('— 英文 —', bold: true),
              code(r'[a-zA-Z]        任意一个英文字母' '\n'
                  r'[a-z]           小写字母' '\n'
                  r'[A-Z]           大写字母' '\n'
                  r'[a-zA-Z]+       连续英文字母' '\n'
                  r'\w              字母、数字或下划线' '\n'
                  r'[a-zA-Z]{4,}    4 个以上连续字母（如英文单词）'),

              const SizedBox(height: 8),
              line('— 中文 —', bold: true),
              code(r'[一-龥]         任意一个常用汉字' '\n'
                  r'[一-龥]+        连续汉字' '\n'
                  r'[\u4e00-\u9fa5]  同 [一-龥]，更完整写法'),

              const SizedBox(height: 8),
              line('— 空白 —', bold: true),
              code(r'\s              任意空白（空格 / Tab / 换行）' '\n'
                  r'\S              任意非空白' '\n'
                  r'[ \t]           空格或 Tab' '\n'
                  r'\n              换行' '\n'
                  r'\r              回车' '\n'
                  r'^\s*$           空行（整行只有空白）'),

              const SizedBox(height: 8),
              line('— 标点 —', bold: true),
              code('，。！？；：       中文标点（直接在 [ ] 里列出来）' '\n'
                  r'[,;:!?]         英文标点（! ? 在正则里是特殊字符，' '\n'
                  r'                放在 [ ] 里就是普通字符）' '\n'
                  '「」『』""\'\'     中文引号' '\n'
                  r'[.。…⋯]{2,}      连续 2 个以上点号/省略号'),

              const SizedBox(height: 8),
              line('— 量词 —', bold: true),
              code(r'*               前面出现 0 次或多次' '\n'
                  r'+               前面出现 1 次或多次' '\n'
                  r'?               前面出现 0 次或 1 次' '\n'
                  r'{n}             正好 n 次' '\n'
                  r'{n,}            至少 n 次' '\n'
                  r'{n,m}           n 到 m 次'),

              const SizedBox(height: 8),
              line('— 位置 —', bold: true),
              code(r'^               行首' '\n'
                  r'$               行尾' '\n'
                  r'\b              单词边界'),

              const SizedBox(height: 8),
              line('— 组合 —', bold: true),
              code(r'[...]           括号里任选一个' '\n'
                  r'[^...]          除了括号里的任意字符' '\n'
                  r'a|b             a 或 b' '\n'
                  r'(... )          分组，替换串里用 $1 引用' '\n'
                  r'.               任意字符（不含换行）'),

              const SizedBox(height: 8),
              line('— 常见完整例子 —', bold: true),
              code(r'\d{4}-\d{2}-\d{2}      日期 2024-01-01' '\n'
                  r'\d{11}                 11 位数字（如手机号）' '\n'
                  r'[a-zA-Z0-9._%-]+@[a-zA-Z0-9.-]+  邮箱' '\n'
                  r'https?://\S+           网址' '\n'
                  r'<[^>]+>                 HTML 标签' '\n'
                  r'第\d+章                 "第1章"、"第23章"'),
            ]),

            // ============ 八、常用正则组合 ============
            section('八、常用正则组合（直接抄）', [
              line('把下面任意一行粘到"正则规则"编辑器里就能用。', bold: true),
              const SizedBox(height: 4),

              line('— 标点归一 —', bold: true),
              code(r'[.。…⋯]{2,}->=>…       连续点号→省略号' '\n'
                  r'(\r?\n)[\r\n]+->=>$1   连续换行只留一个' '\n'
                  r'…{2,}->=>…             连续省略号压成一个' '\n'
                  r'[,，]{2,}->=>，         连续逗号归一'),

              const SizedBox(height: 8),
              line('— 删内容 —', bold: true),
              code(r'<[^>]+>                删掉 HTML 标签' '\n'
                  r'https?://\S+           删掉网址' '\n'
                  r'\d+                    删掉所有数字' '\n'
                  r'第\d+章.*              删掉"第N章"开头整行' '\n'
                  r'^\s*$                  删掉纯空行'),

              const SizedBox(height: 8),
              line('— 清空白 —', bold: true),
              code(r'^[ \t]+                删掉每行开头空格/Tab' '\n'
                  r'[ \t]+$                删掉每行结尾空格/Tab' '\n'
                  r'[ \t]+->=>             多个空格/Tab压成一个空格' '\n'
                  r'\n{3,}->=>\n\n          连续空行只留一个空行'),

              const SizedBox(height: 8),
              line('— 替换 —', bold: true),
              code(r'\d+->=>N               数字换成字母 N' '\n'
                  '“->=>"                 中文左引号→英文引号' '\n'
                  '”->=>"                 中文右引号→英文引号' '\n'
                  '，->=>,                 中文逗号→英文逗号' '\n'
                  '。->=>.                 中文句号→英文句号'),

              const SizedBox(height: 8),
              line('— 组合示例（批量清洗小说） —', bold: true),
              code(r'[.。…⋯]{2,}->=>…' '\n'
                  r'(\r?\n)[\r\n]+->=>$1' '\n'
                  r'[ \t]+->=> ' '\n'
                  r'^\s*$' '\n'
                  r'xx小说网' '\n'
                  r'xx整理'),
              line('上面这一组：点号归一 + 换行归一 + 空格归一 + 删空行 + 删两处水印。'),
            ]),

            // ============ 九、特殊字符写法 ============
            section('九、特殊字符怎么写', [
              line('替换串里，这些转义会被还原：', bold: true),
              const SizedBox(height: 4),
              code(r'\n   → 换行' '\n'
                  r'\r   → 回车' '\n'
                  r'\t   → 制表符 (Tab)' '\n'
                  r'\\   → 一个反斜杠 \' '\n'
                  r'\0   → 空字符（NUL）'),
              const SizedBox(height: 8),
              line('例：', bold: true),
              code(r'第\d+章->=>\n          每章前加换行' '\n'
                  r'分隔线->=>\n\n        换成两个换行' '\n'
                  r'制表位->=>\t           换成 Tab' '\n'
                  r'反斜线->=>\\           换成 \ 一个字符'),
              const SizedBox(height: 8),
              line('注意事项：', bold: true),
              step('匹配串里不写转义：', r'要匹配真正的换行，正则里写 \n 或 [\r\n]。'),
              step('其它 \\x：', r'未被识别的（如 \d、\w）原样保留，不报错。'),
              step('字面反斜杠：', r'想替换成 "\n" 这两个字符（而不是换行），写 \\n。'),
            ]),

            // ============ 十、自定义规则与内置规则 ============
            section('十、自定义规则与内置规则', [
              line('入口：比较设置页。', bold: true),
              step('自定义规则：',
                  '点"新建规则"，填规则名、查找正则、替换串，选作用范围（两份 / 仅原文 / 仅修改版）。'
                  '每条带一个开关，可单独启用/停用。'),
              step('内置规则：',
                  '统一换行、折叠多余空白、去行首尾空白、中英文引号统一、'
                  '逗号空格归一、忽略大小写、全角数字转半角。右侧开关可勾选启用。'),
              const SizedBox(height: 6),
              line('什么时候用自定义规则？'),
              line('· 只对左侧（原版）或右侧（修改版）生效 → 关键词/正则规则做不到。'),
              line('· 需要临时停用某一条 → 关键词/正则规则要删行，自定义规则拨开关即可。'),
            ]),

            // ============ 十一、忽略项 ============
            section('十一、忽略项', [
              line('用于消除无关差异，点开关立即生效：'),
              step('删掉空白符号：', '去掉空格 / Tab 后比较。'),
              step('删掉空行：', '删除纯空行后再比较。'),
              step('统一换行符：', r'统一 \r\n / \r / \n 三种换行格式。'),
              step('大写全转成小写：', 'A 和 a 视为相同。'),
              step('忽略纯数字：', '连续数字（如 123）视为占位符 <NUM>。'),
              step('忽略不可见字符：', '删除零宽空格、方向控制、BOM、软连字符、NBSP 等看不见的字符。'),
              step('统一编码 ANSI：', '非 ANSI 字符（Emoji、生僻字）会被删除。开启会丢失内容，慎用。'),
              const SizedBox(height: 6),
              line('注意：导入页底部也有一小块同样的开关（只列了 4 个常用项），'
                  '两处联动，改哪个都一样。'),
            ]),

            // ============ 十二、对比页 ============
            section('十二、对比页', [
              line('顶栏从左到右：', bold: true),
              step('↑：', '跳到上一处差异。'),
              step('↓：', '跳到下一处差异。'),
              step('放大镜：', '打开查找/替换栏。'),
              step('⋮：', '更多操作（编辑文档、导出差异、删除左/右文件、显示设置、'
                  '比较设置、开启/关闭不换行、开启/关闭两栏同步滚动、'
                  '性能面板、横屏）。'),
              const SizedBox(height: 6),
              line('视图切换（顶栏下方四个按钮）：', bold: true),
              step('差异上下文行（默认）：', '差异行 + 上下各 2 行上下文。'),
              step('纯差异：', '只显示发生变化的行，不带上下文。'),
              step('并排：', '左右双栏逐行对齐，同一逻辑行左右对照。'),
              step('合并：', '原版/修改版交错单栏显示。'),
              const SizedBox(height: 6),
              line('切换视图时会弹一个对话框，', bold: true),
              line('问你切过去后要跳到哪个位置：'),
              line('· 如果正在搜索，会提供"跳到我搜的那个词"。'),
              line('· 否则提供"屏幕第 1 / 2 / 3 行"、"屏幕顶部再往上一点"、"跳到文件最开头"。'),
              const SizedBox(height: 6),
              line('顶部横幅：', bold: true),
              line('· 差异少于 6 处时：显示"共 N 处差异"或"两份文档完全相同"。'),
              line('· 两份文件编码不同时：黄色横幅提示。'),
              line('· 删除过左/右文件时：红色横幅提示（内容仅内存保留）。'),
            ]),

            // ============ 十三、查找 / 替换 ============
            section('十三、查找 / 替换', [
              step('入口：', '对比页顶栏放大镜。'),
              const SizedBox(height: 6),
              line('查找：', bold: true),
              step('输入关键词：', '实时高亮当前视图里所有命中，默认浅黄；当前停留的一处为粉色加粗。'),
              step('上一个 / 下一个：', '在命中之间跳转。'),
              step('范围：', '四种视图都支持。'),
              step('差异视图搜不到时：', '若全量里有命中，顶部会弹提示，引导切到并排/合并视图。'),
              const SizedBox(height: 6),
              line('替换：', bold: true),
              step('替换为：', '在输入框填替换内容。留空 = 删掉。'),
              step('替换当前 / 全部替换：', '替换命中处（进缓存，不立即生效）。'),
              step('应用并刷新：', '右下角按钮，点一下才真正生效、重新对比。'
                  '连续替换多个词时先攒着，最后一次应用，速度快很多。'),
              step('关闭查找：', '若有未应用的替换，会弹窗问"取消 / 放弃 / 应用并关闭"。'),
              const SizedBox(height: 6),
              line('选项：', bold: true),
              step('查左侧 / 查右侧：', '至少开一个。关掉某一侧就不在那一侧查找/替换。'),
              step('正则：', '开启后查找串按正则解析，替换串支持 $1 $2。长按"正则"按钮打开正则帮助。'),
              step('忽略大小写：', 'A 和 a 视为相同。'),
              step('整词：', '只匹配完整英文单词，对中文无效。'),
            ]),

            // ============ 十四、导出差异 ============
            section('十四、导出差异', [
              step('入口：', '对比页 ⋮ →「导出差异为 txt」。'),
              step('选择左右：', '弹出选择"导出左边文件的差异处"或"导出右边文件的差异处"。'),
              step('只导一侧：', '一次只导一个 txt；想两个都导就点两次，分别选左边、右边。'),
              step('导出内容：', '把每处差异中"该侧独有的片段"逐行列出。'),
              const SizedBox(height: 6),
              line('示例：左边"我爱中国" 右边"我爱中国啊"'),
              line('→ 导出左边：无；导出右边：啊'),
              line('示例：左边"abc123" 右边"abc456"'),
              line('→ 导出左边：123；导出右边：456'),
            ]),

            // ============ 十五、编辑与保存 ============
            section('十五、编辑与保存', [
              step('入口：', '对比页 ⋮ →「编辑对比中的 2 个文档」，进入逐行对齐双栏编辑页。'),
              step('两侧都能改：', '左栏是原版，右栏是修改版。'),
              step('查找/替换：', '右上角放大镜：查找高亮、上一处/下一处、替换当前、全部替换；'
                  '"正则:开/关"按钮切换正则模式。'),
              step('保存：', '右上角"保存"。一律"另存为"，弹系统对话框选位置，绝不覆盖原文件。'
                  '两份文件会依次弹出两次保存对话框，请分别选位置。'),
              line('提示：编辑会先写入内存，点"保存"才落盘为新文件。'),
            ]),

            // ============ 十六、显示设置 ============
            section('十六、显示设置', [
              step('入口：', '对比页 ⋮ →「显示设置」。'),
              step('可调项：', '行号显示 / 隐藏、正文字号、行号字号、12 种差异颜色。'),
              step('差异颜色：', '左文件独有行、右文件独有行、被改行（左/右）、'
                  '行内删掉的字、行内新增的字——各有底色和文字颜色。'),
              line('所有显示设置都会保存，重启后仍生效。'),
            ]),

            // ============ 十七、横屏 ============
            section('十七、横屏切换', [
              step('入口：', '对比页 ⋮ →「切换到横屏」，长文并排对照更舒适。'),
              line('切回竖屏：同一个菜单项会变成"切换到竖屏"。'),
            ]),

            // ============ 十八、提示 ============
            section('十八、提示', [
              line('默认配色：红色=左文件独有，绿色=右文件独有，'
                  '浅粉=被改行（左），浅绿=被改行（右）。'),
              line('查找命中：浅黄高亮 + 加粗；当前停留的一处是粉色。'),
              line('关键词规则、正则规则、自定义规则、内置规则开关、忽略项、显示设置'
                  '——全部本地保存，重启后仍生效。'),
              line('本页所有文字可长按选中复制（含代码块）。'),
            ]),

// ============ 十九、开发者备忘 · 规则分布与修改入口 ============
section('【开发】十九、规则分布与修改入口', [
  line('想改某条规则，照这张表找文件。每一条都列出：定义在哪、应用在哪、UI 在哪、存储在哪。',
      bold: true),

  const SizedBox(height: 12),

  // ==================== 忽略项 ====================
  line('▶ 忽略项（当前 8 条）', bold: true),
  code(
    '【定义】\n'
    '  diff_viewer_providers.dart\n'
    '  → defaultIgnoreRules()  返回 List<PreprocessingRule>\n'
    '  字段：id / name / findPattern / replaceWith / script / enabled\n'
    '\n'
    '【应用】\n'
    '  diff_viewer_providers.dart\n'
    '  → applyDiffIgnores(String text, Map<String,bool> enables)\n'
    '  遍历 defaultIgnoreRules()，enabled 为 true 就执行：\n'
    '    - 有 script → 走 switch (script) 里的分支\n'
    '    - 无 script → out.replaceAll(RegExp(findPattern, multiLine: true), replaceWith)\n'
    '\n'
    '【查询某条是否开着】\n'
    '  diff_viewer_providers.dart\n'
    '  → isIgnoreOn(enables, id)\n'
    '\n'
    '【启用状态存储】\n'
    '  diff_viewer_providers.dart\n'
    '  → ignoreRuleEnablesProvider（Map<String,bool>，持久化）\n'
    '  → IgnoreRuleEnablesNotifier.setOne(id, enabled)\n'
    '  key = PrefKeys.ignoreRuleEnables（pref_keys.dart）\n'
    '\n'
    '【比较设置页 UI】\n'
    '  comparison_settings_screen.dart\n'
    '  → _ignoreSubtitles（每条 id 的副标题，Map<String,String>）\n'
    '  → build 里 for (final r in defaultIgnoreRules()) _switchTile(...)\n'
    '    完全自动生成，不用手写\n'
    '\n'
    '【导入页 UI】\n'
    '  import_screen.dart\n'
    '  → _importScreenIgnoreIds = {ig_ws, ig_empty, ig_nl, ig_ansi}\n'
    '    只显示这几个（导入页空间小，不放全部）\n'
    '  → _importIgnoreSubtitles（导入页的副标题）\n'
    '\n'
    '【归一化行号映射】\n'
    '  diff_viewer_providers.dart\n'
    '  → rawLineForNormalizedLine(raw, normalizedLine, ignoreEnables)\n'
    '    读 ig_ws / ig_empty / ig_invisible 三个开关判断行号偏移\n'
    '    被 diff_viewer_screen.dart 两处调用：\n'
    '      _applyRawChanges() 和 _replaceRawLine()\n'
    '\n'
    '【当前 8 条的 id 和实现】\n'
    '  ig_nl         正则  \\r\\n|\\r  →  \\n\n'
    '  ig_invisible  正则  [\\u00A0\\u00AD\\u200B-\\u200F...] → 空\n'
    '  ig_ws         正则  [ \\t]+ → 空\n'
    '  ig_empty      script  dropEmptyLines\n'
    '  ig_comma      正则  [,，] → 空\n'
    '  ig_num        正则  [0-9]+ → <NUM>\n'
    '  ig_case       script  lowercase\n'
    '  ig_ansi       script  unifyAnsi\n'
    '\n'
    '【加新脚本类型】\n'
    '  1. defaultIgnoreRules() 加一条带 script: \'新标识\' 的规则\n'
    '  2. applyDiffIgnores 的 switch (script) 加 case \'新标识\': ...\n'
  ),

  const SizedBox(height: 12),

  // ==================== 内置规则 ====================
  line('▶ 内置规则（当前 7 条）', bold: true),
  code(
    '【定义】\n'
    '  preprocessing/application/builtin_rules.dart\n'
    '  → BuiltinRules.all()  返回 List<PreprocessingRule>\n'
    '\n'
    '【应用】\n'
    '  preprocessing/application/preprocessing_service.dart\n'
    '  → PreprocessingService.apply(input, isOriginal)\n'
    '  合并逻辑：\n'
    '    active = [...]builtinRules.where(enabled) + ...userRules.where(enabled)\n'
    '    active.removeWhere(scope 不匹配 isOriginal 的)\n'
    '    if (active.length > 20) throw PreprocessingException\n'
    '    逐条 out = _applyOne(rule, out)\n'
    '\n'
    '【单条应用】\n'
    '  preprocessing_service.dart → _applyOne(rule, text)\n'
    '  三条分支：\n'
    '    1. rule.id == \'ignore_case\' → text.toLowerCase()  【特判】\n'
    '    2. _isPlainText(findPattern) → text.replaceAll(find, replace)  【快路径】\n'
    '    3. 其它 → text.replaceAllMapped(_cachedRegex(find), 展开 $1 $2)\n'
    '\n'
    '【正则缓存】\n'
    '  preprocessing_service.dart → _cachedRegex(pattern, multiLine)\n'
    '  顶层 _regexCache，cap 512，超了 clear\n'
    '\n'
    '【启用状态存储】\n'
    '  import_providers.dart\n'
    '  → builtinRuleEnablesProvider（Map<String,bool>，持久化）\n'
    '  → BuiltinRuleEnablesNotifier.setOne(id, enabled)\n'
    '  key = PrefKeys.builtinRuleEnables\n'
    '  → builtinRulesWithStateProvider（合并出带启用状态的列表）\n'
    '\n'
    '【UI】\n'
    '  comparison_settings_screen.dart\n'
    '  → for (final r in builtinRules) _ruleTile(...)\n'
    '\n'
    '【当前 7 条的 id 和实现】\n'
    '  norm_eol        \\r\\n|\\r           → \\n      默认开\n'
    '  norm_ws         [ \\t]{2,}          → " "     默认开\n'
    '  trim_line       ^[ \\t]+|[ \\t]+$   → 空      默认开\n'
    '  norm_quote      [""“”]          → "      默认关\n'
    '  norm_comma      [,，] +            → ，      默认开\n'
    '  ignore_case     特判 toLowerCase()              默认关\n'
    '  norm_number     [０-９]             → 0      默认关（这条实际是坏的）\n'
    '\n'
    '【注意】\n'
    '  ignore_case 和 norm_number 走特判。\n'
    '  改它们的 id 会让特判失效，只能改 name / enabled。\n'
  ),

  const SizedBox(height: 12),

  // ==================== 自定义规则 ====================
  line('▶ 自定义规则（用户新建）', bold: true),
  code(
    '【数据结构】\n'
    '  preprocessing/domain/preprocessing_rule.dart → PreprocessingRule\n'
    '  字段：id / name / findPattern / replaceWith / scope / enabled / isBuiltin / script\n'
    '\n'
    '【作用范围】\n'
    '  RuleScope 枚举：both / originalOnly / modifiedOnly\n'
    '\n'
    '【存储】\n'
    '  import_providers.dart\n'
    '  → userRulesProvider（List<PreprocessingRule>，持久化）\n'
    '  → UserRulesNotifier\n'
    '    .add(rule) / .updateRule(rule) / .remove(id) / .toggle(id)\n'
    '    .importFromJson(list)\n'
    '  key = PrefKeys.userRules（JSON 序列化）\n'
    '\n'
    '【应用】\n'
    '  同内置规则，一起进 PreprocessingService.apply()\n'
    '  顺序：内置规则先跑（BuiltinRules.all() 在前），自定义规则后跑\n'
    '  合并后 active.length > 20 会抛异常\n'
    '\n'
    '【UI】\n'
    '  comparison_settings_screen.dart\n'
    '  → _ruleTile(context, ref, rule, builtin: false)\n'
    '  → _RuleEditorDialog（新建规则弹窗）\n'
    '    字段：规则名 / 查找正则 / 替换串 / 作用范围\n'
    '  保存前会 try RegExp(find) 校验，非法则弹 SnackBar\n'
    '\n'
    '【默认值】\n'
    '  import_providers.dart → UserRulesNotifier.defaultValue\n'
    '  当前是 const []（空列表）\n'
    '  想让新用户自带示例规则，在这里填\n'
  ),

  const SizedBox(height: 12),

  // ==================== 关键词规则 ====================
  line('▶ 关键词规则（一整块文本）', bold: true),
  code(
    '【存储】\n'
    '  import_providers.dart\n'
    '  → keywordRulesTextProvider（String，持久化）\n'
    '  → KeywordRulesTextNotifier extends StringPrefNotifier\n'
    '  key = PrefKeys.keywordRulesText\n'
    '\n'
    '【解析】\n'
    '  import_providers.dart → _parseKeywordRules(rulesText)\n'
    '  按行 split，每行 trim：\n'
    '    含 ->=> → 拆成 (find, replace)，进 replacements 列表\n'
    '    不含    → 整行进 deletions 列表（会被删掉）\n'
    '  结果装进 _ParsedKeywordRules\n'
    '  deleteAc：删除类的 Aho-Corasick\n'
    '  replaceAc：替换类的 Aho-Corasick\n'
    '\n'
    '【缓存】\n'
    '  _keywordRulesCache（按 rulesText 作 key）\n'
    '  cap 16，超了 clear\n'
    '\n'
    '【应用】\n'
    '  import_providers.dart → applyKeywordRules(text, rulesText)\n'
    '  1. 先跑 builtinWatermarks（写死水印词库，_watermarkAc）\n'
    '  2. 再跑 deleteAc.replaceAll(out)  一次扫描\n'
    '  3. 再跑 replaceAc.replaceAll(out) 一次扫描\n'
    '\n'
    '【AC 实现】\n'
    '  preprocessing/application/aho_corasick.dart\n'
    '  → AhoCorasick(patterns, replacements)\n'
    '  → .replaceAll(text)\n'
    '  语义：最长优先、非重叠、一次扫描 O(n+m)\n'
    '\n'
    '【写死水印】\n'
    '  import_providers.dart → builtinWatermarks\n'
    '  一个 const List<String>，当前是空\n'
    '  填进去的词会跟关键词规则一起生效，但不受用户编辑\n'
    '  顶层 _watermarkAc 只建一次，永不重建\n'
    '\n'
    '【转义还原】\n'
    '  import_providers.dart → _unescapeReplacement(s)\n'
    '  只处理 4 种：\\n \\r \\t \\0 和 \\\\\n'
    '  其它 \\x 原样保留\n'
    '\n'
    '【编辑器 UI】\n'
    '  replace_rules_screen.dart（isRegex: false）\n'
    '  整页 TextField + 顶部说明 + 底部行数\n'
    '  保存时 update(ctrl.text) + importRevision++\n'
    '\n'
    '【性能特征】\n'
    '  不论多少条规则，全文扫 2 遍（删除类 + 替换类）\n'
    '  比正则规则逐条扫快一个数量级\n'
    '  不支持正则、不支持 $1 捕获组、不链式触发\n'
  ),

  const SizedBox(height: 12),

  // ==================== 正则规则 ====================
  line('▶ 正则规则（一整块文本）', bold: true),
  code(
    '【存储】\n'
    '  import_providers.dart\n'
    '  → regexRulesTextProvider（String，持久化）\n'
    '  → RegexRulesTextNotifier extends StringPrefNotifier\n'
    '  key = PrefKeys.regexRulesText\n'
    '\n'
    '【解析】\n'
    '  import_providers.dart → _parseRegexRules(rulesText)\n'
    '  按行 split，每行 trim：\n'
    '    含 ->=> → 拆成 (find, replace)\n'
    '    不含    → find = 整行，replace = 空（删掉）\n'
    '  每条判断 _isPlainText(find)：\n'
    '    true  → 纯文本，走 String.replaceAll 快路径\n'
    '    false → 正则，走 _cachedRegex\n'
    '  结果：List<_ParsedRegexRule>(find, replace, isPlain)\n'
    '\n'
    '【缓存】\n'
    '  _regexRulesCache（按 rulesText 作 key）\n'
    '  cap 16，超了 clear\n'
    '  _regexCache（按 pattern 作 key）\n'
    '  cap 512，超了 clear\n'
    '\n'
    '【应用】\n'
    '  import_providers.dart → applyRegexRules(text, rulesText)\n'
    '  for (final r in rules)：\n'
    '    if (r.isPlain)：\n'
    '      if (!out.contains(r.find)) continue   ← 目标串不存在直接跳过\n'
    '      out = out.replaceAll(r.find, r.replace)\n'
    '    else：\n'
    '      try { out = out.replaceAll(_cachedRegex(r.find), r.replace) }\n'
    '      catch (_) {}   ← 非法正则忽略，不影响其它行\n'
    '\n'
    '【元字符判断】\n'
    '  import_providers.dart → _regexMeta\n'
    '  RegExp(r\'[\\^$.*+?()\\[\\]{}|\\\\]\')\n'
    '  _isPlainText(s) = !_regexMeta.hasMatch(s)\n'
    '\n'
    '【不支持 $1 展开】\n'
    '  这条管线里替换串原样输出\n'
    '  想要 $1 捕获组？只能走自定义规则（PreprocessingService 里有 _expandReplacement）\n'
    '\n'
    '【编辑器 UI】\n'
    '  replace_rules_screen.dart（isRegex: true）\n'
    '  同关键词规则编辑器，只是顶部说明不同\n'
  ),

  const SizedBox(height: 12),

  // ==================== 处理管线完整顺序 ====================
  line('▶ 处理管线完整顺序', bold: true),
  code(
    '原始文本 raw\n'
    '  │\n'
    '  ├─→ ① PreprocessingService.apply()\n'
    '  │      内置规则 + 自定义规则\n'
    '  │      import_providers.dart → preprocessedOriginalProvider\n'
    '  │\n'
    '  ├─→ ② applyKeywordRules()\n'
    '  │      关键词规则（Aho-Corasick）\n'
    '  │      import_providers.dart\n'
    '  │\n'
    '  ├─→ ③ applyRegexRules()\n'
    '  │      正则规则（逐条 replaceAll）\n'
    '  │      import_providers.dart\n'
    '  │\n'
    '  ├─→ ④ applyDiffIgnores()\n'
    '  │      忽略项（列表式遍历）\n'
    '  │      diff_viewer_providers.dart → diffResultProvider\n'
    '  │\n'
    '  └─→ ⑤ _computeInWorker()\n'
    '         真正的 diff 计算（isolate 里跑）\n'
    '         PUA 路径（uniqueCount <= 6000）或 Myers 路径\n'
    '\n'
    '① ② ③ 在 preprocessedOriginalProvider / preprocessedModifiedProvider 里\n'
    '④ ⑤ 在 diffResultProvider 里\n'
    '\n'
    '每改一条规则、改一个忽略开关、改一份原文 → 整条管线重跑\n'
    'importRevision++ 也会触发重跑\n'
  ),

  const SizedBox(height: 12),

  // ==================== 显示设置 & 颜色 ====================
  line('▶ 显示设置 & 差异颜色', bold: true),
  code(
    '【显示设置】diff_viewer_providers.dart\n'
    '  showLineNumbersProvider   显示行号，默认 true\n'
    '  bodyFontSizeProvider      正文字号，默认 14.0\n'
    '  gutterFontSizeProvider    行号字号，默认 11.0\n'
    '  syncScrollProvider        两栏同步滚动，默认 true\n'
    '\n'
    '【非持久化开关】diff_viewer_providers.dart\n'
    '  viewModeProvider          当前视图（merged / sideBySide / diffOnly / diffOnlyPlain）\n'
    '  noWrapProvider            不换行，默认 false（关 App 复位）\n'
    '  showPerfOverlayProvider   性能面板，默认 false（关 App 复位）\n'
    '\n'
    '【12 个差异颜色】diff_viewer_providers.dart\n'
    '  deleteRowBg / deleteRowFg         左文件独有行\n'
    '  insertRowBg / insertRowFg         右文件独有行\n'
    '  replaceLeftBg / replaceLeftFg     被改行（左）\n'
    '  replaceRightBg / replaceRightFg   被改行（右）\n'
    '  charDeleteBg / charDeleteFg       行内删掉的字\n'
    '  charInsertBg / charInsertFg       行内新增的字\n'
    '  各用 ColorPrefNotifier，key 在 PrefKeys 里\n'
    '\n'
    '【diff 算法参数】diff_viewer_providers.dart 顶部\n'
    '  _puaLimit = 6000      唯一行数 ≤ 这个值走 PUA 编码路径（快）\n'
    '  _myersMaxD = 5000     Myers 最大编辑距离，超过退化\n'
    '\n'
    '【UI 入口】\n'
    '  显示设置面板：diff_viewer_screen.dart → _DisplaySettingsSheet\n'
    '  入口：更多菜单 → 显示设置\n'
  ),

  const SizedBox(height: 12),

  // ==================== 存储 key 总表 ====================
  line('▶ 存储 key 总表（PrefKeys）', bold: true),
  code(
    '前缀：jianming.（PrefKeys._p）\n'
    '\n'
    '【对比页显示设置】\n'
    '  jianming.display.showLineNumbers\n'
    '  jianming.display.bodyFontSize\n'
    '  jianming.display.gutterFontSize\n'
    '  jianming.display.syncScroll\n'
    '\n'
    '【12 个差异颜色】\n'
    '  jianming.color.deleteRowBg / deleteRowFg\n'
    '  jianming.color.insertRowBg / insertRowFg\n'
    '  jianming.color.replaceLeftBg / replaceLeftFg\n'
    '  jianming.color.replaceRightBg / replaceRightFg\n'
    '  jianming.color.charDeleteBg / charDeleteFg\n'
    '  jianming.color.charInsertBg / charInsertFg\n'
    '\n'
    '【忽略项】\n'
    '  jianming.ignore.ruleEnables（Map<String,bool>）\n'
    '  （旧的 ignore.whitespace 等 key 保留但不再用）\n'
    '\n'
    '【规则】\n'
    '  jianming.rules.keyword（String）\n'
    '  jianming.rules.regex（String）\n'
    '  jianming.rules.user（JSON）\n'
    '  jianming.rules.builtinEnables（JSON Map）\n'
    '\n'
    '【文件浏览器】\n'
    '  jianming.browser.sortField / sortAsc / favorites\n'
    '  jianming.browser.searchFolders / lastPath / searchScope\n'
    '\n'
    '【笔记】\n'
    '  comparison_notes（注意这个没有前缀）\n'
    '\n'
    '【不持久化】\n'
    '  originalRawTextProvider / modifiedRawTextProvider\n'
    '  originalFileNameProvider / modifiedFileNameProvider\n'
    '  originalFilePathProvider / modifiedFilePathProvider\n'
    '  originalEncodingProvider / modifiedEncodingProvider\n'
    '  importRevisionProvider / selectedSourceProvider\n'
    '  viewModeProvider / noWrapProvider / showPerfOverlayProvider\n'
    '  lastDiffPerfProvider\n'
  ),

  const SizedBox(height: 12),

  // ==================== 快速定位表 ====================
  line('▶ 快速定位', bold: true),
  code(
    '改忽略项             → diff_viewer_providers.dart → defaultIgnoreRules()\n'
    '改内置规则           → preprocessing/application/builtin_rules.dart → BuiltinRules.all()\n'
    '加忽略项脚本类型     → diff_viewer_providers.dart → applyDiffIgnores 里 switch\n'
    '加内置特判           → preprocessing_service.dart → _applyOne\n'
    '改关键词解析语法     → import_providers.dart → _parseKeywordRules\n'
    '改正则解析语法       → import_providers.dart → _parseRegexRules\n'
    '改关键词应用流程     → import_providers.dart → applyKeywordRules\n'
    '改正则应用流程       → import_providers.dart → applyRegexRules\n'
    '改关键词默认文本     → import_providers.dart → KeywordRulesTextNotifier 的 initial\n'
    '改正则默认文本       → import_providers.dart → RegexRulesTextNotifier 的 initial\n'
    '改自定义规则默认值   → import_providers.dart → UserRulesNotifier.defaultValue\n'
    '改规则上限（20 条）  → preprocessing_service.dart → apply() 里 if (active.length > 20)\n'
    '改 diff 算法参数     → diff_viewer_providers.dart → _puaLimit / _myersMaxD\n'
    '改 diff 主流程       → diff_viewer_providers.dart → diffResultProvider\n'
    '改 12 个颜色默认值   → diff_viewer_providers.dart → 各 xxxBgProvider / xxxFgProvider 的 initial\n'
    '改字号默认值         → diff_viewer_providers.dart → BodyFontSizeNotifier 等\n'
    '改忽略项副标题       → comparison_settings_screen.dart → _ignoreSubtitles\n'
    '改导入页显示的忽略项 → import_screen.dart → _importScreenIgnoreIds\n'
    '改导入页忽略项副标题 → import_screen.dart → _importIgnoreSubtitles\n'
  ),
]),

// ============ 二十、开发者备忘 · 什么能用代码代替替换 ============
section('【开发】二十、什么能用代码代替替换', [
  line('下面这些操作，用一行代码能顶几十条甚至几百条替换规则。'
      '看之前先想一件事：', bold: true),
  line('· 能用纯文本表达、互相不依赖 → 关键词规则（1 遍扫描）'),
  line('· 需要正则、不依赖前一条 → 正则规则（逐条扫描）'),
  line('· 需要代码逻辑 → script 字段或硬编码'),
  const SizedBox(height: 12),

  // ---------- A. 字符串 API ----------
  line('【A】字符串 API —— 正则做不到或很难做', bold: true),
  code(
    '■ 大小写转换\n'
    '  text.toLowerCase()               整段转小写（全 Unicode）\n'
    '  text.toUpperCase()               整段转大写\n'
    '  text[0].toUpperCase() + text.substring(1)   首字母大写\n'
    '  一行顶 26 条字母替换，且覆盖法语、德语、希腊、俄语等所有语言\n'
    '  正则做不到。现有 ig_case 就是 script: lowercase\n'
    '\n'
    '■ 去首尾空白\n'
    '  text.trim()          去整段首尾空白\n'
    '  text.trimLeft()      去开头空白\n'
    '  text.trimRight()     去结尾空白\n'
    '  trim 连全角空格 U+3000、NBSP 都算，比正则 ^[ \\t]+ 更全\n'
    '\n'
    '■ 按行切分 / 合并\n'
    '  text.split(\'\\n\')                 切成行列表\n'
    '  lines.join(\'\\n\')                 拼回文本\n'
    '  可以配合下面所有行级操作一起用\n'
    '\n'
    '■ 去重复行\n'
    '  text.split(\'\\n\').toSet().toList()   去掉内容重复的行\n'
    '  正则做不到。它需要跨行记住"这行出现过没有"\n'
    '\n'
    '■ 行排序 / 倒序\n'
    '  lines..sort()                              字典序排列\n'
    '  lines..sort((a,b)=>b.length.compareTo(a.length))   按长度排\n'
    '  lines.reversed.join(\'\\n\')                 整篇行倒序\n'
    '  lines.shuffle()                            打乱\n'
    '  正则做不到\n'
    '\n'
    '■ 行过滤\n'
    '  lines.where((l) => l.contains(\'关键词\')).join(\'\\n\')    只留含某词的行\n'
    '  lines.where((l) => !l.contains(\'广告\')).join(\'\\n\')   去掉含某词的行\n'
    '  lines.where((l) => l.length > 5).join(\'\\n\')           去掉太短的行\n'
    '  lines.where((l) => l.length < 500).join(\'\\n\')         去掉太长的行\n'
    '  正则做不到\n'
    '\n'
    '■ 加行号\n'
    '  lines.asMap().entries.map((e) => \'\${e.key+1}. \${e.value}\').join(\'\\n\')\n'
    '  正则做不到（正则无法生成递增编号）\n'
    '\n'
    '■ 去掉空行（含纯空格行）\n'
    '  lines.where((l) => l.trim().isNotEmpty).join(\'\\n\')\n'
    '  正则 ^\\s*$ 处理多行空行不干净，尤其头尾。写代码更彻底\n'
    '  现有 ig_empty 就是 script: dropEmptyLines\n'
    '\n'
    '■ 填充 / 截断\n'
    '  text.padLeft(10, \'0\')     左填充到 10 位\n'
    '  text.padRight(10, \' \')    右填充\n'
    '  text.substring(0, 100)     截前 100 字符\n'
  ),

  const SizedBox(height: 12),

  // ---------- B. 正则 ----------
  line('【B】正则一条顶很多条', bold: true),
  code(
    '■ Unicode 分类过滤（Dart 需 unicode: true）\n'
    r"  RegExp(r'\p{L}', unicode: true)   所有字母（中英日韩希腊俄…）" '\n'
    r"  RegExp(r'\p{N}', unicode: true)   所有数字（阿拉伯、中文、罗马…）" '\n'
    r"  RegExp(r'\p{P}', unicode: true)   所有标点" '\n'
    r"  RegExp(r'\p{S}', unicode: true)   所有符号（含 emoji）" '\n'
    r"  RegExp(r'\p{Z}', unicode: true)   所有分隔符（空格类）" '\n'
    r"  RegExp(r'\p{M}', unicode: true)   所有组合符" '\n'
    r"  RegExp(r'\p{C}', unicode: true)   所有控制/不可见字符" '\n'
    '\n'
    '  例：删所有不可见字符\n'
    r"    text.replaceAll(RegExp(r'\p{C}', unicode: true), '')" '\n'
    '  一条顶现在那个硬编码的 _invisibleChars 那一大串 \\u00A0\\u00AD\\u200B...\n'
    '\n'
    '■ 保留字母数字\n'
    r"  text.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')" '\n'
    '  删掉所有标点、符号、emoji、控制字符\n'
    '\n'
    '■ 多行模式（^ 和 $ 匹配每行）\n'
    r"  RegExp(r'^[ \t]+', multiLine: true)   每行开头的空白" '\n'
    r"  RegExp(r'[ \t]+$', multiLine: true)   每行结尾的空白" '\n'
    "  multiLine: true 是关键，不加的话 ^ 只匹配整段开头\n"
    '\n'
    '■ 空白折叠\n'
    r"  RegExp(r'\s+')       所有空白（空格/Tab/换行）" '\n'
    r"  RegExp(r'[ \t]+')    空格和 Tab" '\n'
    r"  RegExp(r'[^\S\n]+')  空格和 Tab 但不碰换行" '\n'
    '\n'
    '■ 连续字符压缩\n'
    r"  RegExp(r'\n{3,}')      3 个以上换行" '\n'
    r"  RegExp(r'[.。…⋯]+')    连续点号/省略号" '\n'
    r"  RegExp(r'[,，]{2,}')   连续逗号" '\n'
    '\n'
    '■ 后向引用（匹配重复）\n'
    r"  RegExp(r'(\w+)\s+\1')   匹配连续重复的词" '\n'
    '\n'
    '■ 命名捕获组\n'
    r"  RegExp(r'(?<year>\d{4})-(?<month>\d{2})')" '\n'
    "  匹配后 m.namedGroup('year')\n"
  ),

  const SizedBox(height: 12),

  // ---------- C. 码位运算 ----------
  line('【C】码位运算（正则做不到）', bold: true),
  code(
    '■ 全角转半角\n'
    '  String.fromCharCodes(text.runes.map((c) {\n'
    '    if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;\n'
    '    if (c == 0x3000) return 0x20;  // 全角空格\n'
    '    return c;\n'
    '  }))\n'
    '  覆盖数字、字母、标点，全 Unicode 完整映射\n'
    '  现有 norm_number 就是这条（但代码里是坏的，只转了 0）\n'
    '\n'
    '■ 半角转全角\n'
    '  String.fromCharCodes(text.runes.map((c) {\n'
    '    if (c >= 0x21 && c <= 0x7E) return c + 0xFEE0;\n'
    '    if (c == 0x20) return 0x3000;\n'
    '    return c;\n'
    '  }))\n'
    '\n'
    '■ 统一编码 ANSI（去掉无法转 GBK 的字符）\n'
    '  逐字符 gbk.encode，能还原的才保留\n'
    '  现有 ig_ansi 就是 script: unifyAnsi（在 diff_viewer_providers.dart）\n'
  ),

  const SizedBox(height: 12),

  // ---------- D. 需引包 ----------
  line('【D】需要引包的（正则绝对做不到）', bold: true),
  code(
    '■ NFC / NFD 归一化（é 的两种编码统一）\n'
    "  import 'package:unicode/unicode.dart';\n"
    '  text.nfc()   规范组合\n'
    '  text.nfd()   规范分解\n'
    '  text.nfkc()  兼容分解（①→1，㈱→(株)）\n'
    '  同一字符不同编码长得一样但码位不同，归一化后统一\n'
    '\n'
    '■ Grapheme 切分（用户感知字符）\n'
    "  import 'package:characters/characters.dart';\n"
    '  text.characters.length   按"用户感知字符"计数\n'
    '  处理 emoji、组合字、印地语连字\n'
    '  text.length 在很多语言里不等于 text.characters.length\n'
    '\n'
    '■ 简繁转换\n'
    "  import 'package:opencc/opencc.dart';\n"
    '  OpenCC.s2t(text)   简 → 繁\n'
    '  OpenCC.t2s(text)   繁 → 简\n'
    '\n'
    '■ 拼音\n'
    "  import 'package:pinyin/pinyin.dart';\n"
    '  PinyinHelper.getPinyinE(text)     汉字 → 拼音\n'
    '  PinyinHelper.getShortPinyin(text) 汉字 → 首字母\n'
    '\n'
    '■ 中文分词（jieba 类）\n'
    '  需要第三方包\n'
    '\n'
    '■ 编码转换\n'
    '  base64Encode(utf8.encode(text))     Base64 编码\n'
    '  utf8.decode(base64Decode(b64))     Base64 解码\n'
    '  Uri.encodeComponent(text)          URL 编码\n'
    '  Uri.decodeComponent(enc)           URL 解码\n'
    "  const HtmlEscape().convert(text)   HTML 实体编码\n"
    "  const HtmlUnescape().convert(text) HTML 实体解码\n"
    '\n'
    '■ 哈希摘要\n'
    "  import 'package:crypto/crypto.dart';\n"
    '  md5.convert(utf8.encode(text)).toString()\n'
    '  sha256.convert(utf8.encode(text)).toString()\n'
  ),

  const SizedBox(height: 12),

  // ---------- E. 需要写函数 ----------
  line('【E】需要写函数（几十行，做一次就够）', bold: true),
  code(
    '■ 中文数字 ↔ 阿拉伯数字\n'
    '  "一二三" ↔ "123"、"壹贰叁" ↔ "123"\n'
    '  需要字典 + 位权处理\n'
    '\n'
    '■ 罗马数字互转\n'
    '  "IV" ↔ 4、"MCMLXXXIV" ↔ 1984\n'
    '\n'
    '■ 进制转换\n'
    "  int.parse('ff', radix: 16)     十六进制 → 十进制\n"
    "  255.toRadixString(16)          十进制 → 十六进制\n"
    "  int.parse('1010', radix: 2)    二进制\n"
    '\n'
    '■ 科学计数法\n'
    "  double.parse('1.5e10')         字符串 → 数字\n"
    '\n'
    '■ 千分位\n'
    "  1234567.toString().replaceAllMapped(RegExp(r'(\\d)(?=(\\d{3})+\\$)'), (m) => '\${m[1]},')\n"
    '\n'
    '■ 词频统计\n'
    "  final words = text.split(RegExp(r'\\s+'));\n"
    '  final freq = <String, int>{};\n'
    '  for (final w in words) freq[w] = (freq[w] ?? 0) + 1;\n'
    '  然后按 freq 排序输出\n'
    '\n'
    '■ 停用词过滤\n'
    '  一个 const List<String> stopwords，逐行逐词 replaceAll\n'
    '  也可以放关键词规则里（词多的话 AC 更快）\n'
  ),

  const SizedBox(height: 12),

  // ---------- F. 决策口诀 ----------
  line('【F】决策口诀', bold: true),
  code(
    '纯文本、互相不依赖     → 关键词规则（Aho-Corasick，1 遍扫描，最快）\n'
    '需要正则、不依赖前一条 → 正则规则（逐条 replaceAll）\n'
    '需要正则、$1 捕获组    → 自定义规则（PreprocessingService 里有 _expandReplacement）\n'
    '只对左/右侧生效        → 自定义规则（带 scope）\n'
    '临时单独关某一条       → 自定义规则（带开关）\n'
    '行操作 / 码位运算      → script 字段（applyDiffIgnores 里加 case）\n'
    '两处都保留？           → 两个列表各跑各的时机，别合并\n'
  ),

  const SizedBox(height: 12),

  // ---------- G. 与规则的转换 ----------
  line('【G】转换示例', bold: true),
  code(
    '■ 原文正则：把 3 个以上连续换行压成 2 个\n'
    r"  RegExp(r'\n{3,}') → '\n\n'" '\n'
    '  能拆成规则吗：能。findPattern + replaceWith 就能表达\n'
    '\n'
    '■ 原文正则：去掉所有 HTML 标签\n'
    r"  RegExp(r'<[^>]+>') → ''" '\n'
    '  能拆成规则吗：能\n'
    '\n'
    '■ 原文正则：把 "2024-01-01" 换成 "2024年01月01日"\n'
    r"  RegExp(r'(\d{4})-(\d{2})-(\d{2})') → '\$1年\$2月\$3日'" '\n'
    '  能拆成规则吗：只有自定义规则支持（正则规则和关键词规则不支持 $1）\n'
    '\n'
    '■ 原文代码：全段转小写\n'
    '  text.toLowerCase()\n'
    '  能拆成规则吗：不能。必须写 script 或在 applyDiffIgnores 里加 case\n'
    '\n'
    '■ 原文代码：去掉重复行\n'
    "  text.split('\\n').toSet().join('\\n')\n"
    '  能拆成规则吗：不能。必须写 script\n'
  ),
]),

// ============ 二十一、开发者备忘 · 全部可用代码替代的替换 ============
section('【开发】二十一、全部可用代码替代的替换', [
  line('把 Dart 里所有能替代"查找+替换"的操作都列出来。'
      '每条标注：正则能不能做、能不能写成规则、是否需要引包。', bold: true),
  const SizedBox(height: 12),

  // ==================== 一、大小写 ====================
  line('一、大小写', bold: true),
  code(
    "text.toLowerCase()                  全小写（全 Unicode）\n"
    "text.toUpperCase()                  全大写\n"
    "text[0].toUpperCase() + text.substring(1)  首字母大写\n"
    "line.split(' ').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join(' ')  Title Case\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否（除非加 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 二、空白 ====================
  line('二、空白处理', bold: true),
  code(
    "text.trim()                          整段去首尾空白\n"
    "text.trimLeft()                      去开头空白\n"
    "text.trimRight()                     去结尾空白\n"
    "text.replaceAll(' ', '')             删普通空格\n"
    "text.replaceAll('\\t', '')            删 Tab\n"
    "text.replaceAll(RegExp(r'\\s+'), '')   删所有空白\n"
    "text.replaceAll(RegExp(r'\\s+'), ' ')  所有空白折叠成一个空格\n"
    "text.replaceAll(RegExp(r'[^\\S\\n]+'), ' ')  折叠空格但不碰换行\n"
    "text.replaceAll('\\t', '    ')          Tab → 4 空格\n"
    "text.replaceAll('    ', '\\t')          4 空格 → Tab\n"
    "text.replaceAll('\\u00A0', ' ')        NBSP → 普通空格\n"
    "text.replaceAll('\\u3000', ' ')        全角空格 → 普通空格\n"
    "text.replaceAll(RegExp(r'^[ \\t]+', multiLine: true), '')  每行开头空白\n"
    "text.replaceAll(RegExp(r'[ \\t]+$', multiLine: true), '')  每行结尾空白\n"
    "\n"
    "正则能做：多数能\n"
    "能写成规则：能（findPattern + replaceWith）\n"
    "例外：trim 家族（比正则更全，覆盖全角空格）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 三、行操作 ====================
  line('三、行级操作', bold: true),
  code(
    "text.split('\\n')                    切成行\n"
    "lines.join('\\n')                    拼回\n"
    "lines.toSet().toList()               去重复行\n"
    "lines.toSet().join('\\n')            去重复行并拼回\n"
    "lines..sort()                        字典序排\n"
    "lines..sort((a,b)=>b.length.compareTo(a.length))  按长度排\n"
    "lines.reversed.toList()              行倒序\n"
    "lines.shuffle()                      打乱\n"
    "lines.where((l) => l.trim().isNotEmpty).toList()   去空行\n"
    "lines.where((l) => l.contains('关键词')).toList()  只留含某词\n"
    "lines.where((l) => !l.contains('广告')).toList()   去掉含某词\n"
    "lines.where((l) => l.length > 5).toList()          去太短\n"
    "lines.where((l) => l.length < 500).toList()        去太长\n"
    "lines.map((l) => '  $l').join('\\n')               每行加缩进\n"
    "lines.map((l) => l.substring(4)).join('\\n')       去掉每行前 4 字符\n"
    "lines.map((l) => l.trimRight()).join('\\n')        每行去尾空白\n"
    "lines.asMap().entries.map((e)=>'${e.key+1}. ${e.value}').join('\\n')  加行号\n"
    "lines.take(10).join('\\n')           只留前 10 行\n"
    "lines.skip(10).join('\\n')           跳过前 10 行\n"
    "lines.takeWhile((l) => l.isNotEmpty) 到空行停\n"
    "lines.where((l) => l.startsWith('#')).toList()   只留注释行\n"
    "lines.where((l) => !l.startsWith('//')).toList() 去注释行\n"
    "\n"
    "正则能做：绝大多数不能\n"
    "能写成规则：不能（需要 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 四、查找替换变体 ====================
  line('四、查找替换的变体（不止 replaceAll）', bold: true),
  code(
    "text.replaceAll('a', 'b')                 替换所有\n"
    "text.replaceFirst('a', 'b')               替换第一个\n"
    "text.replaceRange(0, 5, 'xxx')            按位置替换\n"
    "text.replaceAllMapped(RegExp(r'\\d+'), (m) => '${int.parse(m[0]!)*2}')  匹配后计算\n"
    "text.replaceFirstMapped(RegExp(r'\\d+'), (m) => '${int.parse(m[0]!)+1}')  第一个匹配后计算\n"
    "\n"
    "正则能做：能\n"
    "能写成规则：replaceAll 能；replaceFirst 不能；Mapped 不能（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 五、正则相关 ====================
  line('五、正则相关', bold: true),
  code(
    r"RegExp(r'\p{L}', unicode: true)        所有字母（中英日韩希腊俄）" "\n"
    r"RegExp(r'\p{N}', unicode: true)        所有数字" "\n"
    r"RegExp(r'\p{P}', unicode: true)        所有标点" "\n"
    r"RegExp(r'\p{S}', unicode: true)        所有符号（含 emoji）" "\n"
    r"RegExp(r'\p{Z}', unicode: true)        所有分隔符" "\n"
    r"RegExp(r'\p{M}', unicode: true)        组合符" "\n"
    r"RegExp(r'\p{C}', unicode: true)        控制/不可见" "\n"
    "\n"
    r"RegExp(r'[^\p{L}\p{N}]', unicode: true)  只留字母数字" "\n"
    "\n"
    "text.replaceAll(RegExp(r'\\n{3,}'), '\\n\\n')  3 个以上换行压 2 个\n"
    "text.replaceAll(RegExp(r'[.。…]+'), '…')     连续点号压省略号\n"
    "text.replaceAll(RegExp(r'[,，]{2,}'), '，')   连续逗号归一\n"
    "text.replaceAll(RegExp(r'[ \\t]+'), ' ')      空格 Tab 折叠\n"
    "text.replaceAll(RegExp(r'^\\s*$', multiLine: true), '')  删空行（不彻底）\n"
    "text.replaceAll(RegExp(r'<[^>]+>'), '')      删 HTML 标签\n"
    "text.replaceAll(RegExp(r'https?://\\S+'), '') 删网址\n"
    "\n"
    "text.replaceAllMapped(RegExp(r'(\\d+)'), (m) => 'X${m[1]}X')  包住数字\n"
    "\n"
    "正则能做：能\n"
    "能写成规则：多数能；带回调的不行（需 script）\n"
    "注意：正则规则里替换串不支持 $1（不支持捕获组展开）\n"
    "      只有自定义规则支持 $1\n"
  ),
  const SizedBox(height: 10),

  // ==================== 六、判断类 ====================
  line('六、判断类（用于条件逻辑）', bold: true),
  code(
    "text.isEmpty                          是否空串\n"
    "text.isNotEmpty                       是否非空\n"
    "text.startsWith('xxx')                是否以某串开头\n"
    "text.endsWith('xxx')                  是否以某串结尾\n"
    "text.contains('xxx')                  是否含某串\n"
    "text.contains(RegExp(r'\\d+'))         是否含正则模式\n"
    "text == 'xxx'                         是否等于\n"
    "text.compareTo('xxx') == 0            是否等于（大小写敏感）\n"
    "text.toLowerCase() == other.toLowerCase()  忽略大小写相等\n"
    "\n"
    "正则能做：等价的有 contains(RegExp) / startsWith(RegExp)\n"
    "能写成规则：不能（判断不产生替换）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 七、提取类 ====================
  line('七、提取类', bold: true),
  code(
    "text.substring(0, 10)                            前 10 字符\n"
    "text.substring(text.length - 5)                  后 5 字符\n"
    "text.split(',').first                            第一个元素\n"
    "text.split(',').last                             最后一个元素\n"
    "text.split(',').take(3).join(',')                前 3 个\n"
    "RegExp(r'\\d+').firstMatch(text)?.group(0)      第一个数字串\n"
    "RegExp(r'\\d+').allMatches(text).map((m) => m.group(0))  所有数字串\n"
    "RegExp(r'(?<year>\\d{4})-(?<m>\\d{2})').firstMatch(text)?.namedGroup('year')  命名组\n"
    "text.indexOf('关键词')                           位置\n"
    "text.lastIndexOf('关键词')\n"
    "RegExp(r'\\w+').allMatches(text).length          词数\n"
    "\n"
    "正则能做：能\n"
    "能写成规则：不能（提取不产生替换）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 八、生成类 ====================
  line('八、生成类', bold: true),
  code(
    "text.padLeft(10, '0')                左填充到 10 位\n"
    "text.padRight(10, ' ')               右填充\n"
    "text * 3                             重复 3 次\n"
    "'abc' + text + 'xyz'                 前后加东西\n"
    "List.filled(10, text).join(',')      重复 10 次用逗号连\n"
    "'\\n' * 3                            生成 3 个换行\n"
    "\n"
    "正则能做：否（生成不依赖查找）\n"
    "能写成规则：否\n"
  ),
  const SizedBox(height: 10),

  // ==================== 九、码位运算 ====================
  line('九、码位运算', bold: true),
  code(
    "// 全角 → 半角\n"
    "String.fromCharCodes(text.runes.map((c) {\n"
    "  if (c >= 0xFF01 && c <= 0xFF5E) return c - 0xFEE0;\n"
    "  if (c == 0x3000) return 0x20;\n"
    "  return c;\n"
    "}))\n"
    "\n"
    "// 半角 → 全角\n"
    "String.fromCharCodes(text.runes.map((c) {\n"
    "  if (c >= 0x21 && c <= 0x7E) return c + 0xFEE0;\n"
    "  if (c == 0x20) return 0x3000;\n"
    "  return c;\n"
    "}))\n"
    "\n"
    "// 字符码位\n"
    "text.codeUnitAt(0)                   第 0 字符码位\n"
    "text.runes.first                     第一个码点\n"
    "String.fromCharCode(0x4E2D)          码位 → 字符\n"
    "\n"
    "// 字符遍历\n"
    "for (final rune in text.runes) { ... }       按码点\n"
    "for (final ch in text.characters) { ... }    按用户感知（需 characters 包）\n"
    "\n"
    "正则能做：否（正则不能做算术）\n"
    "能写成规则：否（除非 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十、编码相关 ====================
  line('十、编码相关', bold: true),
  code(
    "utf8.encode(text)                        字符串 → UTF-8 字节\n"
    "utf8.decode(bytes)                       字节 → 字符串\n"
    "latin1.decode(bytes) / latin1.encode(s)  Latin-1\n"
    "gbk.encode(text) / gbk.decode(bytes)     GBK（需包）\n"
    "base64Encode(utf8.encode(text))          Base64 编码\n"
    "utf8.decode(base64Decode(b64))           Base64 解码\n"
    "Uri.encodeComponent(text)                URL 编码\n"
    "Uri.decodeComponent(enc)                 URL 解码\n"
    "Uri.encodeFull(text) / Uri.decodeFull(text)  整 URL\n"
    "const HtmlEscape().convert(text)         HTML 实体编码\n"
    "const HtmlUnescape().convert(text)       HTML 实体解码\n"
    "\n"
    "正则能做：Base64/URL/HTML 有对应模式，但不如内置函数\n"
    "能写成规则：否（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十一、数字处理 ====================
  line('十一、数字处理', bold: true),
  code(
    "int.parse('123')                     字符串 → 整数\n"
    "double.parse('3.14')                 字符串 → 浮点\n"
    "int.parse('ff', radix: 16)           十六进制\n"
    "int.parse('1010', radix: 2)          二进制\n"
    "255.toRadixString(16)                → 'ff'\n"
    "255.toRadixString(2)                 → '11111111'\n"
    "double.parse('1.5e10')               科学计数\n"
    "1234567.toString()                   整数 → 字符串\n"
    "3.14.toStringAsFixed(2)              → '3.14'\n"
    "\n"
    "// 千分位\n"
    "1234567.toString().replaceAllMapped(\n"
    "  RegExp(r'(\\d)(?=(\\d{3})+$)'),\n"
    "  (m) => '${m[1]},',\n"
    ")\n"
    "\n"
    "// 补零\n"
    "5.toString().padLeft(3, '0')         → '005'\n"
    "\n"
    "正则能做：部分能\n"
    "能写成规则：简单的能；进制/千分位需 script\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十二、日期时间 ====================
  line('十二、日期时间', bold: true),
  code(
    "DateTime.parse('2024-01-01')         字符串 → 日期\n"
    "dt.toIso8601String()                 日期 → ISO\n"
    "dt.year / .month / .day / .hour / .minute / .second\n"
    "'${dt.year}年${dt.month}月${dt.day}日'    中文格式\n"
    "\n"
    "// 格式转换\n"
    "'2024-01-01'.replaceAll('-', '/')    → '2024/01/01'\n"
    "'2024/01/01'.replaceAll('/', '-')    → '2024-01-01'\n"
    "\n"
    "// 补零\n"
    "dt.month.toString().padLeft(2, '0')  → '01'\n"
    "\n"
    "正则能做：简单格式转换能\n"
    "能写成规则：简单格式能；解析/补零需 script\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十三、哈希摘要 ====================
  line('十三、哈希摘要', bold: true),
  code(
    "import 'package:crypto/crypto.dart';\n"
    "md5.convert(utf8.encode(text)).toString()      32 位十六进制\n"
    "sha1.convert(utf8.encode(text)).toString()     40 位\n"
    "sha256.convert(utf8.encode(text)).toString()   64 位\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十四、排序比较 ====================
  line('十四、排序比较', bold: true),
  code(
    "list..sort()                                      默认排序\n"
    "list..sort((a,b) => a.compareTo(b))               升序\n"
    "list..sort((a,b) => b.compareTo(a))               降序\n"
    "list..sort((a,b) => a.length.compareTo(b.length)) 按长度\n"
    "list..sort((a,b) => a.toLowerCase().compareTo(b.toLowerCase()))  忽略大小写\n"
    "\n"
    "// 自定义比较：按数字\n"
    "list..sort((a,b) => int.parse(a).compareTo(int.parse(b)))\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十五、集合操作 ====================
  line('十五、集合操作', bold: true),
  code(
    "lines.toSet().toList()               去重\n"
    "lines.toSet().join('\\n')            去重并拼\n"
    "set.toList()..sort()                 去重后排序\n"
    "set.length                           去重后数量\n"
    "a.union(b)                           并集\n"
    "a.intersection(b)                    交集\n"
    "a.difference(b)                      差集\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十六、拼接格式化 ====================
  line('十六、拼接格式化', bold: true),
  code(
    "'text: $x'                           字符串插值\n"
    "'${a}+${b}=${a+b}'                   表达式\n"
    "list.join(',')                       列表拼接\n"
    "list.join('\\n')                      用换行拼\n"
    "'a' * 5                              → 'aaaaa'\n"
    "'\\n' * 3                             → '\\n\\n\\n'\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十七、比较特殊 ====================
  line('十七、Unicode 归一化（需包）', bold: true),
  code(
    "import 'package:unicode/unicode.dart';\n"
    "text.nfc()     规范组合\n"
    "text.nfd()     规范分解\n"
    "text.nfkc()    兼容分解（①→1，㈱→(株)，Ⅳ→IV）\n"
    "text.nfkd()    兼容分解（更激进的 NFKD）\n"
    "\n"
    "用途：é 有两种编码（单码位 / e + 组合符），"
    "视觉一样但 diff 会判成不同。归一化后统一。\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十八、Grapheme ====================
  line('十八、Grapheme 切分（需包）', bold: true),
  code(
    "import 'package:characters/characters.dart';\n"
    "text.characters.length              用户感知字符数\n"
    "text.characters.first               第一个字符\n"
    "text.characters.toList()            切分成列表\n"
    "\n"
    "用途：emoji、组合字、印地语连字、家庭 emoji 等\n"
    "在 text.length 里可能算 1~7 个 UTF-16 码元\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 十九、中文相关（需包） ====================
  line('十九、中文相关（需包）', bold: true),
  code(
    "// 简繁\n"
    "import 'package:opencc/opencc.dart';\n"
    "OpenCC.s2t(text)                    简 → 繁\n"
    "OpenCC.t2s(text)                    繁 → 简\n"
    "\n"
    "// 拼音\n"
    "import 'package:pinyin/pinyin.dart';\n"
    "PinyinHelper.getPinyinE(text)       汉字 → 拼音\n"
    "PinyinHelper.getShortPinyin(text)   汉字 → 拼音首字母\n"
    "\n"
    "// 中文分词\n"
    "需第三方包（jieba 类）\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否（需 script）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 二十、正则高级 ====================
  line('二十、正则高级用法', bold: true),
  code(
    r"RegExp(r'(?<name>\d+)')             命名捕获组" "\n"
    r"RegExp(r'(?:abc)')                   非捕获组" "\n"
    r"RegExp(r'(?=abc)')                   前瞻" "\n"
    r"RegExp(r'(?!abc)')                   负前瞻" "\n"
    r"RegExp(r'(?<=abc)')                  后顾" "\n"
    r"RegExp(r'(?<!abc)')                  负后顾" "\n"
    r"RegExp(r'\b')                        单词边界（英文有效）" "\n"
    r"RegExp(r'^', multiLine: true)        每行开头" "\n"
    r"RegExp(r'$', multiLine: true)        每行结尾" "\n"
    r"RegExp(r'(?i)abc')                   忽略大小写（Dart 用参数 caseSensitive: false）" "\n"
    "\n"
    r"RegExp(r'(.)\1')                     反向引用（连续重复字符）" "\n"
    r"RegExp(r'(\w+)\s+\1')                重复的词" "\n"
    "\n"
    "正则能做：能\n"
    "能写成规则：正则规则里能表达，但替换串不支持 $1（需自定义规则）\n"
  ),
  const SizedBox(height: 10),

  // ==================== 二十一、其它 ====================
  line('二十一、其它零碎', bold: true),
  code(
    "text.codeUnits.length                码元数（≠ 字符数）\n"
    "text.runes.length                    码点数\n"
    "text.length                          UTF-16 单元数\n"
    "text.isEmpty                         是否空\n"
    "text.hashCode                         哈希值\n"
    "text.compareTo(other)                 比较\n"
    "text.codeUnitAt(i)                    第 i 个码元\n"
    "String.fromCharCodes([72, 105])       → 'Hi'\n"
    "text.toString()                       对象 → 字符串\n"
    "int.parse(text) / double.parse(text)  字符串 → 数字\n"
    "\n"
    "正则能做：否\n"
    "能写成规则：否\n"
  ),
  const SizedBox(height: 10),

  // ==================== 汇总决策 ====================
  line('【汇总】决策流程', bold: true),
  code(
    "拿到一个操作，问自己：\n"
    "\n"
    "1. 是纯文本查找替换吗？\n"
    "   是 → 关键词规则（Aho-Corasick，1 遍扫描最快）\n"
    "\n"
    "2. 需要正则吗？\n"
    "   是 → 正则规则（逐条 replaceAll）\n"
    "   需要 $1 捕获组 → 自定义规则\n"
    "\n"
    "3. 只对左/右侧生效？\n"
    "   是 → 自定义规则（scope）\n"
    "\n"
    "4. 需要独立开关？\n"
    "   是 → 自定义规则或内置规则\n"
    "\n"
    "5. 是"忽略差异"而非"改文本"？\n"
    "   是 → 忽略项\n"
    "\n"
    "6. 是行操作 / 码位运算 / 集合操作 / 需要引包？\n"
    "   是 → script 字段\n"
    "      （在 applyDiffIgnores 的 switch 里加 case，\n"
    "        或给 PreprocessingRule 加 script 分支）\n"
    "\n"
    "7. 是判断 / 提取 / 生成 而不是替换？\n"
    "   是 → 规则系统表达不了，只能写 script\n"
    "\n"
    "一句话：能表达式化的，就放规则；需要运算或逻辑的，写 script。\n"
  ),
]),

            

            
          ],
        ),
      ),
    );
  }
}

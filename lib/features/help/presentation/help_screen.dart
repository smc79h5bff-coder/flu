import 'package:flutter/material.dart';

/// 使用说明：覆盖文件浏览与搜索、关键词/正则规则、正则速查、
/// 比较设置、对比页、查找/替换、长按操作、隐藏技巧、
/// 编辑/保存、显示设置、横屏等全部功能。
/// 整页文字可长按选中复制。
///
/// 本页不使用任何 Icon，全部用普通文字符号，避免打包后图标缺失。
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

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
        child: ListView(
          padding: const EdgeInsets.all(16),
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
          ],
        ),
      ),
    );
  }
}

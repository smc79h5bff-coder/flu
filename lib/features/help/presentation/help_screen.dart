import 'package:flutter/material.dart';

/// 使用说明：覆盖导入、预处理规则、关键词/正则规则、常用正则组合、
/// 比较设置、对比页、长按操作、查找、编辑/保存、显示设置、横屏等全部功能。
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;

    Widget section(String title, IconData icon, List<Widget> children) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: s.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ============ 一、导入 ============
          section('一、导入文档', Icons.upload_file, [
            step('方式1 本地文件：', '分别点击「原文档」「修改版文档」卡片的「本地文件」，选 txt / docx。'),
            step('方式2 粘贴文本：', '先复制文本，点「粘贴文本」从剪贴板导入。'),
            step('两份都导入后：', '「开始对比」按钮才亮起。'),
            line('提示：大文件导入与对比均在后台计算，页面不会卡死。'),
          ]),

          // ============ 二、关键词规则 ============
          section('二、关键词规则（批量删除/替换）', Icons.text_fields, [
            line('入口：比较设置 → 关键词规则。', bold: true),
            line('用途：一次塞几百个要删除或替换的词（比如"xx小说网"、"xx整理"）。'),
            const SizedBox(height: 4),
            line('每行一条，格式：'),
            code('xxx              ← 删掉 xxx\n'
                'xxx->=>yyy       ← 把 xxx 换成 yyy'),
            const SizedBox(height: 6),
            step('普通文字匹配：', '不把任何字符当正则，填什么就匹配什么。'),
            step('替换串支持转义：', '见下文「特殊字符写法」表。'),
            const SizedBox(height: 4),
            line('示例：'),
            code('xx小说网\n'
                'xx整理\n'
                '第一版->=>第二版\n'
                '摘要->=>概要'),
            line('效果：删掉"xx小说网"和"xx整理"；把"第一版"换成"第二版"；'
                '把"摘要"换成"概要"。'),
          ]),

          // ============ 三、正则规则 ============
          section('三、正则规则（高级匹配）', Icons.code, [
            line('入口：比较设置 → 正则规则。', bold: true),
            line('格式和关键词一样，但匹配串是正则表达式：'),
            code(r'xxx              ← 匹配 xxx 就删掉' '\n'
                r'xxx->=>yyy       ← 匹配 xxx 替换成 yyy'),
            const SizedBox(height: 6),
            line('常用正则示例：'),
            code(r'[.。…⋯]{2,}->=>…       连续点号→省略号' '\n'
                r'(\r?\n)[\r\n]+->=>$1   连续换行只留一个' '\n'
                r'\d+                     删掉所有数字' '\n'
                r'\d+->=>N               数字换成字母 N'),
            const SizedBox(height: 6),
            step('捕获组：', '替换串里用 \$1、\$2 引用正则中的括号内容，如 (\\d+) 对应 \$1。'),
            step('非法正则：', '会被跳过，不影响其它行。'),
          ]),

          // ============ 三·五、常用正则组合（即抄即用） ============
          section('常用正则组合（直接抄）', Icons.content_paste, [
            line('把下面任意一行粘到"正则规则"编辑器里就能用。', bold: true),
            const SizedBox(height: 4),

            line('— 标点归一 —', bold: true),
            code(r'[.。…⋯]{2,}->=>…'
                '       连续点号→省略号'),
            code(r'(\r?\n)[\r\n]+->=>$1'
                '   连续换行只留一个'),
            code(r'…{2,}->=>…'
                '             连续省略号压成一个'),
            code(r'[,，]{2,}->=>，'
                '           连续逗号归一'),

            const SizedBox(height: 8),
            line('— 删内容 —', bold: true),
            code(r'<[^>]+>'
                '               删掉 HTML 标签'),
            code(r'https?://\S+'
                '           删掉网址'),
            code(r'\d+'
                '                   删掉所有数字'),
            code(r'第\d+章.*'
                '             删掉"第N章"开头整行'),
            code(r'^\s*$'
                '                  删掉纯空行'),

            const SizedBox(height: 8),
            line('— 清空白 —', bold: true),
            code(r'^[ \t]+'
                '                 删掉每行开头空格/Tab'),
            code(r'[ \t]+$'
                '                 删掉每行结尾空格/Tab'),
            code(r'[ \t]+->=> '
                '             多个空格/Tab压成一个空格'),
            code(r'\n{3,}->=>\n\n'
                '          连续空行只留一个空行'),

            const SizedBox(height: 8),
            line('— 替换 —', bold: true),
            code(r'\d+->=>N'
                '                 数字换成字母 N'),
            code('“->=>"'
                '                  中文左引号→英文引号'),
            code('”->=>"'
                '                  中文右引号→英文引号'),
            code('，->=>,'
                '                  中文逗号→英文逗号'),
            code('。->=>.'
                '                  中文句号→英文句号'),

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

          // ============ 四、特殊字符写法 ============
          section('四、特殊字符怎么写', Icons.auto_fix_high, [
            line('替换串里，这些字符有特殊含义，需要转义：', bold: true),
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

          // ============ 五、自定义/内置规则 ============
          section('五、自定义规则与内置规则', Icons.rule, [
            line('入口：比较设置（或首页右上角「预处理规则」）。', bold: true),
            step('自定义规则：', '点"新建规则"，填规则名、查找正则、替换串，选作用范围（两份 / 仅原文 / 仅修改版）。'),
            step('内置规则：', '统一换行、折叠多余空白、去行首尾空白、中英文引号统一、逗号空格归一、忽略大小写、全角数字转半角。右侧开关可勾选启用。'),
            step('优先级：', '内置 → 自定义 → 关键词 → 正则，按这个顺序依次应用。'),
          ]),

          // ============ 六、比较设置（忽略项） ============
          section('六、比较设置（忽略项）', Icons.tune, [
            line('用于消除无关差异，点开关立即生效：'),
            step('删掉空白符号：', '去掉空格 / Tab 后比较。'),
            step('删掉空行：', '删除纯空行后再比较。'),
            step('统一换行符：', r'统一 \r\n / \r / \n 三种换行格式。'),
            step('大写全转成小写：', 'A 和 a 视为相同。'),
            step('忽略纯数字：', '连续数字（如 123）视为占位符 <NUM>。'),
            step('忽略不可见字符：', '删除零宽空格、方向控制、BOM、软连字符、NBSP 等看不见的字符。'),
            step('统一编码 ANSI：', '非 ANSI 字符（Emoji、生僻字）会被删除。开启会丢失内容，慎用。'),
          ]),

          // ============ 七、对比页 ============
          section('七、对比页', Icons.compare_arrows, [
            line('顶栏从左到右：', bold: true),
            step('计数器 xx/xx：', '当前第几处差异 / 共几处。'),
            step('↑ / ↓：', '跳到上一处 / 下一处差异。也可以左右滑动屏幕跳转。'),
            step('🔍：', '打开查找框。'),
            step('🛠：', '更多操作（编辑文档、删除左/右文件、显示设置、同步滚动、性能面板、横屏）。'),
            const SizedBox(height: 6),
            line('视图切换（顶栏下方三个按钮）：', bold: true),
            step('仅差异（默认）：', '只显示发生变化的行，删除在左、新增在右。'),
            step('并排：', '左右双栏逐行对齐，同一逻辑行左右对照。'),
            step('合并：', '原版/修改版交错单栏显示。'),
          ]),

          // ============ 八、长按行操作 ============
          section('八、长按某一行', Icons.touch_app, [
            line('在对比页长按任意一行，弹出菜单：'),
            step('复制左边此行：', '把左侧（原版）这一行文字复制到剪贴板。'),
            step('复制右边此行：', '把右侧（修改版）这一行文字复制到剪贴板。'),
            step('编辑此行：', '弹对话框直接改这一行，改完立即重新对比。'),
            const SizedBox(height: 6),
            line('编辑后会自动重新对比，并尽量停在原位置附近（改行数也不跳回顶部）。'),
          ]),

          // ============ 九、查找 ============
          section('九、查找', Icons.search, [
            step('入口：', '对比页顶栏 🔍。输入关键词即实时高亮所有命中。'),
            step('跳转：', '「上一个 / 下一个」在命中之间跳转；顶部显示 当前 / 总数。'),
            step('范围：', '仅差异、并排、合并三种视图都支持。'),
          ]),

          // ============ 十、编辑与保存 ============
          section('十、编辑与保存', Icons.edit, [
            step('入口：', '对比页 🛠 →「编辑对比中的 2 个文档」，进入逐行对齐双栏编辑页。'),
            step('两侧都能改：', '左栏是原版，右栏是修改版。'),
            step('查找/替换：', '编辑页右上角 🔍：查找高亮、上一处/下一处、替换当前、全部替换；"正则:关"开关可启用正则。'),
            step('保存：', '一律"另存为"，弹系统对话框选位置，绝不覆盖原文件。'),
            line('提示：编辑会先写入内存，点"保存"才落盘为新文件。'),
          ]),

          // ============ 十一、显示设置 ============
          section('十一、显示设置', Icons.format_size, [
            step('入口：', '对比页 🛠 →「显示设置」。'),
            step('可调项：', '行号显示 / 隐藏、正文字号、行号字号、12 种差异颜色。'),
            step('差异颜色：', '左文件独有行、右文件独有行、被改行（左/右）、行内删掉的字、行内新增的字——各有底色和文字颜色。'),
          ]),

          // ============ 十二、横屏 ============
          section('十二、横屏切换', Icons.screen_rotation, [
            step('入口：', '对比页 🛠 →「切换到横屏」，长文并排对照更舒适。'),
          ]),

          // ============ 提示 ============
          section('提示', Icons.lightbulb_outline, [
            line('红色=左文件独有，绿色=右文件独有，黄色=被修改的行。'),
            line('查找命中：黄色高亮 + 加粗。'),
            line('关键词规则和正则规则保存在内存里，关闭 App 会清空。'),
          ]),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// 正则使用帮助。整页文字可长按选中复制。
class RegexHelpScreen extends StatelessWidget {
  const RegexHelpScreen({super.key});

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
      appBar: AppBar(title: const Text('正则帮助')),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ============ 一、基础符号 ============
            section('一、基础符号', Icons.abc, [
              code(r'.       任意一个字符（不含换行）' '\n'
                  r'\d      一个数字 0-9' '\n'
                  r'\D      一个非数字' '\n'
                  r'\w      字母、数字或下划线' '\n'
                  r'\W      不是 \w 的字符' '\n'
                  r'\s      空白（空格 / Tab / 换行）' '\n'
                  r'\S      非空白' '\n'
                  r'\n      换行' '\n'
                  r'\r      回车' '\n'
                  r'\t      Tab' '\n'
                  r'\b      单词边界（英文有效，中文无效）'),
            ]),

            // ============ 二、字符类 ============
            section('二、字符类（中括号）', Icons.data_array, [
              code(r'[abc]        a、b、c 中任意一个' '\n'
                  r'[^abc]       除 a、b、c 外的任意字符' '\n'
                  r'[a-z]        a 到 z 之间任意一个小写字母' '\n'
                  r'[A-Z]        大写字母' '\n'
                  r'[0-9]        数字' '\n'
                  r'[一-龥]      常用中文汉字' '\n'
                  r'[\u4e00-\u9fa5]  中文完整范围（同上）' '\n'
                  r'[，。！？]     中文标点任选一个'),
            ]),

            // ============ 三、量词 ============
            section('三、量词（次数）', Icons.repeat, [
              code(r'*       前面出现 0 次或多次' '\n'
                  r'+       前面出现 1 次或多次' '\n'
                  r'?       前面出现 0 次或 1 次' '\n'
                  r'{n}     正好 n 次' '\n'
                  r'{n,}    至少 n 次' '\n'
                  r'{n,m}   n 到 m 次'),
              const SizedBox(height: 6),
              line('例：'),
              code(r'\d+          一个或多个数字（如 123）' '\n'
                  r'\d{3}        正好 3 个数字' '\n'
                  r'\d{2,5}      2 到 5 个数字' '\n'
                  r'[.。]{2,}    2 个以上连续点号'),
            ]),

            // ============ 四、位置 ============
            section('四、位置', Icons.place, [
              code(r'^       行首' '\n'
                  r'$       行尾' '\n'
                  r'\b      单词边界'),
              const SizedBox(height: 6),
              line('例：'),
              code(r'^abc        以 abc 开头的行' '\n'
                  r'abc$        以 abc 结尾的行' '\n'
                  r'^$          空行'),
            ]),

            // ============ 五、分组与选择 ============
            section('五、分组与选择', Icons.account_tree, [
              code(r'(abc)       分组，替换串里用 $1 引用' '\n'
                  r'(a)(b)      两个分组，$1 $2' '\n'
                  r'(?:abc)     只分组、不捕获（不占 $ 编号）' '\n'
                  r'a|b         a 或 b'),
              const SizedBox(height: 6),
              line('例：'),
              code(r'(\d+)-(\d+)        匹配 "12-34"，$1=12 $2=34' '\n'
                  r'(cat|dog)          匹配 "cat" 或 "dog"'),
            ]),

            // ============ 六、转义 ============
            section('六、转义（匹配符号本身）', Icons.escape, [
              line('下面的符号在正则里有特殊含义。想匹配它们"本身"，前面加反斜杠 \\'),
              const SizedBox(height: 4),
              code(r'. * + ? ( ) [ ] { } | \ ^ $'),
              const SizedBox(height: 6),
              line('例：'),
              code(r'\.          匹配真正的点号' '\n'
                  r'\*          匹配真正的星号' '\n'
                  r'\\          匹配一个反斜杠' '\n'
                  r'\$          匹配 $ 符号'),
              const SizedBox(height: 6),
              line('查找串里可直接用这些转义：', bold: true),
              code(r'\n          换行' '\n'
                  r'\r          回车' '\n'
                  r'\t          Tab'),
            ]),

            // ============ 七、替换串引用 ============
            section('七、替换串引用（仅正则开启时）', Icons.swap_horiz, [
              code(r'$0          整个匹配的内容' '\n'
                  r'$1          第 1 个捕获组' '\n'
                  r'$2          第 2 个捕获组' '\n'
                  r'...'),
              const SizedBox(height: 6),
              line('例：'),
              code(r'查找 (\d+)  替换 $1年' '\n'
                  r'  "2024" 会变成 "2024年"' '\n'
                  r'查找 (\w+)@(\w+)  替换 $2#$1' '\n'
                  r'  "abc@xyz" 会变成 "xyz#abc"'),
            ]),

            // ============ 八、常见完整例子 ============
            section('八、常见完整例子', Icons.lightbulb, [
              code(r'\d+                     连续数字' '\n'
                  r'\d{4}-\d{2}-\d{2}      日期 2024-01-01' '\n'
                  r'[a-zA-Z]+               连续英文字母' '\n'
                  r'[一-龥]+                连续中文' '\n'
                  r'<[^>]+>                 HTML 标签' '\n'
                  r'https?://\S+            网址' '\n'
                  r'第\d+章                 第1章、第23章' '\n'
                  r'^\s*$                   空行' '\n'
                  r'^[ \t]+                 每行开头的空格/Tab' '\n'
                  r'[ \t]+$                 每行结尾的空格/Tab' '\n'
                  r'[ \t]+                  连续空格/Tab' '\n'
                  r'\n{3,}                  连续空行（3 个以上换行）' '\n'
                  r'[.。…⋯]{2,}             连续点号/省略号'),
            ]),

            // ============ 九、怎么用 ============
            section('九、怎么用', Icons.help_outline, [
              line('1. 点对比页顶栏 🔍 打开查找栏', bold: true),
              line('2. 在"查找"框里填内容'),
              line('3. 想在左侧查找就打开"查左侧文件内容"开关；想查右侧就打开"查右侧文件内容"（两个至少要开一个）'),
              line('4. 点"正则"按钮开启正则模式（变蓝变粗）'),
              // 方案 B：用 raw string
              line(r'5. 在"替换为"框里填替换内容，可用 $1 $2'),

              line('6. 点"替换"换当前一处，或"全部替换"一次换完'),
              line('7. 替换累积在缓存里，屏幕暂时不变。点"应用并刷新"才真正生效'),
              const SizedBox(height: 6),
              line('关于"应用并刷新"：', bold: true),
              line('你可以连续替换多个不同的词，每次只改缓存。改完最后点一次"应用并刷新"，一次生效。'
                  '这样做的好处是：连续替换时不用每次等 diff 重算，速度快很多。'),
            ]),

            // ============ 十、注意事项 ============
            section('十、注意事项', Icons.warning_amber, [
              line('· "整词匹配"（词按钮）对中文无效，只对英文生效。'),
              line('· 正则开启时，替换串里的 \$ 有特殊含义。想替换成字面 \$ 就写 \\\$。'),
              line('· 查找串里的反斜杠需要转义。比如想匹配字面 "\\d"，写 "\\\\d"。'),
              line('· 正则过于复杂可能变慢，建议在小范围测试。'),
              line('· 本页所有文字可长按选中复制。'),
            ]),
          ],
        ),
      ),
    );
  }
}

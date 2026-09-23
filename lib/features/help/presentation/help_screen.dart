import 'package:flutter/material.dart';

/// 使用说明：覆盖导入、预处理规则、比较设置、三种视图、查找、编辑/保存、
/// 横屏等全部功能。PRD §2 Module 7（帮助/关于）。
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

    return Scaffold(
      appBar: AppBar(title: const Text('使用说明')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          section('一、导入文档', Icons.upload_file, [
            step('方式1 本地文件：', '分别点击「原文档」「修改版文档」卡片的「本地文件」，选择 txt / docx 文件。'),
            step('方式2 粘贴文本：', '先复制文本，点「粘贴文本」即可从剪贴板导入为对应文档（无需文件）。'),
            step('两份都导入后：', '「开始对比」按钮才会亮起（卡片显示字符数与编码）。'),
            line('提示：大文件导入与对比均在后台计算，页面不会卡死。', bold: false),
          ]),
          section('二、预处理规则（可移除）', Icons.rule, [
            line('首页右上角「预处理规则」可管理规则，规则会先于对比应用到文本：'),
            step('内置规则：', '如统一换行、折叠多余空白、去行首尾空白、中英文引号统一、忽略大小写、全角数字转半角等，右侧开关可勾选启用。'),
            step('自定义规则：', '点右下角「新建规则」，填写规则名、查找正则、替换串，并选择作用范围（两份/仅原文/仅修改版）。'),
            step('移除规则：', '自定义规则右侧有删除图标，点击即移除；内置规则不可删但可关闭。'),
          ]),
          section('三、比较设置（忽略项）', Icons.tune, [
            line('首页「比较设置」可提前开关，用于消除无关差异，点击后立即生效：'),
            step('忽略空白符号：', '去掉空格/制表符等水平空白后比较（多行可能折叠成一行）。'),
            step('忽略空行：', '删除空白/纯空行后再比较。'),
            step('忽略换行符：', '统一 \\r\\n / \\r / \\n 三种换行格式，避免换行符导致的误报。'),
            step('统一编码 ANSI 对比：', '已是 ANSI(GBK) 则不做处理；非 ANSI 转成 ANSI 并删除无法转换的字符，防止乱码误判（含 Emoji、扩展生僻字等）。'),
          ]),
          section('四、开始对比与视图', Icons.compare_arrows, [
            step('开始对比：', '进入结果页。按“行”对比；右上角 🛠 菜单可切换为“字符”引擎（逐字更精细、开销更大）。'),
            line('三种视图（分段按钮切换，行号始终显示在各栏左侧）：'),
            step('合并：', '原版/修改版交错单栏显示；替换行（~）内标出新增字符（绿字下划线）。'),
            step('并排：', '左右双栏逐行对齐，同一逻辑行左右对照；相同行 + 修改行并排显示，修改处标红（删除字符删除线）/ 标绿（新增字符）。'),
            step('仅差异：', '只显示发生变化的行，删除在左、新增在右；被改写的行合并为同一行对照。'),
            line('「上一处/下一处差异」箭头或左右滑动可快速跳转差异处。'),
          ]),
          section('五、查找', Icons.search, [
            step('入口：', '结果页放大镜图标，输入关键词即实时高亮所有命中（含替换行），编辑界面同样支持。'),
            step('跳转：', '「上一个/下一个」在命中之间精确跳转（自动定位到对应行）；顶部显示 当前/总数，随时关闭。'),
            step('范围：', '查找作用于合并、并排、仅差异三种视图，以及编辑界面的两侧文本。'),
          ]),
          section('六、编辑与保存', Icons.edit, [
            step('入口：', '结果页右上角 ✏️ 编辑按钮 →「编辑文档」，进入逐行对齐双栏编辑页，两侧可直接修改。'),
            step('查找/替换：', '编辑页右上角 🔍：支持查找高亮（黄色背景）、上一处/下一处、替换当前、全部替换；「正则:关」开关可启用正则匹配。'),
            step('保存：', '一律「另存为」，弹出系统对话框选择保存位置，绝不覆盖原始文件。'),
            line('提示：编辑后需保存，修改才会写入新文件；原导入文件始终保持不变。'),
          ]),
          section('七、横屏切换', Icons.screen_rotation, [
            step('入口：', '结果页 🛠 更多操作菜单 →「切换到横屏」，长文并排对照更舒适。'),
          ]),
          section('提示', Icons.lightbulb_outline, [
            line('忽略选项、ANSI 统一、预处理规则均影响本次对比，可在首页随时调整。'),
            line('查看差异时：红色=删除（左侧），绿色=新增（右侧），黄色=查找命中。'),
          ]),
        ],
      ),
    );
  }
}
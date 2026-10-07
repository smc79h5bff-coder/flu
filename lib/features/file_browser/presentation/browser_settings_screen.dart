import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/file_browser_providers.dart';

/// 文件浏览器设置页。
///
/// 包含：
///   · 显示方式（列表 / 网格）
///   · 网格显示内容
///   · 字号
///   · 排序（方式 + 方向，左右并排）
///   · 点击文件时的打开方式
///
/// 右上角 ? 打开"使用说明"，Tab 化，可编辑可保存。
class BrowserSettingsScreen extends ConsumerWidget {
  const BrowserSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览器设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: '使用说明',
            onPressed: () => _showHelp(context),
          ),
        ],
      ),
      body: ListView(
        children: [
          _buildDisplayModeSection(context, ref),
          const Divider(height: 1),
          _buildGridContentSection(context, ref),
          const Divider(height: 1),
          _buildFontSizeSection(context, ref),
          const Divider(height: 1),
          _buildSortSection(context, ref),
          const Divider(height: 1),
          _buildOpenModeSection(context, ref),
        ],
      ),
    );
  }

  // ==================== 显示方式 ====================

  Widget _buildDisplayModeSection(BuildContext context, WidgetRef ref) {
    final gridMode = ref.watch(browserGridModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '显示方式'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('列表'),
                selected: !gridMode,
                onSelected: (_) {
                  ref.read(browserGridModeProvider.notifier).update(false);
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('网格'),
                selected: gridMode,
                onSelected: (_) {
                  ref.read(browserGridModeProvider.notifier).update(true);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 网格显示内容 ====================

  Widget _buildGridContentSection(BuildContext context, WidgetRef ref) {
    final gridMode = ref.watch(browserGridModeProvider);
    final showSize = ref.watch(browserGridShowSizeProvider);
    final showTime = ref.watch(browserGridShowTimeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '网格显示内容',
          subtitle: gridMode ? null : '仅网格模式生效',
          dim: !gridMode,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: _SwitchRow(
                  label: '显示大小',
                  value: showSize,
                  enabled: gridMode,
                  onChanged: (v) => ref
                      .read(browserGridShowSizeProvider.notifier)
                      .update(v),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _SwitchRow(
                  label: '显示时间',
                  value: showTime,
                  enabled: gridMode,
                  onChanged: (v) => ref
                      .read(browserGridShowTimeProvider.notifier)
                      .update(v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  // ==================== 字号 ====================

  Widget _buildFontSizeSection(BuildContext context, WidgetRef ref) {
    final gridMode = ref.watch(browserGridModeProvider);
    final listName = ref.watch(browserFontListNameProvider);
    final listMeta = ref.watch(browserFontListMetaProvider);
    final gridName = ref.watch(browserFontGridNameProvider);
    final gridMeta = ref.watch(browserFontGridMetaProvider);

    final nameValue = gridMode ? gridName : listName;
    final metaValue = gridMode ? gridMeta : listMeta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '字号',
          subtitle: gridMode ? '网格模式' : '列表模式',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: _FontSizeRow(
                  label: '文件名',
                  value: nameValue,
                  onChanged: (v) {
                    if (gridMode) {
                      ref
                          .read(browserFontGridNameProvider.notifier)
                          .set(v);
                    } else {
                      ref
                          .read(browserFontListNameProvider.notifier)
                          .set(v);
                    }
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _FontSizeRow(
                  label: '大小/时间',
                  value: metaValue,
                  onChanged: (v) {
                    if (gridMode) {
                      ref
                          .read(browserFontGridMetaProvider.notifier)
                          .set(v);
                    } else {
                      ref
                          .read(browserFontListMetaProvider.notifier)
                          .set(v);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 排序 ====================

  Widget _buildSortSection(BuildContext context, WidgetRef ref) {
    final sortField = ref.watch(sortFieldProvider);
    final sortAsc = ref.watch(sortAscProvider);
    final s = Theme.of(context).colorScheme;

    final labelStyle = TextStyle(
      fontSize: 12,
      color: s.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '排序'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左：排序方式（3 行）
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('排序方式', style: labelStyle),
                      const SizedBox(height: 4),
                      for (final f in SortField.values)
                        _RadioRow(
                          label: _sortLabel(f),
                          selected: sortField == f,
                          onTap: () {
                            ref
                                .read(sortFieldProvider.notifier)
                                .update(f);
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // 右：升序 / 降序（2 行，均匀分布在左 3 行的行间）
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('排序方向', style: labelStyle),
                      Expanded(
                        child: Column(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceAround,
                          children: [
                            _RadioRow(
                              label: '升序',
                              selected: sortAsc,
                              onTap: () {
                                ref
                                    .read(sortAscProvider.notifier)
                                    .update(true);
                              },
                            ),
                            _RadioRow(
                              label: '降序',
                              selected: !sortAsc,
                              onTap: () {
                                ref
                                    .read(sortAscProvider.notifier)
                                    .update(false);
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _sortLabel(SortField f) {
    switch (f) {
      case SortField.name:
        return '名称';
      case SortField.modified:
        return '修改时间';
      case SortField.size:
        return '大小';
    }
  }

  // ==================== 打开方式 ====================

  Widget _buildOpenModeSection(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(fileOpenModeProvider);
    final n = ref.read(fileOpenModeProvider.notifier);

    Widget tile({
      required FileOpenMode value,
      required IconData icon,
      required String title,
      required String subtitle,
    }) {
      return RadioListTile<FileOpenMode>(
        value: value,
        groupValue: mode,
        onChanged: (v) {
          if (v != null) n.update(v);
        },
        title: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Text(title),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(left: 30, top: 2),
          child: Text(subtitle, style: const TextStyle(fontSize: 12)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: '点击文件时',
          subtitle: '点击文本文件时用哪种方式打开。设置会一直记住，下次启动仍生效。',
        ),
        tile(
          value: FileOpenMode.reader,
          icon: Icons.menu_book,
          title: '阅读器',
          subtitle: '分页翻页，适合看小说。不能编辑',
        ),
        tile(
          value: FileOpenMode.editor,
          icon: Icons.edit_note,
          title: '旧编辑器',
          subtitle: '功能全，但大文件会卡',
        ),
        tile(
          value: FileOpenMode.lineEditor,
          icon: Icons.view_list,
          title: '行编辑器',
          subtitle: '虚拟化逐行渲染，大文件流畅',
        ),
        tile(
          value: FileOpenMode.ask,
          icon: Icons.help_outline,
          title: '每次询问',
          subtitle: '每次点击文件都弹窗问一次（弹窗里可以勾选"记住"）',
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  // ==================== 说明弹窗 ====================

  Future<void> _showHelp(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _SettingsHelpDialog(),
    );
  }
}

// ==================== 复用小部件 ====================

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.subtitle,
    this.dim = false,
  });

  final String title;
  final String? subtitle;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: dim ? s.onSurfaceVariant : s.primary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: s.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一行开关。`enabled = false` 时开关变灰不能点。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: enabled ? null : Theme.of(context).disabledColor,
            ),
          ),
        ),
        Switch(
          value: value,
          onChanged: enabled ? onChanged : null,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}

/// 一行字号控件：标签 + [-] [输入框] [+]
class _FontSizeRow extends StatefulWidget {
  const _FontSizeRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_FontSizeRow> createState() => _FontSizeRowState();
}

class _FontSizeRowState extends State<_FontSizeRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.round().toString());
  }

  @override
  void didUpdateWidget(covariant _FontSizeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cur = widget.value.round().toString();
    if (_ctrl.text != cur) {
      _ctrl.text = cur;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final next = (widget.value.round() + delta).clamp(1, 38).toDouble();
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 2),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove, size: 18),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 28,
              ),
              onPressed: () => _step(-1),
            ),
            // 输入框缩窄：能容纳 5 个数字左右
            SizedBox(
              width: 44,
              child: TextFormField(
                controller: _ctrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 6,
                  ),
                ),
                onFieldSubmitted: (v) {
                  final n = int.tryParse(v.trim());
                  if (n == null) {
                    _ctrl.text = widget.value.round().toString();
                    return;
                  }
                  final clamped = n.clamp(1, 38).toDouble();
                  widget.onChanged(clamped);
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 28,
              ),
              onPressed: () => _step(1),
            ),
          ],
        ),
      ],
    );
  }
}

/// 一行单选项：圆圈 + 文字。
class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              size: 20,
              color: selected ? s.primary : s.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

// ==================== 说明弹窗（Tab 化，可编辑） ====================

class _SettingsHelpDialog extends ConsumerStatefulWidget {
  const _SettingsHelpDialog();

  @override
  ConsumerState<_SettingsHelpDialog> createState() =>
      _SettingsHelpDialogState();
}

class _SettingsHelpDialogState extends ConsumerState<_SettingsHelpDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  int _lastIndex = 0;

  List<BrowserHelpTab> _tabs = const [];
  bool _editing = false;

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _contentCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final saved = ref.read(browserSettingsHelpProvider);
    _tabs = List<BrowserHelpTab>.from(saved);
    if (_tabs.isEmpty) _tabs = defaultBrowserHelpTabs();
    _tabCtrl = TabController(length: _tabs.length, vsync: this);
    _tabCtrl.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabCtrl.removeListener(_onTabChanged);
    _tabCtrl.dispose();
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_lastIndex == _tabCtrl.index) return;
    _lastIndex = _tabCtrl.index;
    if (mounted) setState(() {});
  }

  void _recreateTabCtrl(int length, int initial) {
    final old = _tabCtrl;
    old.removeListener(_onTabChanged);
    final newCtrl = TabController(
      length: length,
      initialIndex: length == 0 ? 0 : initial.clamp(0, length - 1),
      vsync: this,
    );
    newCtrl.addListener(_onTabChanged);
    _tabCtrl = newCtrl;
    _lastIndex = newCtrl.index;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  Future<void> _persist() async {
    ref.read(browserSettingsHelpProvider.notifier).setAll(_tabs);
  }

  // ==================== 编辑 ====================

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
    final next = List<BrowserHelpTab>.from(_tabs);
    next[idx] = next[idx].copyWith(
      title: title,
      content: _contentCtrl.text,
    );
    setState(() {
      _tabs = next;
      _editing = false;
    });
    await _persist();
    _snack('已保存');
  }

  // ==================== Tab 管理 ====================

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
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;

    final newTab = BrowserHelpTab(
      id: 'user_${DateTime.now().microsecondsSinceEpoch}',
      title: name.trim(),
      content: '',
    );
    final next = [..._tabs, newTab];
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, next.length - 1);
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
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final next = List<BrowserHelpTab>.from(_tabs);
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
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final next = List<BrowserHelpTab>.from(_tabs)..removeAt(idx);
    final newIdx = idx >= next.length ? next.length - 1 : idx;
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, newIdx);
    await _persist();
  }

  Future<void> _moveCurrent(int delta) async {
    final idx = _tabCtrl.index;
    final j = idx + delta;
    if (j < 0 || j >= _tabs.length) return;
    final next = List<BrowserHelpTab>.from(_tabs);
    final t = next.removeAt(idx);
    next.insert(j, t);
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, j);
    await _persist();
  }

  Future<void> _confirmResetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复默认 Tab？'),
        content: const Text(
          '当前所有 Tab（包括你新建的、改过内容的）会被替换成 4 个默认 Tab。\n'
          '此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final next = defaultBrowserHelpTabs();
    setState(() => _tabs = next);
    _recreateTabCtrl(next.length, 0);
    await _persist();
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

  // ==================== build ====================

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.all(4),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.9,
        child: Column(
          children: [
            // ---------- 标题栏 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '浏览器 · 使用说明',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (_editing) ...[
                    TextButton(
                      onPressed: _cancelEdit,
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: _saveEdit,
                      child: const Text('保存'),
                    ),
                  ] else ...[
                    TextButton(
                      onPressed: _enterEdit,
                      child: const Text('编辑'),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (v) {
                        if (v == 'reset') _confirmResetAll();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'reset',
                          child: Text('恢复默认 Tab'),
                        ),
                      ],
                    ),
                  ],
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // ---------- TabBar ----------
            _buildTabBar(s),

            // ---------- 编辑态下的 Tab 名输入框 ----------
            if (_editing) _buildEditTitleBar(s),

            // ---------- 工具栏（非编辑态） ----------
            if (!_editing) _buildToolbar(s),

            // ---------- 内容区 ----------
            Expanded(
              child: _editing
                  ? _buildEditor()
                  : _buildContent(s),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(ColorScheme s) {
    final bar = Container(
      color: s.surface,
      child: TabBar(
        controller: _tabCtrl,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: [
          for (final t in _tabs) Tab(text: t.title),
        ],
      ),
    );
    if (!_editing) return bar;
    return IgnorePointer(
      child: Opacity(opacity: 0.55, child: bar),
    );
  }

  Widget _buildEditTitleBar(ColorScheme s) {
    return Container(
      color: s.surfaceVariant.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: _titleCtrl,
        decoration: const InputDecoration(
          labelText: 'Tab 名',
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        ),
      ),
    );
  }

  Widget _buildToolbar(ColorScheme s) {
    final idx = _tabCtrl.index;
    final canDelete = _tabs.length > 1;
    final canLeft = idx > 0;
    final canRight = idx < _tabs.length - 1;

    return Container(
      color: s.surfaceVariant.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建'),
              onPressed: _createTab,
            ),
            const SizedBox(width: 2),
            TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('重命名'),
              onPressed: _renameCurrent,
            ),
            const SizedBox(width: 2),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
              onPressed: canDelete ? _deleteCurrent : null,
            ),
            const SizedBox(width: 8),
            Container(width: 1, height: 20, color: s.outlineVariant),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '左移此 Tab',
              icon: const Icon(Icons.arrow_back, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: canLeft ? () => _moveCurrent(-1) : null,
            ),
            IconButton(
              tooltip: '右移此 Tab',
              icon: const Icon(Icons.arrow_forward, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: canRight ? () => _moveCurrent(1) : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ColorScheme s) {
    final idx = _tabCtrl.index;
    if (idx < 0 || idx >= _tabs.length) return const SizedBox.shrink();
    final tab = _tabs[idx];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        tab.content.isEmpty
            ? '（此 Tab 还没有内容。点上方"编辑"写点什么。）'
            : tab.content,
        style: const TextStyle(
          fontSize: 13.5,
          height: 1.6,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _contentCtrl,
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
          hintText: '在这里编辑说明……',
        ),
      ),
    );
  }
}

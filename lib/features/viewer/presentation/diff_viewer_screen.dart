iewMode viewMode,
    String? origName,
    String? modName,
  ) {
    _ensureRowKeys();
    final totalDiffs = _diffIndices().length;
    final currentPos = _currentDiffPos >= 0 ? _currentDiffPos + 1 : 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('对比结果'),
        actions: [
          Center(
            key: const Key('diff-position'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '$currentPos/$totalDiffs',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
          IconButton(
            key: const Key('prev-diff'),
            icon: const Icon(Icons.arrow_upward),
            tooltip: '上一处差异',
            onPressed: _jumpToPrevDiff,
          ),
          IconButton(
            key: const Key('next-diff'),
            icon: const Icon(Icons.arrow_downward),
            tooltip: '下一处差异',
            onPressed: _jumpToNextDiff,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '查找',
            onPressed: () => setState(() => _showFind = !_showFind),
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: '编辑文档',
            onPressed: _openEdit,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.tune),
            tooltip: '更多操作',
onSelected: (v) {
  if (v == 'delOriginal') {
    _deleteSide(isOriginal: true);
  } else if (v == 'delModified') {
    _deleteSide(isOriginal: false);
  } else if (v == 'orientation') {
    _toggleOrientation();
    void _openDisplaySettings() {
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => const _DisplaySettingsSheet(),
  );
    }
  } else if (v == 'perf') {
    final cur = ref.read(showPerfOverlayProvider);
    ref.read(showPerfOverlayProvider.notifier).state = !cur;
  } else if (v == 'syncScroll') {
    final cur = ref.read(syncScrollProvider);
    ref.read(syncScrollProvider.notifier).state = !cur;
  } else if (v == 'displaySettings') {
    _openDisplaySettings();
  }
},
itemBuilder: (context) => [
  PopupMenuItem<String>(
    value: 'delOriginal',
    enabled: !_originalDeleted &&
        ref.read(originalFilePathProvider) != null,
    child: Row(
      children: [
        const Icon(Icons.delete_outline, color: Colors.red),
        const SizedBox(width: 10),
        Text(_originalDeleted ? '原文件已删除' : '删除原文件'),
      ],
    ),
  ),
  PopupMenuItem<String>(
    value: 'delModified',
    enabled: !_modifiedDeleted &&
        ref.read(modifiedFilePathProvider) != null,
    child: Row(
      children: [
        const Icon(Icons.delete_outline, color: Colors.red),
        const SizedBox(width: 10),
        Text(_modifiedDeleted ? '修改版已删除' : '删除修改版'),
      ],
    ),
  ),
  const PopupMenuDivider(),
  PopupMenuItem<String>(
    value: 'displaySettings',
    child: Row(
      children: [
        const Icon(Icons.format_size),
        const SizedBox(width: 10),
        const Text('显示设置'),
      ],
    ),
  ),
  PopupMenuItem<String>(
    value: 'syncScroll',
    child: Row(
      children: [
        Icon(
          ref.watch(syncScrollProvider)
              ? Icons.sync
              : Icons.sync_disabled,
        ),
        const SizedBox(width: 10),
        Text(ref.watch(syncScrollProvider)
            ? '两栏同步滚动：开'
            : '两栏同步滚动：关'),
      ],
    ),
  ),
  PopupMenuItem<String>(
    value: 'perf',
    child: Row(
      children: [
        Icon(
          ref.watch(showPerfOverlayProvider)
              ? Icons.speed
              : Icons.speed_outlined,
        ),
        const SizedBox(width: 10),
        Text(ref.watch(showPerfOverlayProvider)
            ? '性能面板：开'
            : '性能面板：关'),
      ],
    ),
  ),
  const PopupMenuDivider(),
  PopupMenuItem<String>(
    value: 'orientation',
    child: Row(
      children: [
        Icon(
          _landscape ? Icons.screen_rotation : Icons.rotate_left,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Text(_landscape ? '切换到竖屏' : '切换到横屏'),
      ],
    ),
  ),
],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_originalDeleted || _modifiedDeleted) _buildDeletedBanner(),
          if (_showFind) _buildFindBar(),
          DiffStatsBar(result: diff),
          if (ref.watch(showPerfOverlayProvider)) _buildPerfOverlay(),
          SegmentedButton<ViewMode>(
            segments: const [
              ButtonSegment(value: ViewMode.merged, label: Text('合并')),
              ButtonSegment(value: ViewMode.sideBySide, label: Text('并排')),
              ButtonSegment(value: ViewMode.diffOnly, label: Text('仅差异')),
            ],
            selected: {viewMode},
            onSelectionChanged: (s) => _switchView(s.first),
          ),
          Expanded(
            child: NotificationListener<ScrollEndNotification>(
              onNotification: (_) {
                _captureAnchor();
                return false;
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -300) {
                    _jumpToNextDiff();
                  } else if (velocity > 300) {
                    _jumpToPrevDiff();
                  }
                },
child: switch (viewMode) {
  ViewMode.merged => MergedView(
      result: diff,
      controller: _scrollController,
      findQuery: _findQuery,
      rowKeysByEntry: _rowKeysByEntry,
      showLineNumbers: ref.watch(showLineNumbersProvider),
      bodyFontSize: ref.watch(bodyFontSizeProvider),
      gutterFontSize: ref.watch(gutterFontSizeProvider),
    ),
  ViewMode.sideBySide => SideBySideView(
      result: diff,
      originalFileName: origName,
      modifiedFileName: modName,
      controller: _scrollController,
      findQuery: _findQuery,
      rowKeysByEntry: _rowKeysByEntry,
      showLineNumbers: ref.watch(showLineNumbersProvider),
      bodyFontSize: ref.watch(bodyFontSizeProvider),
      gutterFontSize: ref.watch(gutterFontSizeProvider),
      syncScroll: ref.watch(syncScrollProvider),
    ),
  ViewMode.diffOnly => DiffOnlyView(
      result: diff,
      originalFileName: origName,
      modifiedFileName: modName,
      controller: _scrollController,
      findQuery: _findQuery,
      rowKeysByEntry: _rowKeysByEntry,
      showLineNumbers: ref.watch(showLineNumbersProvider),
      bodyFontSize: ref.watch(bodyFontSizeProvider),
      gutterFontSize: ref.watch(gutterFontSizeProvider),
    ),
},
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部红条：显示哪些文件已从磁盘删除（内容仍保留显示）。
  Widget _buildDeletedBanner() {
    final parts = <String>[];
    if (_originalDeleted) parts.add('原文件');
    if (_modifiedDeleted) parts.add('修改版');
    return Container(
      width: double.infinity,
      color: Colors.red.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: Colors.red.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${parts.join(" / ")} 已从磁盘删除（下方内容仅内存保留）',
              style: TextStyle(
                fontSize: 12,
                color: Colors.red.shade900,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerfOverlay() {
    final perf = ref.watch(lastDiffPerfProvider);
    if (perf == null) return const SizedBox.shrink();
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SelectableText(
        perf.oneLine,
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          color: s.onTertiaryContainer,
        ),
        maxLines: 3,
      ),
    );
  }

  Widget _buildFindBar() {
    final total = _matchEntries.length;
    final current = _matchPos >= 0 ? _matchPos + 1 : 0;
    return Material(
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _findController.clear();
                setState(() {
                  _showFind = false;
                  _findQuery = '';
                  _matchEntries = const [];
                  _matchPos = -1;
                });
              },
            ),
            Expanded(
              child: TextField(
                controller: _findController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '输入要查找的内容',
                  isDense: true,
                  border: InputBorder.none,
                ),
                onChanged: _findChanged,
                onSubmitted: (_) => _nextMatch(),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text('$current/$total',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              tooltip: '上一个',
              onPressed: total == 0 ? null : _prevMatch,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_downward),
              tooltip: '下一个',
              onPressed: total == 0 ? null : _nextMatch,
            ),
          ],
        ),
      ),
    );
  }
}
/// 显示设置底部面板：行号显隐、正文字号、行号字号。
class _DisplaySettingsSheet extends ConsumerWidget {
  const _DisplaySettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showLine = ref.watch(showLineNumbersProvider);
    final bodySize = ref.watch(bodyFontSizeProvider);
    final gutterSize = ref.watch(gutterFontSizeProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '显示设置',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('显示行号'),
              value: showLine,
              onChanged: (v) =>
                  ref.read(showLineNumbersProvider.notifier).state = v,
            ),
            const SizedBox(height: 8),
            Text(
              '正文字号：${bodySize.toStringAsFixed(0)}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Slider(
              min: 10,
              max: 28,
              divisions: 18,
              value: bodySize,
              label: bodySize.toStringAsFixed(0),
              onChanged: (v) =>
                  ref.read(bodyFontSizeProvider.notifier).state = v,
            ),
            const SizedBox(height: 4),
            Text(
              '行号字号：${gutterSize.toStringAsFixed(0)}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            Slider(
              min: 8,
              max: 20,
              divisions: 12,
              value: gutterSize,
              label: gutterSize.toStringAsFixed(0),
              onChanged: (v) =>
                  ref.read(gutterFontSizeProvider.notifier).state = v,
            ),
          ],
        ),
      ),
    );
  }
}

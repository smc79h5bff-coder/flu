import 'dart:convert';
import 'dart:io';
import 'package:flutter/rendering.dart';
import 'dart:math' as math;
import 'reader_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reader_models.dart';
import 'reader_pagination.dart';
import 'reader_repository.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({
    super.key,
    required this.filePaths,
    required this.initialIndex,
  });

  /// 当前目录下所有可读文件（已按浏览器排序）。
  final List<String> filePaths;

  /// 打开时定位到第几个。
  final int initialIndex;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  Size _viewportSize = Size.zero;

  late int _fileIndex;
  String? _text;
  String? _error;
  bool _loading = true;

  PaginationResult? _pagination;
  List<String> _lines = const [];
  HighlightIndex _highlightIndex = HighlightIndex.empty;

  int _currentPage = 0;

  String? _lastLoadedPath;
  Size? _lastLoadedSize;

  bool _menuOpen = false;

  /// 最近一次通过 SelectionArea 选中的内容。
  SelectedContent? _lastSelectedContent;

  @override
  void initState() {
    super.initState();
    _fileIndex = widget.initialIndex.clamp(0, widget.filePaths.length - 1);
  }

  @override
  void dispose() {
    _saveProgress();
    super.dispose();
  }

  // ==================== 加载 ====================

  Future<void> _ensureLoaded() async {
    if (widget.filePaths.isEmpty) return;
    if (_viewportSize.width < 10 || _viewportSize.height < 10) return;

    final path = widget.filePaths[_fileIndex];
    if (_lastLoadedPath == path && _lastLoadedSize == _viewportSize) {
      return;
    }
    _lastLoadedPath = path;
    _lastLoadedSize = _viewportSize;

    setState(() {
      _loading = true;
      _error = null;
      _text = null;
      _pagination = null;
      _lines = const [];
      _highlightIndex = HighlightIndex.empty;
      _currentPage = 0;
    });

    try {
      final bytes = await File(path).readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      if (_lastLoadedPath != path) return;

      final settings = ref.read(readerSettingsProvider);
      final pagination = paginate(
        text: text,
        viewportWidth: _viewportSize.width,
        viewportHeight: _viewportSize.height,
        fontSize: settings.fontSize,
        fontWeight: settings.fontWeight,
      );

      final split = splitLinesWithOffsets(text);
      final fileKey = readerFileKey(path);
      final highlights =
          ref.read(readerHighlightsProvider)[fileKey] ?? const [];
      final index = buildHighlightIndex(
        lines: split.lines,
        highlights: highlights,
      );

      final progress = ref.read(readerProgressProvider)[fileKey];
      final startPage = progress != null
          ? findPageForOffset(pagination, progress.charOffset)
          : 0;

      setState(() {
        _text = text;
        _pagination = pagination;
        _lines = split.lines;
        _highlightIndex = index;
        _currentPage = startPage;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ==================== 进度 ====================

  void _saveProgress() {
    if (_pagination == null || widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final offset = pageStartOffset(_pagination!, _currentPage);
    ref.read(readerProgressProvider.notifier).set(fileKey, offset);
  }

  // ==================== 翻页 ====================

  void _nextPage() {
    if (_pagination == null) return;
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    if (_currentPage >= _pagination!.pageCount - 1) return;
    setState(() => _currentPage++);
    _saveProgress();
  }

  void _prevPage() {
    if (_pagination == null) return;
    if (_currentPage <= 0) return;
    setState(() => _currentPage--);
    _saveProgress();
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v > 300) _prevPage();
  }

  void _jumpToPage(int page) {
    if (_pagination == null) return;
    final p = page.clamp(0, _pagination!.pageCount - 1);
    setState(() => _currentPage = p);
    _saveProgress();
  }

  // ==================== 切文件 ====================

  Future<void> _prevFile() async {
    if (_fileIndex <= 0) return;
    _saveProgress();
    setState(() => _fileIndex--);
    await _ensureLoaded();
  }

  Future<void> _nextFile() async {
    if (_fileIndex >= widget.filePaths.length - 1) return;
    _saveProgress();
    setState(() => _fileIndex++);
    await _ensureLoaded();
  }

  // ==================== 顶部菜单 ====================

  void _showTopMenu() {
    setState(() => _menuOpen = true);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      barrierColor: Colors.transparent, // ← 加这行
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _buildTopMenuSheet(ctx),
    ).then((_) {
      if (mounted) setState(() => _menuOpen = false);
    });
  }

  Widget _buildTopMenuSheet(BuildContext ctx) {
    final pct = _pagination == null
        ? '-'
        : '${((_currentPage + 1) / _pagination!.pageCount * 100).toStringAsFixed(1)}%';
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(pct, style: const TextStyle(fontSize: 18)),
            subtitle: const Text('点击调整进度'),
            onTap: () {
              Navigator.pop(ctx);
              _showProgressSlider();
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('查找'),
            onTap: () {
              Navigator.pop(ctx);
              _openFind();
            },
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_add_outlined),
            title: const Text('加书签'),
            onTap: () {
              Navigator.pop(ctx);
              _addBookmark();
            },
          ),
          ListTile(
            leading: const Icon(Icons.bookmarks_outlined),
            title: const Text('书签与高亮'),
            onTap: () {
              Navigator.pop(ctx);
              _openManager();
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('编辑'),
            onTap: () async {
              Navigator.pop(ctx);
              await _openEditor();
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('设置'),
            onTap: () {
              Navigator.pop(ctx);
              showReaderSettingsSheet(context);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _showProgressSlider() {
    if (_pagination == null) return;
    var tempPage = _currentPage;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final total = _pagination!.pageCount;
          final pct = total <= 1 ? 100.0 : (tempPage / (total - 1) * 100);
          return AlertDialog(
            title: const Text('跳转'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${pct.toStringAsFixed(1)}%',
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.bold),
                ),
                Slider(
                  value: tempPage.toDouble(),
                  min: 0,
                  max: (total - 1).toDouble(),
                  divisions: total > 1 ? total - 1 : 1,
                  onChanged: (v) => setSt(() => tempPage = v.round()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _jumpToPage(tempPage);
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _stubFeature(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$name：待第 5 批实现'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _addBookmark() {
    if (_pagination == null || _text == null) return;
    final offset = pageStartOffset(_pagination!, _currentPage);
    final start = math.max(0, offset - 10);
    final end = math.min(_text!.length, offset + 20);
    final preview = _text!.substring(start, end).replaceAll('\n', ' ').trim();
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final bookmark = ReaderBookmark(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      charOffset: offset,
      preview: preview,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    ref.read(readerBookmarksProvider.notifier).add(fileKey, bookmark);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已加书签'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _openFind() {
    if (_text == null || widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    showReaderFindBar(
      context,
      fileKey,
      _text!,
      (offset) {
        if (_pagination == null) return;
        final page = findPageForOffset(_pagination!, offset);
        _jumpToPage(page);
      },
    );
  }

  void _openManager() {
    if (widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final fileName = path.split('/').last;
    openBookmarkHighlightManager(context, fileKey, fileName);
  }

  Future<void> _openEditor() async {
    if (widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileName = path.split('/').last;

    _saveProgress();

    await openEditorAndReturn(context, path, fileName, () {
      _lastLoadedPath = null;
      _lastLoadedSize = null;
      _ensureLoaded();
    });
  }

  // ==================== 长按选中 ====================

  void _onLineLongPress(
    int lineIdx,
    Offset localPos,
    double maxWidth,
    ReaderSettings settings,
  ) {
    final line = _lines[lineIdx];
    if (line.isEmpty) return;
    final style = _baseStyle(settings);

    final tp = TextPainter(
      text: TextSpan(text: line, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    final pos = tp.getPositionForOffset(localPos);
    final word = _extractWordAt(line, pos.offset);
    if (word.isEmpty) return;
    _showWordMenu(word);
  }

  String _extractWordAt(String line, int charOffset) {
    if (charOffset < 0 || charOffset >= line.length) return '';
    final ch = line[charOffset];
    final code = ch.codeUnitAt(0);

    if (code >= 0x4E00 && code <= 0x9FFF) return ch;

    if (_isWordChar(code)) {
      var start = charOffset;
      var end = charOffset + 1;
      while (start > 0 && _isWordChar(line.codeUnitAt(start - 1))) {
        start--;
      }
      while (end < line.length && _isWordChar(line.codeUnitAt(end))) {
        end++;
      }
      return line.substring(start, end);
    }
    return ch;
  }

  bool _isWordChar(int code) =>
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      code == 0x5F;

  Future<void> _showWordMenuAndClear(
    String word,
    SelectableRegionState state,
  ) async {
    await _showWordMenu(word);
    state.clearSelection();
  }

  Future<void> _showWordMenu(String word) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      barrierColor: Colors.transparent, // ← 加这行
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        word,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: '复制',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: word));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已复制'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                const Text('选择色块高亮', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                _buildColorGrid(ctx, word),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildColorGrid(BuildContext ctx, String word) {
    final palette = ref.read(readerPaletteProvider);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 0.9,
      ),
      itemCount: palette.length,
      itemBuilder: (c, i) {
        final p = palette[i];
        final bg = Color(p.colors.first);
        return GestureDetector(
          onTap: () {
            Navigator.pop(ctx);
            _applyHighlight(word, p);
          },
          onLongPress: () {
            Navigator.pop(ctx);
            openPaletteEdit(context, p.index);
          },
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: bg,
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    word.length > 2 ? '${word.substring(0, 2)}…' : word,
                    style: TextStyle(
                      color: Color(p.textColor),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                p.name,
                style: const TextStyle(fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );
  }

  void _applyHighlight(String word, HighlightPalette palette) {
    if (_text == null) return;
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final entry = HighlightEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      keyword: word,
      colors: List<int>.from(palette.colors),
      stops: List<double>.from(palette.stops),
      angle: palette.angle,
      textColor: palette.textColor,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    ref
        .read(readerHighlightsProvider.notifier)
        .addOrReplace(fileKey, entry);

    final newHighlights =
        ref.read(readerHighlightsProvider)[fileKey] ?? const [];
    setState(() {
      _highlightIndex = buildHighlightIndex(
        lines: _lines,
        highlights: newHighlights,
      );
    });
  }

  // ==================== 渲染 ====================

  TextStyle _baseStyle(ReaderSettings settings) => TextStyle(
        fontSize: settings.fontSize,
        fontWeight: _toFontWeight(settings.fontWeight),
        height: kReaderLineHeightFactor,
        color: const Color(0xFF222222),
      );

  FontWeight _toFontWeight(int v) {
    switch (v) {
      case 100:
        return FontWeight.w100;
      case 200:
        return FontWeight.w200;
      case 300:
        return FontWeight.w300;
      case 400:
        return FontWeight.w400;
      case 500:
        return FontWeight.w500;
      case 600:
        return FontWeight.w600;
      case 700:
        return FontWeight.w700;
      case 800:
        return FontWeight.w800;
      case 900:
        return FontWeight.w900;
      default:
        return FontWeight.w400;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(readerSettingsProvider);
    return Scaffold(
      backgroundColor: Color(settings.bgColor),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (ctx, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            if (size.width > 10 &&
                size.height > 10 &&
                _viewportSize != size) {
              _viewportSize = size;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _ensureLoaded();
              });
            }

            if (widget.filePaths.isEmpty) {
              return const Center(child: Text('没有可读取的文件'));
            }
            if (_loading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (_error != null) return _buildError();
            if (_pagination == null) return const SizedBox.shrink();

            return _buildReader(settings, size);
          },
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text('读取失败：\n$_error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                _lastLoadedPath = null;
                _lastLoadedSize = null;
                _ensureLoaded();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReader(ReaderSettings settings, Size size) {
    final pagination = _pagination!;
    final range = pageLineRange(pagination, _currentPage);

    return Stack(
      children: [
        // 正文区（点击翻下一页，右划翻上一页）
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _nextPage,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: kReaderHorizontalPadding,
                vertical: kReaderVerticalPadding,
              ),
              child: SelectionArea(
                onSelectionChanged: (SelectedContent? content) {
                  _lastSelectedContent = content;
                },
                contextMenuBuilder: (ctx, state) {
                  final content = _lastSelectedContent;
                  if (content == null ||
                      content.plainText.trim().isEmpty) {
                    return const SizedBox.shrink();
                  }
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _showWordMenuAndClear(
                        content.plainText.trim(), state);
                  });
                  return const SizedBox.shrink();
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = range.startLine; i < range.endLine; i++)
                      _buildLine(
                        i,
                        settings,
                        size.width - kReaderHorizontalPadding * 2,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // 顶部 40px 热区 → 打开菜单
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 40,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showTopMenu,
            child: Container(color: Colors.transparent),
          ),
        ),

        // 浮动按钮
        if (settings.showButtons) ...[
          _buildFloatButton(
            x: settings.topBtnX,
            y: settings.topBtnY,
            icon: Icons.keyboard_arrow_up,
            size: size,
            settings: settings,
            onTap: _prevFile,
          ),
          _buildFloatButton(
            x: settings.bottomBtnX,
            y: settings.bottomBtnY,
            icon: Icons.keyboard_arrow_down,
            size: size,
            settings: settings,
            onTap: _nextFile,
          ),
        ],
      ],
    );
  }

  Widget _buildLine(int lineIdx, ReaderSettings settings, double maxWidth) {
    final spans = _buildLineSpans(lineIdx, settings);
    return SizedBox(
      width: double.infinity,
      child: Text.rich(TextSpan(children: spans), softWrap: true),
    );
  }

  List<InlineSpan> _buildLineSpans(int lineIdx, ReaderSettings settings) {
    final line = _lines[lineIdx];
    final base = _baseStyle(settings);

    if (line.isEmpty) {
      return [TextSpan(text: ' ', style: base)];
    }

    final highlights = _highlightIndex.forLine(lineIdx);
    if (highlights.isEmpty) {
      return [TextSpan(text: line, style: base)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final h in highlights) {
      if (h.startInLine > cursor) {
        spans.add(TextSpan(
          text: line.substring(cursor, h.startInLine),
          style: base,
        ));
      }
      final entry = h.entry;
      final hlStyle = base.copyWith(
        color: Color(entry.textColor),
        backgroundColor: Color(entry.colors.first),
      );
      spans.add(TextSpan(
        text: line.substring(h.startInLine, h.endInLine),
        style: hlStyle,
      ));
      cursor = h.endInLine;
    }

    if (cursor < line.length) {
      spans.add(TextSpan(text: line.substring(cursor), style: base));
    }

    return spans;
  }

  Widget _buildFloatButton({
    required double x,
    required double y,
    required IconData icon,
    required Size size,
    required ReaderSettings settings,
    required VoidCallback onTap,
  }) {
    final btnSize = 50.0 * settings.buttonScale;
    final left = x * size.width - btnSize / 2;
    final top = y * size.height - btnSize / 2;

    return Positioned(
      left: left,
      top: top,
      child: Opacity(
        opacity: settings.buttonOpacity,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: btnSize,
            height: btnSize,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: btnSize * 0.6,
            ),
          ),
        ),
      ),
    );
  }
}

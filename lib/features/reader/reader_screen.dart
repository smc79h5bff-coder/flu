// reader_screen.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../preprocessing/application/aho_corasick.dart';
import '../preprocessing/application/encoding_detector.dart';
import '../preprocessing/domain/encoding_type.dart';
import 'reader_models.dart';
import 'reader_pagination.dart';
import 'reader_panels.dart';
import 'reader_repository.dart';

// ==================== 选区模型 ====================

class _SelectionRange {
  const _SelectionRange({
    required this.startLine,
    required this.startOffset,
    required this.endLine,
    required this.endOffset,
  });

  final int startLine;
  final int startOffset;
  final int endLine;
  final int endOffset;

  _SelectionRange normalized() {
    if (startLine < endLine ||
        (startLine == endLine && startOffset <= endOffset)) {
      return this;
    }
    return _SelectionRange(
      startLine: endLine,
      startOffset: endOffset,
      endLine: startLine,
      endOffset: startOffset,
    );
  }
}

class _CharPos {
  const _CharPos({required this.line, required this.offset});
  final int line;
  final int offset;
}

// ==================== 手柄绘制 ====================

class _TrapezoidPainter extends CustomPainter {
  _TrapezoidPainter({
    required this.color,
    required this.isLeft,
    required this.flip,
  });

  final Color color;
  final bool isLeft;
  final bool flip;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final mid = h / 2;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final path = Path();

    if (!flip) {
      if (isLeft) {
        path.moveTo(w, 0);
        path.lineTo(w, h);
        path.lineTo(0, h);
        path.lineTo(0, mid);
        path.close();
      } else {
        path.moveTo(0, 0);
        path.lineTo(0, h);
        path.lineTo(w, h);
        path.lineTo(w, mid);
        path.close();
      }
    } else {
      if (isLeft) {
        path.moveTo(w, h);
        path.lineTo(w, 0);
        path.lineTo(0, 0);
        path.lineTo(0, mid);
        path.close();
      } else {
        path.moveTo(0, h);
        path.lineTo(0, 0);
        path.lineTo(w, 0);
        path.lineTo(w, mid);
        path.close();
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TrapezoidPainter old) =>
      old.color != color || old.isLeft != isLeft || old.flip != flip;
}

// ==================== 渐变矩形 ====================

class _GradRect {
  const _GradRect(this.rect, this.colors);
  final Rect rect;
  final List<Color> colors;
}

// ==================== 编码选择 ====================

class _EncodingChoice {
  const _EncodingChoice(this.encoding);
  final EncodingType? encoding;
}

class _EncodingPickerSheet extends StatelessWidget {
  const _EncodingPickerSheet({
    required this.currentManual,
    required this.currentDetected,
  });

  final EncodingType? currentManual;
  final EncodingType? currentDetected;

  static const List<EncodingType> _pickable = [
    EncodingType.utf8,
    EncodingType.utf8bom,
    EncodingType.utf16le,
    EncodingType.utf16be,
    EncodingType.gbk,
    EncodingType.gb18030,
    EncodingType.big5,
    EncodingType.shiftJis,
  ];

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
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
          const Text('选择编码',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '如果自动检测错了，可以在这里手动指定。\n'
              '切换后当前文件会立即按新编码重新打开。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: Icon(
                    currentManual == null
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: currentManual == null ? s.primary : null,
                  ),
                  title: const Text('自动检测'),
                  subtitle: Text(
                    currentDetected == null
                        ? '当前未识别'
                        : '当前检测为：${currentDetected!.label}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () =>
                      Navigator.pop(context, const _EncodingChoice(null)),
                ),
                const Divider(height: 1),
                for (final e in _pickable)
                  ListTile(
                    leading: Icon(
                      currentManual == e
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: currentManual == e ? s.primary : null,
                    ),
                    title: Text(e.label),
                    onTap: () =>
                        Navigator.pop(context, _EncodingChoice(e)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ==================== ReaderScreen ====================

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({
    super.key,
    required this.filePaths,
    required this.initialIndex,
  });

  final List<String> filePaths;
  final int initialIndex;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver {
  Size _viewportSize = Size.zero;

  late int _fileIndex;
  String? _text;
  String? _error;
  bool _loading = true;

  ReaderPaginator? _paginator;
  List<String> _lines = const [];
  List<int> _lineStarts = const [];

  int _currentPage = 0;

  String? _lastLoadedKey;

  EncodingType? _manualEncoding;
  EncodingType? _currentEncoding;

  bool _menuOpen = false;

  // ==================== 高亮（页级 AC 匹配） ====================

  List<HighlightEntry> _highlights = const [];
  AhoCorasick? _highlightAc;
  Map<int, HighlightEntry> _highlightEntryByPattern = const {};
  int _highlightsRevision = 0;

  Map<int, List<HighlightSpan>> _pageHighlightCache = {};
  int _pageHighlightCacheForPage = -1;
  int _pageHighlightCacheForRevision = -1;

  /// 更快点 4：`_highlightsForLine` memo。
  int _lastHighlightQueryLine = -1;
  List<HighlightSpan> _lastHighlightQueryResult = const [];

  // ==================== 手势 / 选区 ====================

  final GlobalKey _contentKey = GlobalKey();
  final Map<int, GlobalKey> _unitKeys = <int, GlobalKey>{};
  int _lastUnitStart = -1;
  int _lastUnitEnd = -1;

  /// 耗电 4 / 更快点 1：每页 spans 缓存。key = unitIdx。
  final Map<int, List<InlineSpan>> _spansCache = {};

  // 渐变矩形缓存
  final Map<String, List<_GradRect>> _gradRectCache = {};
  double _gradCacheFontSize = 0;
  int _gradCacheFontWeight = 0;
  double _gradCacheWidth = 0;

  /// 更快点 3：渐变测量用 TextPainter 单例。
  static final TextPainter _gradTP = TextPainter(
    textDirection: TextDirection.ltr,
  );

  _SelectionRange? _sel;
  bool _hBarVisible = false;

  int _selVersion = 0;
  int _lastOverlayVersion = 0;

  int _draggingHandle = 0;
  Offset? _dragHandlePos;
  Offset? _dragHandleOffset;
  Offset? _lastLongPressPos;

  Timer? _longPressTimer;
  Timer? _resumePrecisionTimer;
  Timer? _progressSaveTimer;

  Offset _downPos = Offset.zero;
  bool _longPressFired = false;
  bool _movedBeyondThreshold = false;
  bool _pressDown = false;

  bool _horizontalDrag = false;
  int _downMs = 0;
  static const double _hDragMinDx = 60.0;

  int _lastTapUpMs = 0;

  static const Color _selectionBg = Color(0x773D7CFF);
  static const int _longPressMs = 400;
  static const double _moveThresholdDp = 10.0;
  static const int _tapDebounceMs = 100;

  @override
  void initState() {
    super.initState();
    _fileIndex = widget.initialIndex.clamp(0, widget.filePaths.length - 1);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    _resumePrecisionTimer?.cancel();
    _progressSaveTimer?.cancel();
    _saveProgressNow();
    _paginator?.removeListener(_onPaginatorChanged);
    _paginator?.dispose();
    super.dispose();
  }

  // ==================== 耗电 2：后台/锁屏暂停 ====================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleResumePrecision();
    } else {
      _pausePrecision();
    }
  }

  // ==================== 加载 ====================

  String _loadKeyFor(String path) {
    final s = ref.read(readerSettingsProvider);
    return '$path|'
        '${_viewportSize.width}x${_viewportSize.height}|'
        '${s.fontSize}|${s.fontWeight}|'
        '${_manualEncoding?.name ?? "auto"}';
  }

  Future<void> _ensureLoaded() async {
    if (widget.filePaths.isEmpty) return;
    if (_viewportSize.width < 10 || _viewportSize.height < 10) return;

    final path = widget.filePaths[_fileIndex];
    final key = _loadKeyFor(path);
    if (_lastLoadedKey == key) return;
    _lastLoadedKey = key;

    _paginator?.removeListener(_onPaginatorChanged);
    _paginator?.dispose();
    _paginator = null;

    setState(() {
      _loading = true;
      _error = null;
      _text = null;
      _lines = const [];
      _lineStarts = const [];
      _highlights = const [];
      _currentPage = 0;
      _sel = null;
      _hBarVisible = false;
    });
    _invalidateAllCaches();

    try {
      final bytes = await File(path).readAsBytes();
      final encoding = _manualEncoding ?? EncodingDetector.detect(bytes);
      _currentEncoding = encoding;
      final text = EncodingDetector.decodeChunked(bytes, encoding);
      if (!mounted) return;
      if (_lastLoadedKey != key) return;

      final settings = ref.read(readerSettingsProvider);
      final paginator = ReaderPaginator(
        text: text,
        viewportWidth: _viewportSize.width,
        viewportHeight: _viewportSize.height,
        fontSize: settings.fontSize,
        fontWeight: settings.fontWeight,
      );
      paginator.addListener(_onPaginatorChanged);
      paginator.start();

      final split = splitLinesWithOffsets(text);
      final fileKey = readerFileKey(path);
      final highlights =
          ref.read(readerHighlightsProvider)[fileKey] ?? const [];

      final progress = ref.read(readerProgressProvider)[fileKey];
      final startPage = progress != null
          ? findPageForOffset(paginator.result!, progress.charOffset)
              .clamp(0, paginator.result!.pageCount - 1)
          : 0;

      setState(() {
        _text = text;
        _paginator = paginator;
        _lines = split.lines;
        _lineStarts = split.lineStarts;
        _highlights = highlights;
        _highlightsRevision++;
        _currentPage = startPage;
        _loading = false;
        _sel = null;
        _hBarVisible = false;
      });

      _rebuildHighlightAc();
      // 通知分页器当前页，让它滑动精修窗口。
      paginator.notifyVisiblePage(startPage);
      _syncPagePreview();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _invalidateAllCaches() {
    _unitKeys.clear();
    _lastUnitStart = -1;
    _lastUnitEnd = -1;
    _spansCache.clear();
    _gradRectCache.clear();
    _pageHighlightCache = {};
    _pageHighlightCacheForPage = -1;
    _pageHighlightCacheForRevision = -1;
    _lastHighlightQueryLine = -1;
    _lastHighlightQueryResult = const [];
  }

  void _onPaginatorChanged() {
    if (!mounted) return;
    final p = _paginator;
    if (p == null || p.result == null) return;

    final anchor = p.anchorCharOffset;
    int? newPage;
    if (anchor != null) {
      newPage = findPageForOffset(p.result!, anchor)
          .clamp(0, p.result!.pageCount - 1);
    }
    setState(() {
      if (newPage != null) _currentPage = newPage;
      // 精修后 result 变了，spans 和 unit key 都要失效。
      _spansCache.clear();
      _unitKeys.clear();
      _lastUnitStart = -1;
      _lastUnitEnd = -1;
      _gradRectCache.clear();
    });
    _paginator?.notifyVisiblePage(_currentPage);
    _syncPagePreview();
  }

  // ==================== 高亮页级 AC 匹配 ====================

  void _rebuildHighlightAc() {
    final patterns = <String>[];
    final entryByPattern = <int, HighlightEntry>{};
    for (final h in _highlights) {
      if (h.keyword.isEmpty) continue;
      patterns.add(h.keyword);
      entryByPattern[patterns.length - 1] = h;
    }
    if (patterns.isEmpty) {
      _highlightAc = null;
      _highlightEntryByPattern = const {};
      return;
    }
    _highlightAc = AhoCorasick(
      patterns: patterns,
      replacements: List<String>.filled(patterns.length, ''),
      priorities: List<int>.generate(patterns.length, (i) => i),
    );
    _highlightEntryByPattern = entryByPattern;
  }

  void _ensurePageHighlightCache() {
    if (_pageHighlightCacheForPage == _currentPage &&
        _pageHighlightCacheForRevision == _highlightsRevision) {
      return;
    }
    _rebuildPageHighlightCache();
  }

  void _rebuildPageHighlightCache() {
    _pageHighlightCacheForPage = _currentPage;
    _pageHighlightCacheForRevision = _highlightsRevision;

    final p = _paginator;
    if (p?.result == null || _highlightAc == null) {
      _pageHighlightCache = {};
      return;
    }

    final range = pageUnitRange(p!.result!, _currentPage);
    if (range.startUnit >= range.endUnit) {
      _pageHighlightCache = {};
      return;
    }

    final lineSet = <int>{};
    for (var i = range.startUnit; i < range.endUnit; i++) {
      lineSet.add(p.result!.renderUnits[i].lineIndex);
    }
    final sortedLineIdxs = lineSet.toList()..sort();

    final buf = StringBuffer();
    final lineStartInBuf = <int>[];
    final lineIdxAtPos = <int>[];
    for (final li in sortedLineIdxs) {
      lineStartInBuf.add(buf.length);
      lineIdxAtPos.add(li);
      buf.write(_lines[li]);
      buf.write('\n');
    }
    final pageText = buf.toString();
    final pageLen = pageText.length;

    final byLine = <int, List<HighlightSpan>>{};
    _highlightAc!.findAllMatches(pageText, (start, end, pi) {
      var lo = 0;
      var hi = lineStartInBuf.length - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (lineStartInBuf[mid] <= start) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      final rowIdx = lo;
      final lineStart = lineStartInBuf[rowIdx];
      final lineEnd = rowIdx + 1 < lineStartInBuf.length
          ? lineStartInBuf[rowIdx + 1] - 1
          : pageLen - 1;
      if (end > lineEnd) return;

      final actualLineIdx = lineIdxAtPos[rowIdx];
      (byLine[actualLineIdx] ??= <HighlightSpan>[]).add(HighlightSpan(
        startInLine: start - lineStart,
        endInLine: end - lineStart,
        entry: _highlightEntryByPattern[pi]!,
      ));
    });

    for (final i in byLine.keys.toList()) {
      final list = byLine[i]!;
      list.sort((a, b) {
        final byStart = a.startInLine.compareTo(b.startInLine);
        if (byStart != 0) return byStart;
        return (a.endInLine - a.startInLine)
            .compareTo(b.endInLine - b.startInLine);
      });
      final kept = <HighlightSpan>[];
      var lastEnd = -1;
      for (final s in list) {
        if (s.startInLine < lastEnd) continue;
        kept.add(s);
        lastEnd = s.endInLine;
      }
      byLine[i] = kept;
    }

    _pageHighlightCache = byLine;
    _lastHighlightQueryLine = -1;
    _lastHighlightQueryResult = const [];
  }

  /// 更快点 4：加 memo 的查询。
  List<HighlightSpan> _highlightsForLine(int lineIdx) {
    if (_lastHighlightQueryLine == lineIdx) {
      return _lastHighlightQueryResult;
    }
    _ensurePageHighlightCache();
    final r = _pageHighlightCache[lineIdx] ?? const <HighlightSpan>[];
    _lastHighlightQueryLine = lineIdx;
    _lastHighlightQueryResult = r;
    return r;
  }

  // ==================== 精度暂停/恢复 ====================

  void _pausePrecision() {
    _resumePrecisionTimer?.cancel();
    _paginator?.pause();
  }

  void _scheduleResumePrecision() {
    _resumePrecisionTimer?.cancel();
    _resumePrecisionTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _paginator?.resume();
    });
  }

  // ==================== 进度（防抖） ====================

  void _saveProgress() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(
      const Duration(milliseconds: 800),
      _saveProgressNow,
    );
  }

  void _saveProgressNow() {
    final p = _paginator;
    if (p?.result == null || widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final offset = pageStartOffset(p!.result!, _currentPage);
    ref.read(readerProgressProvider.notifier).set(fileKey, offset);
  }

  void _syncPagePreview() {
    final p = _paginator;
    if (p?.result == null || _lines.isEmpty) return;
    final r = pageUnitRange(p!.result!, _currentPage);
    if (r.startUnit >= r.endUnit) return;
    final buf = StringBuffer();
    for (var i = r.startUnit; i < r.endUnit; i++) {
      final u = p.result!.renderUnits[i];
      final line = _lines[u.lineIndex];
      final s = u.charStart.clamp(0, line.length);
      final e = u.charEnd.clamp(0, line.length);
      if (e > s) buf.write(line.substring(s, e));
      buf.write('\n');
    }
    ref.read(readerPagePreviewProvider.notifier).state = buf.toString();
  }

  // ==================== 翻页 ====================

  void _nextPage() {
    final p = _paginator;
    if (p?.result == null) return;
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    final maxPage = p!.result!.pageCount - 1;
    if (_currentPage >= maxPage) return;
    _clearSelection();
    setState(() => _currentPage = (_currentPage + 1).clamp(0, maxPage));
    _invalidatePageCaches();
    p.notifyVisiblePage(_currentPage);
    _saveProgress();
    _syncPagePreview();
  }

  void _prevPage() {
    final p = _paginator;
    if (p?.result == null) return;
    if (_currentPage <= 0) return;
    _clearSelection();
    setState(() => _currentPage =
        (_currentPage - 1).clamp(0, p!.result!.pageCount - 1));
    _invalidatePageCaches();
    p.notifyVisiblePage(_currentPage);
    _saveProgress();
    _syncPagePreview();
  }

  void _jumpToPage(int page) {
    final p = _paginator;
    if (p?.result == null) return;
    final maxPage = p!.result!.pageCount - 1;
    final pg = page.clamp(0, maxPage);
    _clearSelection();
    setState(() => _currentPage = pg);
    _invalidatePageCaches();
    p.notifyVisiblePage(pg);
    _saveProgress();
    _syncPagePreview();
  }

  /// 翻页时清掉页面级缓存。不要把 `_gradRectCache` 也清了——它是按 unit 的，
  /// 同字号下跨页可以复用；只有 unitIdx 会重复，但 key 里带了 width，
  /// 不同页的 unitIdx 可能撞车。保险起见还是清一下（渐变行不多，代价小）。
  void _invalidatePageCaches() {
    _spansCache.clear();
    _gradRectCache.clear();
    _lastHighlightQueryLine = -1;
    _lastHighlightQueryResult = const [];
    // _unitKeys 不清，交给 _syncUnitKeys 做增量。
  }

  // ==================== 切文件 ====================

  Future<void> _prevFile() async {
    if (_fileIndex <= 0) return;
    _saveProgressNow();
    _clearSelection();
    _manualEncoding = null;
    setState(() => _fileIndex--);
    await _ensureLoaded();
  }

  Future<void> _nextFile() async {
    if (_fileIndex >= widget.filePaths.length - 1) return;
    _saveProgressNow();
    _clearSelection();
    _manualEncoding = null;
    setState(() => _fileIndex++);
    await _ensureLoaded();
  }

  // ==================== 顶部菜单 ====================

  void _showTopMenu() {
    _clearSelection();
    setState(() => _menuOpen = true);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _buildTopMenuSheet(ctx),
    ).then((_) {
      if (mounted) setState(() => _menuOpen = false);
    });
  }

  Widget _buildTopMenuSheet(BuildContext ctx) {
    final p = _paginator?.result;
    final pct = p == null
        ? '-'
        : '${((_currentPage + 1) / p.pageCount * 100).toStringAsFixed(1)}%';
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
            onTap: () async {
              Navigator.pop(ctx);
              await _openManager();
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
            leading: const Icon(Icons.translate),
            title: const Text('编码'),
            subtitle: Text(_encodingSubtitle()),
            onTap: () {
              Navigator.pop(ctx);
              _showEncodingPicker();
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

  String _encodingSubtitle() {
    final cur = _currentEncoding?.label ?? '未识别';
    if (_manualEncoding == null) return '自动检测（$cur）';
    return '手动：$cur';
  }

  Future<void> _showEncodingPicker() async {
    final picked = await showModalBottomSheet<_EncodingChoice>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _EncodingPickerSheet(
        currentManual: _manualEncoding,
        currentDetected: _currentEncoding,
      ),
    );

    if (!mounted || picked == null) return;
    final same = picked.encoding == _manualEncoding;
    if (same) return;

    setState(() => _manualEncoding = picked.encoding);
    await _ensureLoaded();
  }

  void _showProgressSlider() {
    final p = _paginator?.result;
    if (p == null) return;
    var tempPage = _currentPage;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          final total = p.pageCount;
          final pct = total <= 1 ? 100.0 : (tempPage / (total - 1) * 100);
          return AlertDialog(
            title: const Text('跳转'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${pct.toStringAsFixed(1)}%',
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold)),
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
                  child: const Text('取消')),
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

  void _addBookmark() {
    final p = _paginator?.result;
    if (p == null || _text == null) return;
    final offset = pageStartOffset(p, _currentPage);
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
          content: Text('已加书签'), duration: Duration(seconds: 1)),
    );
  }

  void _openFind() {
    if (_text == null || widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    _clearSelection();
    showReaderFindBar(context, fileKey, _text!, (offset) {
      final p = _paginator?.result;
      if (p == null) return;
      final page = findPageForOffset(p, offset);
      _jumpToPage(page);
    });
  }

  Future<void> _openManager() async {
    if (widget.filePaths.isEmpty) return;
    _clearSelection();
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final fileName = path.split('/').last;
    final result =
        await openBookmarkHighlightManager(context, fileKey, fileName);
    if (!mounted) return;
    if (result != null && _paginator?.result != null) {
      final page = findPageForOffset(_paginator!.result!, result);
      _jumpToPage(page);
    }
    // 用户可能在管理页删/改了高亮，重新读一次。
    final updated =
        ref.read(readerHighlightsProvider)[fileKey] ?? const [];
    if (mounted) {
      setState(() {
        _highlights = updated;
        _highlightsRevision++;
        _rebuildHighlightAc();
        _invalidatePageCaches();
        _pageHighlightCache = {};
        _pageHighlightCacheForPage = -1;
        _pageHighlightCacheForRevision = -1;
      });
    }
  }

  Future<void> _openEditor() async {
    if (widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileName = path.split('/').last;
    _saveProgressNow();
    _clearSelection();
    await openEditorAndReturn(context, path, fileName, () {
      _lastLoadedKey = null;
      _ensureLoaded();
    });
  }

  // ==================== 选区 ====================

  void _clearSelection() {
    _longPressTimer?.cancel();
    _longPressFired = false;
    _movedBeyondThreshold = false;
    _pressDown = false;
    _draggingHandle = 0;
    _dragHandlePos = null;
    _dragHandleOffset = null;
    _lastLongPressPos = null;
    _horizontalDrag = false;
    if (_sel != null || _hBarVisible) {
      setState(() {
        _sel = null;
        _hBarVisible = false;
      });
    }
  }

  _CharPos? _hitTest(Offset globalPos) {
    final contentCtx = _contentKey.currentContext;
    if (contentCtx == null) return null;
    final contentBox = contentCtx.findRenderObject() as RenderBox?;
    if (contentBox == null) return null;
    final local = contentBox.globalToLocal(globalPos);
    if (!(Offset.zero & contentBox.size).contains(local)) return null;

    final p = _paginator;
    if (p?.result == null) return null;
    final range = pageUnitRange(p!.result!, _currentPage);

    for (var unitIdx = range.startUnit; unitIdx < range.endUnit; unitIdx++) {
      final ctx = _unitKeys[unitIdx]?.currentContext;
      if (ctx == null) continue;
      final rp = ctx.findRenderObject();
      if (rp is! RenderParagraph) continue;
      final localUnit = rp.globalToLocal(globalPos);
      final size = rp.size;
      if (localUnit.dy < 0 || localUnit.dy > size.height) continue;
      if (localUnit.dx < 0) continue;
      final clamped = Offset(
        localUnit.dx.clamp(0.0, size.width),
        localUnit.dy.clamp(0.0, size.height),
      );
      final pos = rp.getPositionForOffset(clamped);
      final unit = p.result!.renderUnits[unitIdx];
      final line = _lines[unit.lineIndex];
      final unitText = line.substring(
        unit.charStart.clamp(0, line.length),
        unit.charEnd.clamp(0, line.length),
      );
      final safeUnitOffset = pos.offset.clamp(0, unitText.length);
      return _CharPos(
        line: unit.lineIndex,
        offset: unit.charStart + safeUnitOffset,
      );
    }
    return null;
  }

  _CharPos? _hitTestWithBuffer(Offset globalPos, int preferLine) {
    final p = _paginator;
    if (p?.result == null) return _hitTest(globalPos);
    final range = pageUnitRange(p!.result!, _currentPage);

    for (var unitIdx = range.startUnit; unitIdx < range.endUnit; unitIdx++) {
      final u = p.result!.renderUnits[unitIdx];
      if (u.lineIndex != preferLine) continue;
      final ctx = _unitKeys[unitIdx]?.currentContext;
      if (ctx == null) continue;
      final rp = ctx.findRenderObject();
      if (rp is! RenderParagraph) continue;
      final topLeft = rp.localToGlobal(Offset.zero);
      final h = rp.size.height;
      final buffer = h / 3;
      final dy = globalPos.dy;
      if (dy >= topLeft.dy - buffer && dy <= topLeft.dy + h + buffer) {
        final local = rp.globalToLocal(globalPos);
        final clamped = Offset(
          local.dx.clamp(0.0, rp.size.width),
          local.dy.clamp(0.0, rp.size.height),
        );
        final pos = rp.getPositionForOffset(clamped);
        final line = _lines[u.lineIndex];
        final unitText = line.substring(
          u.charStart.clamp(0, line.length),
          u.charEnd.clamp(0, line.length),
        );
        return _CharPos(
          line: u.lineIndex,
          offset: u.charStart + pos.offset.clamp(0, unitText.length),
        );
      }
    }
    return _hitTest(globalPos);
  }

  ({int unitIdx, RenderUnit unit})? _findUnitFor(int line, int offset) {
    final p = _paginator;
    if (p?.result == null) return null;
    final range = pageUnitRange(p!.result!, _currentPage);
    for (var i = range.startUnit; i < range.endUnit; i++) {
      final u = p.result!.renderUnits[i];
      if (u.lineIndex != line) continue;
      if (offset >= u.charStart && offset <= u.charEnd) {
        return (unitIdx: i, unit: u);
      }
    }
    return null;
  }

  Offset? _posOfCharLeft(int line, int offset) {
    final found = _findUnitFor(line, offset);
    if (found == null) return null;
    final ctx = _unitKeys[found.unitIdx]?.currentContext;
    if (ctx == null) return null;
    final rp = ctx.findRenderObject();
    if (rp is! RenderParagraph) return null;

    final lineText = line < _lines.length ? _lines[line] : '';
    final unitText = lineText.substring(
      found.unit.charStart.clamp(0, lineText.length),
      found.unit.charEnd.clamp(0, lineText.length),
    );
    final unitOffset =
        (offset - found.unit.charStart).clamp(0, unitText.length);
    if (unitText.isEmpty) return rp.localToGlobal(Offset.zero);

    if (unitOffset >= unitText.length) {
      final boxes = rp.getBoxesForSelection(TextSelection(
        baseOffset: unitText.length - 1,
        extentOffset: unitText.length,
      ));
      if (boxes.isEmpty) return rp.localToGlobal(Offset.zero);
      final box = boxes.last;
      return rp.localToGlobal(Offset(box.right, box.top));
    }
    final boxes = rp.getBoxesForSelection(TextSelection(
      baseOffset: unitOffset,
      extentOffset: unitOffset + 1,
    ));
    if (boxes.isEmpty) {
      final caret = rp.getOffsetForCaret(
        TextPosition(offset: unitOffset),
        Rect.fromLTWH(0, 0, 1, rp.size.height),
      );
      return rp.localToGlobal(caret);
    }
    final box = boxes.first;
    return rp.localToGlobal(Offset(box.left, box.top));
  }

  Offset? _posOfCharRight(int line, int offset) {
    final found = _findUnitFor(line, offset);
    if (found == null) return null;
    final ctx = _unitKeys[found.unitIdx]?.currentContext;
    if (ctx == null) return null;
    final rp = ctx.findRenderObject();
    if (rp is! RenderParagraph) return null;

    final lineText = line < _lines.length ? _lines[line] : '';
    final unitText = lineText.substring(
      found.unit.charStart.clamp(0, lineText.length),
      found.unit.charEnd.clamp(0, lineText.length),
    );
    final unitOffset =
        (offset - found.unit.charStart).clamp(0, unitText.length);
    if (unitText.isEmpty) return rp.localToGlobal(Offset.zero);

    if (unitOffset <= 0) {
      final boxes = rp.getBoxesForSelection(const TextSelection(
        baseOffset: 0,
        extentOffset: 1,
      ));
      if (boxes.isEmpty) return rp.localToGlobal(Offset.zero);
      final box = boxes.first;
      return rp.localToGlobal(Offset(box.left, box.top));
    }
    final boxes = rp.getBoxesForSelection(TextSelection(
      baseOffset: unitOffset - 1,
      extentOffset: unitOffset,
    ));
    if (boxes.isEmpty) {
      final caret = rp.getOffsetForCaret(
        TextPosition(offset: unitOffset),
        Rect.fromLTWH(0, 0, 1, rp.size.height),
      );
      return rp.localToGlobal(caret);
    }
    final box = boxes.last;
    return rp.localToGlobal(Offset(box.right, box.top));
  }

  String _selectedText() {
    final sel = _sel;
    if (sel == null) return '';
    final n = sel.normalized();
    if (n.startLine == n.endLine) {
      final line = _lines[n.startLine];
      final s = n.startOffset.clamp(0, line.length);
      final e = n.endOffset.clamp(0, line.length);
      if (e <= s) return '';
      return line.substring(s, e);
    }
    final sb = StringBuffer();
    for (var i = n.startLine; i <= n.endLine; i++) {
      final line = _lines[i];
      if (i == n.startLine) {
        sb.write(line.substring(n.startOffset.clamp(0, line.length)));
      } else if (i == n.endLine) {
        sb.write('\n');
        sb.write(line.substring(0, n.endOffset.clamp(0, line.length)));
      } else {
        sb.write('\n');
        sb.write(line);
      }
    }
    return sb.toString();
  }

  void _selectWordAt(_CharPos pos) {
    final line = _lines[pos.line];
    if (line.isEmpty) return;
    final offset = pos.offset.clamp(0, line.length - 1);
    final code = line.codeUnitAt(offset);

    if (code >= 0x4E00 && code <= 0x9FFF) {
      setState(() {
        _sel = _SelectionRange(
          startLine: pos.line,
          startOffset: offset,
          endLine: pos.line,
          endOffset: offset + 1,
        );
        _hBarVisible = false;
        _selVersion++;
      });
      return;
    }

    if (_isWordChar(code)) {
      var s = offset;
      var e = offset + 1;
      while (s > 0 && _isWordChar(line.codeUnitAt(s - 1))) {
        s--;
      }
      while (e < line.length && _isWordChar(line.codeUnitAt(e))) {
        e++;
      }
      setState(() {
        _sel = _SelectionRange(
          startLine: pos.line,
          startOffset: s,
          endLine: pos.line,
          endOffset: e,
        );
        _hBarVisible = false;
        _selVersion++;
      });
      return;
    }

    setState(() {
      _sel = _SelectionRange(
        startLine: pos.line,
        startOffset: offset,
        endLine: pos.line,
        endOffset: offset + 1,
      );
      _hBarVisible = false;
      _selVersion++;
    });
  }

  bool _isWordChar(int code) =>
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      code == 0x5F;

  // ==================== 手势状态机 ====================

  void _onPointerDown(PointerDownEvent e) {
    _pausePrecision();
    _longPressTimer?.cancel();
    _downPos = e.position;
    _downMs = DateTime.now().millisecondsSinceEpoch;
    _longPressFired = false;
    _movedBeyondThreshold = false;
    _horizontalDrag = false;
    _pressDown = true;
    _lastLongPressPos = null;

    if (_hBarVisible || _sel != null) {
      setState(() => _hBarVisible = false);
    }

    _longPressTimer = Timer(const Duration(milliseconds: _longPressMs), () {
      if (!mounted) return;
      if (!_pressDown) return;
      if (_movedBeyondThreshold) return;
      _longPressFired = true;
      _handleLongPress();
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pressDown) return;

    if (_longPressFired) {
      final sel = _sel;
      if (sel == null) return;
      final ref = _lastLongPressPos ?? _downPos;
      if ((e.position - ref).distance < 10.0) return;
      _lastLongPressPos = e.position;
      final hit = _hitTest(e.position);
      if (hit == null) return;
      setState(() {
        _sel = _SelectionRange(
          startLine: sel.startLine,
          startOffset: sel.startOffset,
          endLine: hit.line,
          endOffset: hit.offset,
        );
        _selVersion++;
      });
      return;
    }

    final dx = e.position.dx - _downPos.dx;
    final dy = e.position.dy - _downPos.dy;
    final absDx = dx.abs();
    final absDy = dy.abs();

    if (!_movedBeyondThreshold) {
      if (absDx > _moveThresholdDp || absDy > _moveThresholdDp) {
        _movedBeyondThreshold = true;
        _longPressTimer?.cancel();
      }
    }

    if (_draggingHandle == 0 && !_horizontalDrag) {
      if (absDx > 20 && absDx > absDy * 1.5) {
        _horizontalDrag = true;
      }
    }

    if (_draggingHandle != 0) {
      _updateSelectionFromDrag(e.position);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _longPressTimer?.cancel();
    _scheduleResumePrecision();

    if (_draggingHandle != 0) {
      setState(() {
        _draggingHandle = 0;
        _dragHandlePos = null;
        _hBarVisible = true;
      });
      _pressDown = false;
      return;
    }

    if (_longPressFired) {
      final sel = _sel;
      if (sel != null &&
          sel.startLine == sel.endLine &&
          sel.startOffset == sel.endOffset) {
        final line = _lines[sel.startLine];
        if (line.isNotEmpty) {
          final off = sel.startOffset.clamp(0, line.length - 1);
          setState(() {
            _sel = _SelectionRange(
              startLine: sel.startLine,
              startOffset: off,
              endLine: sel.startLine,
              endOffset: off + 1,
            );
            _hBarVisible = true;
          });
          _pressDown = false;
          return;
        }
      }
      setState(() => _hBarVisible = true);
      _pressDown = false;
      return;
    }

    if (_horizontalDrag) {
      final dx = e.position.dx - _downPos.dx;
      final elapsed = DateTime.now().millisecondsSinceEpoch - _downMs;
      if (dx > _hDragMinDx && elapsed < 800) {
        _prevPage();
      }
      _pressDown = false;
      _horizontalDrag = false;
      return;
    }

    if (_movedBeyondThreshold) {
      _pressDown = false;
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTapUpMs != 0 && now - _lastTapUpMs < _tapDebounceMs) {
      _pressDown = false;
      return;
    }
    _lastTapUpMs = now;

    _handleTap(e.position);
    _pressDown = false;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _scheduleResumePrecision();
    _longPressTimer?.cancel();
    _pressDown = false;
    _draggingHandle = 0;
  }

  void _handleLongPress() {
    final pos = _hitTest(_downPos);
    if (pos == null) return;
    _selectWordAt(pos);
  }

  void _handleTap(Offset globalPos) {
    final settings = ref.read(readerSettingsProvider);

    final contentBox =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null) {
      _nextPage();
      return;
    }
    final origin = contentBox.localToGlobal(Offset.zero);
    final w = contentBox.size.width;
    final h = contentBox.size.height;

    if (settings.showButtons) {
      final topBtnSize = 50.0 * settings.buttonScale;
      final topCenter =
          origin + Offset(settings.topBtnX * w, settings.topBtnY * h);
      if ((globalPos - topCenter).distance <= topBtnSize / 2 + 8) {
        _prevFile();
        return;
      }
      final bottomCenter =
          origin + Offset(settings.bottomBtnX * w, settings.bottomBtnY * h);
      if ((globalPos - bottomCenter).distance <= topBtnSize / 2 + 8) {
        _nextFile();
        return;
      }
    }

    final safeTop = MediaQuery.of(context).padding.top;
    if (globalPos.dy < safeTop + settings.topHotZoneHeight) {
      _showTopMenu();
      return;
    }

    _nextPage();
  }

  // ==================== 手柄拖动 ====================

  void _startDragLeft(Offset fingerPos) {
    final sel = _sel;
    if (sel == null) return;
    final handleLogic = _posOfCharLeft(sel.startLine, sel.startOffset);
    setState(() {
      _draggingHandle = 1;
      _dragHandlePos = handleLogic ?? fingerPos;
      _dragHandleOffset =
          handleLogic == null ? Offset.zero : fingerPos - handleLogic;
      _hBarVisible = false;
    });
  }

  void _startDragRight(Offset fingerPos) {
    final sel = _sel;
    if (sel == null) return;
    final handleLogic = _posOfCharRight(sel.endLine, sel.endOffset);
    setState(() {
      _draggingHandle = 2;
      _dragHandlePos = handleLogic ?? fingerPos;
      _dragHandleOffset =
          handleLogic == null ? Offset.zero : fingerPos - handleLogic;
      _hBarVisible = false;
    });
  }

  void _updateSelectionFromDrag(Offset handleLogic) {
    final sel = _sel;
    if (sel == null) return;
    final preferLine = _draggingHandle == 1 ? sel.startLine : sel.endLine;
    final hit = _hitTestWithBuffer(handleLogic, preferLine);
    if (hit == null) return;

    if (_draggingHandle == 1) {
      setState(() {
        _sel = _SelectionRange(
          startLine: hit.line,
          startOffset: hit.offset,
          endLine: sel.endLine,
          endOffset: sel.endOffset,
        );
        _selVersion++;
      });
    } else if (_draggingHandle == 2) {
      setState(() {
        _sel = _SelectionRange(
          startLine: sel.startLine,
          startOffset: sel.startOffset,
          endLine: hit.line,
          endOffset: hit.offset,
        );
        _selVersion++;
      });
    }
  }

  ({Offset left, Offset right})? _handlePositions() {
    final sel = _sel;
    if (sel == null) return null;
    final left = _posOfCharLeft(sel.startLine, sel.startOffset);
    final right = _posOfCharRight(sel.endLine, sel.endOffset);
    if (left == null || right == null) return null;
    return (left: left, right: right);
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

    if (_sel != null && _selVersion != _lastOverlayVersion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastOverlayVersion = _selVersion;
        setState(() {});
      });
    }

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
            if (_paginator?.result == null) {
              return const SizedBox.shrink();
            }

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
                _lastLoadedKey = null;
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
    final p = _paginator;
    if (p?.result == null) return const SizedBox.shrink();
    final result = p!.result!;
    final range = pageUnitRange(result, _currentPage);
    final previewHotZone = ref.watch(readerHotZonePreviewProvider);

    // 更快点 2：unitKeys 增量更新。
    if (range.startUnit != _lastUnitStart || range.endUnit != _lastUnitEnd) {
      _unitKeys.removeWhere(
          (k, _) => k < range.startUnit || k >= range.endUnit);
      for (var i = range.startUnit; i < range.endUnit; i++) {
        _unitKeys.putIfAbsent(i, () => GlobalKey());
      }
      _lastUnitStart = range.startUnit;
      _lastUnitEnd = range.endUnit;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: Container(
              key: _contentKey,
              padding: const EdgeInsets.symmetric(
                horizontal: kReaderHorizontalPadding,
                vertical: kReaderVerticalPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = range.startUnit; i < range.endUnit; i++)
                    _buildRenderUnit(i, result.renderUnits[i], settings),
                ],
              ),
            ),
          ),
        ),
        if (previewHotZone)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: settings.topHotZoneHeight,
            child: IgnorePointer(
              child: Container(
                color: Colors.red.withValues(alpha: 0.25),
                alignment: Alignment.center,
                child: Text(
                  '菜单热区 · ${settings.topHotZoneHeight.toStringAsFixed(0)}px',
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        if (settings.showButtons) ...[
          _buildFloatButton(
            x: settings.topBtnX,
            y: settings.topBtnY,
            icon: Icons.keyboard_arrow_up,
            size: size,
            settings: settings,
          ),
          _buildFloatButton(
            x: settings.bottomBtnX,
            y: settings.bottomBtnY,
            icon: Icons.keyboard_arrow_down,
            size: size,
            settings: settings,
          ),
        ],
        ..._buildHandles(settings),
        if (_hBarVisible && _sel != null) _buildHBar(settings, size),
      ],
    );
  }

  Widget _buildRenderUnit(
      int unitIdx, RenderUnit unit, ReaderSettings settings) {
    final line = _lines[unit.lineIndex];
    final int s = unit.charStart.clamp(0, line.length);
    final int e = unit.charEnd.clamp(0, line.length);
    final String sub = e > s ? line.substring(s, e) : '';

    final spans = _buildUnitSpans(unitIdx, unit, sub, settings);
    final highlights = _highlightsForLine(unit.lineIndex);

    final hasGrad = _hasGradientIn(highlights, unit);

    if (!hasGrad) {
      return SizedBox(
        width: double.infinity,
        child: Stack(
          children: [
            Text.rich(
              TextSpan(children: spans),
              softWrap: true,
              key: _unitKeys[unitIdx],
            ),
            _buildUnitSelectionOverlay(unitIdx, unit),
          ],
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final gradRects = _measureGradientRects(
            unitIdx,
            unit,
            sub,
            settings,
            constraints.maxWidth,
            highlights,
          );
          return Stack(
            children: [
              for (final g in gradRects)
                Positioned(
                  left: g.rect.left,
                  top: g.rect.top,
                  width: g.rect.width,
                  height: g.rect.height,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: g.colors,
                        ),
                      ),
                    ),
                  ),
                ),
              Text.rich(
                TextSpan(children: spans),
                softWrap: true,
                key: _unitKeys[unitIdx],
              ),
              _buildUnitSelectionOverlay(unitIdx, unit),
            ],
          );
        },
      ),
    );
  }

  bool _hasGradientIn(List<HighlightSpan> highlights, RenderUnit unit) {
    for (final h in highlights) {
      if (h.entry.colors.length <= 1) continue;
      if (h.endInLine > unit.charStart && h.startInLine < unit.charEnd) {
        return true;
      }
    }
    return false;
  }

  List<_GradRect> _measureGradientRects(
    int unitIdx,
    RenderUnit unit,
    String sub,
    ReaderSettings settings,
    double maxWidth,
    List<HighlightSpan> highlights,
  ) {
    if (sub.isEmpty) return const [];

    if (_gradCacheFontSize != settings.fontSize ||
        _gradCacheFontWeight != settings.fontWeight ||
        _gradCacheWidth != maxWidth) {
      _gradRectCache.clear();
      _gradCacheFontSize = settings.fontSize;
      _gradCacheFontWeight = settings.fontWeight;
      _gradCacheWidth = maxWidth;
    }

    final key = '$unitIdx|${maxWidth.round()}';
    final hit = _gradRectCache[key];
    if (hit != null) return hit;

    final gradientHighlights = <HighlightSpan>[];
    for (final h in highlights) {
      if (h.entry.colors.length > 1 &&
          h.endInLine > unit.charStart &&
          h.startInLine < unit.charEnd) {
        gradientHighlights.add(h);
      }
    }
    if (gradientHighlights.isEmpty) {
      _gradRectCache[key] = const [];
      return const [];
    }

    // 更快点 3：用单例 TextPainter。
    final style = _baseStyle(settings);
    final tp = _gradTP;
    tp.text = TextSpan(text: sub, style: style);
    tp.layout(maxWidth: maxWidth);

    final rects = <_GradRect>[];
    final subStart = unit.charStart;

    for (final h in gradientHighlights) {
      final hs = (h.startInLine - subStart).clamp(0, sub.length);
      final he = (h.endInLine - subStart).clamp(0, sub.length);
      if (hs >= he) continue;

      final boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: hs, extentOffset: he),
      );
      final colors =
          h.entry.colors.map((c) => Color(c)).toList(growable: false);
      for (final box in boxes) {
        rects.add(_GradRect(
          Rect.fromLTRB(box.left, box.top, box.right, box.bottom),
          colors,
        ));
      }
    }

    if (_gradRectCache.length > 256) _gradRectCache.clear();
    _gradRectCache[key] = rects;
    return rects;
  }

  /// 耗电 4 / 更快点 1：spans 缓存。
  List<InlineSpan> _buildUnitSpans(
    int unitIdx,
    RenderUnit unit,
    String sub,
    ReaderSettings settings,
  ) {
    final hit = _spansCache[unitIdx];
    if (hit != null) return hit;

    final spans = _doBuildUnitSpans(unit, sub, settings);
    if (_spansCache.length > 256) _spansCache.clear();
    _spansCache[unitIdx] = spans;
    return spans;
  }

  List<InlineSpan> _doBuildUnitSpans(
    RenderUnit unit,
    String sub,
    ReaderSettings settings,
  ) {
    final base = _baseStyle(settings);
    if (sub.isEmpty) return [TextSpan(text: ' ', style: base)];

    final highlights = _highlightsForLine(unit.lineIndex);
    if (highlights.isEmpty) return [TextSpan(text: sub, style: base)];

    final subStart = unit.charStart;
    final subEnd = unit.charEnd;
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final h in highlights) {
      if (h.endInLine <= subStart || h.startInLine >= subEnd) continue;
      final hs = (h.startInLine - subStart).clamp(0, sub.length);
      final he = (h.endInLine - subStart).clamp(0, sub.length);
      if (hs >= he) continue;
      if (hs < cursor) continue;

      if (hs > cursor) {
        spans.add(TextSpan(text: sub.substring(cursor, hs), style: base));
      }
      final entry = h.entry;
      final hlText = sub.substring(hs, he);
      if (entry.colors.length > 1) {
        spans.add(TextSpan(
          text: hlText,
          style: base.copyWith(color: Color(entry.textColor)),
        ));
      } else {
        spans.add(TextSpan(
          text: hlText,
          style: base.copyWith(
            color: Color(entry.textColor),
            backgroundColor: Color(entry.colors.first),
          ),
        ));
      }
      cursor = he;
    }
    if (cursor < sub.length) {
      spans.add(TextSpan(text: sub.substring(cursor), style: base));
    }
    return spans;
  }

  Widget _buildUnitSelectionOverlay(int unitIdx, RenderUnit unit) {
    final sel = _sel;
    if (sel == null) return const SizedBox.shrink();
    final n = sel.normalized();
    if (unit.lineIndex < n.startLine || unit.lineIndex > n.endLine) {
      return const SizedBox.shrink();
    }
    final line = _lines[unit.lineIndex];
    final subStart = unit.charStart;
    final subEnd = unit.charEnd;

    int selStart;
    int selEnd;
    if (n.startLine == n.endLine) {
      selStart = n.startOffset;
      selEnd = n.endOffset;
    } else if (unit.lineIndex == n.startLine) {
      selStart = n.startOffset;
      selEnd = line.length;
    } else if (unit.lineIndex == n.endLine) {
      selStart = 0;
      selEnd = n.endOffset;
    } else {
      selStart = 0;
      selEnd = line.length;
    }
    final ovStart = selStart > subStart ? selStart : subStart;
    final ovEnd = selEnd < subEnd ? selEnd : subEnd;
    if (ovStart >= ovEnd) return const SizedBox.shrink();

    final ctx = _unitKeys[unitIdx]?.currentContext;
    if (ctx == null) return const SizedBox.shrink();
    final rp = ctx.findRenderObject();
    if (rp is! RenderParagraph) return const SizedBox.shrink();

    final uStart = ovStart - subStart;
    final uEnd = ovEnd - subStart;
    final boxes = rp.getBoxesForSelection(
      TextSelection(baseOffset: uStart, extentOffset: uEnd),
    );
    if (boxes.isEmpty) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            for (final box in boxes)
              Positioned(
                left: box.left,
                top: box.top,
                width: box.right - box.left,
                height: box.bottom - box.top,
                child: Container(color: _selectionBg),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatButton({
    required double x,
    required double y,
    required IconData icon,
    required Size size,
    required ReaderSettings settings,
  }) {
    final btnSize = 50.0 * settings.buttonScale;
    final left = x * size.width - btnSize / 2;
    final top = y * size.height - btnSize / 2;

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Opacity(
          opacity: settings.buttonOpacity,
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

  // ==================== 手柄渲染 ====================

  List<Widget> _buildHandles(ReaderSettings settings) {
    if (_sel == null) return const [];
    final pos = _handlePositions();
    if (pos == null) return const [];

    const trapW = 22.0;
    const trapH = 32.0;
    final color = Theme.of(context).colorScheme.primary;

    var leftPos = pos.left;
    var rightPos = pos.right;

    if (_draggingHandle == 1 && _dragHandlePos != null) {
      leftPos = _dragHandlePos!;
    } else if (_draggingHandle == 2 && _dragHandlePos != null) {
      rightPos = _dragHandlePos!;
    } else {
      final dx = (rightPos.dx - leftPos.dx).abs();
      if (dx < 10 && (rightPos.dy - leftPos.dy).abs() < 2) {
        final mid = (leftPos.dx + rightPos.dx) / 2;
        leftPos = Offset(mid - 10, leftPos.dy);
        rightPos = Offset(mid + 10, rightPos.dy);
      }
    }

    final safeTop = MediaQuery.of(context).padding.top;
    final screenH = MediaQuery.of(context).size.height;

    Widget handle(Offset globalPos, int which) {
      final isLeft = which == 1;
      final textTopY = globalPos.dy;
      final textBottomY = globalPos.dy + settings.fontSize;

      final bottomOverflow = textBottomY + trapH + 4 > screenH;

      final double topPos;
      final bool flip;

      if (bottomOverflow) {
        topPos = textTopY - safeTop - trapH;
        flip = true;
      } else {
        topPos = textBottomY - safeTop;
        flip = false;
      }

      final double left = isLeft ? globalPos.dx - trapW : globalPos.dx;

      return Positioned(
        left: left,
        top: topPos,
        width: trapW,
        height: trapH,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            if (isLeft) {
              _startDragLeft(d.globalPosition);
            } else {
              _startDragRight(d.globalPosition);
            }
          },
          onPanUpdate: (d) {
            if (_draggingHandle != which) return;
            final offset = _dragHandleOffset ?? Offset.zero;
            final handleLogic = d.globalPosition - offset;
            setState(() => _dragHandlePos = handleLogic);
            _updateSelectionFromDrag(handleLogic);
          },
          onPanEnd: (_) {
            setState(() {
              _draggingHandle = 0;
              _dragHandlePos = null;
              _dragHandleOffset = null;
              _hBarVisible = true;
            });
          },
          child: CustomPaint(
            painter: _TrapezoidPainter(
              color: color,
              isLeft: isLeft,
              flip: flip,
            ),
          ),
        ),
      );
    }

    return [handle(leftPos, 1), handle(rightPos, 2)];
  }

  // ==================== 弹窗渲染 ====================

  Widget _buildHBar(ReaderSettings settings, Size size) {
    final sel = _sel;
    if (sel == null) return const SizedBox.shrink();
    final n = sel.normalized();

    final startPos = _posOfCharLeft(n.startLine, n.startOffset);
    final endPos = _posOfCharLeft(n.endLine, n.endOffset);
    if (startPos == null || endPos == null) {
      return const SizedBox.shrink();
    }

    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final topAreaH = size.height - safeTop - safeBottom;

    const approxW = 260.0;
    const approxH = 150.0;

    final selTop = startPos.dy;
    final selBottom =
        endPos.dy + settings.fontSize * kReaderLineHeightFactor;

    final midY = (selTop + selBottom) / 2;
    final screenMid = safeTop + topAreaH / 2;
    final showBelow = midY < screenMid;

    double top;
    if (showBelow) {
      top = selBottom - safeTop + 24;
    } else {
      top = selTop - safeTop - approxH - 8;
    }
    top = top.clamp(4.0, topAreaH - approxH - 4);

    double left = startPos.dx - 8;
    if (left + approxW > size.width - 4) {
      left = size.width - approxW - 4;
    }
    if (left < 4) left = 4;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
        child: Container(
          width: approxW,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      final t = _selectedText();
                      if (t.isEmpty) return;
                      Clipboard.setData(ClipboardData(text: t));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _selectedText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const Divider(height: 6),
              _buildColorRow(0, 10),
              const SizedBox(height: 4),
              _buildColorRow(10, 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColorRow(int from, int to) {
    final palette = ref.read(readerPaletteProvider);
    final list =
        palette.where((p) => p.index >= from && p.index < to).toList();
    if (list.isEmpty) return const SizedBox.shrink();

    const tileW = 44.0;
    const tileH = 40.0;

    return SizedBox(
      height: tileH,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: list.length,
        itemBuilder: (ctx, i) {
          final p = list[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: GestureDetector(
              onTap: () {
                final word = _selectedText();
                if (word.isEmpty) return;
                _applyHighlight(word, p);
              },
              onLongPress: () {
                _clearSelection();
                openPaletteEdit(context, p.index);
              },
              child: Container(
                width: tileW,
                height: tileH,
                decoration: BoxDecoration(
                  color: p.isGradient ? null : Color(p.colors.first),
                  gradient: p.isGradient
                      ? LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: p.colors
                              .map((c) => Color(c))
                              .toList(growable: false),
                        )
                      : null,
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(p.textColor),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        },
      ),
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
      groupId: palette.defaultGroupId,
    );
    ref.read(readerHighlightsProvider.notifier).addOrReplace(fileKey, entry);

    final newHighlights =
        ref.read(readerHighlightsProvider)[fileKey] ?? const [];
    setState(() {
      _highlights = newHighlights;
      _highlightsRevision++;
      _rebuildHighlightAc();
      _sel = null;
      _hBarVisible = false;
      _spansCache.clear();
      _gradRectCache.clear();
      _pageHighlightCache = {};
      _pageHighlightCacheForPage = -1;
      _pageHighlightCacheForRevision = -1;
      _lastHighlightQueryLine = -1;
      _lastHighlightQueryResult = const [];
    });
  }
}

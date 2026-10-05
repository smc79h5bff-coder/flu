
// reader_screen.dart
import '../file_browser/presentation/line_editor_screen.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../preprocessing/application/aho_corasick.dart';
import '../preprocessing/application/encoding_detector.dart';
import '../preprocessing/domain/encoding_type.dart';
import 'reader_load_log.dart';
import 'reader_loupe.dart';
import 'reader_models.dart';
import 'reader_pagination.dart';
import 'reader_panels.dart';
import 'reader_repository.dart';
import 'regex_highlight.dart';
import 'reader_scroll_view.dart';
import 'reader_search_provider.dart';
import 'reader_search_screen.dart';

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

/// 拖动状态（手柄 + 放大镜用）。null 表示不在拖动。
class _DragInfo {
  const _DragInfo({
    required this.handle,
    required this.handlePos,
    this.handleOffset,
  });

  /// 1 = 左手柄，2 = 右手柄。
  final int handle;

  /// 手柄的逻辑位置（global 坐标）。
  final Offset handlePos;

  /// 手指跟手柄逻辑位置的偏移（拖动开始时定下，之后固定）。
  final Offset? handleOffset;
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

// ==================== 垃圾桶图标（自定义绘制） ====================

class _TrashIconPainter extends CustomPainter {
  _TrashIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale, scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final thick = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(const Offset(3, 5), const Offset(21, 5), thick);

    final body = Path()
      ..moveTo(19, 9)
      ..lineTo(19, 20)
      ..arcToPoint(
        const Offset(17, 22),
        radius: const Radius.circular(2),
        clockwise: true,
      )
      ..lineTo(7, 22)
      ..arcToPoint(
        const Offset(5, 20),
        radius: const Radius.circular(2),
        clockwise: true,
      )
      ..lineTo(5, 9);
    canvas.drawPath(body, stroke);

    final handle = Path()
      ..moveTo(8, 5)
      ..lineTo(8, 3)
      ..arcToPoint(
        const Offset(10, 1),
        radius: const Radius.circular(2),
        clockwise: true,
      )
      ..lineTo(14, 1)
      ..arcToPoint(
        const Offset(16, 3),
        radius: const Radius.circular(2),
        clockwise: true,
      )
      ..lineTo(16, 5);
    canvas.drawPath(handle, stroke);

    canvas.drawLine(const Offset(10, 13), const Offset(14, 17), stroke);
    canvas.drawLine(const Offset(14, 13), const Offset(10, 17), stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_TrashIconPainter old) => old.color != color;
}

// ==================== 渐变矩形 ====================

class _GradRect {
  const _GradRect(this.rect, this.colors, this.stops);
  final Rect rect;
  final List<Color> colors;
  final List<double> stops;
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

  /// filePaths 的可变副本。删除文件后从这里移除。
  late List<String> _filePaths;

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

  /// 滚动模式下是否有选中文字。用于禁用/淡出悬浮按钮，
  /// 避免按钮盖住底部选区操作栏导致点不到。
  bool _scrollSelectionActive = false;

  final GlobalKey<ReaderScrollViewState> _scrollViewKey = GlobalKey();

  /// 上一次看到的阅读模式。用于检测用户切模式。
  late int _lastSeenMode;

  /// 底部悬浮提示（跳文件 / 删除反馈）。同一时间只显示一条。
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;

  // ==================== 高亮（页级 AC 匹配） ====================

  List<HighlightEntry> _highlights = const [];
  AhoCorasick? _highlightAc;
  Map<int, HighlightEntry> _highlightEntryByPattern = const {};
  List<HighlightEntry> _regexHighlights = const [];
  int _highlightsRevision = 0;

  Map<int, List<HighlightSpan>> _pageHighlightCache = {};
  int _pageHighlightCacheForPage = -1;
  int _pageHighlightCacheForRevision = -1;

  // ★ 改动1：按页码缓存的高亮匹配结果（翻回来直接用）
  final Map<int, Map<int, List<HighlightSpan>>> _pageHighlightCacheMap = {};
  int _pageHighlightCacheMapRevision = -1;

  // ★ 改动1：按页码缓存的页面预览文本
  final Map<int, String> _previewCache = {};
  int _previewCacheRevision = -1;

  /// 更快点 4：`_highlightsForLine` memo。
  int _lastHighlightQueryLine = -1;
  List<HighlightSpan> _lastHighlightQueryResult = const [];

  int _lastSearchPosForHighlight = -1;
  int _lastSeenSearchPos = -1;

  /// "当前搜索命中"的临时高亮条目（粉色）。
  static final HighlightEntry _searchHitEntry = HighlightEntry(
    id: '__search_hit__',
    keyword: '',
    colors: const [0xFFFF4081],
    stops: const [0.0],
    angle: 0.0,
    textColor: 0xFFFFFFFF,
    createdAt: 0,
  );

  // ==================== 手势 / 选区 ====================

  final GlobalKey _contentKey = GlobalKey();
  final Map<int, GlobalKey> _unitKeys = <int, GlobalKey>{};
  int _lastUnitStart = -1;
  int _lastUnitEnd = -1;

  /// 耗电 4 / 更快点 1：每页 spans 缓存。key = unitIdx。
  final Map<int, List<InlineSpan>> _spansCache = {};

  // 渐变矩形缓存
  final Map<String, List<_GradRect>> _gradRectCache = {};
  // ★ 改动6：删掉了 _gradCacheFontSize / _gradCacheFontWeight / _gradCacheWidth

  /// 更快点 3：渐变测量用 TextPainter 单例。
  static final TextPainter _gradTP = TextPainter(
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.left,
  );

  // ---- 选区状态：走 ValueNotifier，拖动时不动主内容 ----

  final ValueNotifier<_SelectionRange?> _selNotifier =
      ValueNotifier<_SelectionRange?>(null);

  final ValueNotifier<_DragInfo?> _dragNotifier =
      ValueNotifier<_DragInfo?>(null);

  _SelectionRange? get _sel => _selNotifier.value;
  set _sel(_SelectionRange? v) => _selNotifier.value = v;

  int get _draggingHandle => _dragNotifier.value?.handle ?? 0;
  Offset? get _dragHandlePos => _dragNotifier.value?.handlePos;
  Offset? get _dragHandleOffset => _dragNotifier.value?.handleOffset;

  void _setDragState({
    required int handle,
    required Offset? handlePos,
    Offset? handleOffset,
  }) {
    if (handle == 0 || handlePos == null) {
      _dragNotifier.value = null;
    } else {
      _dragNotifier.value = _DragInfo(
        handle: handle,
        handlePos: handlePos,
        handleOffset: handleOffset,
      );
    }
  }

  void _updateDragPos(Offset pos) {
    final cur = _dragNotifier.value;
    if (cur == null) return;
    _dragNotifier.value = _DragInfo(
      handle: cur.handle,
      handlePos: pos,
      handleOffset: cur.handleOffset,
    );
  }

  bool _hBarVisible = false;

  int _selVersion = 0;
  int _lastOverlayVersion = 0;

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
    _filePaths = List<String>.from(widget.filePaths);
    _fileIndex = _filePaths.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, _filePaths.length - 1);
    WidgetsBinding.instance.addObserver(this);
    _lastSeenMode = ref.read(readerSettingsProvider).readerMode;
  }

  @override
  void deactivate() {
    _saveProgressNow();
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    _resumePrecisionTimer?.cancel();
    _progressSaveTimer?.cancel();
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;

    _paginator?.removeListener(_onPaginatorChanged);
    _paginator?.dispose();
    _selNotifier.dispose();
    _dragNotifier.dispose();
    super.dispose();
  }

  // ==================== 后台/锁屏暂停 ====================

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
        '${s.pageBottomSafePx}|'
        '${_manualEncoding?.name ?? "auto"}';
  }

  Future<void> _ensureLoaded() async {
    if (_filePaths.isEmpty) return;
    if (_viewportSize.width < 10 || _viewportSize.height < 10) return;

    final path = _filePaths[_fileIndex];
    final key = _loadKeyFor(path);
    if (_lastLoadedKey == key) return;
    _lastLoadedKey = key;

    final log = ReaderLoadLog.instance;
    log.start('阅读器加载');
    log.info('path = $path');
    log.info(
        'viewport = ${_viewportSize.width.toStringAsFixed(1)} × ${_viewportSize.height.toStringAsFixed(1)}');

    _paginator?.removeListener(_onPaginatorChanged);
    _paginator?.dispose();
    _paginator = null;
    log.mark('dispose 旧分页器');

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
    log.mark('setState(loading=true)');

    _invalidateAllCaches();
    log.mark('清空缓存');

    try {
      final bytes = await File(path).readAsBytes();
      log.mark('File.readAsBytes');
      log.info(
          'bytes = ${bytes.length}  (${(bytes.length / 1024).toStringAsFixed(1)} KB)');

      final encoding = _manualEncoding ?? EncodingDetector.detect(bytes);
      _currentEncoding = encoding;
      log.mark('EncodingDetector.detect');
      log.info('encoding = ${encoding.label}');

      final rawText = EncodingDetector.decodeChunked(bytes, encoding);
      log.mark('decodeChunked');
      log.info('rawText chars = ${rawText.length}');

      final text = _normalizeForReading(rawText);
      log.mark('_normalizeForReading');
      log.info('normalized chars = ${text.length}');

      if (!mounted) {
        log.info('❌ unmounted，中止');
        return;
      }
      if (_lastLoadedKey != key) {
        log.info('❌ key 变了，中止');
        return;
      }

      final settings = ref.read(readerSettingsProvider);
      log.mark('读 readerSettings');
      log.info(
          'fontSize=${settings.fontSize} fontWeight=${settings.fontWeight} pageBottomSafePx=${settings.pageBottomSafePx}');

      final paginator = ReaderPaginator(
        text: text,
        viewportWidth: _viewportSize.width,
        viewportHeight: _viewportSize.height,
        fontSize: settings.fontSize,
        fontWeight: settings.fontWeight,
        pageBottomSafePx: settings.pageBottomSafePx,
      );
      log.mark('new ReaderPaginator');

      paginator.addListener(_onPaginatorChanged);
      log.mark('addListener');

      paginator.start();
      log.mark('paginator.start() 返回');
      log.info('pages = ${paginator.result?.pageCount}');
      log.info('renderUnits = ${paginator.result?.renderUnits.length}');

      final split = splitLinesWithOffsets(text);
      log.mark('splitLinesWithOffsets');
      log.info('lines = ${split.lines.length}');

      final fileKey = readerFileKey(path);
      ref.read(readerHighlightsProvider.notifier).ensureLoaded(fileKey);
      log.mark('readerHighlights.ensureLoaded');

      final local = ref.read(readerHighlightsProvider)[fileKey] ?? const [];
      final global = ref.read(readerGlobalHighlightsProvider);
      final highlights = [...local, ...global];
      log.mark('读高亮');
      log.info('local=${local.length} global=${global.length}');

      final progress = ref.read(readerProgressProvider)[fileKey];
      log.mark('读 readerProgress');

      final startPage = progress != null
          ? findPageForOffset(paginator.result!, progress.charOffset)
              .clamp(0, paginator.result!.pageCount - 1)
          : 0;
      log.mark('findPageForOffset');
      log.info('startPage=$startPage  progress=${progress?.charOffset}');

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
      log.mark('setState(loading=false)');

      final searchState = ref.read(readerSearchProvider);
      if (searchState.fileKey.isNotEmpty &&
          searchState.fileKey != readerFileKey(path)) {
        ref.read(readerSearchProvider.notifier).clear();
      }
      log.mark('清搜索状态（如果需要）');

      _rebuildHighlightAc();
      log.mark('_rebuildHighlightAc');

      paginator.notifyVisiblePage(startPage);
      log.mark('notifyVisiblePage');

      _syncPagePreview();
      log.mark('_syncPagePreview');

      log.end('阅读器加载');
    } catch (e, st) {
      log.mark('❌ 异常');
      log.info('error = $e');
      log.info('stack = $st');
      log.end('阅读器加载（失败）');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ★ 改动2：_invalidateAllCaches 加清空新缓存
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
    _pageHighlightCacheMap.clear();
    _pageHighlightCacheMapRevision = -1;
    _previewCache.clear();
    _previewCacheRevision = -1;
  }

  static String _normalizeForReading(String text) {
    final t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final out = <String>[];
    for (final line in t.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      out.add('\u3000\u3000$trimmed');
    }
    return out.join('\n');
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
    final regexList = <HighlightEntry>[];
    for (final h in _highlights) {
      if (h.keyword.isEmpty) continue;
      if (h.isRegex) {
        regexList.add(h);
        continue;
      }
      patterns.add(h.keyword);
      entryByPattern[patterns.length - 1] = h;
    }
    _regexHighlights = regexList;
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

  // ★ 改动3：_ensurePageHighlightCache 按页缓存
  void _ensurePageHighlightCache() {
    if (_pageHighlightCacheMapRevision != _highlightsRevision) {
      _pageHighlightCacheMap.clear();
      _pageHighlightCacheMapRevision = _highlightsRevision;
    }

    final cached = _pageHighlightCacheMap[_currentPage];
    if (cached != null) {
      _pageHighlightCache = cached;
      _pageHighlightCacheForPage = _currentPage;
      _pageHighlightCacheForRevision = _highlightsRevision;
      return;
    }

    _rebuildPageHighlightCache();
    _pageHighlightCacheMap[_currentPage] = _pageHighlightCache;
    if (_pageHighlightCacheMap.length > 32) {
      _pageHighlightCacheMap.remove(_pageHighlightCacheMap.keys.first);
    }
  }

  void _rebuildPageHighlightCache() {
    _pageHighlightCacheForPage = _currentPage;
    _pageHighlightCacheForRevision = _highlightsRevision;

    final p = _paginator;
    if (p?.result == null ||
        (_highlightAc == null && _regexHighlights.isEmpty)) {
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

    if (_highlightAc != null) {
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
    }

    if (_regexHighlights.isNotEmpty) {
      final regexByLine = matchRegexOnPage(
        pageText: pageText,
        lineStartInBuf: lineStartInBuf,
        lineIdxAtPos: lineIdxAtPos,
        regexEntries: _regexHighlights,
      );
      for (final e in regexByLine.entries) {
        (byLine[e.key] ??= <HighlightSpan>[]).addAll(e.value);
      }
    }

    for (final i in byLine.keys.toList()) {
      final list = byLine[i]!;
      list.sort((a, b) {
        final byStart = a.startInLine.compareTo(b.startInLine);
        if (byStart != 0) return byStart;
        final aR = a.entry.isRegex;
        final bR = b.entry.isRegex;
        if (aR != bR) return aR ? -1 : 1;
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

  List<HighlightSpan> _highlightsForLine(int lineIdx) {
    final state = ref.read(readerSearchProvider);
    final searchPos = state.currentPos;

    if (_lastHighlightQueryLine == lineIdx &&
        _lastSearchPosForHighlight == searchPos) {
      return _lastHighlightQueryResult;
    }

    _ensurePageHighlightCache();
    final userHl = _pageHighlightCache[lineIdx] ?? const <HighlightSpan>[];
    final merged = _mergeWithSearchHit(lineIdx, userHl, state);

    _lastHighlightQueryLine = lineIdx;
    _lastSearchPosForHighlight = searchPos;
    _lastHighlightQueryResult = merged;
    return merged;
  }

  List<HighlightSpan> _mergeWithSearchHit(
    int lineIdx,
    List<HighlightSpan> userHl,
    ReaderSearchState state,
  ) {
    if (state.currentPos < 0 || state.currentPos >= state.hits.length) {
      return userHl;
    }
    final hit = state.hits[state.currentPos];
    if (hit.lineIndex != lineIdx) return userHl;

    final ss = hit.startInLine;
    final se = hit.endInLine;

    final filtered = <HighlightSpan>[];
    for (final h in userHl) {
      if (h.endInLine <= ss || h.startInLine >= se) {
        filtered.add(h);
      }
    }
    filtered.add(HighlightSpan(
      startInLine: ss,
      endInLine: se,
      entry: _searchHitEntry,
    ));
    filtered.sort((a, b) => a.startInLine.compareTo(b.startInLine));
    return filtered;
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
    if (p?.result == null || _filePaths.isEmpty) return;
    final path = _filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final offset = pageStartOffset(p!.result!, _currentPage);
    ref.read(readerProgressProvider.notifier).set(fileKey, offset);
  }

  // ★ 改动4：_syncPagePreview 按页缓存
  void _syncPagePreview() {
    if (_previewCacheRevision != _highlightsRevision) {
      _previewCache.clear();
      _previewCacheRevision = _highlightsRevision;
    }

    final cached = _previewCache[_currentPage];
    if (cached != null) {
      ref.read(readerPagePreviewProvider.notifier).state = cached;
      return;
    }

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
    final text = buf.toString();

    if (_previewCache.length > 64) {
      _previewCache.remove(_previewCache.keys.first);
    }
    _previewCache[_currentPage] = text;
    ref.read(readerPagePreviewProvider.notifier).state = text;
  }

  // ==================== 翻页 ====================

  void _nextPage() {
    final p = _paginator;
    if (p == null || p.result == null) return;
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    final maxPage = p.result!.pageCount - 1;
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
    if (p == null || p.result == null) return;
    if (_currentPage <= 0) return;
    _clearSelection();
    setState(() =>
        _currentPage = (_currentPage - 1).clamp(0, p.result!.pageCount - 1));
    _invalidatePageCaches();
    p.notifyVisiblePage(_currentPage);
    _saveProgress();
    _syncPagePreview();
  }

  void _jumpToPage(int page) {
    final p = _paginator;
    if (p == null || p.result == null) return;
    final maxPage = p.result!.pageCount - 1;
    final pg = page.clamp(0, maxPage);
    _clearSelection();
    setState(() => _currentPage = pg);
    _invalidatePageCaches();
    p.notifyVisiblePage(pg);
    _saveProgress();
    _syncPagePreview();
  }

  // ★ 改动8：_invalidatePageCaches 别全清
  void _invalidatePageCaches() {
    // 不再清 _spansCache 和 _gradRectCache，
    // 它们的 key 里含 unitIdx，翻页时自然用新的 unitIdx，翻回来还能命中。
    _lastHighlightQueryLine = -1;
    _lastHighlightQueryResult = const [];
  }

  // ==================== 切文件 ====================

  Future<void> _prevFile() async {
    if (_fileIndex <= 0) {
      _showToast('已经是第一个文件');
      return;
    }
    _saveProgressNow();
    _clearSelection();
    _manualEncoding = null;
    setState(() => _fileIndex--);
    _showToast(
      '第 ${_fileIndex + 1}/${_filePaths.length} 个 · '
      '${_filePaths[_fileIndex].split('/').last}',
    );
    await _ensureLoaded();
  }

  Future<void> _nextFile() async {
    if (_fileIndex >= _filePaths.length - 1) {
      _showToast('已经是最后一个文件');
      return;
    }
    _saveProgressNow();
    _clearSelection();
    _manualEncoding = null;
    setState(() => _fileIndex++);
    _showToast(
      '第 ${_fileIndex + 1}/${_filePaths.length} 个 · '
      '${_filePaths[_fileIndex].split('/').last}',
    );
    await _ensureLoaded();
  }

  void _closeFile() {
    _saveProgressNow();
    _clearSelection();
    final path =
        _filePaths.isEmpty ? null : _filePaths[_fileIndex];
    Navigator.of(context).pop(path);
  }

  void _showToast(String msg) {
    if (!mounted) return;
    _toastTimer?.cancel();
    _toastEntry?.remove();
    _toastEntry = null;

    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        right: 0,
        bottom: 80,
        child: IgnorePointer(
          child: Center(
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              color: Colors.black.withValues(alpha: 0.82),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  msg,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    _toastEntry = entry;
    _toastTimer = Timer(const Duration(milliseconds: 1600), () {
      if (identical(_toastEntry, entry)) {
        entry.remove();
        _toastEntry = null;
      }
    });
  }

  Future<void> _exportLoadLog() async {
    final log = ReaderLoadLog.instance;
    if (log.isEmpty) {
      _showToast('暂无日志');
      return;
    }

    final path = _filePaths.isEmpty ? '' : _filePaths[_fileIndex];
    final fileName = path.split('/').last;
    final ts = DateTime.now().millisecondsSinceEpoch;

    final header = StringBuffer()
      ..writeln('═══════════════════════════════════════════════════════')
      ..writeln('阅读器加载日志')
      ..writeln('═══════════════════════════════════════════════════════')
      ..writeln('文件：$fileName')
      ..writeln('路径：$path')
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('总条数：${log.entries.length}')
      ..writeln('═══════════════════════════════════════════════════════')
      ..writeln();

    final bytes = Uint8List.fromList(
      utf8.encode(header.toString() + log.dump()),
    );

    try {
      final out = await FilePicker.saveFile(
        fileName: 'reader-log-$ts.txt',
        bytes: bytes,
        mimeType: 'text/plain',
        dialogTitle: '保存阅读器日志',
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (out != null && mounted) {
        _showToast('日志已导出');
      }
    } catch (e) {
      if (mounted) _showToast('导出失败：$e');
    }
  }

  Future<void> _deleteCurrentFile() async {
    if (_filePaths.isEmpty) return;
    final path = _filePaths[_fileIndex];
    final fileName = path.split('/').last;

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除文件？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('将删除：'),
            const SizedBox(height: 4),
            Text(
              fileName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              path,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '删除后无法恢复。',
              style: TextStyle(color: Colors.red),
            ),
          ],
        ),
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

    try {
      await File(path).delete();
    } catch (e) {
      if (!mounted) return;
      _showToast('删除失败：$e');
      return;
    }
    if (!mounted) return;

    ref.read(readerDeletedPathsProvider.notifier).state = [
      ...ref.read(readerDeletedPathsProvider),
      path,
    ];

    setState(() {
      _filePaths.removeAt(_fileIndex);
    });

    if (_filePaths.isEmpty) {
      _showToast('目录里的文件已删完，返回文件浏览器');
      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    var nextIndex = _fileIndex;
    var hitEnd = false;
    if (nextIndex >= _filePaths.length) {
      nextIndex = _filePaths.length - 1;
      hitEnd = true;
    }

    _clearSelection();
    _manualEncoding = null;
    _lastLoadedKey = null;
    setState(() {
      _fileIndex = nextIndex;
    });

    final nextName = _filePaths[nextIndex].split('/').last;
    _showToast(
      hitEnd ? '已到最后，跳到：$nextName' : '已删除，跳到：$nextName',
    );

    await _ensureLoaded();
  }

  // ==================== 顶部菜单 ====================

  void _showTopMenu() {
    _clearSelection();
    _menuOpen = true;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _buildTopMenuSheet(ctx),
    ).then((_) {
      _menuOpen = false;
    });
  }

  Widget _buildTopMenuSheet(BuildContext ctx) {
    final p = _paginator?.result;
    final pct = p == null
        ? '-'
        : '${((_currentPage + 1) / p.pageCount * 100).toStringAsFixed(1)}%';

    final path = _filePaths.isEmpty ? '' : _filePaths[_fileIndex];
    final fileName = path.split('/').last;

    final encodingLabel = _currentEncoding?.label ?? '未识别';

    Widget menuButton({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      Color? color,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: SingleChildScrollView(
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
              const SizedBox(height: 8),

              ListTile(
                isThreeLine: true,
                leading: const Icon(Icons.description_outlined),
                title: Text(
                  fileName.isEmpty ? '（未命名）' : fileName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
                onLongPress: () {
                  if (path.isEmpty) return;
                  Clipboard.setData(ClipboardData(text: path));
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                      content: Text('路径已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              const Divider(height: 1),

              Row(
                children: [
                  Expanded(
                    child: menuButton(
                      icon: Icons.tune,
                      label: '进度 $pct',
                      onTap: () {
                        Navigator.pop(ctx);
                        _showProgressSlider();
                      },
                    ),
                  ),
                  Expanded(
                    child: menuButton(
                      icon: Icons.search,
                      label: '查找',
                      onTap: () {
                        Navigator.pop(ctx);
                        _openFind();
                      },
                    ),
                  ),
                ],
              ),

              Row(
                children: [
                  Expanded(
                    child: menuButton(
                      icon: Icons.bookmark_add_outlined,
                      label: '加书签',
                      onTap: () {
                        Navigator.pop(ctx);
                        _addBookmark();
                      },
                    ),
                  ),
                  Expanded(
                    child: menuButton(
                      icon: Icons.bookmarks_outlined,
                      label: '书签与高亮',
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _openManager();
                      },
                    ),
                  ),
                ],
              ),
              const Divider(height: 1),

              Row(
                children: [
                  Expanded(
                    child: menuButton(
                      icon: Icons.view_list,
                      label: '行编辑',
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _openLineEditor();
                      },
                    ),
                  ),
                  Expanded(
                    child: menuButton(
                      icon: Icons.translate,
                      label: '编码 $encodingLabel',
                      onTap: () {
                        Navigator.pop(ctx);
                        _showEncodingPicker();
                      },
                    ),
                  ),
                ],
              ),

              Row(
                children: [
                  Expanded(
                    child: menuButton(
                      icon: Icons.article_outlined,
                      label: '导出加载日志',
                      onTap: () {
                        Navigator.pop(ctx);
                        _exportLoadLog();
                      },
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
              const Divider(height: 1),

              Row(
                children: [
                  Expanded(
                    child: menuButton(
                      icon: Icons.settings,
                      label: '设置',
                      onTap: () {
                        Navigator.pop(ctx);
                        showReaderSettingsSheet(context);
                      },
                    ),
                  ),
                  Expanded(
                    child: menuButton(
                      icon: Icons.close,
                      label: '关闭文件',
                      color: Colors.red,
                      onTap: () {
                        Navigator.pop(ctx);
                        _closeFile();
                      },
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
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
    final path = _filePaths[_fileIndex];
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

  Future<void> _openFind() async {
    if (_text == null || _filePaths.isEmpty) return;
    final path = _filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    _clearSelection();

    final state = ref.read(readerSearchProvider);
    final sameFile = state.fileKey == fileKey;
    if (!sameFile) {
      ref.read(readerSearchProvider.notifier).clear();
    }

    final result = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (_) => ReaderSearchScreen(
          text: _text!,
          fileKey: fileKey,
          initialQuery: sameFile ? state.query : '',
          initialRegex: sameFile ? state.regex : false,
          initialCaseSensitive: sameFile ? state.caseSensitive : false,
        ),
      ),
    );
    if (!mounted) return;
    if (result != null) {
      final p = _paginator?.result;
      if (p == null) return;
      final page = findPageForOffset(p, result);
      _jumpToPage(page);
    }
  }

  // ★ 改动10：_openManager 里同步清新缓存
  Future<void> _openManager() async {
    if (_filePaths.isEmpty) return;
    _clearSelection();
    final path = _filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final fileName = path.split('/').last;
    final result =
        await openBookmarkHighlightManager(context, fileKey, fileName);
    if (!mounted) return;
    if (result != null && _paginator?.result != null) {
      final page = findPageForOffset(_paginator!.result!, result);
      _jumpToPage(page);
    }

    final local = ref.read(readerHighlightsProvider)[fileKey] ?? const [];
    final global = ref.read(readerGlobalHighlightsProvider);
    final updated = [...local, ...global];
    if (mounted) {
      setState(() {
        _highlights = updated;
        _highlightsRevision++;
        _rebuildHighlightAc();
        _invalidatePageCaches();
        _pageHighlightCache = {};
        _pageHighlightCacheForPage = -1;
        _pageHighlightCacheForRevision = -1;
        _pageHighlightCacheMap.clear();
        _pageHighlightCacheMapRevision = -1;
        _previewCache.clear();
        _previewCacheRevision = -1;
      });
    }
  }

  Future<void> _openEditor() async {
    if (_filePaths.isEmpty) return;
    final path = _filePaths[_fileIndex];
    final fileName = path.split('/').last;
    _saveProgressNow();
    _clearSelection();
    await openEditorAndReturn(context, path, fileName, () {
      _lastLoadedKey = null;
      _ensureLoaded();
    });
  }

  Future<void> _openLineEditor() async {
    if (_filePaths.isEmpty) return;
    final path = _filePaths[_fileIndex];
    final fileName = path.split('/').last;
    _saveProgressNow();
    _clearSelection();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LineEditorScreen(
          filePath: path,
          fileName: fileName,
        ),
      ),
    );
    if (!mounted) return;
    _lastLoadedKey = null;
    _ensureLoaded();
  }

  // ==================== 选区 ====================

  void _clearSelection() {
    _longPressTimer?.cancel();
    _longPressFired = false;
    _movedBeyondThreshold = false;
    _pressDown = false;
    _setDragState(handle: 0, handlePos: null);
    _lastLongPressPos = null;
    _horizontalDrag = false;
    final needRepaint = _sel != null || _hBarVisible;
    _sel = null;
    if (needRepaint) {
      setState(() => _hBarVisible = false);
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
      _sel = _SelectionRange(
        startLine: pos.line,
        startOffset: offset,
        endLine: pos.line,
        endOffset: offset + 1,
      );
      _hBarVisible = false;
      _selVersion++;
      setState(() {});
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
      _sel = _SelectionRange(
        startLine: pos.line,
        startOffset: s,
        endLine: pos.line,
        endOffset: e,
      );
      _hBarVisible = false;
      _selVersion++;
      setState(() {});
      return;
    }

    _sel = _SelectionRange(
      startLine: pos.line,
      startOffset: offset,
      endLine: pos.line,
      endOffset: offset + 1,
    );
    _hBarVisible = false;
    _selVersion++;
    setState(() {});
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
      _sel = _SelectionRange(
        startLine: sel.startLine,
        startOffset: sel.startOffset,
        endLine: hit.line,
        endOffset: hit.offset,
      );
      _selVersion++;
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
      _setDragState(handle: 0, handlePos: null);
      setState(() => _hBarVisible = true);
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
          _sel = _SelectionRange(
            startLine: sel.startLine,
            startOffset: off,
            endLine: sel.startLine,
            endOffset: off + 1,
          );
          setState(() => _hBarVisible = true);
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
    _setDragState(handle: 0, handlePos: null);
  }

  void _handleLongPress() {
    final pos = _hitTest(_downPos);
    if (pos == null) return;
    _selectWordAt(pos);
  }

  void _handleTap(Offset globalPos) {
    if (_hBarVisible || _sel != null) {
      _clearSelection();
      return;
    }
    final btn = _hitFloatButton(globalPos);
    if (btn == 'prev') {
      _prevFile();
      return;
    }
    if (btn == 'next') {
      _nextFile();
      return;
    }
    if (btn == 'del') {
      _deleteCurrentFile();
      return;
    }
    if (_isInHotZone(globalPos)) {
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
    _setDragState(
      handle: 1,
      handlePos: handleLogic ?? fingerPos,
      handleOffset:
          handleLogic == null ? Offset.zero : fingerPos - handleLogic,
    );
    if (_hBarVisible) setState(() => _hBarVisible = false);
  }

  void _startDragRight(Offset fingerPos) {
    final sel = _sel;
    if (sel == null) return;
    final handleLogic = _posOfCharRight(sel.endLine, sel.endOffset);
    _setDragState(
      handle: 2,
      handlePos: handleLogic ?? fingerPos,
      handleOffset:
          handleLogic == null ? Offset.zero : fingerPos - handleLogic,
    );
    if (_hBarVisible) setState(() => _hBarVisible = false);
  }

  void _updateSelectionFromDrag(Offset handleLogic) {
    final sel = _sel;
    if (sel == null) return;
    final preferLine = _draggingHandle == 1 ? sel.startLine : sel.endLine;
    final hit = _hitTestWithBuffer(handleLogic, preferLine);
    if (hit == null) return;

    if (_draggingHandle == 1) {
      _sel = _SelectionRange(
        startLine: hit.line,
        startOffset: hit.offset,
        endLine: sel.endLine,
        endOffset: sel.endOffset,
      );
      _selVersion++;
    } else if (_draggingHandle == 2) {
      _sel = _SelectionRange(
        startLine: sel.startLine,
        startOffset: sel.startOffset,
        endLine: hit.line,
        endOffset: hit.offset,
      );
      _selVersion++;
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
        letterSpacing: 0,
        wordSpacing: 0,
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
    final searchState = ref.watch(readerSearchProvider);

    if (_lastSeenSearchPos != searchState.currentPos) {
      _lastSeenSearchPos = searchState.currentPos;
      _spansCache.clear();
    }

    if (_lastSeenMode != settings.readerMode) {
      _lastSeenMode = settings.readerMode;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _saveProgressNow();
        if (settings.readerMode == 0 && _paginator?.result != null) {
          final path = _filePaths[_fileIndex];
          final fileKey = readerFileKey(path);
          final progress = ref.read(readerProgressProvider)[fileKey];
          if (progress != null) {
            final targetPage = findPageForOffset(
              _paginator!.result!,
              progress.charOffset,
            );
            if (targetPage != _currentPage) {
              setState(() => _currentPage = targetPage);
            }
          }
        }
      });
    }

    if (_sel != null && _selVersion != _lastOverlayVersion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastOverlayVersion = _selVersion;
        setState(() {});
      });
    }

    if (!_loading &&
        !_filePaths.isEmpty &&
        _fileIndex >= 0 &&
        _fileIndex < _filePaths.length) {
      final path = _filePaths[_fileIndex];
      final currentKey = _loadKeyFor(path);
      if (_lastLoadedKey != currentKey) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _ensureLoaded();
        });
      }
    }

    return PopScope<String?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final path =
            _filePaths.isEmpty ? null : _filePaths[_fileIndex];
        Navigator.of(context).pop(path);
      },
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.noScaling,
        ),
        child: Scaffold(
          backgroundColor: Color(settings.bgColor),
          resizeToAvoidBottomInset: false,
  body: SafeArea(
  bottom: settings.respectSystemInsets,
  child: LayoutBuilder(
              builder: (ctx, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);

                final route = ModalRoute.of(context);
                final routeIsCurrent = route == null || route.isCurrent;

                if (routeIsCurrent &&
                    size.width > 10 &&
                    size.height > 10) {
                  final diff = (_viewportSize.width - size.width).abs() +
                      (_viewportSize.height - size.height).abs();
                  if (diff > 1.0) {
                    _viewportSize = size;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _ensureLoaded();
                    });
                  }
                }

                if (_filePaths.isEmpty) {
                  return const Center(child: Text('没有可读取的文件'));
                }
                if (_loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_error != null) return _buildError();

                final content = settings.readerMode == 1
                    ? _buildScrollReader(settings)
                    : (_paginator?.result == null
                        ? const SizedBox.shrink()
                        : _buildReader(settings, size));

                return Stack(
                  children: [
                    Positioned.fill(child: content),
                    ..._buildShellOverlays(settings, size),
                  ],
                );
              },
            ),
          ),
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

        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<_SelectionRange?>(
              valueListenable: _selNotifier,
              builder: (_, sel, __) => _buildSelectionOverlay(sel),
            ),
          ),
        ),

        Positioned.fill(
          child: ValueListenableBuilder<_DragInfo?>(
            valueListenable: _dragNotifier,
            builder: (_, drag, __) {
              return ValueListenableBuilder<_SelectionRange?>(
                valueListenable: _selNotifier,
                builder: (_, sel, __) {
                  return Stack(
                    children: [
                      ..._buildHandles(settings),
                      if (drag != null && sel != null)
                        _buildLoupe(settings, size, drag, sel),
                    ],
                  );
                },
              );
            },
          ),
        ),

        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Consumer(
            builder: (context, ref, _) {
              final state = ref.watch(readerSearchProvider);
              if (!state.hasSearch) return const SizedBox.shrink();
              return ReaderSearchMinibar(
                onJump: (offset) {
                  final p = _paginator?.result;
                  if (p == null) return;
                  final page = findPageForOffset(p, offset);
                  _jumpToPage(page);
                },
                onExpand: _openFind,
                onClose: () {
                  ref.read(readerSearchProvider.notifier).clear();
                },
              );
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _buildShellOverlays(ReaderSettings settings, Size size) {
    return [
      _buildHotZone(settings, size),
      if (settings.showButtons)
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _scrollSelectionActive,
            child: AnimatedOpacity(
              opacity: _scrollSelectionActive ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: Stack(
                children: [
                  _buildFloatButton(
                    style: settings.topBtnStyle,
                    bgColor: Color(settings.topBtnBgColor),
                    fgColor: Color(settings.topBtnFgColor),
                    ringColor: Color(settings.topBtnRingColor),
                    ringWidth: settings.topBtnRingWidth,
                    x: settings.topBtnX,
                    y: settings.topBtnY,
                    scale: settings.topBtnScale,
                    opacity: settings.topBtnOpacity,
                    icon: Icons.keyboard_arrow_up,
                    size: size,
                    onTap: _prevFile,
                  ),
                  _buildFloatButton(
                    style: settings.bottomBtnStyle,
                    bgColor: Color(settings.bottomBtnBgColor),
                    fgColor: Color(settings.bottomBtnFgColor),
                    ringColor: Color(settings.bottomBtnRingColor),
                    ringWidth: settings.bottomBtnRingWidth,
                    x: settings.bottomBtnX,
                    y: settings.bottomBtnY,
                    scale: settings.bottomBtnScale,
                    opacity: settings.bottomBtnOpacity,
                    icon: Icons.keyboard_arrow_down,
                    size: size,
                    onTap: _nextFile,
                  ),
                  _buildDeleteButton(settings, size),
                ],
              ),
            ),
          ),
        ),
      if (settings.readerMode == 0 && _hBarVisible && _sel != null)
        _buildHBar(settings, size),
    ];
  }

  Widget _buildScrollReader(ReaderSettings settings) {
    if (_text == null || _lines.isEmpty) {
      return const SizedBox.shrink();
    }
    final path = _filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final progress = ref.read(readerProgressProvider)[fileKey];
    final initialOffset = progress?.charOffset ?? 0;

    return ReaderScrollView(
      key: _scrollViewKey,
      text: _text!,
      lines: _lines,
      lineStarts: _lineStarts,
      settings: settings,
      initialOffset: initialOffset,
      highlights: _highlights,
      palettes: ref.watch(readerPaletteProvider),
      onProgressChanged: (offset) {
        ref.read(readerProgressProvider.notifier).set(fileKey, offset);
      },
      onHighlightAdded: (word, palette) {
        _applyHighlight(word, palette);
      },
      onPaletteEdit: (index) {
        openPaletteEdit(context, index);
      },
      onSelectionActiveChanged: (active) {
        if (_scrollSelectionActive == active) return;
        if (!mounted) return;
        setState(() => _scrollSelectionActive = active);
      },
      onTapOnShell: (pos) {
        final btn = _hitFloatButton(pos);
        if (btn == 'prev') {
          _prevFile();
          return true;
        }
        if (btn == 'next') {
          _nextFile();
          return true;
        }
        if (btn == 'del') {
          _deleteCurrentFile();
          return true;
        }
        if (_isInHotZone(pos)) {
          _showTopMenu();
          return true;
        }
        return false;
      },
    );
  }

  // ==================== 菜单热区绘制 ====================

  bool _isInHotZone(Offset globalPos) {
    final settings = ref.read(readerSettingsProvider);
    final screen = MediaQuery.of(context).size;
    final safe = MediaQuery.of(context).padding;
    final contentLeft = safe.left;
    final contentTop = safe.top;
    final contentW = screen.width - safe.left - safe.right;
    final contentH = screen.height - safe.top - safe.bottom;

    final left =
        contentLeft + (settings.hotZoneX - settings.hotZoneW / 2) * contentW;
    final top =
        contentTop + (settings.hotZoneY - settings.hotZoneH / 2) * contentH;
    final right = left + settings.hotZoneW * contentW;
    final bottom = top + settings.hotZoneH * contentH;

    return globalPos.dx >= left &&
        globalPos.dx <= right &&
        globalPos.dy >= top &&
        globalPos.dy <= bottom;
  }

  String? _hitFloatButton(Offset globalPos) {
    final settings = ref.read(readerSettingsProvider);
    if (!settings.showButtons) return null;

    final screen = MediaQuery.of(context).size;
    final safe = MediaQuery.of(context).padding;
    final contentLeft = safe.left;
    final contentTop = safe.top;
    final contentW = screen.width - safe.left - safe.right;
    final contentH = screen.height - safe.top - safe.bottom;

    bool inBtn(double x, double y, double scale) {
      final btnSize = 50.0 * scale;
      final cx = contentLeft + x * contentW;
      final cy = contentTop + y * contentH;
      final dx = globalPos.dx - cx;
      final dy = globalPos.dy - cy;
      final r = btnSize / 2 + 8;
      return dx * dx + dy * dy < r * r;
    }

    if (inBtn(settings.delBtnX, settings.delBtnY, settings.delBtnScale)) {
      return 'del';
    }
    if (inBtn(settings.topBtnX, settings.topBtnY, settings.topBtnScale)) {
      return 'prev';
    }
    if (inBtn(settings.bottomBtnX, settings.bottomBtnY,
        settings.bottomBtnScale)) {
      return 'next';
    }
    return null;
  }

  Widget _buildHotZone(ReaderSettings settings, Size size) {
    final left = (settings.hotZoneX - settings.hotZoneW / 2) * size.width;
    final top = (settings.hotZoneY - settings.hotZoneH / 2) * size.height;
    final width = settings.hotZoneW * size.width;
    final height = settings.hotZoneH * size.height;

    final touchLeft = left <= 1;
    final touchTop = top <= 1;
    final touchRight = left + width >= size.width - 1;
    final touchBottom = top + height >= size.height - 1;

    final Widget inner;
    if (!settings.hotZoneVisible) {
      inner = const SizedBox.expand();
    } else {
      final color = Color(settings.hotZoneColor)
          .withValues(alpha: settings.hotZoneOpacity.clamp(0.0, 1.0));
      if (settings.hotZoneStyle == 0) {
        inner = Container(color: color);
      } else {
        final bw = settings.hotZoneBorderWidth;
        inner = Container(
          decoration: BoxDecoration(
            border: Border(
              left: touchLeft
                  ? BorderSide.none
                  : BorderSide(color: color, width: bw),
              top: touchTop
                  ? BorderSide.none
                  : BorderSide(color: color, width: bw),
              right: touchRight
                  ? BorderSide.none
                  : BorderSide(color: color, width: bw),
              bottom: touchBottom
                  ? BorderSide.none
                  : BorderSide(color: color, width: bw),
            ),
          ),
        );
      }
    }

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(child: inner),
    );
  }

  // ==================== 选区覆盖层 ====================

  Widget _buildSelectionOverlay(_SelectionRange? sel) {
    if (sel == null) return const SizedBox.shrink();

    final p = _paginator;
    if (p?.result == null) return const SizedBox.shrink();
    final result = p!.result!;
    final range = pageUnitRange(result, _currentPage);
    final n = sel.normalized();

    final contentCtx = _contentKey.currentContext;
    if (contentCtx == null) return const SizedBox.shrink();
    final contentBox = contentCtx.findRenderObject() as RenderBox?;
    if (contentBox == null) return const SizedBox.shrink();
    final contentOrigin = contentBox.localToGlobal(Offset.zero);

    final rects = <Rect>[];
    for (var unitIdx = range.startUnit; unitIdx < range.endUnit; unitIdx++) {
      final u = result.renderUnits[unitIdx];
      if (u.lineIndex < n.startLine || u.lineIndex > n.endLine) continue;

      final line = _lines[u.lineIndex];
      final subStart = u.charStart;
      final subEnd = u.charEnd;

      int selStart;
      int selEnd;
      if (n.startLine == n.endLine) {
        selStart = n.startOffset;
        selEnd = n.endOffset;
      } else if (u.lineIndex == n.startLine) {
        selStart = n.startOffset;
        selEnd = line.length;
      } else if (u.lineIndex == n.endLine) {
        selStart = 0;
        selEnd = n.endOffset;
      } else {
        selStart = 0;
        selEnd = line.length;
      }
      final ovStart = selStart > subStart ? selStart : subStart;
      final ovEnd = selEnd < subEnd ? selEnd : subEnd;
      if (ovStart >= ovEnd) continue;

      final ctx = _unitKeys[unitIdx]?.currentContext;
      if (ctx == null) continue;
      final rp = ctx.findRenderObject();
      if (rp is! RenderParagraph) continue;

      final uStart = ovStart - subStart;
      final uEnd = ovEnd - subStart;
      final boxes = rp.getBoxesForSelection(
        TextSelection(baseOffset: uStart, extentOffset: uEnd),
      );
      if (boxes.isEmpty) continue;
      final unitOrigin = rp.localToGlobal(Offset.zero) - contentOrigin;
      for (final box in boxes) {
        rects.add(Rect.fromLTWH(
          unitOrigin.dx + box.left,
          unitOrigin.dy + box.top,
          box.right - box.left,
          box.bottom - box.top,
        ));
      }
    }
    if (rects.isEmpty) return const SizedBox.shrink();

    return Stack(
      children: [
        for (final r in rects)
          Positioned(
            left: r.left,
            top: r.top,
            width: r.width,
            height: r.height,
            child: const ColoredBox(color: _selectionBg),
          ),
      ],
    );
  }

  // ★ 改动5：_buildRenderUnit 用 mergedStyle + textScaler
  Widget _buildRenderUnit(
      int unitIdx, RenderUnit unit, ReaderSettings settings) {
    final line = _lines[unit.lineIndex];
    final int s = unit.charStart.clamp(0, line.length);
    final int e = unit.charEnd.clamp(0, line.length);
    final String sub = e > s ? line.substring(s, e) : '';

    final spans = _buildUnitSpans(unitIdx, unit, sub, settings);
    final highlights = _highlightsForLine(unit.lineIndex);

    final effectiveStyle =
        DefaultTextStyle.of(context).style.merge(_baseStyle(settings));
    final textScaler = MediaQuery.textScalerOf(context);

    final hasGrad = _hasGradientIn(highlights, unit);

    if (!hasGrad) {
      return SizedBox(
        width: double.infinity,
        child: Text.rich(
          TextSpan(children: spans),
          style: effectiveStyle,
          textAlign: TextAlign.left,
          softWrap: true,
          
  overflow: TextOverflow.visible,
          key: _unitKeys[unitIdx],
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
            spans,
            effectiveStyle,
            textScaler,
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
                          stops: g.stops.length == g.colors.length
                              ? g.stops
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              Text.rich(
                TextSpan(children: spans),
                style: effectiveStyle,
                textAlign: TextAlign.left,
                softWrap: true,
                
  overflow: TextOverflow.visible,
                key: _unitKeys[unitIdx],
              ),
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

  // ★ 改动6：_measureGradientRects 加参数 + LRU
  List<_GradRect> _measureGradientRects(
    int unitIdx,
    RenderUnit unit,
    String sub,
    ReaderSettings settings,
    double maxWidth,
    List<HighlightSpan> highlights,
    List<InlineSpan> spans,
    TextStyle effectiveStyle,
    TextScaler textScaler,
  ) {
    if (sub.isEmpty) return const [];

    final fontFamilyKey = effectiveStyle.fontFamily ?? 'null';
    final scalerKey = textScaler.scale(10).toStringAsFixed(4);
    final key = '$unitIdx|${maxWidth.round()}'
        '|f${effectiveStyle.fontSize}'
        '|w${effectiveStyle.fontWeight?.index}'
        '|ff$fontFamilyKey'
        '|sc$scalerKey';

    final hit = _gradRectCache.remove(key);
    if (hit != null) {
      _gradRectCache[key] = hit;
      return hit;
    }

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

    final tp = _gradTP;
    tp.text = TextSpan(style: effectiveStyle, children: spans);
    tp.textScaler = textScaler;
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

      List<double> stops;
      if (h.entry.stops.length == h.entry.colors.length &&
          h.entry.stops.length > 1) {
        stops = List<double>.from(h.entry.stops);
        var ok = true;
        for (var i = 1; i < stops.length; i++) {
          if (stops[i] <= stops[i - 1]) {
            ok = false;
            break;
          }
        }
        if (!ok) {
          stops = [
            for (var i = 0; i < colors.length; i++)
              i / (colors.length - 1),
          ];
        }
      } else {
        stops = [
          for (var i = 0; i < colors.length; i++)
            i / ((colors.length - 1) < 1 ? 1 : (colors.length - 1)),
        ];
      }

      final caretAtEnd = tp.getOffsetForCaret(
        TextPosition(offset: he),
        Rect.zero,
      );
      final caretEndDx = caretAtEnd.dx;

      for (var bi = 0; bi < boxes.length; bi++) {
        final box = boxes[bi];
        var right = box.right;
        if (bi == boxes.length - 1 && caretEndDx < right) {
          right = caretEndDx;
        }
        rects.add(_GradRect(
          Rect.fromLTRB(box.left, box.top, right, box.bottom),
          colors,
          stops,
        ));
      }
    }

    if (_gradRectCache.length > 256) {
      _gradRectCache.remove(_gradRectCache.keys.first);
    }
    _gradRectCache[key] = rects;
    return rects;
  }

  // ★ 改动7：_buildUnitSpans 改 LRU
  List<InlineSpan> _buildUnitSpans(
    int unitIdx,
    RenderUnit unit,
    String sub,
    ReaderSettings settings,
  ) {
    final hit = _spansCache.remove(unitIdx);
    if (hit != null) {
      _spansCache[unitIdx] = hit;
      return hit;
    }

    final spans = _doBuildUnitSpans(unit, sub, settings);
    const cap = 512;
    if (_spansCache.length >= cap) {
      _spansCache.remove(_spansCache.keys.first);
    }
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

  // ==================== 悬浮按钮 ====================

  Widget _buildFloatButton({
    required int style,
    required Color bgColor,
    required Color fgColor,
    required Color ringColor,
    required double ringWidth,
    required double x,
    required double y,
    required double scale,
    required double opacity,
    required IconData icon,
    required Size size,
    required VoidCallback onTap,
  }) {
    final btnSize = 50.0 * scale;
    final left = x * size.width - btnSize / 2;
    final top = y * size.height - btnSize / 2;
    final alpha = opacity.clamp(0.0, 1.0);

    Widget body;
    if (style == 0) {
      body = Container(
        width: btnSize,
        height: btnSize,
        decoration: BoxDecoration(
          color: bgColor.withValues(alpha: bgColor.a * alpha),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: fgColor.withValues(alpha: fgColor.a * alpha),
          size: btnSize * 0.6,
        ),
      );
    } else {
      body = Container(
        width: btnSize,
        height: btnSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: ringColor.withValues(alpha: ringColor.a * alpha),
            width: ringWidth,
          ),
        ),
      );
    }

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(child: body),
    );
  }

  Widget _buildDeleteButton(ReaderSettings settings, Size size) {
    final btnSize = 50.0 * settings.delBtnScale;
    final left = settings.delBtnX * size.width - btnSize / 2;
    final top = settings.delBtnY * size.height - btnSize / 2;
    final alpha = settings.delBtnOpacity.clamp(0.0, 1.0);

    final iconBaseColor = settings.delBtnStyle == 0
        ? Color(settings.delBtnFgColor)
        : Color(settings.delBtnRingColor);
    final iconColor = iconBaseColor.withValues(alpha: iconBaseColor.a * alpha);
    final iconSize = btnSize * 0.6;

    Widget body;
    if (settings.delBtnStyle == 0) {
      final bg = Color(settings.delBtnBgColor);
      body = Container(
        width: btnSize,
        height: btnSize,
        decoration: BoxDecoration(
          color: bg.withValues(alpha: bg.a * alpha),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: CustomPaint(
          size: Size.square(iconSize),
          painter: _TrashIconPainter(color: iconColor),
        ),
      );
    } else {
      final ring = Color(settings.delBtnRingColor);
      body = Container(
        width: btnSize,
        height: btnSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: ring.withValues(alpha: ring.a * alpha),
            width: settings.delBtnRingWidth,
          ),
        ),
        alignment: Alignment.center,
        child: CustomPaint(
          size: Size.square(iconSize),
          painter: _TrashIconPainter(color: iconColor),
        ),
      );
    }

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(child: body),
    );
  }

  // ==================== 手柄渲染 ====================

  List<Widget> _buildHandles(ReaderSettings settings) {
    if (_sel == null) return const [];
    final pos = _handlePositions();
    if (pos == null) return const [];

    const trapW = 22.0;
    const trapH = 32.0;
    final baseColor = Theme.of(context).colorScheme.primary;
    final color = baseColor.withValues(alpha: 0.75);

    final drag = _dragNotifier.value;
    final dragging = drag?.handle ?? 0;
    final dragPos = drag?.handlePos;

    var leftPos = pos.left;
    var rightPos = pos.right;

    if (dragging == 1 && dragPos != null) {
      leftPos = dragPos;
    } else if (dragging == 2 && dragPos != null) {
      rightPos = dragPos;
    } else {
      final dx = rightPos.dx - leftPos.dx;
      const minGap = 6.0;
      if (dx.abs() < minGap && (rightPos.dy - leftPos.dy).abs() < 2) {
        final mid = (leftPos.dx + rightPos.dx) / 2;
        const half = minGap / 2;
        leftPos = Offset(mid - half, leftPos.dy);
        rightPos = Offset(mid + half, rightPos.dy);
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
            _updateDragPos(handleLogic);

            final lineHeight = settings.fontSize * kReaderLineHeightFactor;
            final charBottom = handleLogic.dy + settings.fontSize;
            final judge = Offset(
              handleLogic.dx,
              charBottom - lineHeight / 3,
            );

            _updateSelectionFromDrag(judge);
          },
          onPanEnd: (_) {
            _setDragState(handle: 0, handlePos: null);
            setState(() => _hBarVisible = true);
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

  // ==================== 放大镜 ====================

  Widget _buildLoupe(
    ReaderSettings settings,
    Size size,
    _DragInfo drag,
    _SelectionRange sel,
  ) {
    final int line;
    final int offset;
    int? selStartInLine;
    int? selEndInLine;

    if (drag.handle == 1) {
      line = sel.startLine;
      offset = sel.startOffset;
      selStartInLine = sel.startOffset;
      if (sel.startLine == sel.endLine) {
        selEndInLine = sel.endOffset;
      } else {
        selEndInLine = (line >= 0 && line < _lines.length)
            ? _lines[line].length
            : sel.startOffset;
      }
    } else {
      line = sel.endLine;
      offset = sel.endOffset;
      if (sel.startLine == sel.endLine) {
        selStartInLine = sel.startOffset;
      } else {
        selStartInLine = 0;
      }
      selEndInLine = sel.endOffset;
    }

    if (line < 0 || line >= _lines.length) return const SizedBox.shrink();

    const double loupeW = 160;
    const double loupeH = 56;
    const double scale = 1.4;
    const double gap = 18;
    const double margin = 8;

    final h = drag.handlePos;

    final aboveCenter = Offset(h.dx, h.dy - gap - loupeH / 2);
    final belowCenter = Offset(h.dx, h.dy + gap + loupeH / 2);
    var center = aboveCenter;
    if (aboveCenter.dy - loupeH / 2 < margin) {
      center = belowCenter;
    }
    center = Offset(
      center.dx.clamp(
          margin + loupeW / 2, size.width - margin - loupeW / 2),
      center.dy.clamp(
          margin + loupeH / 2, size.height - margin - loupeH / 2),
    );

    final base = _baseStyle(settings);
    final loupeStyle = base.copyWith(color: null);

    return Positioned(
      left: center.dx - loupeW / 2,
      top: center.dy - loupeH / 2,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.10),
                  width: 0.5,
                ),
              ),
              child: ReaderLoupe(
                lineText: _lines[line],
                caretOffset: offset,
                style: loupeStyle,
                bgColor: Color(settings.bgColor),
                fgColor: const Color(0xFF222222),
                caretColor: Theme.of(context).colorScheme.primary,
                selectionStart: selStartInLine,
                selectionEnd: selEndInLine,
                selectionBg: _selectionBg,
                scale: scale,
                width: loupeW,
                height: loupeH,
              ),
            ),
          ),
        ),
      ),
    );
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
      child: Container(
        width: approxW,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
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
                IconButton(
                  icon: const Icon(Icons.share, size: 18),
                  tooltip: '分享',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    final t = _selectedText();
                    if (t.isEmpty) return;
                    Share.share(t);
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
                          stops: p.stops.length == p.colors.length
                              ? p.stops
                              : null,
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

  // ★ 改动9：_applyHighlight 里同步清新缓存
  void _applyHighlight(String word, HighlightPalette palette) {
    if (_text == null) return;
    final path = _filePaths[_fileIndex];
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
      isGlobal: false,
    );
    ref.read(readerHighlightsProvider.notifier).addOrReplace(fileKey, entry);

    final local = ref.read(readerHighlightsProvider)[fileKey] ?? const [];
    final global = ref.read(readerGlobalHighlightsProvider);
    final newHighlights = [...local, ...global];
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
      _pageHighlightCacheMap.clear();
      _pageHighlightCacheMapRevision = -1;
      _previewCache.clear();
      _previewCacheRevision = -1;
    });
  }
}


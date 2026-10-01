// reader_screen.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  _SelectionRange copyWith({
    int? startLine,
    int? startOffset,
    int? endLine,
    int? endOffset,
  }) =>
      _SelectionRange(
        startLine: startLine ?? this.startLine,
        startOffset: startOffset ?? this.startOffset,
        endLine: endLine ?? this.endLine,
        endOffset: endOffset ?? this.endOffset,
      );

  /// 交换起止，让 start <= end（按阅读顺序）。
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

/// 某个 (line, offset) 的位置信息。
class _CharPos {
  const _CharPos({
    required this.line,
    required this.offset,
  });
  final int line;
  final int offset;
}

// ==================== 手柄绘制 ====================

class _HandlePainter extends CustomPainter {
  _HandlePainter({
    required this.color,
    required this.lineHeight,
    required this.circleR,
  });

  final Color color;
  final double lineHeight;
  final double circleR;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    const top = 0.0;
    final lineBottom = top + lineHeight;
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final circlePaint = Paint()..color = color;

    canvas.drawLine(
      Offset(cx, top),
      Offset(cx, lineBottom),
      linePaint,
    );
    canvas.drawCircle(
      Offset(cx, lineBottom + circleR + 2),
      circleR,
      circlePaint,
    );
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.color != color ||
      old.lineHeight != lineHeight ||
      old.circleR != circleR;
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

  // ==================== 手势 / 选区状态 ====================

  /// 正文区整体 key，用于 globalToLocal。
  final GlobalKey _contentKey = GlobalKey();

  /// 当前页每一行的 GlobalKey，用于命中测试和坐标反查。
  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};

  _SelectionRange? _sel;
  bool _hBarVisible = false;

  /// 0=无, 1=拖左, 2=拖右
  int _draggingHandle = 0;

  Timer? _longPressTimer;
  Timer? _autoFadeTimer;

  Offset _downPos = Offset.zero;
  bool _longPressFired = false;
  bool _movedBeyondThreshold = false;
  bool _pressDown = false;

  int _lastTapUpMs = 0;

  /// 弹窗大小（用于摆放位置）。每次 build 后记录。
  Size _hBarSize = const Size(220, 100);

  static const Color _selectionBg = Color(0x5533B5FF);
  static const Color _selectionFg = Color(0xFF000000);
  static const int _longPressMs = 400;
  static const double _moveThresholdDp = 10.0;
  static const int _tapDebounceMs = 100;
  static const int _autoFadeMs = 2000;

  @override
  void initState() {
    super.initState();
    _fileIndex = widget.initialIndex.clamp(0, widget.filePaths.length - 1);
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _autoFadeTimer?.cancel();
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
      _sel = null;
      _hBarVisible = false;
    });
    _lineKeys.clear();

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
        _sel = null;
        _hBarVisible = false;
      });
      _lineKeys.clear();
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
    _clearSelection();
    setState(() => _currentPage++);
    _saveProgress();
  }

  void _prevPage() {
    if (_pagination == null) return;
    if (_currentPage <= 0) return;
    _clearSelection();
    setState(() => _currentPage--);
    _saveProgress();
  }

  void _jumpToPage(int page) {
    if (_pagination == null) return;
    final p = page.clamp(0, _pagination!.pageCount - 1);
    _clearSelection();
    setState(() => _currentPage = p);
    _saveProgress();
  }

  // ==================== 切文件 ====================

  Future<void> _prevFile() async {
    if (_fileIndex <= 0) return;
    _saveProgress();
    _clearSelection();
    setState(() => _fileIndex--);
    await _ensureLoaded();
  }

  Future<void> _nextFile() async {
    if (_fileIndex >= widget.filePaths.length - 1) return;
    _saveProgress();
    _clearSelection();
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
    _clearSelection();
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

  Future<void> _openManager() async {
    if (widget.filePaths.isEmpty) return;
    _clearSelection();
    final path = widget.filePaths[_fileIndex];
    final fileKey = readerFileKey(path);
    final fileName = path.split('/').last;
    final result =
        await openBookmarkHighlightManager(context, fileKey, fileName);
    if (!mounted) return;
    if (result != null && _pagination != null) {
      final page = findPageForOffset(_pagination!, result);
      _jumpToPage(page);
    }
  }

  Future<void> _openEditor() async {
    if (widget.filePaths.isEmpty) return;
    final path = widget.filePaths[_fileIndex];
    final fileName = path.split('/').last;

    _saveProgress();
    _clearSelection();

    await openEditorAndReturn(context, path, fileName, () {
      _lastLoadedPath = null;
      _lastLoadedSize = null;
      _ensureLoaded();
    });
  }

  // ==================== 选区操作 ====================

  void _clearSelection() {
    _longPressTimer?.cancel();
    _autoFadeTimer?.cancel();
    _longPressFired = false;
    _movedBeyondThreshold = false;
    _pressDown = false;
    _draggingHandle = 0;
    if (_sel != null || _hBarVisible) {
      setState(() {
        _sel = null;
        _hBarVisible = false;
      });
    }
  }

  void _resetAutoFade() {
    _autoFadeTimer?.cancel();
    if (!_hBarVisible) return;
    _autoFadeTimer = Timer(const Duration(milliseconds: _autoFadeMs), () {
      if (!mounted) return;
      _clearSelection();
    });
  }

  /// 用全局坐标找 (line, offset)。
  _CharPos? _hitTest(Offset globalPos) {
    final contentCtx = _contentKey.currentContext;
    if (contentCtx == null) return null;
    final contentBox = contentCtx.findRenderObject() as RenderBox?;
    if (contentBox == null) return null;
    final local = contentBox.globalToLocal(globalPos);
    if (!(Offset.zero & contentBox.size).contains(local)) return null;

    for (final entry in _lineKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final rp = ctx.findRenderObject();
      if (rp is! RenderParagraph) continue;
      final localLine = rp.globalToLocal(globalPos);
      final size = rp.size;
      // 允许一点纵向误差，方便点到行边缘
      if (localLine.dy < -2 || localLine.dy > size.height + 2) continue;
      if (localLine.dx < -2 || localLine.dx > size.width + 2) continue;
      final clamped = Offset(
        localLine.dx.clamp(0.0, size.width),
        localLine.dy.clamp(0.0, size.height),
      );
      final pos = rp.getPositionForOffset(clamped);
      return _CharPos(line: entry.key, offset: pos.offset);
    }
    return null;
  }

  /// 从 (line, offset) 算屏幕全局坐标。
  Offset? _posOfChar(int line, int offset, {bool isEnd = false}) {
    final ctx = _lineKeys[line]?.currentContext;
    if (ctx == null) return null;
    final rp = ctx.findRenderObject();
    if (rp is! RenderParagraph) return null;

    // 用 getOffsetForCaret，行尾时要特殊处理一下
    final textPos = TextPosition(offset: offset);
    final local = rp.getOffsetForCaret(textPos, Rect.zero);
    // 转成全局坐标
    return rp.localToGlobal(local);
  }

  /// 选区选中范围内的纯文本。
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

  /// 长按命中后，选中一个"词"或一个字。
  void _selectWordAt(_CharPos pos) {
    final line = _lines[pos.line];
    if (line.isEmpty) return;
    final offset = pos.offset.clamp(0, line.length - 1);
    final code = line.codeUnitAt(offset);

    // 中文单字
    if (code >= 0x4E00 && code <= 0x9FFF) {
      setState(() {
        _sel = _SelectionRange(
          startLine: pos.line,
          startOffset: offset,
          endLine: pos.line,
          endOffset: offset + 1,
        );
        _hBarVisible = true;
      });
      _resetAutoFade();
      return;
    }

    // 英文/数字：扩到单词边界
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
        _hBarVisible = true;
      });
      _resetAutoFade();
      return;
    }

    // 其它字符，选一个
    setState(() {
      _sel = _SelectionRange(
        startLine: pos.line,
        startOffset: offset,
        endLine: pos.line,
        endOffset: offset + 1,
      );
      _hBarVisible = true;
    });
    _resetAutoFade();
  }

  bool _isWordChar(int code) =>
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      code == 0x5F;

  // ==================== 手势状态机 ====================

  void _onPointerDown(PointerDownEvent e) {
    _longPressTimer?.cancel();
    _downPos = e.position;
    _longPressFired = false;
    _movedBeyondThreshold = false;
    _pressDown = true;

    // 照参考 app：任意按下先收起弹窗和手柄
    if (_hBarVisible || _sel != null) {
      setState(() {
        _hBarVisible = false;
      });
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

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final dx = (e.position.dx - _downPos.dx).abs();
    final dy = (e.position.dy - _downPos.dy).abs();
    final threshold = _moveThresholdDp * dpr / dpr; // dp 就当逻辑像素

    if (!_movedBeyondThreshold) {
      if (dx > _moveThresholdDp || dy > _moveThresholdDp) {
        _movedBeyondThreshold = true;
        _longPressTimer?.cancel();
      }
    }

    // 已经在拖手柄 → 更新选区
    if (_draggingHandle != 0) {
      _updateSelectionFromDrag(e.position);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _longPressTimer?.cancel();

    if (_draggingHandle != 0) {
      // 手柄松手：重新显示弹窗
      setState(() {
        _draggingHandle = 0;
        _hBarVisible = true;
      });
      _resetAutoFade();
      _pressDown = false;
      return;
    }

    if (_longPressFired) {
      // 长按已触发，抬起什么都不做
      _pressDown = false;
      return;
    }

    if (_movedBeyondThreshold) {
      _pressDown = false;
      return;
    }

    // 单击判定
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
    _longPressTimer?.cancel();
    _pressDown = false;
    _draggingHandle = 0;
  }

  void _handleLongPress() {
    final settings = ref.read(readerSettingsProvider);
    final pos = _hitTest(_downPos);
    if (pos == null) return;

    // 顶部热区？悬浮按钮？—— 照参考 app，长按优先级更高，不区分区域
    // 但保留一个开关位置，方便以后修改。
    // if (_isInTopZone(_downPos) && !_allowLongPressInTopZone) return;

    _selectWordAt(pos);
    // 触发一次重绘让手柄和弹窗出来
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    // 忽略 settings 警告（保留占位）
    // ignore: unused_local_variable
    final _ = settings;
  }

  /// 点击分发。
  void _handleTap(Offset globalPos) {
    final settings = ref.read(readerSettingsProvider);

    // 1. 悬浮按钮
    final size = _viewportSize;
    if (settings.showButtons) {
      final topBtnSize = 50.0 * settings.buttonScale;
      final topCenter = Offset(
        settings.topBtnX * size.width,
        settings.topBtnY * size.height,
      );
      if ((globalPos - topCenter).distance <= topBtnSize / 2 + 8) {
        _prevFile();
        return;
      }
      final bottomCenter = Offset(
        settings.bottomBtnX * size.width,
        settings.bottomBtnY * size.height,
      );
      if ((globalPos - bottomCenter).distance <= topBtnSize / 2 + 8) {
        _nextFile();
        return;
      }
    }

    // 2. 顶部热区。坐标是"局部"还是"全局"：
    //    这里 globalPos 是全局坐标；SafeArea 会把内容往下推，
    //    所以用 _contentKey 的 top 来比较更稳妥。
    final contentCtx = _contentKey.currentContext;
    if (contentCtx != null) {
      final box = contentCtx.findRenderObject() as RenderBox?;
      if (box != null) {
        final top = box.localToGlobal(Offset.zero).dy;
        // 顶部热区：从屏幕顶端开始算。SafeArea 顶部以下的内容才会走翻页。
        final safeTop = MediaQuery.of(context).padding.top;
        if (globalPos.dy < safeTop + settings.topHotZoneHeight) {
          _showTopMenu();
          return;
        }
        // 避免未使用变量
        // ignore: unused_local_variable
        final _t = top;
      }
    }

    // 3. 正文 → 翻页
    _nextPage();
  }

  // ==================== 手柄拖动 ====================

  void _startDragLeft() {
    if (_sel == null) return;
    setState(() {
      _draggingHandle = 1;
      _hBarVisible = false;
    });
    _autoFadeTimer?.cancel();
  }

  void _startDragRight() {
    if (_sel == null) return;
    setState(() {
      _draggingHandle = 2;
      _hBarVisible = false;
    });
    _autoFadeTimer?.cancel();
  }

  void _updateSelectionFromDrag(Offset globalPos) {
    final sel = _sel;
    if (sel == null) return;
    final hit = _hitTest(globalPos);
    if (hit == null) return;

    if (_draggingHandle == 1) {
      // 拖左：新起点 = hit，终点 = 原 end
      // 如果越过终点，则交换
      setState(() {
        _sel = _SelectionRange(
          startLine: hit.line,
          startOffset: hit.offset,
          endLine: sel.endLine,
          endOffset: sel.endOffset,
        ).normalized();
      });
    } else if (_draggingHandle == 2) {
      // 拖右
      setState(() {
        _sel = _SelectionRange(
          startLine: sel.startLine,
          startOffset: sel.startOffset,
          endLine: hit.line,
          endOffset: hit.offset,
        ).normalized();
      });
    }
  }

  // ==================== 手柄位置 ====================

  /// 返回左 / 右两个手柄顶端的全局坐标（手柄尺寸由 _HandleSize 决定）
  ({Offset left, Offset right})? _handlePositions() {
    final sel = _sel;
    if (sel == null) return null;
    final n = sel.normalized();
    final left = _posOfChar(n.startLine, n.startOffset);
    final right = _posOfChar(n.endLine, n.endOffset);
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
    final previewHotZone = ref.watch(readerHotZonePreviewProvider);

    // 为当前页每一行准备 key
    _lineKeys.removeWhere((k, v) => k < range.startLine || k >= range.endLine);
    for (var i = range.startLine; i < range.endLine; i++) {
      _lineKeys.putIfAbsent(i, () => GlobalKey());
    }

    return Stack(
      children: [
        // ==================== 正文 ====================
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
                  for (var i = range.startLine; i < range.endLine; i++)
                    KeyedSubtree(
                      key: _lineKeys[i],
                      child: _buildLine(
                        i,
                        settings,
                        size.width - kReaderHorizontalPadding * 2,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),

        // ==================== 顶部热区可视化 ====================
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

        // ==================== 浮动按钮 ====================
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

        // ==================== 手柄 ====================
        ..._buildHandles(settings),

        // ==================== 弹窗 ====================
        if (_hBarVisible && _sel != null) _buildHBar(settings, size),
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

  /// 把选区叠加到 spans 上。
  List<InlineSpan> _buildLineSpans(int lineIdx, ReaderSettings settings) {
    final line = _lines[lineIdx];
    final base = _baseStyle(settings);

    // ---------- 1. 生成基础 spans（含高亮叠加） ----------
    final baseSpans = <InlineSpan>[];
    final highlights = _highlightIndex.forLine(lineIdx);

    if (line.isEmpty) {
      baseSpans.add(TextSpan(text: ' ', style: base));
    } else if (highlights.isEmpty) {
      baseSpans.add(TextSpan(text: line, style: base));
    } else {
      var cursor = 0;
      for (final h in highlights) {
        if (h.startInLine > cursor) {
          baseSpans.add(TextSpan(
            text: line.substring(cursor, h.startInLine),
            style: base,
          ));
        }
        final entry = h.entry;
        final hlText = line.substring(h.startInLine, h.endInLine);
        if (entry.colors.length > 1) {
          baseSpans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: entry.colors
                      .map((c) => Color(c))
                      .toList(growable: false),
                ),
              ),
              child: Text(
                hlText,
                style: base.copyWith(color: Color(entry.textColor)),
              ),
            ),
          ));
        } else {
          final hlStyle = base.copyWith(
            color: Color(entry.textColor),
            backgroundColor: Color(entry.colors.first),
          );
          baseSpans.add(TextSpan(text: hlText, style: hlStyle));
        }
        cursor = h.endInLine;
      }
      if (cursor < line.length) {
        baseSpans.add(TextSpan(text: line.substring(cursor), style: base));
      }
    }

    // ---------- 2. 叠加选区 ----------
    final sel = _sel;
    if (sel == null) return baseSpans;
    final n = sel.normalized();

    int? selStart;
    int? selEnd;
    if (lineIdx >= n.startLine && lineIdx <= n.endLine) {
      if (n.startLine == n.endLine) {
        selStart = n.startOffset;
        selEnd = n.endOffset;
      } else if (lineIdx == n.startLine) {
        selStart = n.startOffset;
        selEnd = line.length;
      } else if (lineIdx == n.endLine) {
        selStart = 0;
        selEnd = n.endOffset;
      } else {
        selStart = 0;
        selEnd = line.length;
      }
    }
    if (selStart == null || selEnd == null) return baseSpans;
    if (selEnd <= selStart && !(selStart == 0 && selEnd == 0)) {
      return baseSpans;
    }

    // 把 baseSpans 按选区区间重新切分。
    // 因为 baseSpans 里的 TextSpan 已经是"连续片段"，
    // 这里不做精细合并，直接用字符串整体重切：
    final plainSpans = <InlineSpan>[];
    for (final span in baseSpans) {
      if (span is TextSpan && span.text != null) {
        plainSpans.add(span);
      } else {
        // WidgetSpan 原样保留（渐变高亮），把它当成一个字符处理
        plainSpans.add(span);
      }
    }

    // 找出"纯文本"总长，用于对齐
    final out = <InlineSpan>[];
    var charCount = 0;
    for (final span in plainSpans) {
      if (span is TextSpan) {
        final t = span.text ?? '';
        final segStart = charCount;
        final segEnd = charCount + t.length;
        charCount = segEnd;

        // 与本行选区求交集
        final a = math.max(segStart, selStart);
        final b = math.min(segEnd, selEnd);
        if (b <= a) {
          out.add(span);
          continue;
        }
        final before = t.substring(0, a - segStart);
        final mid = t.substring(a - segStart, b - segStart);
        final after = t.substring(b - segStart);
        final midStyle = (span.style ?? base).copyWith(
          backgroundColor: _selectionBg,
          color: span.style?.color ?? _selectionFg,
        );
        if (before.isNotEmpty) {
          out.add(TextSpan(text: before, style: span.style));
        }
        if (mid.isNotEmpty) {
          out.add(TextSpan(text: mid, style: midStyle));
        }
        if (after.isNotEmpty) {
          out.add(TextSpan(text: after, style: span.style));
        }
      } else {
        // WidgetSpan：算作 1 个字符位置
        final segStart = charCount;
        final segEnd = charCount + 1;
        charCount = segEnd;
        if (segEnd > selStart && segStart < selEnd) {
          // 选中状态：包一层蓝色边框
          out.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: _selectionBg, width: 6),
              ),
              child: span.child,
            ),
          ));
        } else {
          out.add(span);
        }
      }
    }

    return out;
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

    final lineHeight = settings.fontSize * kReaderLineHeightFactor;
    const handleW = 22.0;
    final handleH = lineHeight + 20.0;
    const circleR = 6.0;

    Widget handle(Offset globalPos, int which) {
      // 相对于 Stack（= SafeArea 内部），需要扣掉 SafeArea padding。
      final top = MediaQuery.of(context).padding.top;
      final left = globalPos.dx - handleW / 2;
      final topPos = globalPos.dy - top;

      return Positioned(
        left: left,
        top: topPos,
        width: handleW,
        height: handleH,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            if (which == 1) {
              _startDragLeft();
            } else {
              _startDragRight();
            }
          },
          onPanUpdate: (d) {
            if (_draggingHandle != which) return;
            final local = Offset(
              globalPos.dx + d.delta.dx,
              globalPos.dy + d.delta.dy,
            );
            _updateSelectionFromDrag(local);
          },
          onPanEnd: (_) {
            setState(() {
              _draggingHandle = 0;
              _hBarVisible = true;
            });
            _resetAutoFade();
          },
          child: CustomPaint(
            painter: _HandlePainter(
              color: Theme.of(context).colorScheme.primary,
              lineHeight: lineHeight,
              circleR: circleR,
            ),
          ),
        ),
      );
    }

    return [
      handle(pos.left, 1),
      handle(pos.right, 2),
    ];
  }

  // ==================== 弹窗渲染 ====================

  Widget _buildHBar(ReaderSettings settings, Size size) {
    final sel = _sel;
    if (sel == null) return const SizedBox.shrink();
    final n = sel.normalized();

    final startPos = _posOfChar(n.startLine, n.startOffset);
    final endPos = _posOfChar(n.endLine, n.endOffset);
    if (startPos == null || endPos == null) return const SizedBox.shrink();

    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final topAreaH = size.height - safeTop - safeBottom;

    // 弹窗参考高度：两行色块 + 复制按钮 ≈ 140
    const approxW = 260.0;
    const approxH = 150.0;
    _hBarSize = const Size(approxW, approxH);

    final selTop = startPos.dy;
    final selBottom = endPos.dy + settings.fontSize * kReaderLineHeightFactor;

    // 选区在屏幕上半 → 放下方；下半 → 放上方
    final midY = (selTop + selBottom) / 2;
    final screenMid = safeTop + topAreaH / 2;
    final showBelow = midY < screenMid;

    double top;
    if (showBelow) {
      top = selBottom - safeTop + 8;
    } else {
      top = selTop - safeTop - approxH - 8;
    }
    top = top.clamp(4.0, topAreaH - approxH - 4);

    // 水平：以选区左边缘为参照，超出右边贴右
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
              // ---------- 顶部：复制按钮 ----------
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
                      _resetAutoFade();
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
              // ---------- 色块：两行，每行横向滚动 ----------
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
    final list = palette.where((p) => p.index >= from && p.index < to).toList();
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
                _resetAutoFade();
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
      // 加完高亮保留选区，但让用户看到结果
    });
  }
}

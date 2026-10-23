import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'crash_trace.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../diff/application/diff_cache.dart';
import '../../diff/domain/diff_entry.dart';
import '../../diff/domain/diff_operation.dart';
import '../../diff/domain/diff_result.dart';
import '../../edit/presentation/edit_screen.dart';
import '../../file_browser/presentation/comparison_settings_screen.dart';
import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/preprocessing_service.dart';
import '../../preprocessing/domain/preprocessing_rule.dart';


import '../../preprocessing/application/aho_corasick.dart';

import '../../../core/debug/crash_logger.dart';
import 'diagnostic_screen.dart';
import 'diff_text_index.dart';
import 'grouped_diff_view.dart';
import 'line_list_page.dart';
import 'line_height_cache.dart';
import 'line_height_calculator.dart';
import 'providers/diff_viewer_providers.dart';
import 'providers/toolbar_rules_provider.dart';
import 'regex_help_screen.dart';
import 'viewer_widgets.dart';
import 'widgets/diff_only_plain_view.dart';
import 'widgets/diff_only_view.dart';
import 'widgets/merged_view.dart';
import 'widgets/side_by_side_view.dart';

class DiffViewerScreen extends ConsumerStatefulWidget {
  const DiffViewerScreen({super.key});

  @override
  ConsumerState<DiffViewerScreen> createState() => _DiffViewerScreenState();
}

class _SwitchChoice {
  const _SwitchChoice.top()
      : targetEntry = null,
        isTop = true;
  const _SwitchChoice.entry(int this.targetEntry) : isTop = false;

  final int? targetEntry;
  final bool isTop;
}

class _HeightBundle {
  const _HeightBundle({
    this.merged,
    this.sbsSync,
    this.sbsLeft,
    this.sbsRight,
    this.diffOnly,
    this.diffOnlyPlain,
  });

  final LineHeightTable? merged;
  final LineHeightTable? sbsSync;
  final LineHeightTable? sbsLeft;
  final LineHeightTable? sbsRight;
  final LineHeightTable? diffOnly;
  final LineHeightTable? diffOnlyPlain;
}

class _DiffViewerScreenState extends ConsumerState<DiffViewerScreen> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _hScrollController = ScrollController();

  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();

  bool _showFind = false;
  String _findQuery = '';
  List<int> _matchEntries = const <int>[];
  int _matchPos = -1;

  String _scannedQuery = '';
  String? _noResultHint;

  String? _findWarning;
  String? _replaceHint;
  String? _regexErrorHint;

  bool _regexEnable = false;
  bool _caseInsensitive = false;
  bool _wholeWord = false;
  bool _searchLeft = true;
  bool _searchRight = true;

  final Map<int, String> _pendingOrigChanges = <int, String>{};
  final Map<int, String> _pendingModChanges = <int, String>{};

  bool _landscape = false;
  bool _originalDeleted = false;
  bool _modifiedDeleted = false;

  /// 正在删除确认弹窗中的一侧：null = 没有，true = 左侧，false = 右侧。
  /// 只在弹窗存活期间给对应那一栏盖红色遮罩，确认或取消后立即清空。
  bool? _pendingDeleteOriginal;

  List<int>? _cachedDiffIndices;
  DiffResult? _cachedDiffIndicesFor;

  Map<int, int>? _entryToRowMap;
  DiffResult? _entryToRowMapFor;
  ViewMode? _entryToRowMapMode;

  // 后台精确高度表
  final Map<ViewMode, Future<_HeightBundle>> _heightFutures = {};
  final Map<ViewMode, _HeightBundle> _heightExactResults = {};
  // 已完成精确计算的模式（用于切视图"就绪即走"判断）。
  final Set<ViewMode> _completedHeightModes = {};
  DiffResult? _heightFuturesFor;
  String? _heightFuturesConfigKey;

  static final Future<_HeightBundle> _emptyHeightFuture =
      Future.value(const _HeightBundle());
  int? _jumpedToEntry;

  double? _pendingGroupedRestoreOffset;

  _HeightBundle? _activeHeights;
  // 是否已经成功显示过一次正文。首次进入 = false，切视图 = true。
  bool _hasShownContentOnce = false;

  double? _cachedContentWidth;
  DiffResult? _cachedContentWidthFor;
  String? _cachedContentWidthConfig;

  int? _pendingJumpEntry;
  int? _pendingJumpOrigLine;
  bool _pendingJumpQueued = false;
OverlayEntry? _floatEntry;
Timer? _floatTimer;

bool _jumping = false;
JumpDirection _jumpDirection = JumpDirection.down;
  Timer? _findDebounce;
  bool _processing = false;
  String _processingText = '';

  DiffResult? _lastDiagDiff;
  final GlobalKey _groupedKey = GlobalKey();

  final ScrollController _tabScrollController = ScrollController();
  bool _tabAtEnd = false;

  final Map<ViewMode, GlobalKey> _tabKeys = {
    for (final m in ViewMode.values) m: GlobalKey(),
  };

  // 切视图遮罩：截止时间。非 null 且未到期时显示加载动画；
  // 目标高度表已就绪时为 null，瞬时切换不遮罩。
  DateTime? _switchOverlayUntil;
  Timer? _switchOverlayTimer;

 @override
void initState() {
  super.initState();
  // 每次进入对比页，清空行列表（一次性会话）。
  ref.read(lineListTextProvider.notifier).state = '';
  WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(viewModeProvider.notifier).state =
          ref.read(defaultViewModeProvider);
    });
  _tabScrollController.addListener(_onTabScroll);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final mode = ref.read(viewModeProvider);
    final ctx = _tabKeys[mode]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: Duration.zero, alignment: 0.5);
    }
  });
  }

  @override
  void dispose() {

    _findDebounce?.cancel();
_floatTimer?.cancel();
_floatEntry?.remove();
    _switchOverlayTimer?.cancel();
    _findController.dispose();
    _replaceController.dispose();
    _tabScrollController.removeListener(_onTabScroll);
    _tabScrollController.dispose();
    _scrollController.dispose();
    _hScrollController.dispose();
    super.dispose();
  }

  DiffResult? get _diff => ref.read(diffResultProvider).value;

  int? get _currentMatchEntry {
    if (_matchEntries.isEmpty) return null;
    if (_matchPos < 0 || _matchPos >= _matchEntries.length) return null;
    return _matchEntries[_matchPos];
  }

  bool _isDiffOnlyMode(ViewMode m) =>
      m == ViewMode.diffOnly || m == ViewMode.diffOnlyPlain;

  bool get _isLargeFile {
    final diff = _diff;
    return diff != null && diff.entries.length > 2000;
  }

  void _log(String msg) {
    if (!ref.read(diagHistoryEnabledProvider)) return;
    DiagHistory.record(msg);
  }

  // ==================== 查找 / 替换基础逻辑 ====================

  Pattern _buildFindPattern() {
    final q = _findQuery;
    if (q.isEmpty) return RegExp(r'(?!)');
    var src = _regexEnable ? q : RegExp.escape(q);
    if (_wholeWord) src = r'\b' + src + r'\b';
    try {
      return RegExp(src, caseSensitive: !_caseInsensitive, multiLine: true);
    } catch (_) {
      return RegExp(r'(?!)');
    }
  }

  ({String name, String detail}) _translateRegexError(Object e) {
    var msg = e.toString();
    for (final p in const ['FormatException: ', 'Exception: ']) {
      if (msg.startsWith(p)) {
        msg = msg.substring(p.length);
        break;
      }
    }
    const table = <String, (String, String)>{
      'Unterminated character class': (
        '字符类 [ 没有闭合',
        '正则里每个 [ 都要有一个 ] 配对。\n'
            '比如 [abc 应改成 [abc]，[0-9 应改成 [0-9]。',
      ),
      'Unterminated group': (
        '括号 ( 没有闭合',
        '每个 ( 都要有一个 ) 配对。\n'
            '比如 (abc 应改成 (abc)，((a)(b) 应改成 ((a)(b))。',
      ),
      'Nothing to repeat': (
        '量词前面没有可重复的内容',
        '*、+、?、{n} 这些符号前面必须有东西让它们重复。\n'
            '比如 *abc 应改成 a*bc；想匹配任意字符，应改成 .*abc。',
      ),
      'Lone quantifier brackets': (
        '出现了单独的 { 或 }',
        '{ 和 } 在正则里是量词符号（如 {2,5} 表示重复 2 到 5 次）。\n'
            '如果只是想要字面的花括号，请写成 \\{ 和 \\}。',
      ),
      'Range out of order': (
        '字符类的范围顺序反了',
        '比如 [z-a] 里 z 比 a 大，是无效的。\n'
            '范围要从小到大写，比如 [a-z]。',
      ),
      'Invalid range': (
        '量词范围写法不对',
        '{n,m} 里 n 必须小于等于 m，且都是非负整数。\n'
            '比如 {5,2} 应改成 {2,5}。',
      ),
      'Invalid escape': (
        '含非法的转义字符',
        '反斜杠只能转义有限的字符：\\d \\w \\s \\. \\* \\\\ 等。\n'
            '如果你想搜字面的反斜杠，请写两个反斜杠 \\\\。',
      ),
      'Invalid Unicode escape': (
        'Unicode 转义写法不对',
        '\\u 后面必须跟 4 位十六进制数字，比如 \\u4e2d 表示"中"。',
      ),
      'Invalid decimal escape': (
        '十进制转义写法不对',
        '\\1 \\2 在正则里表示反向引用（引用前面捕获到的内容），\n'
            '但引用的组必须已经存在。',
      ),
      'Invalid group': (
        '分组写法不对',
        '常见错误：\n'
            '· (?:abc) 非捕获组，? 后面必须是 : 或 = 或 ! 或 <\n'
            '· (?<name>...) 命名组，name 只能用字母、数字、下划线',
      ),
      'Invalid capture group name': (
        '捕获组名字不合法',
        '(?<名字>...) 里的名字只能用字母、数字、下划线，不能有空格或中文。',
      ),
      'Duplicate capture group name': (
        '捕获组名字重复',
        '同一个正则里 (?<name>...) 的 name 不能重复出现。',
      ),
      'Invalid named reference': (
        '引用了不存在的命名组',
        '\\k<name> 里的 name 必须在前面的 (?<name>...) 里定义过。',
      ),
      'Trailing': (
        '末尾是反斜杠 \\，后面缺字符',
        '反斜杠必须后跟一个字符才有效。\n'
            '如果只想搜字面的反斜杠，请写两个反斜杠 \\\\。',
      ),
    };
    for (final entry in table.entries) {
      if (msg.contains(entry.key)) {
        return (name: entry.value.$1, detail: entry.value.$2);
      }
    }
    return (
      name: '语法有误',
      detail: 'Dart 返回的原始错误：$msg\n'
          '常见排查：\n'
          '· 方括号 [ ] 是否配对\n'
          '· 圆括号 ( ) 是否配对\n'
          '· 反斜杠 \\ 后面是否有字符\n'
          '· { n,m } 里的数字是否从小到大',
    );
  }

  int _countCaptureGroups(String pattern) {
    var count = 0;
    var i = 0;
    var inClass = false;
    while (i < pattern.length) {
      final c = pattern.codeUnitAt(i);
      if (c == 0x5C) { i += 2; continue; }
      if (inClass) {
        if (c == 0x5D) inClass = false;
        i++;
        continue;
      }
      if (c == 0x5B) { inClass = true; i++; continue; }
      if (c == 0x28) {
        if (i + 1 < pattern.length && pattern.codeUnitAt(i + 1) == 0x3F) {
          if (i + 2 < pattern.length) {
            final c3 = pattern.codeUnitAt(i + 2);
            if (c3 == 0x3A || c3 == 0x21 || c3 == 0x3D) {
              i += 3;
              continue;
            }
            if (c3 == 0x3C && i + 3 < pattern.length) {
              final c4 = pattern.codeUnitAt(i + 3);
              if (c4 == 0x3D || c4 == 0x21) {
                i += 4;
                continue;
              }
              count++;
              i += 3;
              continue;
            }
          }
          i += 2;
          continue;
        }
        count++;
      }
      i++;
    }
    return count;
  }

  int? _captureGroupCount() {
    if (!_regexEnable) return null;
    var src = _findQuery;
    if (src.isEmpty) return null;
    if (_wholeWord) src = r'\b' + src + r'\b';
    try {
      RegExp(src);
    } catch (_) {
      return null;
    }
    return _countCaptureGroups(src);
  }

  String? _diagnoseFind(String q) {
    if (q.isEmpty) return null;
    if (_regexEnable) {
      var src = q;
      if (_wholeWord) src = r'\b' + src + r'\b';
      try {
        RegExp(src, caseSensitive: !_caseInsensitive, multiLine: true);
      } catch (e) {
        final info = _translateRegexError(e);
        throw _RegexError(name: info.name, detail: info.detail);
      }
    }
    if (_wholeWord && RegExp(r'[\u4e00-\u9fff]').hasMatch(q)) {
      return '「整词」对中文无效\n'
          '「整词」的原理是在搜索词前后加 \\b（单词边界标记），\n'
          '但 \\b 只认英文字母、数字、下划线，中文字符不算单词，\n'
          '所以搜"北京"这类纯中文时，开着「整词」多半搜不到任何结果。\n'
          '建议：搜中文时把「整词」关掉。';
    }
    return null;
  }

  String? _diagnoseReplace() {
    final repl = _replaceController.text;
    if (repl.isEmpty) return null;
    if (!_regexEnable) return null;
    final bslash = RegExp(r'\\[1-9]').firstMatch(repl);
    if (bslash != null) {
      final n = bslash.group(0)![1];
      return '替换文本里的 ${bslash.group(0)} 不会生效\n'
          '本功能引用捕获组要用 \$ 符号，不是反斜杠。\n'
          '第 1 个捕获组写 \$1，第 2 个写 \$2，以此类推。\n'
          '请把 ${bslash.group(0)} 改成 \$$n。';
    }
    final groups = _captureGroupCount();
    if (groups != null) {
      for (final m in RegExp(r'\$(\d+)').allMatches(repl)) {
        final n = int.parse(m.group(1)!);
        if (n > groups) {
          final groupWord = groups == 0 ? '没有捕获组' : '只有 $groups 个捕获组';
          return '替换文本里的 \$$n 超出范围\n'
              '当前正则有 $groupWord，\n'
              '\$$n 会被替换成空字符串（不是你想的内容）。\n'
              '请检查是不是想用 \$1、\$2、\$3；\n'
              '如果需要更多捕获组，请在正则里多加括号 ()。';
        }
      }
    }
    if (RegExp(r'\$(?!\d)').hasMatch(repl)) {
      return '替换文本里的 \$ 用法提示\n'
          '本功能里 \$ 后面必须紧跟数字（如 \$1、\$2）才表示捕获组。\n'
          '现在这个 \$ 后面是别的字符，会被当成字面的 \$ 输出。\n'
          '· 如果想引用捕获组：改成 \$1、\$2 之类；\n'
          '· 如果想输出字面的 \$ 字符：目前暂不支持转义，请改用其他符号。';
    }
    return null;
  }

  void _onReplaceInput(String _) {
    final hint = _diagnoseReplace();
    if (hint == _replaceHint) return;
    setState(() => _replaceHint = hint);
  }

  String _expandReplacement(String tpl, Match m) {
    final out = StringBuffer();
    final re = RegExp(r'\$(\d+)');
    var last = 0;
    for (final match in re.allMatches(tpl)) {
      out.write(tpl.substring(last, match.start));
      final idx = int.parse(match.group(1)!);
      out.write(m.group(idx) ?? '');
      last = match.end;
    }
    out.write(tpl.substring(last));
    return out.toString();
  }

  String _applyReplace(String text, String replacement) {
    final p = _buildFindPattern();
    if (_regexEnable) {
      return text.replaceAllMapped(p, (m) => _expandReplacement(replacement, m));
    }
    return text.replaceAll(p, replacement);
  }

  bool _entryMatchesOnLeft(DiffEntry e) {
    if (!_searchLeft) return false;
    if (e.operation == DiffOperation.insert) return false;
    return true;
  }

  bool _entryMatchesOnRight(DiffEntry e) {
    if (!_searchRight) return false;
    if (e.operation == DiffOperation.delete) return false;
    return true;
  }

  String _entryLeftText(DiffEntry e) {
    if (e.operation == DiffOperation.replace && e.oldText.isNotEmpty) {
      return e.oldText;
    }
    return e.text;
  }

  String _entryRightText(DiffEntry e) {
    if (e.operation == DiffOperation.replace && e.newText.isNotEmpty) {
      return e.newText;
    }
    return e.text;
  }

  Set<int> _visibleEntriesFor(ViewMode mode, DiffResult diff) {
    final s = <int>{};
    switch (mode) {
      case ViewMode.diffOnly:
        for (final spec in cachedDiffOnlyRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.diffOnlyPlain:
        for (final spec in cachedDiffOnlyPlainRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.sideBySide:
        for (final spec in cachedAlignedRows(diff)) {
          if (spec.del != null) s.add(spec.del!);
          if (spec.ins != null) s.add(spec.ins!);
        }
        break;
      case ViewMode.merged:
        for (final ei in cachedMergedOrder(diff)) {
          s.add(ei);
        }
        break;
      case ViewMode.grouped:
        break;
    }
    return s;
  }

  void _onFindInput(String q) {
    _findDebounce?.cancel();
    setState(() => _findQuery = q);
    final delay = _isLargeFile
        ? const Duration(milliseconds: 600)
        : const Duration(milliseconds: 250);
    _findDebounce = Timer(delay, () {
      if (!mounted) return;
      _findChanged(q);
    });
  }

  void _findChanged(String q, {bool autoScroll = true}) {
    _findWarning = null;
    try {
      final warn = _diagnoseFind(q);
      _findWarning = warn;
    } on _RegexError catch (e) {
      _findQuery = q;
      _scannedQuery = q;
      setState(() {
        _matchEntries = const [];
        _matchPos = -1;
        _regexErrorHint = '正则语法错误：${e.name}\n${e.detail}';
      });
      (_groupedKey.currentState as dynamic)?.updateFindQuery('');
      return;
    }
    if (_regexErrorHint != null) {
      setState(() => _regexErrorHint = null);
    }

    if (ref.read(viewModeProvider) == ViewMode.grouped) {
      _findQuery = q;
      _scannedQuery = q;

      final diff = _diff;
      final matches = <int>[];
      if (q.isNotEmpty && diff != null) {
        final p = _buildFindPattern();
        for (var i = 0; i < diff.entries.length; i++) {
          final e = diff.entries[i];
          var hit = false;
          if (_entryMatchesOnLeft(e) &&
              p.allMatches(_entryLeftText(e)).isNotEmpty) {
            hit = true;
          }
          if (!hit &&
              _entryMatchesOnRight(e) &&
              p.allMatches(_entryRightText(e)).isNotEmpty) {
            hit = true;
          }
          if (hit) matches.add(i);
        }
      }
      final isLiteral = !_regexEnable && !_caseInsensitive && !_wholeWord;
      setState(() {
        _matchEntries = matches;
        _matchPos = matches.isEmpty ? -1 : 0;
        if (_findWarning != null) {
          _noResultHint = _findWarning;
        } else if (q.isNotEmpty && matches.isEmpty) {
          _noResultHint = '没找到「$q」';
        } else if (q.isNotEmpty && !isLiteral) {
          _noResultHint = '高级搜索已开，搜索结果暂不支持显示高亮';
        } else {
          _noResultHint = null;
        }
      });
      if (isLiteral) {
        (_groupedKey.currentState as dynamic)?.updateFindQuery(q);
      } else {
        (_groupedKey.currentState as dynamic)?.updateFindQuery('');
      }

      if (autoScroll && matches.isNotEmpty) {
        (_groupedKey.currentState as dynamic)?.scrollToEntry(matches[0]);
      }
      return;
    }

    _findQuery = q;
    _scannedQuery = q;
    final diff = _diff;
    final matches = <int>[];
    var hasGlobalHits = false;
    String? hint;

    if (q.isNotEmpty && diff != null) {
      final p = _buildFindPattern();
      final mode = ref.read(viewModeProvider);
      final visible = _visibleEntriesFor(mode, diff);
      for (var i = 0; i < diff.entries.length; i++) {
        if (!visible.contains(i)) continue;
        final e = diff.entries[i];
        var hit = false;
        if (_entryMatchesOnLeft(e) &&
            p.allMatches(_entryLeftText(e)).isNotEmpty) {
          hit = true;
        }
        if (!hit &&
            _entryMatchesOnRight(e) &&
            p.allMatches(_entryRightText(e)).isNotEmpty) {
          hit = true;
        }
        if (hit) matches.add(i);
      }

      if (matches.isEmpty && _isDiffOnlyMode(mode)) {
        for (var i = 0; i < diff.entries.length; i++) {
          final e = diff.entries[i];
          if (p.allMatches(_entryLeftText(e)).isNotEmpty ||
              p.allMatches(_entryRightText(e)).isNotEmpty) {
            hasGlobalHits = true;
            break;
          }
        }
        if (hasGlobalHits) {
          hint = '本视图搜不到，切视图试试';
        }
      }
    }
    if (q.isNotEmpty && (_regexEnable || _caseInsensitive || _wholeWord)) {
      const warn = '高级搜索已开，搜索结果暂不支持显示高亮';
      hint = hint == null ? warn : '$hint\n$warn';
    }
    int newPos = 0;
    if (matches.isNotEmpty && diff != null) {
      final mode = ref.read(viewModeProvider);
      final topRow = _currentTopRow();
      if (topRow != null) {
        final map = _entryToRowMapOf(diff, mode);
        for (var i = 0; i < matches.length; i++) {
          final r = map[matches[i]];
          if (r != null && r >= topRow) {
            newPos = i;
            break;
          }
        }
      }
    }

    setState(() {
      _matchEntries = matches;
      _matchPos = matches.isEmpty ? -1 : newPos;
      _noResultHint = _findWarning ?? hint;
if (_noResultHint == null &&
    q.isNotEmpty &&
    (_regexEnable || _caseInsensitive || _wholeWord)) {
  _noResultHint = '高级搜索已开，搜索结果暂不支持显示高亮';
}
    });
    if (autoScroll && matches.isNotEmpty) {
      _scrollToEntry(matches[newPos]);
    }
  }

  void _ensureFindApplied() {
    _findDebounce?.cancel();
    if (_scannedQuery != _findController.text) {
      _findChanged(_findController.text, autoScroll: false);
    }
  }

  void _recordFindHistory() {
    final q = _findController.text;
    if (q.trim().isEmpty) return;
    ref.read(findHistoryProvider.notifier).add(q);
  }

  Future<void> _showFindHistory() async {
    await showDialog<void>(
      context: context,
      builder: (_) => FindHistoryDialog(
        onPick: (q) {
          _findController.text = q;
          setState(() => _findQuery = q);
        },
      ),
    );
  }

  // ==================== 替换 ====================

  void _replaceCurrentInline() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    final hint = _diagnoseReplace();
    if (hint != null) {
      setState(() => _replaceHint = hint);
      _toast(hint);
      return;
    }
    if (_matchEntries.isEmpty || _matchPos < 0) {
      _toast('没有可替换的内容');
      return;
    }
    _doReplace(replacement: _replaceController.text, all: false);
  }

  void _replaceAllInline() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    final hint = _diagnoseReplace();
    if (hint != null) {
      setState(() => _replaceHint = hint);
      _toast(hint);
      return;
    }
    if (_matchEntries.isEmpty) {
      _toast('没有可替换的内容');
      return;
    }
    _doReplace(replacement: _replaceController.text, all: true);
  }

  void _doReplace({required String replacement, required bool all}) {
    final diff = _diff;
    if (diff == null) return;

    final targets = all
        ? _matchEntries
        : (_matchPos >= 0 && _matchPos < _matchEntries.length
            ? <int>[_matchEntries[_matchPos]]
            : const <int>[]);
    if (targets.isEmpty) {
      _toast('没有可替换的内容');
      return;
    }

    final meta = _computeLineMeta(diff);
    final p = _buildFindPattern();
    var count = 0;

    for (final ei in targets) {
      final e = diff.entries[ei];

      if (_entryMatchesOnLeft(e) && meta[ei].orig >= 0) {
        final origLine = meta[ei].orig;
        final current = _pendingOrigChanges[origLine] ?? _entryLeftText(e);
        if (p.allMatches(current).isNotEmpty) {
          _pendingOrigChanges[origLine] = _applyReplace(current, replacement);
          count++;
        }
      }

      if (_entryMatchesOnRight(e) && meta[ei].mod >= 0) {
        final modLine = meta[ei].mod;
        final current = _pendingModChanges[modLine] ?? _entryRightText(e);
        if (p.allMatches(current).isNotEmpty) {
          _pendingModChanges[modLine] = _applyReplace(current, replacement);
          count++;
        }
      }
    }

    if (count == 0) {
      _toast('没有可替换的内容');
      return;
    }

    setState(() {});
    _toast('已加入待应用队列（$count 处）· 点"应用并刷新"生效');
  }

  void _applyPendingChanges() {
    if (_pendingOrigChanges.isEmpty && _pendingModChanges.isEmpty) return;

    _applyRawChanges(isOriginal: true, changes: _pendingOrigChanges);
    _applyRawChanges(isOriginal: false, changes: _pendingModChanges);
    _pendingOrigChanges.clear();
    _pendingModChanges.clear();
    _rememberCurrentRowForReset();
    _log('应用替换（重算中）');
    ref.read(importRevisionProvider.notifier).state++;
    _resetViewAfterEdit();
    _toast('已应用替换');
  }

  void _applyRawChanges({
    required bool isOriginal,
    required Map<int, String> changes,
  }) {
    if (changes.isEmpty) return;

    final current = ref.read(
      isOriginal ? preprocessedOriginalProvider : preprocessedModifiedProvider,
    );
    if (current.isEmpty) return;

    final lines = current.split('\n');
    for (final entry in changes.entries) {
      final lineNo = entry.key;
      if (lineNo < 0 || lineNo >= lines.length) continue;
      lines[lineNo] = entry.value;
    }
    final newProcessed = lines.join('\n');

    if (isOriginal) {
      ref.read(editedOriginalProvider.notifier).state = newProcessed;
    } else {
      ref.read(editedModifiedProvider.notifier).state = newProcessed;
    }
  }

  Future<void> _closeFindBar() async {
    if (_pendingOrigChanges.isNotEmpty || _pendingModChanges.isNotEmpty) {
      if (!mounted) return;
      final n = _pendingOrigChanges.length + _pendingModChanges.length;
      final choice = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('有未应用的替换'),
          content: Text('有 $n 处修改还没应用，怎么处理？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, 'cancel'),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, 'discard'),
              child: const Text('放弃'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, 'apply'),
              child: const Text('应用并关闭'),
            ),
          ],
        ),
      );
      if (choice == 'cancel' || choice == null) return;
      if (choice == 'apply') {
        _applyPendingChanges();
      } else {
        _pendingOrigChanges.clear();
        _pendingModChanges.clear();
      }
    }

    if (!mounted) return;
    if (ref.read(viewModeProvider) == ViewMode.grouped) {
      (_groupedKey.currentState as dynamic)?.clearFind();
    }
    _findDebounce?.cancel();
    _findController.clear();
    _replaceController.clear();
    setState(() {
      _showFind = false;
      _findQuery = '';
      _scannedQuery = '';
      _matchEntries = const [];
      _matchPos = -1;
      _noResultHint = null;
      _findWarning = null;
      _replaceHint = null;
      _regexErrorHint = null;
    });
  }

  // ==================== 行数 / 行映射 ====================

  Map<int, int> _entryToRowMapOf(DiffResult diff, ViewMode mode) {
    if (identical(_entryToRowMapFor, diff) &&
        _entryToRowMapMode == mode &&
        _entryToRowMap != null) {
      return _entryToRowMap!;
    }
    final map = <int, int>{};
    if (mode == ViewMode.merged) {
      final order = cachedMergedOrder(diff);
      for (var r = 0; r < order.length; r++) {
        map[order[r]] = r;
      }
    } else if (mode == ViewMode.sideBySide) {
      final rows = cachedAlignedRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    } else if (mode == ViewMode.diffOnlyPlain) {
      final rows = cachedDiffOnlyPlainRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    } else if (mode == ViewMode.diffOnly) {
      final rows = cachedDiffOnlyRows(diff);
      for (var r = 0; r < rows.length; r++) {
        final spec = rows[r];
        if (spec.del != null) map.putIfAbsent(spec.del!, () => r);
        if (spec.ins != null) map.putIfAbsent(spec.ins!, () => r);
      }
    }
    _entryToRowMap = map;
    _entryToRowMapFor = diff;
    _entryToRowMapMode = mode;
    return map;
  }

  // ==================== 高度表：懒加载 + 后台补精确 ====================

void _startHeightComputation(DiffResult diff, ViewMode mode) {
  if (mode == ViewMode.grouped) return;
  CrashLogger.instance.mark('启动高度计算: ${mode.name}');
  CrashTrace.mark('启动高度计算: ${mode.name}');
  // 预热点一次，正式 build 时会命中同一个 Future 对象。
  _getHeightFuture(diff, mode);
}

  Future<_HeightBundle> _getHeightFuture(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.grouped) return _emptyHeightFuture;

    final mq = MediaQuery.of(context);
    final configKey = '${mq.size.width}|'
        '${ref.read(bodyFontSizeProvider)}|'
        '${ref.read(contextFontSizeProvider)}|'
        '${ref.read(gutterFontSizeProvider)}|'
        '${ref.read(noWrapProvider)}|'
        '${ref.read(showLineNumbersProvider)}|'
        '${ref.read(importRevisionProvider)}';

    if (!identical(_heightFuturesFor, diff) ||
        _heightFuturesConfigKey != configKey) {
      _heightFutures.clear();
      _heightExactResults.clear();
      _completedHeightModes.clear();
      _heightFuturesFor = diff;
      _heightFuturesConfigKey = configKey;
    }

    // ★ 关键：命中的是同一个 Future 对象，FutureBuilder 不会认为它变了。
    // 不在这里再包 catchError，否则每次返回新 Future，视图反复重建。
    final existing = _heightFutures[mode];
    if (existing != null) return existing;

    // 首次计算：catchError 只包一次，把降级后的 Future 存起来。
    final f = _computeHeightBundle(diff, mode)
        .catchError((Object e, StackTrace st) {
      debugPrint('高度表计算失败(降级估算): $e\n$st');
      return _getQuickBundle(diff, mode);
    });

    f.then((exact) {
      if (!mounted) return;
      if (!identical(_heightFuturesFor, diff)) return;
      _completedHeightModes.add(mode);
      _heightExactResults[mode] = exact;
      // 内存保护：本会话最多驻留最近 2 个模式的精确表。
      // 旧的丢掉也没关系——全局 LineHeightCache 里还有，重进秒取。
      while (_heightExactResults.length > 2) {
        _heightExactResults.remove(_heightExactResults.keys.first);
      }
      if (ref.read(viewModeProvider) == mode && _activeHeights != exact) {
        ViewerDiag.mark('精确高度表就绪 (${mode.name})');
        _log('精确高度表就绪: ${mode.name}');
        setState(() => _activeHeights = exact);
      }
    });

    _heightFutures[mode] = f;
    return f;
  }

  _HeightBundle _getQuickBundle(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.grouped) return const _HeightBundle();

    final cached = _heightExactResults[mode];
    if (cached != null) return cached;

    final fs = ref.read(bodyFontSizeProvider);
    final h = fs * 1.5 * 1.5 + 10;

    int rows;
    switch (mode) {
      case ViewMode.merged:
        rows = cachedMergedOrder(diff).length;
      case ViewMode.sideBySide:
        rows = cachedAlignedRows(diff).length;
      case ViewMode.diffOnly:
        rows = cachedDiffOnlyRows(diff).length;
      case ViewMode.diffOnlyPlain:
        rows = cachedDiffOnlyPlainRows(diff).length;
      case ViewMode.grouped:
        return const _HeightBundle();
    }

    final table = LineHeightTable.fromHeights(List<double>.filled(rows, h));
    return switch (mode) {
      ViewMode.merged => _HeightBundle(merged: table),
      ViewMode.sideBySide => _HeightBundle(sbsSync: table),
      ViewMode.diffOnly => _HeightBundle(diffOnly: table),
      ViewMode.diffOnlyPlain => _HeightBundle(diffOnlyPlain: table),
      ViewMode.grouped => const _HeightBundle(),
    };
  }

 Future<_HeightBundle> _computeHeightBundle(
  DiffResult diff,
  ViewMode mode,
) async {
  CrashLogger.instance.mark('开始算高度表: ${mode.name}');
  CrashTrace.mark('开始算高度表: ${mode.name}');
  ViewerDiag.mark('高度: 开始 (${mode.name})');
  _log('开始计算高度: ${mode.name}');

  final mq = MediaQuery.of(context);
  final viewportW = mq.size.width;
  final dpr = mq.devicePixelRatio;
  final scaler = mq.textScaler;

  final noWrap = ref.read(noWrapProvider);
  final showLine = ref.read(showLineNumbersProvider);
  final bodySize = ref.read(bodyFontSizeProvider);
  final style = TextStyle(fontSize: bodySize, height: 1.5);

  final fp = contentFingerprint(
    ref.read(originalRawTextProvider) ?? '',
    ref.read(modifiedRawTextProvider) ?? '',
  );
  final rev = ref.read(importRevisionProvider);

  String cacheKey(String name) {
    final base = buildLineHeightCacheKey(
      contentFingerprint: fp,
      importRevision: rev,
      viewModeName: name,
      viewportWidth: viewportW,
      bodyFontSize: bodySize,
      showLineNumbers: showLine,
      noWrap: noWrap,
      devicePixelRatio: dpr,
    );
    final ctxFs = ref.read(contextFontSizeProvider);
    final gutterFs = ref.read(gutterFontSizeProvider);
    return '$base|ctx:$ctxFs|gut:$gutterFs';
  }

  if (mode == ViewMode.merged) {
    final order = cachedMergedOrder(diff);
    final rowW = showLine ? viewportW - 50.0 : viewportW - 16.0;
    final k = cacheKey('merged');
    final cached = LineHeightCache.instance.get(k);
    if (cached != null && cached.length == order.length) {
      CrashLogger.instance.mark('高度表命中缓存: merged');
      CrashTrace.mark('高度表命中缓存: merged');
      ViewerDiag.mark('高度: 完成(命中缓存) (${mode.name})');
      _log('高度完成(缓存): ${mode.name}');
      return _HeightBundle(merged: cached);
    }
    final table = await computeLineHeights(
      itemCount: order.length,
      widthForItem: (_) => rowW,
      textForItem: (i) => diff.entries[order[i]].text,
      style: style,
      textScaler: scaler,
      noWrap: noWrap,
      extraVerticalPadding: 12, // 原 10，加 2px 缓冲，绝对不裁
    );
    LineHeightCache.instance.put(k, table);
    CrashLogger.instance.mark('高度表完成: merged (${order.length}行)');
    CrashTrace.mark('高度表完成: merged (${order.length}行)');
    ViewerDiag.mark('高度: 完成 (${mode.name})');
    _log('高度完成: ${mode.name}');
    return _HeightBundle(merged: table);
  }

  if (mode == ViewMode.sideBySide) {
    final rows = cachedAlignedRows(diff);
    final panelW = (viewportW - 1) / 2;
    final contentW = panelW - 52.0;
    final k = cacheKey('sbs_sync');
    final cached = LineHeightCache.instance.get(k);
    if (cached != null && cached.length == rows.length) {
      CrashLogger.instance.mark('高度表命中缓存: sbs');
      CrashTrace.mark('高度表命中缓存: sbs');
      ViewerDiag.mark('高度: 完成(命中缓存) (${mode.name})');
      _log('高度完成(缓存): ${mode.name}');
      return _HeightBundle(sbsSync: cached);
    }
    final table = await computeLineHeightsForTwoPane(
      itemCount: rows.length,
      leftWidth: contentW,
      rightWidth: contentW,
      leftTextForItem: (i) {
        final spec = rows[i];
        if (spec.del != null) return diff.entries[spec.del!].text;
        return '';
      },
      rightTextForItem: (i) {
        final spec = rows[i];
        if (spec.ins != null) return diff.entries[spec.ins!].text;
        return '';
      },
      style: style,
      textScaler: scaler,
      noWrap: noWrap,
      extraVerticalPadding: 14, // 原 12，加 2px 缓冲
    );
    LineHeightCache.instance.put(k, table);
    CrashLogger.instance.mark('高度表完成: sbs (${rows.length}行)');
    CrashTrace.mark('高度表完成: sbs (${rows.length}行)');
    ViewerDiag.mark('高度: 完成 (${mode.name})');
    _log('高度完成: ${mode.name}');
    return _HeightBundle(sbsSync: table);
  }

  final isPlain = mode == ViewMode.diffOnlyPlain;
  final rows =
      isPlain ? cachedDiffOnlyPlainRows(diff) : cachedDiffOnlyRows(diff);
  final panelW = (viewportW - 1) / 2;
  final contentW = panelW - 44.0;
  final k = cacheKey(isPlain ? 'diff_only_plain' : 'diff_only');
  final cached = LineHeightCache.instance.get(k);
  if (cached != null && cached.length == rows.length) {
    CrashLogger.instance.mark('高度表命中缓存: diffOnly');
    CrashTrace.mark('高度表命中缓存: diffOnly');
    ViewerDiag.mark('高度: 完成(命中缓存) (${mode.name})');
    _log('高度完成(缓存): ${mode.name}');
    return isPlain
        ? _HeightBundle(diffOnlyPlain: cached)
        : _HeightBundle(diffOnly: cached);
  }

  final bool needContextOverride = !isPlain;

  bool isContextRow(int i) {
    if (i < 0 || i >= rows.length) return false;
    final spec = rows[i];
    return spec.ins == null &&
        spec.del != null &&
        diff.entries[spec.del!].operation == DiffOperation.equal;
  }

  final ctxSize = ref.read(contextFontSizeProvider);
  final contextStyle = TextStyle(
    fontSize: ctxSize,
    height: 1.5,
  );

  final table = await computeLineHeightsForTwoPane(
    itemCount: rows.length,
    leftWidth: contentW,
    rightWidth: contentW,
    leftTextForItem: (i) {
      final spec = rows[i];
      if (spec.del != null) {
        final e = diff.entries[spec.del!];
        if (e.operation == DiffOperation.replace && e.oldText.isNotEmpty) {
          return e.oldText;
        }
        return e.text;
      }
      return '';
    },
    rightTextForItem: (i) {
      final spec = rows[i];
      if (spec.ins != null) {
        final e = diff.entries[spec.ins!];
        if (e.operation == DiffOperation.replace && e.newText.isNotEmpty) {
          return e.newText;
        }
        return e.text;
      }
      return '';
    },
    style: style,
    textScaler: scaler,
    noWrap: noWrap,
    extraVerticalPadding: 8,
    styleForItem: needContextOverride
        ? (i) => isContextRow(i) ? contextStyle : null
        : null,
    noWrapForItem: needContextOverride
        ? (i) => isContextRow(i) ? true : noWrap
        : null,
  );
  LineHeightCache.instance.put(k, table);
  CrashLogger.instance.mark(
      '高度表完成: ${isPlain ? "diffOnlyPlain" : "diffOnly"} (${rows.length}行)');
  CrashTrace.mark(
      '高度表完成: ${isPlain ? "diffOnlyPlain" : "diffOnly"} (${rows.length}行)');
  ViewerDiag.mark('高度: 完成 (${mode.name})');
  _log('高度完成: ${mode.name}');
  return isPlain
      ? _HeightBundle(diffOnlyPlain: table)
      : _HeightBundle(diffOnly: table);
}

  LineHeightTable? _activeTableFor(ViewMode mode) {
    final h = _activeHeights;
    if (h == null) return null;
    switch (mode) {
      case ViewMode.merged:
        return h.merged;
      case ViewMode.sideBySide:
        return h.sbsSync ?? h.sbsLeft;
      case ViewMode.diffOnly:
        return h.diffOnly;
      case ViewMode.diffOnlyPlain:
        return h.diffOnlyPlain;
      case ViewMode.grouped:
        return null;
    }
  }

  LineHeightTable? _tableOf(_HeightBundle? h, ViewMode mode) {
    if (h == null) return null;
    switch (mode) {
      case ViewMode.merged:
        return h.merged;
      case ViewMode.sideBySide:
        return h.sbsSync ?? h.sbsLeft;
      case ViewMode.diffOnly:
        return h.diffOnly;
      case ViewMode.diffOnlyPlain:
        return h.diffOnlyPlain;
      case ViewMode.grouped:
        return null;
    }
  }

  // ==================== 滚动 / 跳转 ====================

  int? _findEntryByOrigLine(DiffResult diff, int origLine) {
    final mode = ref.read(viewModeProvider);
    final visible = _visibleEntriesFor(mode, diff);
    final meta = _computeLineMeta(diff);
    int? best;
    var bestDist = 1 << 30;
    for (final i in visible) {
      final o = meta[i].orig;
      if (o < 0) continue;
      final d = (o - origLine).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  void _scrollToEntry(int entryIndex) {
    final diff = _diff;
    if (diff == null) {
      _log('_scrollToEntry($entryIndex): 中断 diff==null');
      return;
    }
    final mode = ref.read(viewModeProvider);
    final table = _activeTableFor(mode);
    if (table == null) {
      _log('_scrollToEntry($entryIndex): 中断 table==null');
      return;
    }
    if (!_scrollController.hasClients) {
      _log('_scrollToEntry($entryIndex): 中断 noClients');
      return;
    }

    final map = _entryToRowMapOf(diff, mode);
    final row = map[entryIndex];
    if (row == null) {
      _log('_scrollToEntry($entryIndex): 中断 row==null');
      return;
    }

    final offset = table.offsetOf(row);
    final max = _scrollController.position.maxScrollExtent;
    final clamped = offset < 0 ? 0.0 : (offset > max ? max : offset);
    _log('_scrollToEntry($entryIndex): row=$row offset=$offset max=$max clamped=$clamped');
    _scrollController.jumpTo(clamped);

    if (_jumpedToEntry != entryIndex) {
      setState(() => _jumpedToEntry = entryIndex);
    }
  }

  void _nextMatch() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    if (_matchEntries.isEmpty) {
      _toast('没有找到「$_findQuery」');
      return;
    }
   final next = (_matchPos + 1) % _matchEntries.length;
setState(() => _matchPos = next);

bool jumped = true;
if (ref.read(viewModeProvider) == ViewMode.grouped) {
  jumped = (_groupedKey.currentState as dynamic)
          ?.scrollToEntry(_matchEntries[next]) as bool? ??
      false;
} else {
  _scrollToEntry(_matchEntries[next]);
}

if (!jumped) {
  _toast('这处在折叠的相同行里，点下一个继续');
} else if (_matchEntries.length > 1 &&
    next == _matchEntries.length - 1) {
  _toast('已经是最后一个结果，再点回到第一个');
}
    }

  void _prevMatch() {
    _ensureFindApplied();
    _recordFindHistory();
    if (_findQuery.isEmpty) {
      _toast('请先输入查找内容');
      return;
    }
    if (_matchEntries.isEmpty) {
      _toast('没有找到「$_findQuery」');
      return;
    }
    final prev = (_matchPos - 1 + _matchEntries.length) % _matchEntries.length;
setState(() => _matchPos = prev);

bool jumped = true;
if (ref.read(viewModeProvider) == ViewMode.grouped) {
  jumped = (_groupedKey.currentState as dynamic)
          ?.scrollToEntry(_matchEntries[prev]) as bool? ??
      false;
} else {
  _scrollToEntry(_matchEntries[prev]);
}

if (!jumped) {
  _toast('这处在折叠的相同行里，点上一个继续');
} else if (_matchEntries.length > 1 && prev == 0) {
  _toast('已经是第一个结果，再点回到最后一个');
}
  }

  void _openEdit() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const EditScreen()),
    );
  }

  void _openRegexHelp() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RegexHelpScreen()),
    );
  }

  void _openDiagnostic() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DiagnosticScreen()),
    );
  }

  List<int> _diffIndices() {
    final diff = _diff;
    if (diff == null) return const <int>[];
    if (identical(_cachedDiffIndicesFor, diff) && _cachedDiffIndices != null) {
      return _cachedDiffIndices!;
    }
    final list = <int>[];
    var inBlock = false;
    for (var i = 0; i < diff.entries.length; i++) {
      final isDiff = diff.entries[i].operation != DiffOperation.equal;
      if (isDiff && !inBlock) {
        list.add(i);
        inBlock = true;
      } else if (!isDiff) {
        inBlock = false;
      }
    }
    _cachedDiffIndices = list;
    _cachedDiffIndicesFor = diff;
    return list;
  }

  int _diffBlockCount(DiffResult diff) {
    var count = 0;
    var inBlock = false;
    for (final e in diff.entries) {
      final isDiff = e.operation != DiffOperation.equal;
      if (isDiff && !inBlock) {
        count++;
        inBlock = true;
      } else if (!isDiff) {
        inBlock = false;
      }
    }
    return count;
  }

  int? _currentTopRow() {
    final diff = _diff;
    if (diff == null) return null;
    final mode = ref.read(viewModeProvider);
    final table = _activeTableFor(mode);
    if (table == null) return null;
    if (!_scrollController.hasClients) return null;
    return table.indexAt(_scrollController.position.pixels);
  }

  Future<void> _jumpToDocTop() async {
  CrashLogger.instance.mark('跳到文首');
  if (!_scrollController.hasClients) return;
  if (_jumping) return;

  setState(() {
    _jumping = true;
    _jumpDirection = JumpDirection.up;
  });
  await WidgetsBinding.instance.endOfFrame;

  var stableFrames = 0;
  for (var step = 0; step < 3000; step++) {
    if (!mounted || !_scrollController.hasClients) break;
    final p = _scrollController.position;

    if (p.pixels <= 0.5) {
      stableFrames++;
      if (stableFrames >= 3) break;
    } else {
      stableFrames = 0;
      final next = (p.pixels - p.viewportDimension * 30)
          .clamp(0.0, p.maxScrollExtent);
      if ((p.pixels - next).abs() < 0.5) {
        _scrollController.jumpTo(0);
      } else {
        _scrollController.jumpTo(next);
      }
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  if (mounted && _scrollController.hasClients) {
    if (_scrollController.position.pixels > 0.5) {
      _scrollController.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  if (!mounted) return;
  setState(() => _jumping = false);
}

  Future<void> _jumpToDocBottom() async {
  CrashLogger.instance.mark('跳到文末');
  if (!_scrollController.hasClients) return;
  if (_jumping) return;

  setState(() {
    _jumping = true;
    _jumpDirection = JumpDirection.down;
  });
  await WidgetsBinding.instance.endOfFrame;

  var stableFrames = 0;
  for (var step = 0; step < 3000; step++) {
    if (!mounted || !_scrollController.hasClients) break;
    final p = _scrollController.position;

    if (p.pixels >= p.maxScrollExtent - 0.5) {
      stableFrames++;
      if (stableFrames >= 3) break;
    } else {
      stableFrames = 0;
      final next = (p.pixels + p.viewportDimension * 30)
          .clamp(0.0, p.maxScrollExtent);
      if ((next - p.pixels).abs() < 0.5) {
        _scrollController.jumpTo(p.maxScrollExtent);
      } else {
        _scrollController.jumpTo(next);
      }
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  if (mounted && _scrollController.hasClients) {
    final p = _scrollController.position;
    if (p.pixels < p.maxScrollExtent - 0.5) {
      _scrollController.jumpTo(p.maxScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  if (!mounted) return;
  setState(() => _jumping = false);
}

  void _onTabScroll() {
    if (!mounted) return;
    if (!_tabScrollController.hasClients) return;
    final pos = _tabScrollController.position;
    final atEnd = pos.pixels >= pos.maxScrollExtent - 1;
    if (atEnd != _tabAtEnd) {
      setState(() => _tabAtEnd = atEnd);
    }
  }

  void _scrollTabsToEnd() {
    if (!_tabScrollController.hasClients) return;
    _tabScrollController.animateTo(
      _tabScrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _pageDown() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final target = (pos.pixels + pos.viewportDimension * 0.95)
        .clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < 0.5) return;
    _scrollController.jumpTo(target);
  }

  void _pageUp() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final target = (pos.pixels - pos.viewportDimension * 0.95)
        .clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < 0.5) return;
    _scrollController.jumpTo(target);
  }

 void _jumpToNextDiff() {
  CrashLogger.instance.mark('跳到下一处差异');
  final diff = _diff;
  if (diff == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    final currentRow = _currentTopRow();
    if (currentRow == null) return;

    final indices = _diffIndices();
    if (indices.isEmpty) return;

    for (final ei in indices) {
      final r = map[ei];
      if (r != null && r > currentRow) {
        _log('跳转: 下一处差异');
        _scrollToEntry(ei);
        return;
      }
    }
    _toast('到底了');
  }

 void _jumpToPrevDiff() {
  CrashLogger.instance.mark('跳到上一处差异');
  final diff = _diff;
  if (diff == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    final currentRow = _currentTopRow();
    if (currentRow == null) return;

    final indices = _diffIndices();
    if (indices.isEmpty) return;

    for (var i = indices.length - 1; i >= 0; i--) {
      final ei = indices[i];
      final r = map[ei];
      if (r != null && r < currentRow) {
        _log('跳转: 上一处差异');
        _scrollToEntry(ei);
        return;
      }
    }
    _toast('到顶了');
  }

  // ==================== 切视图 ====================

 Future<void> _switchView(ViewMode newMode) async {
  CrashLogger.instance.mark('切视图 -> ${_viewModeName(newMode)}');
  CrashTrace.mark('切视图 -> ${_viewModeName(newMode)}');
  final current = ref.read(viewModeProvider);
  if (current == newMode) return;

    if (newMode == ViewMode.grouped || current == ViewMode.grouped) {
      _log('切视图: ${_viewModeName(newMode)}');
      ref.read(viewModeProvider.notifier).state = newMode;
      setState(() {});
      _ensureTabVisible(newMode);
      return;
    }

    // 注意：高度计算挪到对话框确认之后才启动。
    // 以前是弹对话框前就开算，大文件计算会把主线程塞满，
    // 对话框和旧画面一起冻住，用户以为死机。
    final searchEntry = _currentMatchEntry;
    final hasSearch = _findQuery.isNotEmpty && _matchEntries.isNotEmpty;

    final choice = await _showSwitchChoiceDialog(
      newMode: newMode,
      hasSearch: hasSearch,
      searchEntry: searchEntry,
    );
    if (!mounted || choice == null) return;

    final diff = _diff;
    if (diff != null) {
      _startHeightComputation(diff, newMode);
    }

    _log('切视图: ${_viewModeName(newMode)}');
    ref.read(viewModeProvider.notifier).state = newMode;
    // 就绪即走：目标高度表已算完则瞬时切换不遮罩；
    // 未就绪才遮罩，保底 600ms 表情动画。
    _switchOverlayUntil = _completedHeightModes.contains(newMode)
        ? null
        : DateTime.now().add(const Duration(milliseconds: 600));
    _switchOverlayTimer?.cancel();

    final target = choice.isTop ? -1 : (choice.targetEntry ?? -1);
    _pendingJumpEntry = target;
    _pendingJumpOrigLine = null;
    _pendingJumpQueued = false;
    setState(() {});
    _ensureTabVisible(newMode);
  }

  void _ensureTabVisible(ViewMode mode, {bool instant = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _tabKeys[mode]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration:
              instant ? Duration.zero : const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _tabLabel(ViewMode m) {
    switch (m) {
      case ViewMode.diffOnly:
        return '差异行+上下2行';
      case ViewMode.diffOnlyPlain:
        return '仅显示差异行';
      case ViewMode.grouped:
        return '跨行块';
      case ViewMode.merged:
        return '全文上下';
      case ViewMode.sideBySide:
        return '全文并排';
    }
  }

  String _viewModeName(ViewMode m) {
    switch (m) {
      case ViewMode.merged:
        return '全文上下合并';
      case ViewMode.sideBySide:
        return '全文左右并排';
      case ViewMode.diffOnly:
        return '差异行+上下2行';
      case ViewMode.diffOnlyPlain:
        return '仅显示差异行';
      case ViewMode.grouped:
        return '跨行块';
    }
  }

  Future<_SwitchChoice?> _showSwitchChoiceDialog({
    required ViewMode newMode,
    required bool hasSearch,
    required int? searchEntry,
  }) async {
    final modeName = _viewModeName(newMode);

    final diff = _diff;
    final mode = ref.read(viewModeProvider);
    final map = diff == null ? <int, int>{} : _entryToRowMapOf(diff, mode);
    final topRow = _currentTopRow();

    int? entryAtRowDelta(int delta) {
      if (diff == null || topRow == null || map.isEmpty) return null;
      var target = topRow + delta;
      if (target < 0) target = 0;
      int? best;
      var bestDist = 1 << 30;
      for (final e in map.entries) {
        final d = (e.value - target).abs();
        if (d < bestDist) {
          bestDist = d;
          best = e.key;
        }
      }
      return best;
    }

    final entry0 = entryAtRowDelta(0);
    final entry1 = entryAtRowDelta(1);
    final entry2 = entryAtRowDelta(2);
    final entryNeg = entryAtRowDelta(-1);

    String preview(int? entryIndex) {
      if (diff == null || entryIndex == null) return '';
      final e = diff.entries[entryIndex];
      final raw =
          (e.operation == DiffOperation.replace && e.newText.isNotEmpty)
              ? e.newText
              : e.text;
      if (raw.isEmpty) return '（空行）';
      return raw.length > 20 ? '${raw.substring(0, 20)}…' : raw;
    }

    Widget choiceTile({
      required IconData icon,
      required String title,
      required String? subtitle,
      required VoidCallback onTap,
    }) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null || subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
        onTap: onTap,
      );
    }

    return showDialog<_SwitchChoice>(
      context: context,
      builder: (c) {
        final children = <Widget>[];

        if (hasSearch && searchEntry != null) {
          children.add(choiceTile(
            icon: Icons.search,
            title: '跳到我搜的那个词',
            subtitle: preview(searchEntry),
            onTap: () => Navigator.pop(c, _SwitchChoice.entry(searchEntry)),
          ));
        } else {
          if (entry0 != null) {
            children.add(choiceTile(
              icon: Icons.looks_one,
              title: '停在我现在看的地方（屏幕第 1 行）',
              subtitle: preview(entry0),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry0)),
            ));
          }
          if (entry1 != null) {
            children.add(choiceTile(
              icon: Icons.looks_two,
              title: '停在我现在看的地方（屏幕第 2 行）',
              subtitle: preview(entry1),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry1)),
            ));
          }
          if (entry2 != null) {
            children.add(choiceTile(
              icon: Icons.looks_3,
              title: '停在我现在看的地方（屏幕第 3 行）',
              subtitle: preview(entry2),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entry2)),
            ));
          }
          if (entryNeg != null) {
            children.add(choiceTile(
              icon: Icons.expand_less,
              title: '屏幕顶部再往上一点',
              subtitle: preview(entryNeg),
              onTap: () => Navigator.pop(c, _SwitchChoice.entry(entryNeg)),
            ));
          }
        }

        children.add(const Divider(height: 1));
        children.add(choiceTile(
          icon: Icons.vertical_align_top,
          title: '跳到文件最开头',
          subtitle: null,
          onTap: () => Navigator.pop(c, const _SwitchChoice.top()),
        ));

        return SimpleDialog(
          title: Text('切换到$modeName视图'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                '切换后请选择要跳转到的位置：',
                style: Theme.of(c).textTheme.bodySmall,
              ),
            ),
            ...children,
          ],
        );
      },
    );
  }

  Future<void> _showGroupedContextMenu() async {
    final current = ref.read(groupedContextLinesProvider).round();
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '跨行块视图 · 上下文行数',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            for (final n in const <int>[0, 1, 2, 3, 5, 8, 10])
              ListTile(
                leading: Icon(
                  n == 0 ? Icons.crop_square : Icons.view_agenda_outlined,
                  size: 20,
                ),
                title: Text(
                  n == 0 ? '仅显示差异块' : '上下各 $n 行相同内容',
                ),
                trailing: current == n
                    ? Icon(Icons.check,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(c, n),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(c),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    ref.read(groupedContextLinesProvider.notifier).update(picked.toDouble());
  }

  Future<void> _pickDefaultViewMode() async {
    final currentDefault = ref.read(defaultViewModeProvider);
    final currentOrder = List<ViewMode>.from(ref.read(viewModeOrderProvider));

    await showDialog<void>(
      context: context,
      builder: (c) {
        var order = currentOrder;
        var selected = currentDefault;
        return StatefulBuilder(
          builder: (c, setDialogState) => AlertDialog(
            title: const Text('默认打开视图'),
            contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(c).size.height * 0.6,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '点选设为默认；拖右侧手柄可调整 tab 显示顺序。',
                      style: Theme.of(c).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: order.length,
                      onReorder: (oldIndex, newIndex) {
                        if (newIndex > oldIndex) newIndex--;
                        final next = List<ViewMode>.from(order);
                        final item = next.removeAt(oldIndex);
                        next.insert(newIndex, item);
                        setDialogState(() => order = next);
                      },
                      itemBuilder: (ctx, i) {
                        final m = order[i];
                        return RadioListTile<ViewMode>(
                          key: ValueKey(m.name),
                          value: m,
                          groupValue: selected,
                          title: Text(_viewModeName(m)),
                          onChanged: (v) {
                            if (v == null) return;
                            setDialogState(() => selected = v);
                          },
                          secondary: ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setDialogState(() => order = ViewMode.values.toList());
                },
                child: const Text('恢复默认顺序'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  ref
                      .read(defaultViewModeProvider.notifier)
                      .update(selected);
                  ref.read(viewModeOrderProvider.notifier).setAll(order);
                  Navigator.pop(c);
                },
                child: const Text('保存'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    _toast('已保存');
  }

  Future<void> _toggleOrientation() async {
    setState(() => _landscape = !_landscape);
    await SystemChrome.setPreferredOrientations(_landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp]);
  }

  void _openDisplaySettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const DisplaySettingsSheet(),
    );
  }

  Future<void> _openComparisonSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const ComparisonSettingsScreen(
          confirmOnExit: true,
        ),
      ),
    );
    if (!mounted) return;
    if (changed != true) {
      _log('比较设置返回，规则未变，跳过重算');
      return;
    }
    _rememberCurrentRowForReset();

    _log('比较设置返回，规则已变，重算');
    ref.read(importRevisionProvider.notifier).state++;
    _resetViewAfterEdit();
  }

  // ==================== 导出差异 ====================

  ({List<String> left, List<String> right}) _collectDiffParts(
      DiffResult diff) {
    final leftParts = <String>[];
    final rightParts = <String>[];

    final entries = diff.entries;
    var i = 0;
    while (i < entries.length) {
      if (entries[i].operation == DiffOperation.equal) {
        i++;
        continue;
      }
      final delLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.delete) {
        delLines.add(entries[i].text);
        i++;
      }
      final insLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.insert) {
        insLines.add(entries[i].text);
        i++;
      }

      final pairs = delLines.length < insLines.length
          ? delLines.length
          : insLines.length;

      for (var k = 0; k < pairs; k++) {
        final segs =
            DiffCache.instance.charSegments(delLines[k], insLines[k]);
        for (final (op, text) in segs) {
          if (text.isEmpty) continue;
          if (op == -1) {
            leftParts.add(text);
          } else if (op == 1) {
            rightParts.add(text);
          }
        }
      }

      for (var k = pairs; k < delLines.length; k++) {
        leftParts.add(delLines[k]);
      }
      for (var k = pairs; k < insLines.length; k++) {
        rightParts.add(insLines[k]);
      }
    }

    return (left: leftParts, right: rightParts);
  }

  /// 按差异块收集整行，用于导出：连续的 delete/insert 归为一组。
  /// type: 'mod' 修改（成对）、'del' 删除（仅左侧有）、'ins' 新增（仅右侧有）。
  List<({String type, List<String> left, List<String> right})>
      _collectDiffGroups(DiffResult diff) {
    final groups =
        <({String type, List<String> left, List<String> right})>[];

    final entries = diff.entries;
    var i = 0;
    while (i < entries.length) {
      if (entries[i].operation == DiffOperation.equal) {
        i++;
        continue;
      }
      final delLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.delete) {
        delLines.add(entries[i].text);
        i++;
      }
      final insLines = <String>[];
      while (i < entries.length &&
          entries[i].operation == DiffOperation.insert) {
        insLines.add(entries[i].text);
        i++;
      }

      if (delLines.isEmpty && insLines.isEmpty) continue;
      groups.add((
        type: delLines.isEmpty
            ? 'ins'
            : insLines.isEmpty
                ? 'del'
                : 'mod',
        left: delLines,
        right: insLines,
      ));
    }
    return groups;
  }
Future<void> _openLineListFromDiff({required bool isLeft}) async {
  final diff = _diff;
  if (diff == null) {
    _toast('还没有差异可列出');
    return;
  }
  final parts = _collectDiffParts(diff);
  final list = isLeft ? parts.left : parts.right;
  if (list.isEmpty) {
    _toast(isLeft ? '左侧没有差异' : '右侧没有差异');
    return;
  }
  await _openLineList(appendLines: list);
}

Future<void> _openLineList({List<String>? appendLines}) async {
  if (appendLines != null && appendLines.isNotEmpty) {
    final cur = ref.read(lineListTextProvider);
    final existing = cur.isEmpty ? <String>[] : cur.split('\n');
    final existingSet = existing.where((l) => l.isNotEmpty).toSet();
    final added = <String>[];
    for (final l in appendLines) {
      if (l.isEmpty) continue;
      if (existingSet.contains(l)) continue;
      existingSet.add(l);
      added.add(l);
    }
    final merged = [...existing, ...added].join('\n');
    ref.read(lineListTextProvider.notifier).state = merged;
  }
   if (!mounted) return;
  await Navigator.of(context).push(
    PageRouteBuilder(
      pageBuilder: (_, __, ___) => const LineListPage(),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
}
  Future<void> _exportDiff() async {
    final diff = _diff;
    if (diff == null) return;

    final groups = _collectDiffGroups(diff);
    if (groups.isEmpty) {
      _toast('没有差异可导出');
      return;
    }

    final leftName = ref.read(originalFileNameProvider);
    final rightName = ref.read(modifiedFileNameProvider);

    final buf = StringBuffer();
    buf.writeln('- ${leftName ?? "原文件"}');
    buf.writeln('+ ${rightName ?? "修改版"}');
    buf.writeln();

    for (final g in groups) {
      for (final l in g.left) {
        buf.writeln('- $l');
      }
      for (final r in g.right) {
        buf.writeln('+ $r');
      }
      buf.writeln();
    }

    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));

    final out = await FilePicker.saveFile(
      fileName: 'docdiff-${DateTime.now().millisecondsSinceEpoch}.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: '导出差异',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out != null && mounted) {
      _toast('差异已导出');
    }
  }

  // ==================== 长按：直接编辑 ====================

  List<({int orig, int mod})> _computeLineMeta(DiffResult result) {
    final meta = <({int orig, int mod})>[];
    var o = 0, m = 0;
    for (final e in result.entries) {
      final usesOrig = e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.delete ||
          e.operation == DiffOperation.replace;
      final usesMod = e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.insert ||
          e.operation == DiffOperation.replace;
      meta.add((orig: usesOrig ? o : -1, mod: usesMod ? m : -1));
      if (usesOrig) o++;
      if (usesMod) m++;
    }
    return meta;
  }

  void _replaceRawLine({
    required bool isOriginal,
    required int normalizedLine,
    required String newText,
  }) {
    final current = ref.read(
      isOriginal ? preprocessedOriginalProvider : preprocessedModifiedProvider,
    );
    if (current.isEmpty) return;

    final lines = current.split('\n');
    if (normalizedLine < 0 || normalizedLine >= lines.length) return;
    lines[normalizedLine] = newText;
    final newProcessed = lines.join('\n');

    if (isOriginal) {
      ref.read(editedOriginalProvider.notifier).state = newProcessed;
    } else {
      ref.read(editedModifiedProvider.notifier).state = newProcessed;
    }
  }

  Future<void> _onRowLongPress(List<int> entryIndices) async {
    final diff = _diff;
    if (diff == null || entryIndices.isEmpty) return;

    int? origEntryIdx;
    int? modEntryIdx;
    for (final i in entryIndices) {
      final op = diff.entries[i].operation;
      if (op == DiffOperation.equal) {
        origEntryIdx ??= i;
        modEntryIdx ??= i;
      } else if (op == DiffOperation.delete ||
          op == DiffOperation.replace) {
        origEntryIdx ??= i;
      } else if (op == DiffOperation.insert) {
        modEntryIdx ??= i;
      }
    }
    if (origEntryIdx == null && modEntryIdx == null) return;

    final meta = _computeLineMeta(diff);

    String? origText;
    String? modText;
    int? origLine;
    int? modLine;

    if (origEntryIdx != null) {
      final e = diff.entries[origEntryIdx];
      origText =
          (e.operation == DiffOperation.replace && e.oldText.isNotEmpty)
              ? e.oldText
              : e.text;
      final m = meta[origEntryIdx].orig;
      if (m >= 0) origLine = m;
    }
    if (modEntryIdx != null) {
      final e = diff.entries[modEntryIdx];
      modText =
          (e.operation == DiffOperation.replace && e.newText.isNotEmpty)
              ? e.newText
              : e.text;
      final m = meta[modEntryIdx].mod;
      if (m >= 0) modLine = m;
    }

    final edited = await _showRowEditDialog(
      origText: origText,
      modText: modText,
    );
    if (edited == null) return;

    if (origLine != null && origText != null) {
      _replaceRawLine(
        isOriginal: true,
        normalizedLine: origLine,
        newText: edited.orig,
      );
    }
    if (modLine != null && modText != null) {
      _replaceRawLine(
        isOriginal: false,
        normalizedLine: modLine,
        newText: edited.mod,
      );
    }

    _log('编辑行（重算中）');
    ref.read(importRevisionProvider.notifier).state++;
    _pendingJumpEntry = null;
    _pendingJumpOrigLine = origLine ?? modLine;
    _pendingJumpQueued = false;
    _log('编辑行: pendingOrigLine=$_pendingJumpOrigLine origLine=$origLine modLine=$modLine');
    _resetViewAfterEdit();
  }

  Future<({String orig, String mod})?> _showRowEditDialog({
    required String? origText,
    required String? modText,
  }) async {
    final origCtrl = TextEditingController(text: origText ?? '');
    final modCtrl = TextEditingController(text: modText ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('编辑此行'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消',
              onPressed: () => Navigator.pop(c, false),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('确定'),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (origText != null) ...[
                  const Text('左边'),
                  const SizedBox(height: 4),
                  Expanded(
                    child: TextField(
                      controller: origCtrl,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      autofocus: modText == null,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.4,
                      ),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(c).colorScheme.primary,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ),
                ],
                if (origText != null && modText != null)
                  const SizedBox(height: 12),
                if (modText != null) ...[
                  const Text('右边'),
                  const SizedBox(height: 4),
                  Expanded(
                    child: TextField(
                      controller: modCtrl,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      autofocus: true,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.4,
                      ),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(c).colorScheme.primary,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return null;
    return (orig: origCtrl.text, mod: modCtrl.text);
  }

  void _rememberCurrentRowForReset() {
    final diff = _diff;
    if (diff == null) return;

    if (ref.read(viewModeProvider) == ViewMode.grouped) {
  final state = _groupedKey.currentState;
  final off = (state as dynamic)?.currentScrollOffset as double?;
  CrashLogger.instance.mark('[restore] 主screen 记位置 off=$off');
  if (off != null) {
    ref.read(groupedRestoreOffsetProvider.notifier).state = off;
  }
  return;
}

    final topRow = _currentTopRow();
    if (topRow == null) return;
    final mode = ref.read(viewModeProvider);
    final map = _entryToRowMapOf(diff, mode);
    int? bestEntry;
    var bestDist = 1 << 30;
    for (final e in map.entries) {
      final d = (e.value - topRow).abs();
      if (d < bestDist) {
        bestDist = d;
        bestEntry = e.key;
      }
    }
    if (bestEntry != null) {
      final meta = _computeLineMeta(diff);
      final o = meta[bestEntry].orig;
      final m = meta[bestEntry].mod;
      _pendingJumpEntry = null;
      _pendingJumpOrigLine = o >= 0 ? o : (m >= 0 ? m : null);
      _pendingJumpQueued = false;
    }
  }

  void _resetViewAfterEdit() {
    _matchEntries = const <int>[];
    _matchPos = -1;
    _noResultHint = null;
    _scannedQuery = '';
    _cachedDiffIndices = null;
    _cachedDiffIndicesFor = null;
    _entryToRowMap = null;
    _entryToRowMapFor = null;
    _entryToRowMapMode = null;
    _heightFutures.clear();
    _heightExactResults.clear();
    _completedHeightModes.clear();
    _heightFuturesFor = null;
    _heightFuturesConfigKey = null;
    _cachedContentWidth = null;
    _cachedContentWidthFor = null;
    _cachedContentWidthConfig = null;

    DiffTextIndex.invalidate();
    setState(() {});



    if (ref.read(viewModeProvider) == ViewMode.grouped) {
  // 位置已经通过 groupedRestoreOffsetProvider 传给 GroupedDiffView，
  // 它在收到新 diff 时自己恢复，不依赖 State 存活。
  _pendingGroupedRestoreOffset = null;
  _pendingJumpEntry = null;
  _pendingJumpOrigLine = null;
  _pendingJumpQueued = false;
  CrashLogger.instance.mark('[restore] 主screen reset');
  return;
}




    

    if (_pendingJumpEntry == null && _pendingJumpOrigLine == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scrollController.hasClients) _scrollController.jumpTo(0);
        if (_hScrollController.hasClients) _hScrollController.jumpTo(0);
      });
    }
  }

  void _showFloatHint(String msg) {
  if (!mounted) return;
  _floatTimer?.cancel();
  _floatEntry?.remove();
  _floatEntry = null;

  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 0,
      right: 0,
      top: MediaQuery.of(context).size.height * 0.35,
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: Theme.of(context)
                .colorScheme
                .inverseSurface
                .withValues(alpha: 0.9),
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              child: Text(
                msg,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onInverseSurface,
                  fontSize: 13,
                ),
                maxLines: 3,
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
  _floatEntry = entry;
  _floatTimer = Timer(const Duration(milliseconds: 1800), () {
    if (identical(_floatEntry, entry)) {
      entry.remove();
      _floatEntry = null;
    }
  });
}

void _toast(String msg) {
  _showFloatHint(msg);
}

  // ---------- 删除文件 ----------

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _fmtTime(DateTime t) {
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<bool> _confirmDelete(String label, String? path) async {
    if (path == null) return false;
    int? size;
    DateTime? modified;
    try {
      final st = await File(path).stat();
      size = st.size;
      modified = st.modified;
    } catch (_) {}

    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除$label？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请确认以下信息，防止删错：'),
            const SizedBox(height: 8),
            Text('路径：$path', style: Theme.of(c).textTheme.bodySmall),
            if (size != null)
              Text('大小：${_fmtSize(size)}',
                  style: Theme.of(c).textTheme.bodySmall),
            if (modified != null)
              Text('修改时间：${_fmtTime(modified)}',
                  style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(
              '删除后无法恢复。',
              style: TextStyle(
                color: Theme.of(c).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteSide({required bool isOriginal}) async {
    final path = ref.read(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final label = isOriginal ? '左边文件' : '右边文件';
    // 弹窗打开期间，给即将被删的那一栏盖红色遮罩。
    setState(() => _pendingDeleteOriginal = isOriginal);
    final ok = await _confirmDelete(label, path);
    if (mounted) {
      setState(() => _pendingDeleteOriginal = null);
    }
    if (!ok || !mounted) return;

    try {
      await File(path!).delete();
      if (!mounted) return;
      setState(() {
        if (isOriginal) {
          _originalDeleted = true;
        } else {
          _modifiedDeleted = true;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label 已删除')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final diffAsync = ref.watch(diffResultProvider);
    final viewMode = ref.watch(viewModeProvider);

    return diffAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: const _LoadingBody(),
      ),
      error: (e, st) => Scaffold(
        appBar: AppBar(title: const Text('对比结果')),
        body: Center(child: Text('计算差异失败：$e')),
      ),
      data: (diff) {
        final origName = ref.watch(originalFileNameProvider);
        final modName = ref.watch(modifiedFileNameProvider);
        if (diff == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('对比结果')),
            body: const Center(child: Text('请先导入两份文档')),
          );
        }
        return _buildWithHeights(diff, viewMode, origName, modName);
      },
    );
  }

  Widget _buildWithHeights(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
  ) {
    if (!identical(_lastDiagDiff, diff)) {
      _lastDiagDiff = diff;
      ViewerDiag.reset();
      ViewerDiag.mark('diff 计算完成，进入渲染');
      _log('diff 已就绪，准备渲染');
    }

    final future = _getHeightFuture(diff, viewMode);
    return FutureBuilder<_HeightBundle>(
      future: future,
      builder: (context, snapshot) {
        // ────────── 场景 1：首次进入（还没成功显示过正文）──────────
        // 保留原来的整页 Scaffold + 原转圈动画
        if (!_hasShownContentOnce) {
          if (snapshot.hasError) {
            return Scaffold(
              appBar: AppBar(title: const Text('对比结果')),
              body: Center(child: Text('加载失败：${snapshot.error}')),
            );
          }
          if (!snapshot.hasData) {
            return Scaffold(
              appBar: AppBar(title: const Text('对比结果')),
              body: const _LoadingBody(),
            );
          }
          // 高度表首次就绪，从这里开始进入「已显示过正文」的状态
          _hasShownContentOnce = true;
        }

        // ────────── 从这里开始，_hasShownContentOnce == true ──────────
        final now = DateTime.now();
        final overlayActive =
            _switchOverlayUntil != null && now.isBefore(_switchOverlayUntil!);

        final heights = snapshot.data;
        final tableForCurrent = _tableOf(heights, viewMode);
        final tableReady = viewMode == ViewMode.grouped ||
            (tableForCurrent != null && tableForCurrent.length > 0);

        // ────────── 场景 2：切视图遮罩 / 表还没就绪 ──────────
        // 保留 AppBar、tab、工具栏，只遮内容区
        if (overlayActive || !tableReady) {
          if (overlayActive) {
            _switchOverlayTimer?.cancel();
            _switchOverlayTimer = Timer(const Duration(milliseconds: 60), () {
              if (mounted) setState(() {});
            });
          }
          return _buildDiffScaffold(
            diff,
            viewMode,
            origName,
            modName,
            heights ?? const _HeightBundle(),
            showLoadingOverlay: true,
          );
        }

        // ────────── 场景 3：表就绪，正常渲染 ──────────
        _switchOverlayUntil = null;
        ViewerDiag.mark('视图就绪');
        _activeHeights = heights!;

        if ((_pendingJumpEntry != null || _pendingJumpOrigLine != null) &&
            !_pendingJumpQueued) {
          _pendingJumpQueued = true;

          int? targetEntry = _pendingJumpEntry;
          if (targetEntry == null && _pendingJumpOrigLine != null) {
            targetEntry = _findEntryByOrigLine(diff, _pendingJumpOrigLine!);
            _log('按 origLine=${_pendingJumpOrigLine} 反查到 entry=$targetEntry');
          }
          final target = targetEntry ?? -1;
          _pendingJumpEntry = null;
          _pendingJumpOrigLine = null;
          _log('准备跳转: target=$target mode=${viewMode.name}');

          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            _pendingJumpEntry = null;
            _pendingJumpOrigLine = null;
            _pendingJumpQueued = false;

            for (var attempt = 0; attempt < 5; attempt++) {
              if (!mounted) return;
              if (!_scrollController.hasClients) {
                await WidgetsBinding.instance.endOfFrame;
                continue;
              }
              if (_scrollController.position.maxScrollExtent > 0 ||
                  attempt >= 4) {
                break;
              }
              await WidgetsBinding.instance.endOfFrame;
            }
            if (!mounted) return;

            if (target < 0) {
              _log('跳转: 走 target<0 分支 → 跳到开头');
              if (_scrollController.hasClients) {
                _scrollController.jumpTo(0);
              }
            } else {
              _log('跳转: 走 _scrollToEntry($target)');
              _scrollToEntry(target);
            }
          });
        }

        return _buildDiffScaffold(diff, viewMode, origName, modName, heights);
      },
    );
  }

  // ==================== 内容宽度 ====================

  double _getContentWidth(DiffResult diff, ViewMode mode, double viewportW) {
    final noWrap = ref.read(noWrapProvider);
    if (!noWrap) return viewportW;

    final bodySize = ref.read(bodyFontSizeProvider);
    final showLine = ref.read(showLineNumbersProvider);
    final rev = ref.read(importRevisionProvider);
    final configKey =
        '${viewportW.round()}|${bodySize.round()}|$showLine|${mode.name}|$rev';

    if (identical(_cachedContentWidthFor, diff) &&
        _cachedContentWidthConfig == configKey &&
        _cachedContentWidth != null) {
      return _cachedContentWidth!;
    }

    final charWidth = bodySize * 0.75;
    final numW = showLine ? 44.0 : 16.0;
    final pad = 30.0;

    double computed;

    if (mode == ViewMode.merged) {
      var maxChars = 0;
      for (final ei in cachedMergedOrder(diff)) {
        final t = diff.entries[ei].text;
        if (t.length > maxChars) maxChars = t.length;
      }
      computed = numW + maxChars * charWidth + pad;
    } else {
      computed = viewportW;
    }

    if (computed < viewportW) computed = viewportW;

    _cachedContentWidth = computed;
    _cachedContentWidthFor = diff;
    _cachedContentWidthConfig = configKey;
    return computed;
  }

  // ==================== 视图 ====================

  Widget _buildActiveView(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
    _HeightBundle heights,
    bool noWrap,
  ) {
    final Widget inner = switch (viewMode) {
      ViewMode.merged => MergedView(
          result: diff,
          heightTable: heights.merged ?? LineHeightTable.empty,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          noWrap: noWrap,
          onLongPressEntry: (i) => _onRowLongPress([i]),
        ),
      ViewMode.sideBySide => SideBySideView(
          result: diff,
          syncHeightTable: heights.sbsSync ?? LineHeightTable.empty,
          leftHeightTable: heights.sbsLeft ?? LineHeightTable.empty,
          rightHeightTable: heights.sbsRight ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          syncScroll: true,
          noWrap: noWrap,
          onLongPressEntry: _onRowLongPress,
          onDeleteFile: _deleteSide,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
        ),
      ViewMode.diffOnly => DiffOnlyView(
          result: diff,
          heightTable: heights.diffOnly ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          contextFontSize: ref.watch(contextFontSizeProvider),
          noWrap: noWrap,
          onLongPressEntry: _onRowLongPress,
          onDeleteFile: _deleteSide,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
        ),
      ViewMode.diffOnlyPlain => DiffOnlyPlainView(
          result: diff,
          heightTable: heights.diffOnlyPlain ?? LineHeightTable.empty,
          originalFileName: origName,
          modifiedFileName: modName,
          controller: _scrollController,
          findQuery: _findQuery,
          currentMatchEntry: _currentMatchEntry,
          jumpedToEntry: _jumpedToEntry,
          showLineNumbers: ref.watch(showLineNumbersProvider),
          bodyFontSize: ref.watch(bodyFontSizeProvider),
          gutterFontSize: ref.watch(gutterFontSizeProvider),
          noWrap: noWrap,
          onLongPressEntry: _onRowLongPress,
          onDeleteFile: _deleteSide,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
        ),
      ViewMode.grouped => GroupedDiffView(
          key: _groupedKey,
          deletedLeft: _pendingDeleteOriginal == true,
          deletedRight: _pendingDeleteOriginal == false,
        ),
    };

    if (!noWrap) return inner;

    if (viewMode == ViewMode.merged) {
      final screenW = MediaQuery.of(context).size.width;
      final contentW = _getContentWidth(diff, viewMode, screenW);
      if (contentW <= screenW + 1) return inner;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _hScrollController,
        child: SizedBox(
          width: contentW,
          child: inner,
        ),
      );
    }

    return inner;
  }

  // ==================== 顶栏按钮（返回 / 更多 固定，中间可按设置排序） ====================

  Widget _buildTopBarBack() {
    return SizedBox(
      height: 48,
      child: Tooltip(
        message: '返回',
        child: InkWell(
          onTap: () => Navigator.of(context).maybePop(),
          child: const Center(
            child: Icon(Icons.arrow_back, size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarAction(TopBarButton b, ViewMode viewMode) {
    switch (b) {
      case TopBarButton.pageUp:
        return _buildTopBarPageButton(viewMode: viewMode, up: true);
      case TopBarButton.pageDown:
        return _buildTopBarPageButton(viewMode: viewMode, up: false);
      case TopBarButton.prevDiff:
        return _buildTopBarDiffJump(viewMode: viewMode, prev: true);
      case TopBarButton.nextDiff:
        return _buildTopBarDiffJump(viewMode: viewMode, prev: false);
      case TopBarButton.find:
        return _buildTopBarFind();
      case TopBarButton.deleteLeft:
        return _buildTopBarDelete(isOriginal: true);
      case TopBarButton.deleteRight:
        return _buildTopBarDelete(isOriginal: false);
    }
  }

  Widget _buildTopBarPageButton({
    required ViewMode viewMode,
    required bool up,
  }) {
    return SizedBox(
      height: 48,
      child: Builder(builder: (ctx) {
        final iconColor =
            IconTheme.of(ctx).color ?? Theme.of(ctx).colorScheme.onSurface;
        return InkWell(
          key: Key(up ? 'page-up' : 'page-down'),
          onTap: () {
            if (viewMode == ViewMode.grouped) {
              final s = _groupedKey.currentState as dynamic;
              if (up) {
                s?.pageUp();
              } else {
                s?.pageDown();
              }
            } else {
              if (up) {
                _pageUp();
              } else {
                _pageDown();
              }
            }
          },
          onLongPress: () {
            if (viewMode == ViewMode.grouped) {
              final s = _groupedKey.currentState as dynamic;
              if (up) {
                s?.jumpToTop();
              } else {
                s?.jumpToBottom();
              }
            } else {
              if (up) {
                _jumpToDocTop();
              } else {
                _jumpToDocBottom();
              }
            }
          },
          child: Center(
            child: CustomPaint(
              size: const Size.square(24),
              painter: up
                  ? _PageUpIconPainter(color: iconColor)
                  : _PageDownIconPainter(color: iconColor),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildTopBarDiffJump({
    required ViewMode viewMode,
    required bool prev,
  }) {
    return SizedBox(
      height: 48,
      child: InkWell(
        key: Key(prev ? 'prev-diff' : 'next-diff'),
        onTap: () {
          if (viewMode == ViewMode.grouped) {
            final s = _groupedKey.currentState as dynamic;
            if (prev) {
              s?.jumpToPrevDiff();
            } else {
              s?.jumpToNextDiff();
            }
          } else {
            if (prev) {
              _jumpToPrevDiff();
            } else {
              _jumpToNextDiff();
            }
          }
        },
        onLongPress: () {
          if (viewMode == ViewMode.grouped) {
            final s = _groupedKey.currentState as dynamic;
            if (prev) {
              s?.jumpToTop();
            } else {
              s?.jumpToBottom();
            }
          } else {
            if (prev) {
              _jumpToDocTop();
            } else {
              _jumpToDocBottom();
            }
          }
        },
        child: Center(
          child: Icon(
            prev ? Icons.arrow_upward : Icons.arrow_downward,
            size: 24,
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarFind() {
    return SizedBox(
      height: 48,
      child: Tooltip(
        message: '查找 / 替换',
        child: InkWell(
          onTap: () => setState(() => _showFind = !_showFind),
          child: const Center(
            child: Icon(Icons.find_in_page, size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarDelete({required bool isOriginal}) {
    final deleted = isOriginal ? _originalDeleted : _modifiedDeleted;
    final path = ref.watch(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final enabled = !deleted && path != null;
    final s = Theme.of(context).colorScheme;
    final base = enabled
        ? (IconTheme.of(context).color ?? s.onSurface)
        : s.onSurfaceVariant.withValues(alpha: 0.4);
    final label = isOriginal ? '左边文件' : '右边文件';

    return SizedBox(
      height: 48,
      child: Tooltip(
        message: deleted ? '$label已删除' : '删除$label',
        child: InkWell(
          key: Key(isOriginal ? 'topbar-del-left' : 'topbar-del-right'),
          onTap: enabled ? () => _deleteSide(isOriginal: isOriginal) : null,
          child: Center(
            child: CustomPaint(
              size: const Size.square(22),
              painter: DeleteSideIconPainter(
                color: base,
                accent: enabled ? s.error : base,
                isLeft: isOriginal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDiffScaffold(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
    _HeightBundle heights, {
    bool showLoadingOverlay = false,
  }) {
    final noWrap = ref.watch(noWrapProvider);
    final diffBlocks = _diffBlockCount(diff);

  return PopScope(
  canPop: !_showFind,
  onPopInvokedWithResult: (didPop, result) {
    if (didPop) return;
    if (_showFind) _closeFindBar();
  },
  child: Scaffold(
  appBar: AppBar(
  backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  toolbarHeight: 48,
  automaticallyImplyLeading: false,
  leadingWidth: 0,
  titleSpacing: 0,
  title: Row(
    children: [
      // 固定：返回
      Expanded(child: _buildTopBarBack()),
      // 可排序：按用户设置的顺序
      for (final b in ref.watch(topBarOrderProvider.notifier).visibleButtons)
        Expanded(child: _buildTopBarAction(b, viewMode)),
      // 固定：更多
      Expanded(
        child: PopupMenuButton<String>(
          tooltip: '更多操作',
          padding: EdgeInsets.zero,
          child: const SizedBox(
            height: 48,
            child: Center(child: Icon(Icons.more_vert)),
          ),
          onSelected: (v) {
              final toolbarVisible = ref.read(toolbarVisibleProvider);
              if (v == 'edit') {
                _openEdit();
              } else if (v == 'exportDiff') {
                _exportDiff();
              } else if (v == 'delOriginal') {
                _deleteSide(isOriginal: true);
              } else if (v == 'delModified') {
                _deleteSide(isOriginal: false);
              } else if (v == 'orientation') {
                _toggleOrientation();
              } else if (v == 'noWrap') {
                final cur = ref.read(noWrapProvider);
                ref.read(noWrapProvider.notifier).state = !cur;
                if (_hScrollController.hasClients) {
                  _hScrollController.jumpTo(0);
                }
              } else if (v == 'toggleToolbar') {
                ref.read(toolbarVisibleProvider.notifier).state =
                    !toolbarVisible;
              } else if (v == 'listLeftDiff') {
                _openLineListFromDiff(isLeft: true);
              } else if (v == 'listRightDiff') {
                _openLineListFromDiff(isLeft: false);
              } else if (v == 'displaySettings') {
                _openDisplaySettings();
              } else if (v == 'comparisonSettings') {
                _openComparisonSettings();
              } else if (v == 'diagnostic') {
                _openDiagnostic();
              } else if (v == 'defaultView') {
                _pickDefaultViewMode();
              }
            },
            itemBuilder: (context) {
              final canDeleteOriginal = !_originalDeleted &&
                  ref.read(originalFilePathProvider) != null;
              final canDeleteModified = !_modifiedDeleted &&
                  ref.read(modifiedFilePathProvider) != null;
              final toolbarVisible = ref.read(toolbarVisibleProvider);
              return [
              const PopupMenuItem<String>(
                value: 'exportDiff',
                child: Row(
                  children: [
                    Icon(Icons.ios_share),
                    SizedBox(width: 10),
                    Text('导出差异为 txt'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delOriginal',
                enabled: canDeleteOriginal,
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      color: canDeleteOriginal
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _originalDeleted ? '左边文件已删除' : '删除左边文件',
                      style: TextStyle(
                        color: canDeleteOriginal
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delModified',
                enabled: canDeleteModified,
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      color: canDeleteModified
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _modifiedDeleted ? '右边文件已删除' : '删除右边文件',
                      style: TextStyle(
                        color: canDeleteModified
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'displaySettings',
                child: Row(
                  children: [
                    Icon(Icons.format_size),
                    SizedBox(width: 10),
                    Text('显示设置'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'comparisonSettings',
                child: Row(
                  children: [
                    Icon(Icons.rule),
                    SizedBox(width: 10),
                    Text('对比规则设置'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'toggleToolbar',
                child: Row(
                  children: [
                    Icon(
                      toolbarVisible
                          ? Icons.dashboard_customize
                          : Icons.dashboard_customize_outlined,
                    ),
                    const SizedBox(width: 10),
                    Text(toolbarVisible ? '隐藏工具栏' : '显示工具栏'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'noWrap',
                enabled: viewMode != ViewMode.grouped,
                child: Row(
                  children: [
                    Icon(
                      viewMode == ViewMode.grouped
                          ? Icons.block
                          : (noWrap ? Icons.wrap_text : Icons.notes),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      viewMode == ViewMode.grouped
                          ? '跨行块视图不支持不换行'
                          : (noWrap ? '关闭不换行' : '开启不换行'),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'defaultView',
                child: Row(
                  children: [
                    Icon(Icons.visibility),
                    SizedBox(width: 10),
                    Text('默认打开视图'),
                  ],
                ),
              ),
               PopupMenuItem<String>(
                value: 'orientation',
                child: Row(
                  children: [
                    Icon(
                      _landscape
                          ? Icons.screen_rotation
                          : Icons.rotate_left,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Text(_landscape ? '切换到竖屏' : '切换到横屏'),
                  ],
                ),
              ),

              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'diagnostic',
                child: Row(
                  children: [
                    Icon(Icons.bug_report),
                    SizedBox(width: 10),
                    Text('诊断'),
                  ],
                ),
              ),
            ];
          },
        ),
      ),
    ],
  ),
  actions: const [],
),
  body: Stack(
  children: [
    Column(
      children: [
          if (_originalDeleted || _modifiedDeleted) _buildDeletedBanner(),
          _buildEncodingBanner(),
          if (diffBlocks < 6) _buildFewDiffsBanner(diffBlocks),
          if (_showFind) _buildFindBar(),

          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final order = ref.watch(viewModeOrderProvider);
                  final tabFlex = {
                    ViewMode.diffOnly: 2.4,
                    ViewMode.diffOnlyPlain: 2.4,
                    ViewMode.grouped: 2.4,
                    ViewMode.merged: 2,
                    ViewMode.sideBySide: 2,
                  };
                  const totalFlex = 11.2;

                  const double unitMin = 52.0;
                  final unitW = (constraints.maxWidth / totalFlex)
                      .clamp(unitMin, double.infinity);
                  final totalW = unitW * totalFlex;
                  final needsScroll = totalW > constraints.maxWidth + 0.5;
                  final cs = Theme.of(context).colorScheme;

                  final tabsRow = SizedBox(
                    width: totalW,
                    height: 40,
                    child: Row(
                      children: [
                        for (final m in order)
                          SizedBox(
                            key: _tabKeys[m], // 用于自动滚到高亮
                            width: unitW * tabFlex[m]!,
                            child: _viewChip(
                              label: _tabLabel(m),
                              value: m,
                              current: viewMode,
                              onLongPress: m == ViewMode.grouped
                                  ? _showGroupedContextMenu
                                  : null,
                              trailingIcon: m == ViewMode.grouped
                                  ? Icons.settings_outlined
                                  : null,
                              onTrailingTap: m == ViewMode.grouped
                                  ? _showGroupedContextMenu
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  );

                  if (!needsScroll) return SizedBox(height: 40, child: tabsRow);

                  return Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: SingleChildScrollView(
                            controller: _tabScrollController,
                            scrollDirection: Axis.horizontal,
                            child: tabsRow,
                          ),
                        ),
                      ),
                      if (!_tabAtEnd)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _scrollTabsToEnd,
                          child: Container(
                            width: 24,
                            height: 40,
                            alignment: Alignment.center,
                            color: cs.surfaceContainerLow,
                            child: Icon(
                              Icons.chevron_right,
                              size: 20,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),

          if (ref.watch(toolbarVisibleProvider)) _buildToolbar(),
          if (_processing) _buildProcessingBanner(),
                   Expanded(
              child: showLoadingOverlay
                  ? ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: const Center(child: _SwitchLoadingBody()),
                    )
                  : _buildActiveView(
                      diff,
                      viewMode,
                      origName,
                      modName,
                      heights,
                      noWrap,
                    ),
            ),
          ],
        ),
               if (ref.watch(floatingPageDownEnabledProvider))
          _buildFloatingButton(
            size: ref.watch(floatingPageDownSizeProvider),
            x: ref.watch(floatingPageDownXProvider),
            y: ref.watch(floatingPageDownYProvider),
            opacity: ref.watch(floatingPageDownOpacityProvider),
            borderWidth: ref.watch(floatingPageDownBorderWidthProvider),
            color: ref.watch(floatingPageDownColorProvider),
            onTap: _onFloatingPageDownTap,
          ),
        if (ref.watch(floatingPageUpEnabledProvider))
          _buildFloatingButton(
            size: ref.watch(floatingPageUpSizeProvider),
            x: ref.watch(floatingPageUpXProvider),
            y: ref.watch(floatingPageUpYProvider),
            opacity: ref.watch(floatingPageUpOpacityProvider),
            borderWidth: ref.watch(floatingPageUpBorderWidthProvider),
            color: ref.watch(floatingPageUpColorProvider),
            onTap: _onFloatingPageUpTap,
          ),
        if (_jumping)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: Center(
                  child: JumpIndicator(
                    direction: _jumpDirection,
                    size: 64,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  ));
}



Widget _buildFloatingButton({
  required double size,
  required double x,
  required double y,
  required double opacity,
  required double borderWidth,
  required Color color,
  required VoidCallback onTap,
}) {
  final mq = MediaQuery.of(context);
  final screenW = mq.size.width;
  final screenH = mq.size.height;

  final left = screenW * (x / 100) - size / 2;
  final top = screenH * (y / 100) - size / 2;

  return Positioned(
    left: left,
    top: top,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          border: Border.all(
            color: color.withValues(alpha: opacity / 100),
            width: borderWidth,
          ),
        ),
      ),
    ),
  );
}

void _onFloatingPageDownTap() {
  final mode = ref.read(viewModeProvider);
  if (mode == ViewMode.grouped) {
    (_groupedKey.currentState as dynamic)?.pageDown();
  } else {
    _pageDown();
  }
}

void _onFloatingPageUpTap() {
  final mode = ref.read(viewModeProvider);
  if (mode == ViewMode.grouped) {
    (_groupedKey.currentState as dynamic)?.pageUp();
  } else {
    _pageUp();
  }
}



  
  // ==================== 按钮栏 ====================

  Widget _buildToolbar() {
    final rules = ref.watch(toolbarRulesOrderedProvider);
    final colors = ref.watch(toolbarButtonColorsProvider);
    final s = Theme.of(context).colorScheme;

    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: s.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: s.outlineVariant,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Text(
                      '点 + 添加快捷操作按钮（长按编辑）',
                      style: TextStyle(
                        fontSize: 10,
                        color: s.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: rules.length,
                    itemBuilder: (ctx, i) {
                      final r = rules[i];
                      final c = colors[r.id];
                      final bg = c?.bg ?? s.surface;
                      final fg = c?.fg ?? s.onSurface;
                      final border = c?.border ?? s.outline;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 1,
                          vertical: 3,
                        ),
                        child: GestureDetector(
                          onTap: () => _onToolbarButtonTap(r),
                          onLongPress: () => _editToolbarRule(r),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                            ),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: border),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: fg,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.add, size: 16),
              padding: EdgeInsets.zero,
              tooltip: '新建快捷操作按钮',
              visualDensity: VisualDensity.compact,
              onPressed: _addToolbarRule,
            ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.sort, size: 16),
              padding: EdgeInsets.zero,
              tooltip: '按钮排序、样式更改、删除',
              visualDensity: VisualDensity.compact,
              onPressed: _showToolbarOrderDialog,
            ),
          ),
          TextButton(
            onPressed: () =>
                ref.read(toolbarVisibleProvider.notifier).update(false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '折叠',
              style: TextStyle(fontSize: 11, color: s.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewChip({
    required String label,
    required ViewMode value,
    required ViewMode current,
    bool compact = false,
    VoidCallback? onLongPress,
    IconData? trailingIcon,
    VoidCallback? onTrailingTap,
  }) {
    final selected = value == current;
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _switchView(value),
      onLongPress: onLongPress,
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? s.primary : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal,
                  color:
                      selected ? s.primary : s.onSurfaceVariant,
                ),
              ),
            ),
            if (trailingIcon != null) ...[
              const SizedBox(width: 2),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTrailingTap,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    trailingIcon,
                    size: 14,
                    color: s.onSurfaceVariant
                        .withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingBanner() {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        _processingText,
        style: TextStyle(
          fontSize: 13,
          color: s.onTertiaryContainer,
        ),
      ),
    );
  }

  Future<void> _onToolbarButtonTap(PreprocessingRule rule) async {
    final side = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '「${rule.name}」应用到：',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('只改左侧文件'),
              onTap: () => Navigator.pop(c, 'left'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_forward),
              title: const Text('只改右侧文件'),
              onTap: () => Navigator.pop(c, 'right'),
            ),
            ListTile(
              leading: const Icon(Icons.compare_arrows),
              title: const Text('两侧都改'),
              onTap: () => Navigator.pop(c, 'both'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(c),
            ),
          ],
        ),
      ),
    );
    if (side == null || !mounted) return;
    await _applyToolbarRule(rule, side);
  }

  Future<void> _applyToolbarRule(PreprocessingRule rule, String side) async {
    setState(() {
      _processing = true;
      _processingText = '正在执行「${rule.name}」…';
    });
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      final currentOrig = ref.read(preprocessedOriginalProvider);
      final currentMod = ref.read(preprocessedModifiedProvider);

      if (side == 'left' || side == 'both') {
        if (currentOrig.isNotEmpty) {
          final next = applyOneRule(currentOrig, rule);
          ref.read(editedOriginalProvider.notifier).state = next;
        }
      }
      if (side == 'right' || side == 'both') {
        if (currentMod.isNotEmpty) {
          final next = applyOneRule(currentMod, rule);
          ref.read(editedModifiedProvider.notifier).state = next;
        }
      }
      _rememberCurrentRowForReset();

      _log('按钮规则: ${rule.name} → $side');
      ref.read(importRevisionProvider.notifier).state++;
      _resetViewAfterEdit();

      if (!mounted) return;
      _toast('已应用「${rule.name}」');
    } catch (e) {
      if (mounted) _toast('执行失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _processing = false;
          _processingText = '';
        });
      }
    }
  }

  Future<void> _addToolbarRule() async {
    final rule = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => const RuleEditorDialog(
        showCopyToPreprocess: false,
      ),
    );
    if (rule == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).add(rule);
    _toast('已添加按钮「${rule.name}」');
  }

  Future<void> _editToolbarRule(PreprocessingRule rule) async {
    final updated = await showDialog<PreprocessingRule>(
      context: context,
      builder: (_) => RuleEditorDialog(
        initial: rule,
        showCopyToPreprocess: true,
        onCopyToPreprocess: (copied) {
          _toast('「${copied.name}」已复制到对比规则设置里');
        },
      ),
    );
    if (updated == null || !mounted) return;
    ref.read(toolbarRulesProvider.notifier).updateRule(updated);
  }

  Future<void> _showToolbarOrderDialog() async {
    final rules = ref.read(toolbarRulesOrderedProvider);
    if (rules.isEmpty) {
      _toast('还没有按钮');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => ToolbarOrderDialog(rules: rules),
    );
  }

  Widget _buildDeletedBanner() {
    final parts = <String>[];
    if (_originalDeleted) parts.add('左边文件');
    if (_modifiedDeleted) parts.add('右边文件');
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.error,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: s.onError),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${parts.join(" / ")} 已从磁盘删除（下方内容仅内存保留）',
              style: TextStyle(
                fontSize: 13,
                color: s.onError,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEncodingBanner() {
    final origEnc = ref.watch(originalEncodingProvider);
    final modEnc = ref.watch(modifiedEncodingProvider);
    if (origEnc == modEnc) return const SizedBox.shrink();
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: s.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '两份文件编码不同（$origEnc / $modEnc），已分别解码后对比',
              style: TextStyle(
                fontSize: 13,
                color: s.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFewDiffsBanner(int blocks) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: s.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              blocks == 0
                  ? '两份文档完全相同'
                  : '共 $blocks 处差异，已全部显示',
              style: TextStyle(
                fontSize: 13,
                color: s.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 查找栏 UI ====================

  Widget _buildFindBar() {
    final total = _matchEntries.length;
    final pendingCount =
        _pendingOrigChanges.length + _pendingModChanges.length;
    final s = Theme.of(context).colorScheme;

    Widget toggle({
      required String label,
      required bool value,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
    }) {
      return InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Container(
            height: 32,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: value
                ? BoxDecoration(
                    border: Border.all(
                      color: s.primary,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  )
                : null,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: value ? FontWeight.bold : FontWeight.normal,
                color: value ? s.primary : s.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    // 三选一胶囊（左侧 / 右侧 / 两侧）
    Widget sidePill({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      final s = Theme.of(context).colorScheme;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          splashColor: s.primary.withValues(alpha: 0.18),
          highlightColor: s.primary.withValues(alpha: 0.08),
          child: Container(
            height: 32,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected ? s.primary : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? s.primary : s.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: s.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
               const SizedBox(width: 6),
    Expanded(
  child: SizedBox(
  height: 40,
  child: TextField(
    controller: _findController,
                    autofocus: true,
                    cursorColor: s.primary,
                    decoration: const InputDecoration(
                      hintText: '查找',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: _onFindInput,
                    onSubmitted: (_) => _nextMatch(),
                  ),
                ),
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  color: s.primary,
                  tooltip: '立即搜索',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
  if (_findQuery.isEmpty) {
    _toast('请先输入查找内容');
    return;
  }
  _findDebounce?.cancel();
  _findChanged(_findController.text);
  if (_matchEntries.isEmpty) {
    _toast('没有找到「$_findQuery」');
  }
},
                ),
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: '查找历史',
                  visualDensity: VisualDensity.compact,
                  onPressed: _showFindHistory,
                ),
              ],
            ),
            if (_noResultHint != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: s.tertiaryContainer.withValues(alpha: 0.5),
                  border: Border.all(color: s.tertiary),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 15, color: s.onTertiaryContainer),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _noResultHint!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: s.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                const SizedBox(width: 6),
       Expanded(
  child: Padding(
padding: const EdgeInsets.only(top: 6),
child: SizedBox(
height: 36,
child: TextField(
  controller: _replaceController,
                    cursorColor: s.primary,
                    decoration: const InputDecoration(
                      hintText: '替换为（留空 = 删掉）',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: _onReplaceInput,
                  ),
                ),
),
    ),
                
               TextButton(
  style: TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    foregroundColor: s.primary,
  ),
  onPressed: _matchEntries.isEmpty ? null : _replaceCurrentInline,
  child: const Text('替换当前'),
),
TextButton(
  style: TextButton.styleFrom(
    visualDensity: VisualDensity.compact,
    foregroundColor: s.primary,
  ),
  onPressed: _matchEntries.isEmpty ? null : _replaceAllInline,
  child: const Text('全部替换'),
),



                
              ],
            ),
            if (_replaceHint != null || _regexErrorHint != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4, bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: s.errorContainer.withValues(alpha: 0.5),
                  border: Border.all(color: s.error),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber,
                          size: 15, color: s.error),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        [
                          if (_regexErrorHint != null)
                            '查找框：$_regexErrorHint',
                          if (_replaceHint != null)
                            '替换框：$_replaceHint',
                        ].join('\n\n'),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          fontWeight: FontWeight.bold,
                          color: s.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
     SizedBox(
  height: 40,
  child: Row(
    children: [
      const SizedBox(width: 8),
      const Text(
        '查找/替换范围：',
        style: TextStyle(fontSize: 12),
      ),
      const SizedBox(width: 6),
      sidePill(
        label: '左侧',
        selected: _searchLeft && !_searchRight,
        onTap: () {
          if (_searchLeft && !_searchRight) return;
          setState(() {
            _searchLeft = true;
            _searchRight = false;
          });
          _findChanged(_findController.text);
        },
      ),
      const SizedBox(width: 4),
      sidePill(
        label: '右侧',
        selected: !_searchLeft && _searchRight,
        onTap: () {
          if (!_searchLeft && _searchRight) return;
          setState(() {
            _searchLeft = false;
            _searchRight = true;
          });
          _findChanged(_findController.text);
        },
      ),
      const SizedBox(width: 4),
      sidePill(
        label: '两侧',
        selected: _searchLeft && _searchRight,
        onTap: () {
          if (_searchLeft && _searchRight) return;
          setState(() {
            _searchLeft = true;
            _searchRight = true;
          });
          _findChanged(_findController.text);
        },
      ),
      const Spacer(),
      IconButton(
        icon: const Icon(Icons.arrow_upward),
        iconSize: 30,
        color: s.primary,
        tooltip: '上一个',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
        onPressed: _matchEntries.isEmpty ? null : _prevMatch,
      ),
      IconButton(
        icon: const Icon(Icons.arrow_downward),
        iconSize: 30,
        color: s.primary,
        tooltip: '下一个',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
        onPressed: _matchEntries.isEmpty ? null : _nextMatch,
      ),
    ],
  ),
),
            SizedBox(
  height: 40,
  child: Row(
    children: [
      const SizedBox(width: 8),
      const Text(
        '高级搜索：',
        style: TextStyle(fontSize: 12),
      ),
      const SizedBox(width: 4),
      toggle(
        label: '正则',
        value: _regexEnable,
        onTap: () => setState(() {
          _regexEnable = !_regexEnable;
          _findChanged(_findController.text);
        }),
        onLongPress: _openRegexHelp,
      ),
      toggle(
        label: '忽略大小写',
        value: _caseInsensitive,
        onTap: () => setState(() {
          _caseInsensitive = !_caseInsensitive;
          _findChanged(_findController.text);
        }),
        onLongPress: () => _toast('开启后 A 和 a 视为相同'),
      ),
      toggle(
        label: '整词',
        value: _wholeWord,
        onTap: () => setState(() {
          _wholeWord = !_wholeWord;
          _findChanged(_findController.text);
        }),
        onLongPress: () => _toast('只匹配完整单词，对中文无效'),
      ),
      if (pendingCount > 0) ...[
        const SizedBox(width: 8),
        Text(
          '待应用 $pendingCount',
          style: TextStyle(
            fontSize: 12,
            color: s.tertiary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
      const Spacer(),
      TextButton.icon(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          foregroundColor: pendingCount > 0 ? s.tertiary : null,
        ),
        onPressed: pendingCount > 0 ? _applyPendingChanges : null,
        icon: const Icon(Icons.done_all, size: 16),
        label: const Text('应用并刷新'),
      ),
    ],
  ),
),
          ],
        ),
      ),
    );
  }
}

// ==================== 翻屏图标 ====================

class _PageDownIconPainter extends CustomPainter {
  _PageDownIconPainter({required this.color});

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

    final strokeDim = Paint()
      ..color = color.withValues(alpha: color.a * 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawRect(const Rect.fromLTWH(9, 1, 6, 10), stroke);

    final small = Path()
      ..moveTo(9.5, 14.5)
      ..lineTo(12, 16.5)
      ..lineTo(14.5, 14.5);
    canvas.drawPath(small, strokeDim);

    final large = Path()
      ..moveTo(8.5, 18)
      ..lineTo(12, 20.5)
      ..lineTo(15.5, 18);
    canvas.drawPath(large, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_PageDownIconPainter old) => old.color != color;
}

class _PageUpIconPainter extends CustomPainter {
  _PageUpIconPainter({required this.color});

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

    final strokeDim = Paint()
      ..color = color.withValues(alpha: color.a * 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawRect(const Rect.fromLTWH(9, 13, 6, 10), stroke);

    final small = Path()
      ..moveTo(9.5, 9.5)
      ..lineTo(12, 7.5)
      ..lineTo(14.5, 9.5);
    canvas.drawPath(small, strokeDim);

    final large = Path()
      ..moveTo(8.5, 6)
      ..lineTo(12, 3.5)
      ..lineTo(15.5, 6);
    canvas.drawPath(large, stroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_PageUpIconPainter old) => old.color != color;
}

class _RegexError implements Exception {
  const _RegexError({required this.name, required this.detail});
  final String name;
  final String detail;
}

class _LoadingBody extends StatefulWidget {
  const _LoadingBody();

  @override
  State<_LoadingBody> createState() => _LoadingBodyState();
}

class _LoadingBodyState extends State<_LoadingBody>
    with TickerProviderStateMixin {
  late final AnimationController _clock;   // 表情主时钟
  late final AnimationController _breath;  // 呼吸
  late final AnimationController _intro;   // 开场过渡

  final List<String> _stages = const [
    '正在比较…',
    '正在排版…',
    '马上就绪…',
  ];
  int _stageIndex = 0;
  Timer? _stageTimer;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(hours: 1),
    )..repeat();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _intro.forward();  // 播放一次，不循环
    CrashTrace.mark('进入对比页加载页');
    _stageTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) {
        if (!mounted) return;
        setState(() => _stageIndex = (_stageIndex + 1) % _stages.length);
      },
    );
  }

  @override
  void dispose() {
    _clock.dispose();
    _breath.dispose();
    _intro.dispose();
    _stageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Center(
      child: AnimatedBuilder(
        animation: _intro,
        builder: (_, __) {
          final t = Curves.easeOutCubic.transform(_intro.value);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 72×72 容器：表情在里面
              SizedBox(
                width: 72,
                height: 72,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // （已删除开场小圈：它和表情缩放入场重叠时
                    //   会从透明环里透出来，看着像闪过一个紫色小圆。）
                    // 表情圆：从 36px（scale 0.5）放大到 72px
                    Transform.scale(
                      scale: 0.5 + t * 0.5,
                      child: Opacity(
                        opacity: t,
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_clock, _breath]),
                            builder: (_, __) {
                              final elapsedMs = _clock.value * 3600000.0;
                              return CustomPaint(
                                painter: _LoadingRingPainter(
                                  elapsedMs: elapsedMs,
                                  breath: _breath.value,
                                  color: s.primary,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // 文案：跟表情同步淡入
              Opacity(
                opacity: t,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.4),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: Text(
                    _stages[_stageIndex],
                    key: ValueKey(_stageIndex),
                    style: TextStyle(
                      fontSize: 14,
                      color: s.onSurfaceVariant,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LoadingRingPainter extends CustomPainter {
  _LoadingRingPainter({
    required this.elapsedMs,
    required this.breath,
    required this.color,
  });

  final double elapsedMs;
  final double breath;
  final Color color; // 保留参数以兼容调用方，实际不再使用

  static const double _pi = 3.141592653589793;
  static const double _tau = 2 * _pi;

  static const double _lapMs = 400;         // 每圈 400ms（再快会频闪成模糊光晕）
  static const double _transitionMs = 100;  // 圈速提快后按比例缩短，否则颜色永远在过渡中
  static const double _blinkMs = 3000;      // 表情形态 3 秒一轮

  // 马卡龙色系（Material 300 色阶，柔和粉彩）
  static const Color _lavender = Color(0xFFB388FF);  // 浅紫（提高饱和度+提亮）
  static const Color _pink     = Color(0xFFF6A5C0);  // 浅粉（比原来浅一档）
  static const Color _peach    = Color(0xFFFFB74D);  // 浅橙
  static const Color _lemon    = Color(0xFFFFE082);  // 浅黄
  static const Color _mint     = Color(0xFF81C784);  // 薄荷绿
  static const Color _sky      = Color(0xFF64B5F6);  // 天蓝

  // 如果想第一圈回到主题紫，把 _lavender 换成 color
  List<Color> get _palette => const [
        _lavender,
        _pink,
        _peach,
        _lemon,
        _mint,
        _sky,
      ];

  Color get _currentColor {
    final palette = _palette;
    final n = palette.length;
    final lapIndex = (elapsedMs ~/ _lapMs);
    final tInLap = elapsedMs - lapIndex * _lapMs;

    final curIdx = lapIndex % n;
    if (lapIndex == 0) return palette[0];

    if (tInLap < _transitionMs) {
      final prevIdx = (lapIndex - 1) % n;
      final raw = tInLap / _transitionMs;
      final t = Curves.easeInOut.transform(raw); // 起步/收尾都柔
      return Color.lerp(palette[prevIdx], palette[curIdx], t)!;
    }
    return palette[curIdx];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final baseRadius = size.width / 2 - 4;
    final radius = baseRadius * (0.88 + 0.12 * breath);

    final currentColor = _currentColor;

    final tInLap = (elapsedMs % _lapMs) / _lapMs;
    final arcStart = tInLap * _tau;
    const arcSweep = 1.9;

    // 底环
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = currentColor.withValues(alpha: 0.15),
    );

    // 旋转弧：头部实心，尾部透明
    final rect = Rect.fromCircle(center: center, radius: radius);
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          currentColor.withValues(alpha: 0.0),
          currentColor,
        ],
        stops: const [0.0, 0.30],
        transform: GradientRotation(arcStart),
      ).createShader(rect);

    canvas.drawArc(rect, arcStart, arcSweep, false, arcPaint);

    // 弧头亮点 + 光晕
    final dotAngle = arcStart + arcSweep;
    final dotCenter = Offset(
      center.dx + radius * math.cos(dotAngle),
      center.dy + radius * math.sin(dotAngle),
    );
    canvas.drawCircle(
      dotCenter,
      6,
      Paint()
        ..color = currentColor.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(dotCenter, 3.2, Paint()..color = currentColor);

    // 表情形态：3 秒一轮，与颜色无关
    final blinkMs = elapsedMs % _blinkMs;
    if (blinkMs < 1400) {
      _drawRoundEyes(canvas, center, currentColor);
    } else if (blinkMs < 1500) {
      _drawClosedEyes(canvas, center, currentColor);
    } else if (blinkMs < 2900) {
      _drawCurvedEyes(canvas, center, currentColor);
    } else {
      _drawClosedEyes(canvas, center, currentColor);
    }
  }

  void _drawRoundEyes(Canvas canvas, Offset center, Color c) {
    final fill = Paint()
      ..color = c
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(center: center.translate(-8, -2), width: 9, height: 12),
      fill,
    );
    canvas.drawOval(
      Rect.fromCenter(center: center.translate(8, -2), width: 9, height: 12),
      fill,
    );
    final shine = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center.translate(-10, -5), 1.8, shine);
    canvas.drawCircle(center.translate(6, -5), 1.8, shine);
  }

  void _drawCurvedEyes(Canvas canvas, Offset center, Color c) {
    final stroke = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center.translate(-8, 3), radius: 5.5),
      _pi, _pi, false, stroke,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center.translate(8, 3), radius: 5.5),
      _pi, _pi, false, stroke,
    );
  }

  void _drawClosedEyes(Canvas canvas, Offset center, Color c) {
    final stroke = Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center.translate(-11.5, 0),
      center.translate(-4.5, 0),
      stroke,
    );
    canvas.drawLine(
      center.translate(4.5, 0),
      center.translate(11.5, 0),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_LoadingRingPainter old) =>
      old.elapsedMs != elapsedMs ||
      old.breath != breath ||
      old.color != color;
}

// ==================== 切视图专用加载动画 ====================
//
// 和 _LoadingBody 的区别：
//   1. 不依赖 AnimationController.repeat()，纯 Timer 驱动
//      → 主线程在算高度表时，它依然能跳状态
//   2. 用于「切视图」的遮罩，只在内容区显示（AppBar / tab / 工具栏保留）
//
// 设计：
//   - 圆圈固定不动，颜色每 1.8 秒换一次
//   - 眼睛三态（圆 / 眯 / 闭）每 3 秒变一次
//   - 文字沿用「正在比较 / 排版 / 就绪」
//   - 下面三个点每 0.5 秒轮流亮
class _SwitchLoadingBody extends StatefulWidget {
  const _SwitchLoadingBody();

  @override
  State<_SwitchLoadingBody> createState() => _SwitchLoadingBodyState();
}

class _SwitchLoadingBodyState extends State<_SwitchLoadingBody> {
  static const List<String> _stages = [
    '正在比较…',
    '正在排版…',
    '马上就绪…',
  ];

  static const List<Color> _palette = [
    Color(0xFFB388FF), // 紫
    Color(0xFFF6A5C0), // 粉
    Color(0xFFFFB74D), // 橙
    Color(0xFFFFE082), // 黄
    Color(0xFF81C784), // 绿
    Color(0xFF64B5F6), // 蓝
  ];

  int _stageIndex = 0;
  int _colorIndex = 0;
  int _dotIndex = 0;
  int _eyeIndex = 0;

  Timer? _stageTimer;
  Timer? _colorTimer;
  Timer? _dotTimer;
  Timer? _eyeTimer;

  @override
  void initState() {
    super.initState();
    CrashTrace.mark('进入切视图加载页');
    _stageTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!mounted) return;
      setState(() => _stageIndex = (_stageIndex + 1) % _stages.length);
    });
    _colorTimer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (!mounted) return;
      setState(() => _colorIndex = (_colorIndex + 1) % _palette.length);
    });
    _dotTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() => _dotIndex = (_dotIndex + 1) % 3);
    });
    _eyeTimer = Timer.periodic(const Duration(milliseconds: 3000), (_) {
      if (!mounted) return;
      setState(() => _eyeIndex = (_eyeIndex + 1) % 3);
    });
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _colorTimer?.cancel();
    _dotTimer?.cancel();
    _eyeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _palette[_colorIndex];
    final s = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: CustomPaint(
              painter: _SwitchRingPainter(
                color: color,
                eyeIndex: _eyeIndex,
              ),
            ),
          ),
          const SizedBox(height: 24),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.3),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: Text(
              _stages[_stageIndex],
              key: ValueKey(_stageIndex),
              style: TextStyle(
                fontSize: 14,
                color: s.onSurfaceVariant,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final active = i == _dotIndex;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: active ? 9 : 6,
                height: active ? 9 : 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? color : color.withValues(alpha: 0.25),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _SwitchRingPainter extends CustomPainter {
  _SwitchRingPainter({required this.color, required this.eyeIndex});
  final Color color;
  final int eyeIndex;

  static const double _pi = 3.141592653589793;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 4;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = color.withValues(alpha: 0.2),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = color,
    );

    switch (eyeIndex) {
      case 0:
        _drawRoundEyes(canvas, center);
        break;
      case 1:
        _drawCurvedEyes(canvas, center);
        break;
      case 2:
        _drawClosedEyes(canvas, center);
        break;
    }
  }

  void _drawRoundEyes(Canvas canvas, Offset center) {
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(center: center.translate(-8, -2), width: 9, height: 12),
      fill,
    );
    canvas.drawOval(
      Rect.fromCenter(center: center.translate(8, -2), width: 9, height: 12),
      fill,
    );
    final shine = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center.translate(-10, -5), 1.8, shine);
    canvas.drawCircle(center.translate(6, -5), 1.8, shine);
  }

  void _drawCurvedEyes(Canvas canvas, Offset center) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center.translate(-8, 3), radius: 5.5),
      _pi, _pi, false, stroke,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center.translate(8, 3), radius: 5.5),
      _pi, _pi, false, stroke,
    );
  }

  void _drawClosedEyes(Canvas canvas, Offset center) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center.translate(-11.5, 0),
      center.translate(-4.5, 0),
      stroke,
    );
    canvas.drawLine(
      center.translate(4.5, 0),
      center.translate(11.5, 0),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_SwitchRingPainter old) =>
      old.color != color || old.eyeIndex != eyeIndex;
}

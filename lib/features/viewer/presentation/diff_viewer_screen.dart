import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../../core/constants/app_colors.dart';
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

import '../../../core/debug/crash_logger.dart';
import 'diagnostic_screen.dart';
import 'diff_text_index.dart';
import 'grouped_diff_view.dart';
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

  List<int>? _cachedDiffIndices;
  DiffResult? _cachedDiffIndicesFor;

  Map<int, int>? _entryToRowMap;
  DiffResult? _entryToRowMapFor;
  ViewMode? _entryToRowMapMode;

  // 后台精确高度表
  final Map<ViewMode, Future<_HeightBundle>> _heightFutures = {};
  final Map<ViewMode, _HeightBundle> _heightExactResults = {};
  DiffResult? _heightFuturesFor;
  String? _heightFuturesConfigKey;
  int? _jumpedToEntry;

  double? _pendingGroupedRestoreOffset;

  _HeightBundle? _activeHeights;

  double? _cachedContentWidth;
  DiffResult? _cachedContentWidthFor;
  String? _cachedContentWidthConfig;

  int? _pendingJumpEntry;
  int? _pendingJumpOrigLine;
  bool _pendingJumpQueued = false;

  Timer? _findDebounce;
  bool _processing = false;
  String _processingText = '';

  DiffResult? _lastDiagDiff;

  final GlobalKey _groupedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(viewModeProvider.notifier).state =
          ref.read(defaultViewModeProvider);
    });
  }

  @override
  void dispose() {
    _findDebounce?.cancel();
    _findController.dispose();
    _replaceController.dispose();
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
  CrashLogger.instance.mark('启动高度计算: ${mode.name}');
  if (mode == ViewMode.grouped) return;

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
      _heightFuturesFor = diff;
      _heightFuturesConfigKey = configKey;
    }

    if (_heightFutures.containsKey(mode)) return;

    final f = _computeHeightBundle(diff, mode);
    _heightFutures[mode] = f;
    f.then((exact) {
      if (!mounted) return;
      if (!identical(_heightFuturesFor, diff)) return;
      _heightExactResults[mode] = exact;
      if (ref.read(viewModeProvider) == mode) {
        ViewerDiag.mark('精确高度表就绪，切回精确 (${mode.name})');
        _log('精确高度表就绪: ${mode.name}');
        setState(() {
          _activeHeights = exact;
        });
      }
    }).catchError((Object e, StackTrace st) {
      debugPrint('高度表计算失败: $e\n$st');
    });
  }

  _HeightBundle _getQuickBundle(DiffResult diff, ViewMode mode) {
    if (mode == ViewMode.grouped) return const _HeightBundle();

    final cached = _heightExactResults[mode];
    if (cached != null) return cached;

    final fs = ref.read(bodyFontSizeProvider);
    final h = fs * 1.35 * 1.5 + 8;

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
  ViewerDiag.mark('高度: 开始 (${mode.name})');
  _log('开始计算高度: ${mode.name}');

  final mq = MediaQuery.of(context);
  final viewportW = mq.size.width;
  final dpr = mq.devicePixelRatio;
  final scaler = mq.textScaler;

  final noWrap = ref.read(noWrapProvider);
  final showLine = ref.read(showLineNumbersProvider);
  final bodySize = ref.read(bodyFontSizeProvider);
  final style = TextStyle(fontSize: bodySize, height: 1.35);

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
    if (cached != null) {
      CrashLogger.instance.mark('高度表命中缓存: merged');
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
      extraVerticalPadding: 8,
    );
    LineHeightCache.instance.put(k, table);
    CrashLogger.instance.mark('高度表完成: merged (${order.length}行)');
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
    if (cached != null) {
      CrashLogger.instance.mark('高度表命中缓存: sbs');
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
      extraVerticalPadding: 12,
    );
    LineHeightCache.instance.put(k, table);
    CrashLogger.instance.mark('高度表完成: sbs (${rows.length}行)');
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
  if (cached != null) {
    CrashLogger.instance.mark('高度表命中缓存: diffOnly');
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
    height: 1.35,
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
    extraVerticalPadding: 4,
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
    if (ref.read(viewModeProvider) == ViewMode.grouped) {
      (_groupedKey.currentState as dynamic)?.scrollToEntry(_matchEntries[next]);
    } else {
      _scrollToEntry(_matchEntries[next]);
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
    if (ref.read(viewModeProvider) == ViewMode.grouped) {
      (_groupedKey.currentState as dynamic)?.scrollToEntry(_matchEntries[prev]);
    } else {
      _scrollToEntry(_matchEntries[prev]);
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

  void _jumpToDocTop() {
  CrashLogger.instance.mark('跳到文首');
  if (!_scrollController.hasClients) return;
  _scrollController.jumpTo(0);
}

  void _jumpToDocBottom() {
  CrashLogger.instance.mark('跳到文末');
  if (!_scrollController.hasClients) return;
  _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
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
  final current = ref.read(viewModeProvider);
  if (current == newMode) return;

    if (newMode == ViewMode.grouped || current == ViewMode.grouped) {
      _log('切视图: ${_viewModeName(newMode)}');
      ref.read(viewModeProvider.notifier).state = newMode;
      setState(() {});
      return;
    }

    final diff = _diff;
    if (diff != null) {
      _startHeightComputation(diff, newMode);
    }

    final searchEntry = _currentMatchEntry;
    final hasSearch = _findQuery.isNotEmpty && _matchEntries.isNotEmpty;

    final choice = await _showSwitchChoiceDialog(
      newMode: newMode,
      hasSearch: hasSearch,
      searchEntry: searchEntry,
    );
    if (!mounted || choice == null) return;

    _log('切视图: ${_viewModeName(newMode)}');
    ref.read(viewModeProvider.notifier).state = newMode;

    final target = choice.isTop ? -1 : (choice.targetEntry ?? -1);
    _pendingJumpEntry = target;
    _pendingJumpOrigLine = null;
    _pendingJumpQueued = false;
    setState(() {});
  }

  String _viewModeName(ViewMode m) {
    switch (m) {
      case ViewMode.merged:
        return '合并';
      case ViewMode.sideBySide:
        return '并排';
      case ViewMode.diffOnly:
        return '差异行+上下文';
      case ViewMode.diffOnlyPlain:
        return '仅差异行';
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
    final current = ref.read(defaultViewModeProvider);
    final picked = await showDialog<ViewMode>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('进入对比页时默认显示'),
        children: [
          for (final m in ViewMode.values)
            RadioListTile<ViewMode>(
              value: m,
              groupValue: current,
              title: Text(_viewModeName(m)),
              onChanged: (v) => Navigator.pop(c, v),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      ref.read(defaultViewModeProvider.notifier).update(picked);
      _toast('默认视图已设为「${_viewModeName(picked)}」');
    }
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

  Future<void> _exportDiff() async {
    final diff = _diff;
    if (diff == null) return;

    final side = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('导出哪一侧的差异？',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('导出左边文件的差异处'),
              onTap: () => Navigator.pop(c, 'left'),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_forward),
              title: const Text('导出右边文件的差异处'),
              onTap: () => Navigator.pop(c, 'right'),
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
    if (!mounted || side == null) return;

    final isLeft = side == 'left';
    final parts = _collectDiffParts(diff);
    final list = isLeft ? parts.left : parts.right;

    if (list.isEmpty) {
      _toast('这一侧没有差异可导出');
      return;
    }

    final fileName = isLeft
        ? ref.read(originalFileNameProvider)
        : ref.read(modifiedFileNameProvider);
    final hasEdit = ref.read(
          isLeft ? editedOriginalProvider : editedModifiedProvider,
        ) !=
        null;

    final buf = StringBuffer();

    buf.writeln('# ============================================================');
    buf.writeln('# DocDiff 差异导出');
    buf.writeln('# ============================================================');
    buf.writeln('#');
    buf.writeln('# 导出侧：${isLeft ? "左边（原文件）" : "右边（修改版）"}');
    if (fileName != null && fileName.isNotEmpty) {
      buf.writeln('# 文件：$fileName');
    }
    buf.writeln('# 内容来源：对比页当前显示的内容'
        '${hasEdit ? "（含你在对比页上的编辑）" : ""}，');
    buf.writeln('#           已套用当前所有生效的比较规则。');
    buf.writeln('# 导出时间：${DateTime.now()}');
    buf.writeln('#');
    buf.writeln('# ------------------------------------------------------------');
    buf.writeln('# 【本文件导出的是什么】');
    buf.writeln('# ------------------------------------------------------------');
    buf.writeln('#');
    buf.writeln('# 只包含「这一侧独有的差异字符片段」，相同内容一律不导出。');
    buf.writeln('# 每个片段单独占一行。');
    buf.writeln('#');
    buf.writeln('# 因为做了字符级比对，一个词、一句话可能被切开，');
    buf.writeln('# 只把"变化的那几个字"拿出来。脱离原句单看可能难以理解，');
    buf.writeln('# 这是正常现象。');
    buf.writeln('#');
    buf.writeln('# 举例一：');
    buf.writeln('#   左边：今天我回来是要吃饭的。');
    buf.writeln('#   右边：明天我回来是要吃饭的。');
    buf.writeln('#   本侧导出：明');
    buf.writeln('#   （意思是这句里"今"被改成了"明"）');
    buf.writeln('#');
    buf.writeln('# 举例二：');
    buf.writeln('#   左边：2024-01-01');
    buf.writeln('#   右边：2024-02-02');
    buf.writeln('#   本侧导出：');
    buf.writeln('#     2');
    buf.writeln('#     2');
    buf.writeln('#   （意思是这行有两处数字变了：月份、日期各一处）');
    buf.writeln('#');
    buf.writeln('# 想看完整句子的对照？请回到对比页，');
    buf.writeln('# 用「并排」或「合并」视图查看。');
    buf.writeln('#');
    buf.writeln('# 下面的说明行以 # 开头，删除它们不影响正文内容。');
    buf.writeln('# ------------------------------------------------------------');
    buf.writeln('# 以下为差异片段正文');
    buf.writeln('# ------------------------------------------------------------');
    buf.writeln();

    for (final p in list) {
      buf.writeln(p);
    }

    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));

    final out = await FilePicker.saveFile(
      fileName:
          'docdiff-${isLeft ? "left" : "right"}-${DateTime.now().millisecondsSinceEpoch}.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: isLeft ? '导出左边文件差异' : '导出右边文件差异',
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
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(10),
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
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(10),
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
      _pendingGroupedRestoreOffset =
          (state as dynamic)?.currentScrollOffset as double?;
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
    _heightFuturesFor = null;
    _heightFuturesConfigKey = null;
    _cachedContentWidth = null;
    _cachedContentWidthFor = null;
    _cachedContentWidthConfig = null;

    DiffTextIndex.invalidate();
    setState(() {});

    if (ref.read(viewModeProvider) == ViewMode.grouped) {
      final o = _pendingGroupedRestoreOffset;
      _pendingGroupedRestoreOffset = null;
      _pendingJumpEntry = null;
      _pendingJumpOrigLine = null;
      _pendingJumpQueued = false;
      if (o != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (ref.read(viewModeProvider) != ViewMode.grouped) return;
          (_groupedKey.currentState as dynamic)?.restoreScrollOffset(o);
        });
      }
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

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
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
            const Text(
              '删除后无法恢复。',
              style:
                  TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
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
    return ok == true;
  }

  Future<void> _deleteSide({required bool isOriginal}) async {
    final path = ref.read(
      isOriginal ? originalFilePathProvider : modifiedFilePathProvider,
    );
    final label = isOriginal ? '左边文件' : '右边文件';
    final ok = await _confirmDelete(label, path);
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
        body: const Center(child: CircularProgressIndicator()),
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

    // 1. 启动/复用后台精确计算（异步，不阻塞）
    _startHeightComputation(diff, viewMode);

    // 2. 立刻渲染：优先用精确表（如果已缓存），否则用快速估算
    final exact = _heightExactResults[viewMode];
    final heights = exact ?? _getQuickBundle(diff, viewMode);
    _activeHeights = heights;

    ViewerDiag.mark(exact == null ? '视图就绪(估算)' : '视图就绪(精确)');

    // 3. 待处理跳转
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
        ),
      ViewMode.grouped => GroupedDiffView(key: _groupedKey),
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

  Widget _buildDiffScaffold(
    DiffResult diff,
    ViewMode viewMode,
    String? origName,
    String? modName,
    _HeightBundle heights,
  ) {
    final noWrap = ref.watch(noWrapProvider);
    final diffBlocks = _diffBlockCount(diff);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 43,
        titleSpacing: 1,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(builder: (ctx) {
              final iconColor =
                  IconTheme.of(ctx).color ?? const Color(0xFF000000);
              return SizedBox(
                width: 56,
                height: 42,
                child: InkWell(
                  key: const Key('page-up'),
                  onTap: () {
                    if (viewMode == ViewMode.grouped) {
                      (_groupedKey.currentState as dynamic)?.pageUp();
                    } else {
                      _pageUp();
                    }
                  },
                  onLongPress: () {
                    if (viewMode == ViewMode.grouped) {
                      (_groupedKey.currentState as dynamic)?.jumpToTop();
                    } else {
                      _jumpToDocTop();
                    }
                  },
                  child: Center(
                    child: CustomPaint(
                      size: const Size.square(24),
                      painter: _PageUpIconPainter(color: iconColor),
                    ),
                  ),
                ),
              );
            }),
            Builder(builder: (ctx) {
              final iconColor =
                  IconTheme.of(ctx).color ?? const Color(0xFF000000);
              return SizedBox(
                width: 56,
                height: 42,
                child: InkWell(
                  key: const Key('page-down'),
                  onTap: () {
                    if (viewMode == ViewMode.grouped) {
                      (_groupedKey.currentState as dynamic)?.pageDown();
                    } else {
                      _pageDown();
                    }
                  },
                  onLongPress: () {
                    if (viewMode == ViewMode.grouped) {
                      (_groupedKey.currentState as dynamic)?.jumpToBottom();
                    } else {
                      _jumpToDocBottom();
                    }
                  },
                  child: Center(
                    child: CustomPaint(
                      size: const Size.square(24),
                      painter: _PageDownIconPainter(color: iconColor),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
        actions: [
          InkWell(
            key: const Key('prev-diff'),
            onTap: () {
              if (viewMode == ViewMode.grouped) {
                (_groupedKey.currentState as dynamic)?.jumpToPrevDiff();
              } else {
                _jumpToPrevDiff();
              }
            },
            onLongPress: () {
              if (viewMode == ViewMode.grouped) {
                (_groupedKey.currentState as dynamic)?.jumpToTop();
              } else {
                _jumpToDocTop();
              }
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Icon(Icons.arrow_upward, size: 26),
            ),
          ),
          InkWell(
            key: const Key('next-diff'),
            onTap: () {
              if (viewMode == ViewMode.grouped) {
                (_groupedKey.currentState as dynamic)?.jumpToNextDiff();
              } else {
                _jumpToNextDiff();
              }
            },
            onLongPress: () {
              if (viewMode == ViewMode.grouped) {
                (_groupedKey.currentState as dynamic)?.jumpToBottom();
              } else {
                _jumpToDocBottom();
              }
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Icon(Icons.arrow_downward, size: 26),
            ),
          ),
          IconButton(
          icon: const Icon(Icons.find_in_page),
            iconSize: 26,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            tooltip: '查找 / 替换',
            onPressed: () => setState(() => _showFind = !_showFind),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.tune),
            tooltip: '更多操作',
            onSelected: (v) {
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
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit),
                    SizedBox(width: 10),
                    Text('编辑对比中的2个文档'),
                  ],
                ),
              ),
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
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'delOriginal',
                enabled: !_originalDeleted &&
                    ref.read(originalFilePathProvider) != null,
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline, color: Colors.red),
                    const SizedBox(width: 10),
                    Text(_originalDeleted ? '左边文件已删除' : '删除左边文件'),
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
                    Text(_modifiedDeleted ? '右边文件已删除' : '删除右边文件'),
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
                    Text('比较设置'),
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
              const PopupMenuDivider(),
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
                value: 'defaultView',
                child: Row(
                  children: [
                    Icon(Icons.visibility),
                    SizedBox(width: 10),
                    Text('默认打开视图'),
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
          _buildEncodingBanner(),
          if (diffBlocks < 6) _buildFewDiffsBanner(diffBlocks),
          if (_showFind) _buildFindBar(),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _viewChip(
                    label: '差异行+上下2行',
                    value: ViewMode.diffOnly,
                    current: viewMode,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: _viewChip(
                    label: '仅显示差异行',
                    value: ViewMode.diffOnlyPlain,
                    current: viewMode,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: _viewChip(
                    label: '跨行块',
                    value: ViewMode.grouped,
                    current: viewMode,
                    onLongPress: _showGroupedContextMenu,
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: _viewChip(
                    label: '上下',
                    value: ViewMode.merged,
                    current: viewMode,
                    compact: true,
                  ),
                ),
              ],
            ),
          ),

          _buildToolbar(),
          if (_processing) _buildProcessingBanner(),
          Expanded(
            child: _buildActiveView(
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
    );
  }

  // ==================== 按钮栏 ====================

  Widget _buildToolbar() {
    final rules = ref.watch(toolbarRulesOrderedProvider);
    final colors = ref.watch(toolbarButtonColorsProvider);
    final s = Theme.of(context).colorScheme;

    return Container(
      height: 42,
      color: s.surfaceVariant.withOpacity(0.25),
      child: Row(
        children: [
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Text(
                      '点 + 添加按钮（长按编辑）',
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
                      final bg = c?.bg ?? Colors.white;
                      final fg = c?.fg ?? Colors.black;
                      final border = c?.border ?? Colors.black.withOpacity(0.5);
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
              tooltip: '新建按钮',
              visualDensity: VisualDensity.compact,
              onPressed: _addToolbarRule,
            ),
          ),
          SizedBox(
            width: 28,
            child: IconButton(
              icon: const Icon(Icons.sort, size: 16),
              padding: EdgeInsets.zero,
              tooltip: '排序按钮',
              visualDensity: VisualDensity.compact,
              onPressed: _showToolbarOrderDialog,
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
  }) {
    final selected = value == current;
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _switchView(value),
      onLongPress: onLongPress,
      child: Container(
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? s.primary : Colors.transparent,
              width: 6,
            ),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? s.primary : s.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingBanner() {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: s.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        _processingText,
        style: TextStyle(
          fontSize: 12,
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
          _toast('「${copied.name}」已复制到预处理规则');
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
    return Container(
      width: double.infinity,
      color: Colors.red.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${parts.join(" / ")} 已从磁盘删除（下方内容仅内存保留）',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white,
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
    return Container(
      width: double.infinity,
      color: Colors.amber.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: Colors.amber.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '两份文件编码不同（$origEnc / $modEnc），已分别解码后对比',
              style: TextStyle(
                fontSize: 11,
                color: Colors.amber.shade900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFewDiffsBanner(int blocks) {
    return Container(
      width: double.infinity,
      color: Colors.green.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 20,
            color: Colors.white,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              blocks == 0
                  ? '两份文档完全相同'
                  : '共 $blocks 处差异，已全部显示',
              style: const TextStyle(
                fontSize: 15,
                color: Colors.white,
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
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: value
                ? BoxDecoration(
                    border: Border.all(
                      color: Colors.orange.shade300,
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
                color: value
                    ? AppColors.accentPurple
                    : Theme.of(context).colorScheme.onSurfaceVariant,
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
          splashColor: AppColors.accentPurple.withOpacity(0.18),
          highlightColor: AppColors.accentPurple.withOpacity(0.08),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color:
                    selected ? AppColors.accentPurple : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? AppColors.accentPurple : s.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.disabled_by_default),
                  tooltip: '关闭查找',
                  visualDensity: VisualDensity.compact,
                  onPressed: _closeFindBar,
                ),
                Expanded(
                  child: TextField(
                    controller: _findController,
                    autofocus: true,
                    cursorColor: AppColors.accentPurple,
                    decoration: const InputDecoration(
                      hintText: '查找',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: _onFindInput,
                    onSubmitted: (_) => _nextMatch(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  color: AppColors.accentPurple,
                  tooltip: '立即搜索',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    if (_findQuery.isEmpty) {
                      _toast('请先输入查找内容');
                      return;
                    }
                    _findDebounce?.cancel();
                    _findChanged(_findController.text, autoScroll: false);
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
                  color: const Color(0xFFFFF8F0),
                  border: Border.all(color: Colors.orange.shade300),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 15, color: Colors.orange.shade800),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _noResultHint!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                const SizedBox(width: 48),
                Expanded(
                  child: TextField(
                    controller: _replaceController,
                    cursorColor: AppColors.accentPurple,
                    decoration: const InputDecoration(
                      hintText: '替换为（留空 = 删掉）',
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: _onReplaceInput,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: AppColors.accentPurple,
                  ),
                  onPressed: _findQuery.isEmpty ? null : _replaceCurrentInline,
                  child: const Text('替换当前'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: AppColors.accentPurple,
                  ),
                  onPressed: _findQuery.isEmpty ? null : _replaceAllInline,
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
                  color: const Color(0xFFFFF5F5),
                  border: Border.all(color: Colors.red.shade800),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber,
                          size: 15, color: Colors.red.shade800),
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
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF000000),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                const SizedBox(width: 8),

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
                const SizedBox(width: 10),

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
                const SizedBox(width: 10),

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
                  color: AppColors.accentPurple,
                  tooltip: '上一个',
                  visualDensity: VisualDensity.compact,
                  onPressed: _findQuery.isEmpty ? null : _prevMatch,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward),
                  color: AppColors.accentPurple,
                  tooltip: '下一个',
                  visualDensity: VisualDensity.compact,
                  onPressed: _findQuery.isEmpty ? null : _nextMatch,
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 8),
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
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: pendingCount > 0
                        ? Colors.orange.shade800
                        : null,
                  ),
                  onPressed: pendingCount > 0 ? _applyPendingChanges : null,
                  icon: const Icon(Icons.done_all, size: 16),
                  label: const Text('应用并刷新'),
                ),
              ],
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

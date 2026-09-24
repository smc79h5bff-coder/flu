import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/foundation.dart';
import 'package:charset/charset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../../../import/presentation/providers/import_providers.dart';

/// View mode in the diff viewer. PRD §2 Module 6.
enum ViewMode { merged, sideBySide, diffOnly }

final viewModeProvider = StateProvider<ViewMode>((ref) => ViewMode.merged);

/// 计时面板开关。默认打开（调试用）。发布时把默认值改成 false。
final showPerfOverlayProvider = StateProvider<bool>((ref) => true);

/// 最近一次 diff 各阶段耗时（毫秒）。调试用，显示在对比页顶部。
class DiffPerfStats {
  const DiffPerfStats({
    required this.prepMs,
    required this.isolateRoundTripMs,
    required this.expandMs,
    required this.ansiMs,
    required this.splitMs,
    required this.encodeMs,
    required this.diffMs,
    required this.isolateExpandMs,
    required this.lineCount,
    required this.origLen,
    required this.modLen,
  });

  final int prepMs;
  final int isolateRoundTripMs;
  final int expandMs;
  final int ansiMs;
  final int splitMs;
  final int encodeMs;
  final int diffMs;
  final int isolateExpandMs;
  final int lineCount;
  final int origLen;
  final int modLen;

  String get oneLine =>
      'prep=$prepMs isolate=$isolateRoundTripMs expand=$expandMs '
      '| ansi=$ansiMs split=$splitMs encode=$encodeMs '
      'diffMain=$diffMs expandInIso=$isolateExpandMs '
      '| lineCount=$lineCount origLen=$origLen modLen=$modLen';
}

/// 最近一次 diff 的性能数据。对比页读取它来显示顶部面板。
final lastDiffPerfProvider = StateProvider<DiffPerfStats?>((ref) => null);

/// 忽略空白符号：比较前去掉水平空白字符（空格、制表符）。
/// 注意用 `[ \t]+` 而非 `\s`，因为 `\s` 会把换行也吃掉、导致整篇并成一行。
final RegExp _horizontalWhitespace = RegExp(r'[ \t]+');
final ignoreWhitespaceProvider = StateProvider<bool>((ref) => true);

/// 忽略空行：比较前删除空白/空行。
final ignoreEmptyLinesProvider = StateProvider<bool>((ref) => true);

/// 忽略换行符：比较前统一换行格式（\r\n / \r / \n），避免换行符差异误报。
final ignoreLineEndingsProvider = StateProvider<bool>((ref) => true);

/// 统一编码 ANSI 对比。
final unifyAnsiProvider = StateProvider<bool>((ref) => false);

/// 忽略大小写：A 和 a 视为相同。
final ignoreCaseProvider = StateProvider<bool>((ref) => false);

/// 忽略中英文逗号：去掉 , 和 ， 后对比。
final ignoreCommasProvider = StateProvider<bool>((ref) => false);

/// 忽略纯数字：连续的 [0-9]+ 整体替换成 <NUM> 占位符。
/// 例：abc123 和 abc456 视为相同。
final ignoreNumbersProvider = StateProvider<bool>((ref) => false);

/// ANSI 编码（中文 Windows 环境下通常即 GBK / GB2312 / CP936）。
String unifyToAnsi(String text) {
  try {
    final bytes = gbk.encode(text);
    if (gbk.decode(bytes) == text) return text;
  } catch (_) {
    // 整体编码失败（存在无法表示字符），走逐字符删除路径。
  }
  final sb = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    try {
      final bytes = gbk.encode(ch);
      if (gbk.decode(bytes) != ch) continue;
      sb.write(ch);
    } catch (_) {
      // 无法转换 → 删除
    }
  }
  return sb.toString();
}

/// 按三个“忽略”开关对文本做比较前预处理。
String applyDiffIgnores(
  String text, {
  bool whitespace = false,
  bool emptyLines = false,
  bool lineEndings = false,
  bool ignoreCase = false,
  bool ignoreCommas = false,
  bool ignoreNumbers = false,
}) {
  var out = text;
  if (lineEndings) {
    out = out.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }
  if (whitespace) {
    out = out.replaceAll(_horizontalWhitespace, '');
  }
  if (emptyLines) {
    out = out
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .join('\n');
  }
  if (ignoreCommas) {
    // 只处理中英文逗号。
    out = out.replaceAll(',', '').replaceAll('，', '');
  }
  if (ignoreNumbers) {
    // 连续数字整体替换成占位符，避免 abc123 和 abc456 被误判为不同。
    out = out.replaceAll(RegExp(r'[0-9]+'), '<NUM>');
  }
  if (ignoreCase) {
    // 最后做：前面步骤可能引入 ASCII 字符（<NUM>），统一转小写。
    out = out.toLowerCase();
  }
  return out;
}

/// 传给后台 isolate 的入参（record 可跨 isolate 传输）。
typedef _DiffRequest =
    ({
      String original,
      String modified,
      bool unifyAnsi,
    });

/// isolate 返回值：展开好的每行 diff + 各阶段耗时。
typedef _DiffPayload =
    ({
      List<(int, String)> entries,
      int ansiMs,
      int splitMs,
      int encodeMs,
      int diffMs,
      int expandMs,
    });

/// dmp 的 op 常量映射到 [DiffOperation] 的 index。
///   dmp:           DIFF_DELETE = -1, DIFF_EQUAL = 0, DIFF_INSERT = 1
///   DiffOperation: equal = 0, insert = 1, delete = 2, replace = 3
int _dmpOpToIndex(int op) {
  if (op == DIFF_EQUAL) return DiffOperation.equal.index;
  if (op == DIFF_INSERT) return DiffOperation.insert.index;
  return DiffOperation.delete.index;
}

/// 按 '\n' 切分，保留空行（与 split('\n') 语义一致）。
List<String> _splitLines(String text) {
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      out.add(text.substring(start, i));
      start = i + 1;
    }
  }
  if (start < text.length) {
    out.add(text.substring(start));
  }
  return out;
}

/// 检测文本是否含 Unicode Private Use Area 字符（U+E000..U+F8FF）。
/// 若含，则不能用 PUA 编码做行映射（会冲突），退化到字符级 diff。
bool _containsPua(String s) {
  for (final r in s.runes) {
    if (r >= 0xE000 && r <= 0xF8FF) return true;
  }
  return false;
}

/// 在后台 isolate 中执行 diff 计算。
///
/// **行级 diff 的实现方式**（绕开 dmp 0.4.1 缺失的 diffLinesToChars 等 API）：
///   1. 按 '\n' 切分两份文本为行列表
///   2. 把每个不同的行唯一映射到一个 Unicode PUA 码点（U+E000 起）
///      —— 每行对应 1 个字符
///   3. 把两串 PUA 字符交给 `dmp.diff()`，它内部是 Myers O(ND)，
///      因为字符数 == 行数，等价于对行做 Myers diff
///   4. 把结果的每个 PUA 字符还原成对应的行文本
///
/// 复杂度：O(行数 + D²)，D 是差异块数。几万行文档、几百处差异，
/// 在 Dart 上 < 100ms。
_DiffPayload _computeInWorker(_DiffRequest req) {
  final sw = Stopwatch()..start();

  final original = req.unifyAnsi ? unifyToAnsi(req.original) : req.original;
  final modified = req.unifyAnsi ? unifyToAnsi(req.modified) : req.modified;
  final tAnsi = sw.elapsedMilliseconds;

  if (original.isEmpty && modified.isEmpty) {
    return (
      entries: const <(int, String)>[],
      ansiMs: tAnsi,
      splitMs: 0,
      encodeMs: 0,
      diffMs: 0,
      expandMs: 0,
    );
  }

  // 退化路径：输入含 PUA 字符时，做字符级 diff（慢但正确）。
  // 实际业务里几乎不会发生。
  if (_containsPua(original) || _containsPua(modified)) {
    final dmp = DiffMatchPatch();
    final raw = dmp.diff(original, modified);
    final out = <(int, String)>[];
    for (final d in raw) {
      out.add((_dmpOpToIndex(d.operation), d.text));
    }
    final t0 = sw.elapsedMilliseconds;
    return (
      entries: out,
      ansiMs: tAnsi,
      splitMs: 0,
      encodeMs: 0,
      diffMs: t0 - tAnsi,
      expandMs: 0,
    );
  }

  final linesA = _splitLines(original);
  final linesB = _splitLines(modified);
  final tSplit = sw.elapsedMilliseconds;

  final lineToCode = <String, int>{};
  final codeToLine = <int, String>{};
  var nextCode = 0xE000;

  String encode(List<String> lines) {
    final sb = StringBuffer();
    for (final line in lines) {
      var code = lineToCode[line];
      if (code == null) {
        code = nextCode++;
        lineToCode[line] = code;
        codeToLine[code] = line;
      }
      sb.writeCharCode(code);
    }
    return sb.toString();
  }

  final encA = encode(linesA);
  final encB = encode(linesB);
  final tEncode = sw.elapsedMilliseconds;

  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(encA, encB);
  final tDiff = sw.elapsedMilliseconds;

  // 把每个 chunk 展开成逐行的 (opIndex, line) 列表。
  // 同一 op 的连续行会被拆成多行——主线程直接构造 DiffEntry，不再展开。
  final out = <(int, String)>[];
  for (final d in diffs) {
    final opIndex = _dmpOpToIndex(d.operation);
    for (final rune in d.text.runes) {
      final line = codeToLine[rune];
      if (line != null) {
        out.add((opIndex, line));
      }
    }
  }
  final tExpand = sw.elapsedMilliseconds;

  return (
    entries: out,
    ansiMs: tAnsi,
    splitMs: tSplit - tAnsi,
    encodeMs: tEncode - tSplit,
    diffMs: tDiff - tEncode,
    expandMs: tExpand - tDiff,
  );
}

DiffEntry _mkEntry(DiffOperation op, String line) {
  switch (op) {
    case DiffOperation.equal:
      return DiffEntry(operation: op, text: line);
    case DiffOperation.insert:
      return DiffEntry(operation: op, text: line, newText: line);
    case DiffOperation.delete:
      return DiffEntry(operation: op, text: line, oldText: line);
    case DiffOperation.replace:
      return DiffEntry(operation: op, text: line);
  }
}

/// Computed diff. Listens to preprocessed text + an import revision counter.
final diffResultProvider = FutureProvider.autoDispose<DiffResult?>((ref) async {
  final sw = Stopwatch()..start();

  final original = ref.watch(preprocessedOriginalProvider);
  final modified = ref.watch(preprocessedModifiedProvider);
  if (original.isEmpty || modified.isEmpty) return null;

final ignoreWs = ref.watch(ignoreWhitespaceProvider);
final ignoreEmpty = ref.watch(ignoreEmptyLinesProvider);
final ignoreNl = ref.watch(ignoreLineEndingsProvider);
final ignoreCase = ref.watch(ignoreCaseProvider);
final ignoreCommas = ref.watch(ignoreCommasProvider);
final ignoreNumbers = ref.watch(ignoreNumbersProvider);
final origNorm = applyDiffIgnores(
  original,
  whitespace: ignoreWs,
  emptyLines: ignoreEmpty,
  lineEndings: ignoreNl,
  ignoreCase: ignoreCase,
  ignoreCommas: ignoreCommas,
  ignoreNumbers: ignoreNumbers,
);
final modNorm = applyDiffIgnores(
  modified,
  whitespace: ignoreWs,
  emptyLines: ignoreEmpty,
  lineEndings: ignoreNl,
  ignoreCase: ignoreCase,
  ignoreCommas: ignoreCommas,
  ignoreNumbers: ignoreNumbers,
);
  if (origNorm.isEmpty || modNorm.isEmpty) return null;

  ref.watch(importRevisionProvider);

  final unifyAnsi = ref.watch(unifyAnsiProvider);
  final tPrep = sw.elapsedMilliseconds;

  final payload = await compute(
    _computeInWorker,
    (
      original: origNorm,
      modified: modNorm,
      unifyAnsi: unifyAnsi,
    ),
  );
  final tIsolate = sw.elapsedMilliseconds;

  final entries = <DiffEntry>[
    for (final (opIndex, line) in payload.entries)
      _mkEntry(DiffOperation.values[opIndex], line),
  ];
  final tExpand = sw.elapsedMilliseconds;

  ref.read(lastDiffPerfProvider.notifier).state = DiffPerfStats(
    prepMs: tPrep,
    isolateRoundTripMs: tIsolate - tPrep,
    expandMs: tExpand - tIsolate,
    ansiMs: payload.ansiMs,
    splitMs: payload.splitMs,
    encodeMs: payload.encodeMs,
    diffMs: payload.diffMs,
    isolateExpandMs: payload.expandMs,
    lineCount: payload.entries.length,
    origLen: origNorm.length,
    modLen: modNorm.length,
  );

  return DiffResult(entries: entries, engineType: DiffEngineType.line);
});

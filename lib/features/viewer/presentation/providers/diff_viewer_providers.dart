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
    required this.mapLinesMs,
    required this.diffMainMs,
    required this.charsToLinesMs,
    required this.chunksMs,
    required this.chunkCount,
    required this.entryCount,
    required this.origLen,
    required this.modLen,
  });

  final int prepMs;
  final int isolateRoundTripMs;
  final int expandMs;
  final int ansiMs;
  final int mapLinesMs;
  final int diffMainMs;
  final int charsToLinesMs;
  final int chunksMs;
  final int chunkCount;
  final int entryCount;
  final int origLen;
  final int modLen;

  String get oneLine =>
      'prep=$prepMs isolate=$isolateRoundTripMs expand=$expandMs '
      '| ansi=$ansiMs mapLines=$mapLinesMs diffMain=$diffMainMs '
      'charsToLines=$charsToLinesMs chunks=$chunksMs '
      '| chunkCount=$chunkCount entries=$entryCount '
      'origLen=$origLen modLen=$modLen';
}

/// 最近一次 diff 的性能数据。对比页读取它来显示顶部面板。
final lastDiffPerfProvider = StateProvider<DiffPerfStats?>((ref) => null);

/// 忽略空白符号：比较前去掉水平空白字符（空格、制表符）。
/// 注意用 `[ \t]+` 而非 `\s`，因为 `\s` 会把换行也吃掉、导致整篇并成一行。
final RegExp _horizontalWhitespace = RegExp(r'[ \t]+');
final ignoreWhitespaceProvider = StateProvider<bool>((ref) => false);

/// 忽略空行：比较前删除空白/空行。
final ignoreEmptyLinesProvider = StateProvider<bool>((ref) => false);

/// 忽略换行符：比较前统一换行格式（\r\n / \r / \n），避免换行符差异误报。
final ignoreLineEndingsProvider = StateProvider<bool>((ref) => false);

/// 统一编码 ANSI 对比。
final unifyAnsiProvider = StateProvider<bool>((ref) => false);

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
      sb.add(ch);
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
  return out;
}

/// 传给后台 isolate 的入参（record 可跨 isolate 传输）。
typedef _DiffRequest =
    ({
      String original,
      String modified,
      bool unifyAnsi,
    });

/// isolate 返回值：chunks + isolate 内各阶段耗时。
/// record 各字段类型都可跨 isolate 传输。
typedef _DiffResultPayload =
    ({
      List<(int, String)> chunks,
      int ansiMs,
      int mapLinesMs,
      int diffMainMs,
      int charsToLinesMs,
      int chunksMs,
    });

/// dmp 的 op 常量映射到 [DiffOperation] 的 index。
///   dmp:           DIFF_DELETE = -1, DIFF_EQUAL = 0, DIFF_INSERT = 1
///   DiffOperation: equal = 0, insert = 1, delete = 2, replace = 3
int _dmpOpToIndex(int op) {
  if (op == DIFF_EQUAL) return DiffOperation.equal.index;
  if (op == DIFF_INSERT) return DiffOperation.insert.index;
  return DiffOperation.delete.index;
}

/// 在后台 isolate 中执行 diff 计算。
///
/// 返回 chunks + 各阶段耗时。耗时用 int（毫秒），跨 isolate 传输开销可忽略。
_DiffResultPayload _computeInWorker(_DiffRequest req) {
  final sw = Stopwatch()..start();

  final original = req.unifyAnsi ? unifyToAnsi(req.original) : req.original;
  final modified = req.unifyAnsi ? unifyToAnsi(req.modified) : req.modified;
  final tAnsi = sw.elapsedMilliseconds;

  if (original.isEmpty && modified.isEmpty) {
    return (
      chunks: const <(int, String)>[],
      ansiMs: tAnsi,
      mapLinesMs: 0,
      diffMainMs: 0,
      charsToLinesMs: 0,
      chunksMs: 0,
    );
  }

  final dmp = DiffMatchPatch();
  final lines = dmp.diffLinesToChars(original, modified);
  final chars1 = lines[0] as String;
  final chars2 = lines[1] as String;
  final lineArray = lines[2] as List<String>;
  final tMapLines = sw.elapsedMilliseconds;

  final diffs = dmp.diffMain(chars1, chars2, false);
  final tMain = sw.elapsedMilliseconds;

  dmp.diffCharsToLines(diffs, lineArray);
  final tBack = sw.elapsedMilliseconds;

  final chunks = <(int, String)>[
    for (final d in diffs) (_dmpOpToIndex(d.operation), d.text),
  ];
  final tChunks = sw.elapsedMilliseconds;

  return (
    chunks: chunks,
    ansiMs: tAnsi,
    mapLinesMs: tMapLines - tAnsi,
    diffMainMs: tMain - tMapLines,
    charsToLinesMs: tBack - tMain,
    chunksMs: tChunks - tBack,
  );
}

/// 把 isolate 返回的 chunks 展开成单行 [DiffEntry] 列表。
List<DiffEntry> _expandChunks(List<(int, String)> chunks) {
  final out = <DiffEntry>[];
  for (final (opIndex, text) in chunks) {
    final op = DiffOperation.values[opIndex];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        out.add(_mkEntry(op, text.substring(start, i)));
        start = i + 1;
      }
    }
    if (start < text.length) {
      out.add(_mkEntry(op, text.substring(start)));
    }
  }
  return out;
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
  final origNorm = applyDiffIgnores(
    original,
    whitespace: ignoreWs,
    emptyLines: ignoreEmpty,
    lineEndings: ignoreNl,
  );
  final modNorm = applyDiffIgnores(
    modified,
    whitespace: ignoreWs,
    emptyLines: ignoreEmpty,
    lineEndings: ignoreNl,
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

  final entries = _expandChunks(payload.chunks);
  final tExpand = sw.elapsedMilliseconds;

  // 写入性能数据，供对比页顶部显示。
  ref.read(lastDiffPerfProvider.notifier).state = DiffPerfStats(
    prepMs: tPrep,
    isolateRoundTripMs: tIsolate - tPrep,
    expandMs: tExpand - tIsolate,
    ansiMs: payload.ansiMs,
    mapLinesMs: payload.mapLinesMs,
    diffMainMs: payload.diffMainMs,
    charsToLinesMs: payload.charsToLinesMs,
    chunksMs: payload.chunksMs,
    chunkCount: payload.chunks.length,
    entryCount: entries.length,
    origLen: origNorm.length,
    modLen: modNorm.length,
  );

  return DiffResult(entries: entries, engineType: DiffEngineType.line);
});

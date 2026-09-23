import 'package:flutter/foundation.dart';
import 'package:charset/charset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/application/diff_engine.dart';
import '../../../diff/application/line_diff_engine.dart';
import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../../../import/presentation/providers/import_providers.dart';

/// View mode in the diff viewer. PRD §2 Module 6.
enum ViewMode { merged, sideBySide, diffOnly }

final viewModeProvider = StateProvider<ViewMode>((ref) => ViewMode.merged);

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
/// 用 charset 包的 `gbk` codec（真双字节 GBK，即 CP936/ANSI）作为目标编码：
/// 若文本已能完整表示为 ANSI 则原样返回（不处理，防止误判）；若有无法表示
/// 的字符则删除这些字符。
/// 注意该操作需逐个检测字符，开销较大，故放在 diff 计算的后台 isolate 内执行。
String unifyToAnsi(String text) {
  try {
    final bytes = gbk.encode(text);
    if (gbk.decode(bytes) == text) return text; // 已完全可表示为 ANSI，无需处理
  } catch (_) {
    // 整体编码失败（存在无法表示字符），走逐字符删除路径。
  }
  final sb = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    try {
      final bytes = gbk.encode(ch);
      if (gbk.decode(bytes) != ch) continue; // 无法精确往返 → 视为不可表示，删除
      sb.write(ch);
    } catch (_) {
      // 无法转换 → 删除
    }
  }
  return sb.toString();
}

/// 按三个“忽略”开关对文本做比较前预处理。
/// 顺序：先统一换行符 → 去空白符号 → 删空行。
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

/// 在后台 isolate 中执行 diff 计算。
///
/// 只保留行 diff 引擎。之前还有 CharDiffEngine（对全文做字符级 Myers），
/// 在几千几万行的文件上是 1~3 秒的灾难，且语义不对——它丢掉了“行”这个
/// 基本单位。NMM 也只用行级 xdiff + 行内字符 diff，没有全文字符引擎。
List<(int, String, String, String, double)> _computeInWorker(
  _DiffRequest req,
) {
  final original = req.unifyAnsi ? unifyToAnsi(req.original) : req.original;
  final modified = req.unifyAnsi ? unifyToAnsi(req.modified) : req.modified;
  const DiffEngine engine = LineDiffEngine();
  final result = engine.compute(original, modified);
  return <(int, String, String, String, double)>[
    for (final e in result.entries)
      (e.operation.index, e.text, e.oldText, e.newText, e.similarity),
  ];
}

/// Computed diff. Listens to preprocessed text + an import revision counter
/// (so a re-import forces a recompute).
///
/// diff 计算在后台 isolate 中进行，避免大文本卡死主线程。
final diffResultProvider = FutureProvider.autoDispose<DiffResult?>((ref) async {
  final original = ref.watch(preprocessedOriginalProvider);
  final modified = ref.watch(preprocessedModifiedProvider);
  if (original.isEmpty || modified.isEmpty) return null;

  // 三个“忽略”开关：比较前对文本做统一预处理。
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

  // Revision bump triggers a fresh read.
  ref.watch(importRevisionProvider);

  final unifyAnsi = ref.watch(unifyAnsiProvider);
  final rows = await compute(
    _computeInWorker,
    (
      original: origNorm,
      modified: modNorm,
      unifyAnsi: unifyAnsi,
    ),
  );

  return DiffResult(
    entries: <DiffEntry>[
      for (final r in rows)
        DiffEntry(
          operation: DiffOperation.values[r.$1],
          text: r.$2,
          oldText: r.$3,
          newText: r.$4,
          similarity: r.$5,
        ),
    ],
    engineType: DiffEngineType.line,
  );
});

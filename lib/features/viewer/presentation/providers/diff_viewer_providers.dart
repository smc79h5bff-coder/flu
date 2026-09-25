import 'package:charset/charset.dart';
import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../../../import/presentation/providers/import_providers.dart';

/// View mode in the diff viewer. PRD §2 Module 6.
enum ViewMode { merged, sideBySide, diffOnly }

/// **不持久化**：每次打开对比页回默认"仅差异"。
final viewModeProvider = StateProvider<ViewMode>((ref) => ViewMode.merged);

/// 计时面板开关。**不持久化**，固定关闭。
final showPerfOverlayProvider = StateProvider<bool>((ref) => false);

// ==================== 显示设置（持久化） ====================

/// 对比页显示行号。
final showLineNumbersProvider =
    NotifierProvider<ShowLineNumbersNotifier, bool>(
  ShowLineNumbersNotifier.new,
);

class ShowLineNumbersNotifier extends BoolPrefNotifier {
  ShowLineNumbersNotifier()
      : super(key: PrefKeys.showLineNumbers, initial: true);
}

/// 对比页正文字号。
final bodyFontSizeProvider =
    NotifierProvider<BodyFontSizeNotifier, double>(BodyFontSizeNotifier.new);

class BodyFontSizeNotifier extends DoublePrefNotifier {
  BodyFontSizeNotifier()
      : super(key: PrefKeys.bodyFontSize, initial: 14.0);
}

/// 对比页行号字号。
final gutterFontSizeProvider =
    NotifierProvider<GutterFontSizeNotifier, double>(
  GutterFontSizeNotifier.new,
);

class GutterFontSizeNotifier extends DoublePrefNotifier {
  GutterFontSizeNotifier()
      : super(key: PrefKeys.gutterFontSize, initial: 11.0);
}

/// 并排视图两栏同步滚动。关闭后左右独立滚动。
final syncScrollProvider =
    NotifierProvider<SyncScrollNotifier, bool>(SyncScrollNotifier.new);

class SyncScrollNotifier extends BoolPrefNotifier {
  SyncScrollNotifier() : super(key: PrefKeys.syncScroll, initial: true);
}

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

// ==================== 忽略开关（暂未持久化，下一步改） ====================
// 这 8 个开关和 import_providers.dart 关系更紧，放一起改更顺。

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
final ignoreNumbersProvider = StateProvider<bool>((ref) => false);

/// 忽略不可见字符（零宽、方向控制、BOM、软连字符、NBSP 等）。
final ignoreInvisibleProvider = StateProvider<bool>((ref) => true);

/// 不可见字符正则。只列"纯控制/零宽/方向"类，不含普通空格、Tab、换行、
/// 全角空格（这些有独立开关或语义）。
final RegExp _invisibleChars = RegExp(
  r'[\u00A0\u00AD'
  r'\u200B-\u200F'
  r'\u202A-\u202E'
  r'\u202F'
  r'\u2060-\u2064'
  r'\u2066-\u2069'
  r'\uFEFF]',
);

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

/// 按三个"忽略"开关对文本做比较前预处理。
String applyDiffIgnores(
  String text, {
  bool whitespace = false,
  bool emptyLines = false,
  bool lineEndings = false,
  bool ignoreCase = false,
  bool ignoreCommas = false,
  bool ignoreNumbers = false,
  bool ignoreInvisible = false,
}) {
  var out = text;
  if (lineEndings) {
    out = out.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }
  if (ignoreInvisible) {
    out = out.replaceAll(_invisibleChars, '');
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
    out = out.replaceAll(',', '').replaceAll('，', '');
  }
  if (ignoreNumbers) {
    out = out.replaceAll(RegExp(r'[0-9]+'), '<NUM>');
  }
  if (ignoreCase) {
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
bool _containsPua(String s) {
  for (final r in s.runes) {
    if (r >= 0xE000 && r <= 0xF8FF) return true;
  }
  return false;
}

/// 在后台 isolate 中执行 diff 计算。
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

  final minLen =
      linesA.length < linesB.length ? linesA.length : linesB.length;

  var commonPrefix = 0;
  while (commonPrefix < minLen &&
      linesA[commonPrefix] == linesB[commonPrefix]) {
    commonPrefix++;
  }

  var commonSuffix = 0;
  final maxSuffix = minLen - commonPrefix;
  while (commonSuffix < maxSuffix &&
      linesA[linesA.length - 1 - commonSuffix] ==
          linesB[linesB.length - 1 - commonSuffix]) {
    commonSuffix++;
  }

  final midAStart = commonPrefix;
  final midAEnd = linesA.length - commonSuffix;
  final midBStart = commonPrefix;
  final midBEnd = linesB.length - commonSuffix;

  final lineToCode = <String, int>{};
  final codeToLine = <int, String>{};
  var nextCode = 0xE000;

  String encode(List<String> lines, int start, int end) {
    final sb = StringBuffer();
    for (var i = start; i < end; i++) {
      final line = lines[i];
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

  final encA = encode(linesA, midAStart, midAEnd);
  final encB = encode(linesB, midBStart, midBEnd);
  final tEncode = sw.elapsedMilliseconds;

  final dmp = DiffMatchPatch();
  final diffs = dmp.diff(encA, encB);
  final tDiff = sw.elapsedMilliseconds;

  final out = <(int, String)>[];

  for (var i = 0; i < commonPrefix; i++) {
    out.add((DiffOperation.equal.index, linesA[i]));
  }

  for (final d in diffs) {
    final opIndex = _dmpOpToIndex(d.operation);
    for (final rune in d.text.runes) {
      final line = codeToLine[rune];
      if (line != null) {
        out.add((opIndex, line));
      }
    }
  }

  for (var i = linesA.length - commonSuffix; i < linesA.length; i++) {
    out.add((DiffOperation.equal.index, linesA[i]));
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
  final ignoreInvisible = ref.watch(ignoreInvisibleProvider);
  final origNorm = applyDiffIgnores(
    original,
    whitespace: ignoreWs,
    emptyLines: ignoreEmpty,
    lineEndings: ignoreNl,
    ignoreCase: ignoreCase,
    ignoreCommas: ignoreCommas,
    ignoreNumbers: ignoreNumbers,
    ignoreInvisible: ignoreInvisible,
  );
  final modNorm = applyDiffIgnores(
    modified,
    whitespace: ignoreWs,
    emptyLines: ignoreEmpty,
    lineEndings: ignoreNl,
    ignoreCase: ignoreCase,
    ignoreCommas: ignoreCommas,
    ignoreNumbers: ignoreNumbers,
    ignoreInvisible: ignoreInvisible,
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

// ==================== 差异颜色（持久化） ====================
//
// 12 个颜色项，分三组：
//   1) 纯删除 / 纯新增行的整行颜色（正红 / 正绿）
//   2) 修改行的整行颜色（浅粉 / 浅绿）+ 字体色
//   3) 字符级差异（深红 / 深绿）+ 字体色
//
// 存成 "#RRGGBB" 字符串，从 provider 读，改动立即生效。

/// 颜色专用持久化 Notifier：内存里是 Color，磁盘上是 "#RRGGBB"。
class ColorPrefNotifier extends PersistentNotifier<Color> {
  ColorPrefNotifier({required this.key, required Color initial})
      : _initial = initial;

  @override
  final String key;
  final Color _initial;

  @override
  Color get defaultValue => _initial;

  @override
  Color decode(String raw) {
    final c = hexToColor(raw);
    if (c == null) throw const FormatException('Invalid color string');
    return c;
  }

  @override
  String encode(Color value) => colorToHex(value);
}

/// 纯删除行整行背景（左侧独有行）。
final deleteRowBgProvider =
    NotifierProvider<DeleteRowBgNotifier, Color>(DeleteRowBgNotifier.new);

class DeleteRowBgNotifier extends ColorPrefNotifier {
  DeleteRowBgNotifier()
      : super(
          key: PrefKeys.colorDeleteRowBg,
          initial: const Color(0xFFFF0000),
        );
}

/// 纯删除行整行字体。
final deleteRowFgProvider =
    NotifierProvider<DeleteRowFgNotifier, Color>(DeleteRowFgNotifier.new);

class DeleteRowFgNotifier extends ColorPrefNotifier {
  DeleteRowFgNotifier()
      : super(
          key: PrefKeys.colorDeleteRowFg,
          initial: const Color(0xFF000000),
        );
}

/// 纯新增行整行背景（右侧独有行）。
final insertRowBgProvider =
    NotifierProvider<InsertRowBgNotifier, Color>(InsertRowBgNotifier.new);

class InsertRowBgNotifier extends ColorPrefNotifier {
  InsertRowBgNotifier()
      : super(
          key: PrefKeys.colorInsertRowBg,
          initial: const Color(0xFF00FF00),
        );
}

/// 纯新增行整行字体。
final insertRowFgProvider =
    NotifierProvider<InsertRowFgNotifier, Color>(InsertRowFgNotifier.new);

class InsertRowFgNotifier extends ColorPrefNotifier {
  InsertRowFgNotifier()
      : super(
          key: PrefKeys.colorInsertRowFg,
          initial: const Color(0xFF000000),
        );
}

/// 修改行左侧（原文件侧）整行背景。
final replaceLeftBgProvider =
    NotifierProvider<ReplaceLeftBgNotifier, Color>(
  ReplaceLeftBgNotifier.new,
);

class ReplaceLeftBgNotifier extends ColorPrefNotifier {
  ReplaceLeftBgNotifier()
      : super(
          key: PrefKeys.colorReplaceLeftBg,
          initial: const Color(0xFFFFCDD2),
        );
}

/// 修改行左侧整行字体。
final replaceLeftFgProvider =
    NotifierProvider<ReplaceLeftFgNotifier, Color>(
  ReplaceLeftFgNotifier.new,
);

class ReplaceLeftFgNotifier extends ColorPrefNotifier {
  ReplaceLeftFgNotifier()
      : super(
          key: PrefKeys.colorReplaceLeftFg,
          initial: const Color(0xFF000000),
        );
}

/// 修改行右侧（修改版侧）整行背景。
final replaceRightBgProvider =
    NotifierProvider<ReplaceRightBgNotifier, Color>(
  ReplaceRightBgNotifier.new,
);

class ReplaceRightBgNotifier extends ColorPrefNotifier {
  ReplaceRightBgNotifier()
      : super(
          key: PrefKeys.colorReplaceRightBg,
          initial: const Color(0xFFC8E6C9),
        );
}

/// 修改行右侧整行字体。
final replaceRightFgProvider =
    NotifierProvider<ReplaceRightFgNotifier, Color>(
  ReplaceRightFgNotifier.new,
);

class ReplaceRightFgNotifier extends ColorPrefNotifier {
  ReplaceRightFgNotifier()
      : super(
          key: PrefKeys.colorReplaceRightFg,
          initial: const Color(0xFF000000),
        );
}

/// 字符级删除（左侧行内被删的字）背景。
final charDeleteBgProvider =
    NotifierProvider<CharDeleteBgNotifier, Color>(CharDeleteBgNotifier.new);

class CharDeleteBgNotifier extends ColorPrefNotifier {
  CharDeleteBgNotifier()
      : super(
          key: PrefKeys.colorCharDeleteBg,
          initial: const Color(0xFFB71C1C),
        );
}

/// 字符级删除字体。
final charDeleteFgProvider =
    NotifierProvider<CharDeleteFgNotifier, Color>(CharDeleteFgNotifier.new);

class CharDeleteFgNotifier extends ColorPrefNotifier {
  CharDeleteFgNotifier()
      : super(
          key: PrefKeys.colorCharDeleteFg,
          initial: const Color(0xFFFFFFFF),
        );
}

/// 字符级新增（右侧行内新增的字）背景。
final charInsertBgProvider =
    NotifierProvider<CharInsertBgNotifier, Color>(CharInsertBgNotifier.new);

class CharInsertBgNotifier extends ColorPrefNotifier {
  CharInsertBgNotifier()
      : super(
          key: PrefKeys.colorCharInsertBg,
          initial: const Color(0xFF1B5E20),
        );
}

/// 字符级新增字体。
final charInsertFgProvider =
    NotifierProvider<CharInsertFgNotifier, Color>(CharInsertFgNotifier.new);

class CharInsertFgNotifier extends ColorPrefNotifier {
  CharInsertFgNotifier()
      : super(
          key: PrefKeys.colorCharInsertFg,
          initial: const Color(0xFFFFFFFF),
        );
}

/// 一次性从 ref 读 12 个颜色的辅助类型。
typedef DiffColors = ({
  Color deleteRowBg,
  Color deleteRowFg,
  Color insertRowBg,
  Color insertRowFg,
  Color replaceLeftBg,
  Color replaceLeftFg,
  Color replaceRightBg,
  Color replaceRightFg,
  Color charDeleteBg,
  Color charDeleteFg,
  Color charInsertBg,
  Color charInsertFg,
});

DiffColors watchDiffColors(WidgetRef ref) => (
      deleteRowBg: ref.watch(deleteRowBgProvider),
      deleteRowFg: ref.watch(deleteRowFgProvider),
      insertRowBg: ref.watch(insertRowBgProvider),
      insertRowFg: ref.watch(insertRowFgProvider),
      replaceLeftBg: ref.watch(replaceLeftBgProvider),
      replaceLeftFg: ref.watch(replaceLeftFgProvider),
      replaceRightBg: ref.watch(replaceRightBgProvider),
      replaceRightFg: ref.watch(replaceRightFgProvider),
      charDeleteBg: ref.watch(charDeleteBgProvider),
      charDeleteFg: ref.watch(charDeleteFgProvider),
      charInsertBg: ref.watch(charInsertBgProvider),
      charInsertFg: ref.watch(charInsertFgProvider),
    );

/// Color → "#RRGGBB"（大写）。
String colorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// "#RRGGBB" → Color。格式错误返回 null。
Color? hexToColor(String s) {
  if (s.length != 7 || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// 把"预处理后的行号"映射回 raw 文本中的行号。
int? rawLineForNormalizedLine(
  String raw, {
  required int normalizedLine,
  required bool ignoreWhitespace,
  required bool ignoreEmptyLines,
  required bool ignoreInvisible,
}) {
  if (normalizedLine < 0) return null;
  final lines =
      raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

  if (!ignoreEmptyLines) {
    return normalizedLine < lines.length ? normalizedLine : null;
  }

  var count = 0;
  for (var i = 0; i < lines.length; i++) {
    var s = lines[i];
    if (ignoreInvisible) s = s.replaceAll(_invisibleChars, '');
    if (ignoreWhitespace) s = s.replaceAll(_horizontalWhitespace, '');
    if (s.trim().isNotEmpty) {
      if (count == normalizedLine) return i;
      count++;
    }
  }
  return null;
}

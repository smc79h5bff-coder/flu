import 'dart:convert';

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

enum ViewMode { merged, sideBySide, diffOnly, diffOnlyPlain }

final viewModeProvider = StateProvider<ViewMode>((ref) => ViewMode.merged);

final showPerfOverlayProvider = StateProvider<bool>((ref) => false);

final noWrapProvider = StateProvider<bool>((ref) => false);

// ==================== 显示设置（持久化） ====================

final showLineNumbersProvider =
    NotifierProvider<ShowLineNumbersNotifier, bool>(
  ShowLineNumbersNotifier.new,
);

class ShowLineNumbersNotifier extends BoolPrefNotifier {
  ShowLineNumbersNotifier()
      : super(key: PrefKeys.showLineNumbers, initial: true);
}

final bodyFontSizeProvider =
    NotifierProvider<BodyFontSizeNotifier, double>(BodyFontSizeNotifier.new);

class BodyFontSizeNotifier extends DoublePrefNotifier {
  BodyFontSizeNotifier()
      : super(key: PrefKeys.bodyFontSize, initial: 14.0);
}

final gutterFontSizeProvider =
    NotifierProvider<GutterFontSizeNotifier, double>(
  GutterFontSizeNotifier.new,
);

class GutterFontSizeNotifier extends DoublePrefNotifier {
  GutterFontSizeNotifier()
      : super(key: PrefKeys.gutterFontSize, initial: 11.0);
}

final syncScrollProvider =
    NotifierProvider<SyncScrollNotifier, bool>(SyncScrollNotifier.new);

class SyncScrollNotifier extends BoolPrefNotifier {
  SyncScrollNotifier() : super(key: PrefKeys.syncScroll, initial: true);
}

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
    required this.origLines,
    required this.modLines,
    required this.uniqueLines,
    required this.usedMyers,
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
  final int origLines;
  final int modLines;
  final int uniqueLines;
  final bool usedMyers;

  String get oneLine =>
      'prep=$prepMs isolate=$isolateRoundTripMs expand=$expandMs '
      '| ansi=$ansiMs split=$splitMs encode=$encodeMs '
      'diffMain=$diffMs expandInIso=$isolateExpandMs '
      '| lineCount=$lineCount origLen=$origLen modLen=$modLen '
      '| origLines=$origLines modLines=$modLines '
      'uniqueLines=$uniqueLines myers=$usedMyers';
}

final lastDiffPerfProvider = StateProvider<DiffPerfStats?>((ref) => null);

// ==================== Diff 计算 ====================

typedef _DiffRequest = ({
  String original,
  String modified,
});

typedef _DiffPayload = ({
  List<(int, String)> entries,
  int ansiMs,
  int splitMs,
  int encodeMs,
  int diffMs,
  int expandMs,
  int origLines,
  int modLines,
  int uniqueLines,
  bool usedMyers,
});

int _dmpOpToIndex(int op) {
  if (op == DIFF_EQUAL) return DiffOperation.equal.index;
  if (op == DIFF_INSERT) return DiffOperation.insert.index;
  return DiffOperation.delete.index;
}

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

const int _puaLimit = 6000;

_DiffPayload _computeInWorker(_DiffRequest req) {
  final sw = Stopwatch()..start();

  final original = req.original;
  final modified = req.modified;

  if (original.isEmpty && modified.isEmpty) {
    return (
      entries: const <(int, String)>[],
      ansiMs: 0,
      splitMs: 0,
      encodeMs: 0,
      diffMs: 0,
      expandMs: 0,
      origLines: 0,
      modLines: 0,
      uniqueLines: 0,
      usedMyers: false,
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

  final lineToId = <String, int>{};
  final idToLine = <int, String>{};
  var nextId = 0;

  List<int> encodeIds(List<String> lines, int start, int end) {
    final ids = <int>[];
    for (var i = start; i < end; i++) {
      final line = lines[i];
      var id = lineToId[line];
      if (id == null) {
        id = nextId++;
        lineToId[line] = id;
        idToLine[id] = line;
      }
      ids.add(id);
    }
    return ids;
  }

  final idsA = encodeIds(linesA, midAStart, midAEnd);
  final idsB = encodeIds(linesB, midBStart, midBEnd);
  final tEncode = sw.elapsedMilliseconds;

  final uniqueCount = idToLine.length;
  final out = <(int, String)>[];
  var usedMyers = false;

  if (uniqueCount <= _puaLimit) {
    // 小唯一行数：用 diff_match_patch 的位运算加速（PUA 编码）
    final codeToLine = <int, String>{};
    var nextCode = 0xE000;
    for (final e in idToLine.entries) {
      codeToLine[nextCode] = e.value;
      nextCode++;
    }
    final idToCode = <int, int>{};
    var c = 0xE000;
    for (final id in idToLine.keys) {
      idToCode[id] = c;
      c++;
    }
    final sbA = StringBuffer();
    for (final id in idsA) {
      sbA.writeCharCode(idToCode[id]!);
    }
    final sbB = StringBuffer();
    for (final id in idsB) {
      sbB.writeCharCode(idToCode[id]!);
    }
    final dmp = DiffMatchPatch();
    final diffs = dmp.diff(sbA.toString(), sbB.toString());
    for (var i = 0; i < commonPrefix; i++) {
      out.add((DiffOperation.equal.index, linesA[i]));
    }
    for (final d in diffs) {
      final opIndex = _dmpOpToIndex(d.operation);
      for (final rune in d.text.runes) {
        final line = codeToLine[rune];
        if (line != null) out.add((opIndex, line));
      }
    }
    for (var i = linesA.length - commonSuffix; i < linesA.length; i++) {
      out.add((DiffOperation.equal.index, linesA[i]));
    }
  } else {
    // 唯一行多（如小说全文）：用耐心 diff。
    // 它先找"两边都唯一"的行当锚点，把问题切成小块，速度快、
    // 内存低，且不像原始 Myers 那样差异一大就退化成"全部标红"。
    usedMyers = true;
    final ops = _patienceDiff(idsA, idsB);
    for (var i = 0; i < commonPrefix; i++) {
      out.add((DiffOperation.equal.index, linesA[i]));
    }
    for (final (op, id) in ops) {
      final line = idToLine[id];
      if (line != null) out.add((op, line));
    }
    for (var i = linesA.length - commonSuffix; i < linesA.length; i++) {
      out.add((DiffOperation.equal.index, linesA[i]));
    }
  }
  final tDiff = sw.elapsedMilliseconds;
  final tExpand = tDiff;

  return (
    entries: out,
    ansiMs: 0,
    splitMs: tSplit,
    encodeMs: tEncode - tSplit,
    diffMs: tDiff - tEncode,
    expandMs: tExpand - tDiff,
    origLines: linesA.length,
    modLines: linesB.length,
    uniqueLines: uniqueCount,
    usedMyers: usedMyers,
  );
}

// ==================== 耐心 diff ====================

/// 耐心 diff：先找"两边都只出现一次"的公共行当锚点，用锚点把问题
/// 切成小块。对小说这类几乎每行唯一的文本，比 Myers 快 100 倍。
List<(int, int)> _patienceDiff(List<int> a, List<int> b) {
  final out = <(int, int)>[];
  _patienceRec(a, 0, a.length, b, 0, b.length, out);
  return out;
}

void _patienceRec(
  List<int> a, int aLo, int aHi,
  List<int> b, int bLo, int bHi,
  List<(int, int)> out,
) {
  // 剥公共前缀
  while (aLo < aHi && bLo < bHi && a[aLo] == b[bLo]) {
    out.add((DiffOperation.equal.index, a[aLo]));
    aLo++;
    bLo++;
  }
  // 剥公共后缀
  var aEnd = aHi;
  var bEnd = bHi;
  while (aEnd > aLo && bEnd > bLo && a[aEnd - 1] == b[bEnd - 1]) {
    aEnd--;
    bEnd--;
  }

  if (aLo == aEnd) {
    for (var j = bLo; j < bEnd; j++) {
      out.add((DiffOperation.insert.index, b[j]));
    }
  } else if (bLo == bEnd) {
    for (var i = aLo; i < aEnd; i++) {
      out.add((DiffOperation.delete.index, a[i]));
    }
  } else if ((aEnd - aLo) + (bEnd - bLo) < 200) {
    // 区块足够小，直接 Myers，别折腾锚点
    _myersRec(a, aLo, aEnd, b, bLo, bEnd, out);
  } else {
    final anchors = _findUniqueAnchors(a, aLo, aEnd, b, bLo, bEnd);
    if (anchors.isEmpty) {
      // 这一块没有唯一行（重复段落），退回 Myers
      _myersRec(a, aLo, aEnd, b, bLo, bEnd, out);
    } else {
      var curA = aLo;
      var curB = bLo;
      for (final (ai, bi) in anchors) {
        _patienceRec(a, curA, ai, b, curB, bi, out);
        out.add((DiffOperation.equal.index, a[ai]));
        curA = ai + 1;
        curB = bi + 1;
      }
      _patienceRec(a, curA, aEnd, b, curB, bEnd, out);
    }
  }

  // 回填后缀
  for (var i = aEnd; i < aHi; i++) {
    out.add((DiffOperation.equal.index, a[i]));
  }
}

/// 找"两边都只出现一次"的公共行，用最长递增子序列挑出配对。
List<(int, int)> _findUniqueAnchors(
  List<int> a, int aLo, int aHi,
  List<int> b, int bLo, int bHi,
) {
  final aCount = <int, int>{};
  final aPos = <int, int>{};
  for (var i = aLo; i < aHi; i++) {
    final id = a[i];
    aCount[id] = (aCount[id] ?? 0) + 1;
    aPos[id] = i;
  }
  final bCount = <int, int>{};
  final bPos = <int, int>{};
  for (var i = bLo; i < bHi; i++) {
    final id = b[i];
    bCount[id] = (bCount[id] ?? 0) + 1;
    bPos[id] = i;
  }
  final candidates = <(int, int)>[];
  for (final id in aCount.keys) {
    if (aCount[id] == 1 && bCount[id] == 1) {
      candidates.add((aPos[id]!, bPos[id]!));
    }
  }
  if (candidates.isEmpty) return const [];
  candidates.sort((x, y) => x.$1.compareTo(y.$1));
  return _longestIncreasingSubsequence(candidates);
}

List<(int, int)> _longestIncreasingSubsequence(List<(int, int)> pairs) {
  final n = pairs.length;
  if (n == 0) return const [];
  final tails = <int>[];
  final prev = List<int>.filled(n, -1);
  for (var i = 0; i < n; i++) {
    final v = pairs[i].$2;
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (pairs[tails[mid]].$2 < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) prev[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final res = <(int, int)>[];
  var k = tails.isEmpty ? -1 : tails.last;
  while (k >= 0) {
    res.add(pairs[k]);
    k = prev[k];
  }
  return res.reversed.toList();
}

// ==================== 线性空间 Myers（耐心 diff 的兜底） ====================

void _myersRec(
  List<int> a, int aStart, int aEnd,
  List<int> b, int bStart, int bEnd,
  List<(int, int)> out,
) {
  while (aStart < aEnd && bStart < bEnd && a[aStart] == b[bStart]) {
    out.add((DiffOperation.equal.index, a[aStart]));
    aStart++;
    bStart++;
  }
  var aSuf = aEnd;
  var bSuf = bEnd;
  while (aSuf > aStart && bSuf > bStart && a[aSuf - 1] == b[bSuf - 1]) {
    aSuf--;
    bSuf--;
  }

  if (aStart == aSuf) {
    for (var j = bStart; j < bSuf; j++) {
      out.add((DiffOperation.insert.index, b[j]));
    }
  } else if (bStart == bSuf) {
    for (var i = aStart; i < aSuf; i++) {
      out.add((DiffOperation.delete.index, a[i]));
    }
  } else {
    final mid = _myersFindMiddleSnake(a, aStart, aSuf, b, bStart, bSuf);
    _myersRec(a, aStart, mid.$1, b, bStart, mid.$2, out);
    _myersRec(a, mid.$1, aSuf, b, mid.$2, bSuf, out);
  }

  for (var i = aSuf; i < aEnd; i++) {
    out.add((DiffOperation.equal.index, a[i]));
  }
}

(int, int) _myersFindMiddleSnake(
  List<int> a, int aStart, int aEnd,
  List<int> b, int bStart, int bEnd,
) {
  final n = aEnd - aStart;
  final m = bEnd - bStart;
  final delta = n - m;
  final deltaIsOdd = delta.abs() % 2 == 1;
  final maxD = (n + m + 1) ~/ 2;
  final offset = maxD;
  final size = 2 * maxD + 1;
  final vf = List<int>.filled(size, 0);
  final vb = List<int>.filled(size, 0);

  for (var d = 0; d <= maxD; d++) {
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d ||
          (k != d && vf[offset + k - 1] < vf[offset + k + 1])) {
        x = vf[offset + k + 1];
      } else {
        x = vf[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[aStart + x] == b[bStart + y]) {
        x++;
        y++;
      }
      vf[offset + k] = x;
      if (deltaIsOdd) {
        final bK = delta - k;
        if (bK >= -d + 1 && bK <= d - 1) {
          if (vf[offset + k] + vb[offset + bK] >= n) {
            return (aStart + x, bStart + y);
          }
        }
      }
    }
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d ||
          (k != d && vb[offset + k - 1] < vb[offset + k + 1])) {
        x = vb[offset + k + 1];
      } else {
        x = vb[offset + k - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[aEnd - 1 - x] == b[bEnd - 1 - y]) {
        x++;
        y++;
      }
      vb[offset + k] = x;
      if (!deltaIsOdd) {
        final fK = delta - k;
        if (fK >= -d && fK <= d) {
          if (vb[offset + k] + vf[offset + fK] >= n) {
            final fx = vf[offset + fK];
            final fy = fx - fK;
            return (aStart + fx, bStart + fy);
          }
        }
      }
    }
  }
  return ((aStart + aEnd) ~/ 2, (bStart + bEnd) ~/ 2);
}

// ==================== 组装 DiffEntry ====================

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

final diffResultProvider = FutureProvider.autoDispose<DiffResult?>((ref) async {
  final sw = Stopwatch()..start();

  final original = ref.watch(preprocessedOriginalProvider);
  final modified = ref.watch(preprocessedModifiedProvider);
  if (original.isEmpty || modified.isEmpty) return null;

  ref.watch(importRevisionProvider);

  final tPrep = sw.elapsedMilliseconds;

  final payload = await compute(
    _computeInWorker,
    (
      original: original,
      modified: modified,
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
    origLen: original.length,
    modLen: modified.length,
    origLines: payload.origLines,
    modLines: payload.modLines,
    uniqueLines: payload.uniqueLines,
    usedMyers: payload.usedMyers,
  );

  return DiffResult(entries: entries, engineType: DiffEngineType.line);
});

// ==================== 差异颜色（持久化） ====================

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

final deleteRowBgProvider =
    NotifierProvider<DeleteRowBgNotifier, Color>(DeleteRowBgNotifier.new);

class DeleteRowBgNotifier extends ColorPrefNotifier {
  DeleteRowBgNotifier()
      : super(
          key: PrefKeys.colorDeleteRowBg,
          initial: const Color(0xFFFF0000),
        );
}

final deleteRowFgProvider =
    NotifierProvider<DeleteRowFgNotifier, Color>(DeleteRowFgNotifier.new);

class DeleteRowFgNotifier extends ColorPrefNotifier {
  DeleteRowFgNotifier()
      : super(
          key: PrefKeys.colorDeleteRowFg,
          initial: const Color(0xFF000000),
        );
}

final insertRowBgProvider =
    NotifierProvider<InsertRowBgNotifier, Color>(InsertRowBgNotifier.new);

class InsertRowBgNotifier extends ColorPrefNotifier {
  InsertRowBgNotifier()
      : super(
          key: PrefKeys.colorInsertRowBg,
          initial: const Color(0xFF00FF00),
        );
}

final insertRowFgProvider =
    NotifierProvider<InsertRowFgNotifier, Color>(InsertRowFgNotifier.new);

class InsertRowFgNotifier extends ColorPrefNotifier {
  InsertRowFgNotifier()
      : super(
          key: PrefKeys.colorInsertRowFg,
          initial: const Color(0xFF000000),
        );
}

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

final charDeleteBgProvider =
    NotifierProvider<CharDeleteBgNotifier, Color>(CharDeleteBgNotifier.new);

class CharDeleteBgNotifier extends ColorPrefNotifier {
  CharDeleteBgNotifier()
      : super(
          key: PrefKeys.colorCharDeleteBg,
          initial: const Color(0xFFB71C1C),
        );
}

final charDeleteFgProvider =
    NotifierProvider<CharDeleteFgNotifier, Color>(CharDeleteFgNotifier.new);

class CharDeleteFgNotifier extends ColorPrefNotifier {
  CharDeleteFgNotifier()
      : super(
          key: PrefKeys.colorCharDeleteFg,
          initial: const Color(0xFFFFFFFF),
        );
}

final charInsertBgProvider =
    NotifierProvider<CharInsertBgNotifier, Color>(CharInsertBgNotifier.new);

class CharInsertBgNotifier extends ColorPrefNotifier {
  CharInsertBgNotifier()
      : super(
          key: PrefKeys.colorCharInsertBg,
          initial: const Color(0xFF1B5E20),
        );
}

final charInsertFgProvider =
    NotifierProvider<CharInsertFgNotifier, Color>(CharInsertFgNotifier.new);

class CharInsertFgNotifier extends ColorPrefNotifier {
  CharInsertFgNotifier()
      : super(
          key: PrefKeys.colorCharInsertFg,
          initial: const Color(0xFFFFFFFF),
        );
}

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

String colorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? hexToColor(String s) {
  if (s.length != 7 || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

// ==================== 查找历史（持久化） ====================

/// 上限 50 条，去重（最新在前）。
final findHistoryProvider =
    NotifierProvider<FindHistoryNotifier, List<String>>(
  FindHistoryNotifier.new,
);

class FindHistoryNotifier extends StringListPrefNotifier {
  FindHistoryNotifier() : super(key: PrefKeys.findHistory);

  static const int _max = 50;

  /// 记住一条。空串跳过；重复的挪到最前。
  void add(String q) {
    if (q.trim().isEmpty) return;
    final next = <String>[q, ...state.where((s) => s != q)];
    if (next.length > _max) next.removeRange(_max, next.length);
    update(next);
  }

  void remove(String q) {
    update(state.where((s) => s != q).toList());
  }
}

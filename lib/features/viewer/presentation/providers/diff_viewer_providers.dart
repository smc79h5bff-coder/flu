import 'dart:convert';

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
import '../../../preprocessing/domain/preprocessing_rule.dart';

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

// ==================== 忽略规则（持久化，列表式） ====================

final RegExp _horizontalWhitespace = RegExp(r'[ \t]+');

final RegExp _invisibleChars = RegExp(
  r'[\u00A0\u00AD'
  r'\u200B-\u200F'
  r'\u202A-\u202E'
  r'\u202F'
  r'\u2060-\u2064'
  r'\u2066-\u2069'
  r'\uFEFF]',
);

/// 8 条忽略规则。顺序 = 执行顺序。
List<PreprocessingRule> defaultIgnoreRules() => const [
      PreprocessingRule(
        id: 'ig_nl',
        name: '统一换行符',
        findPattern: r'\r\n|\r',
        replaceWith: '\n',
        isBuiltin: true,
      ),
      PreprocessingRule(
        id: 'ig_invisible',
        name: '忽略不可见字符',
        findPattern:
            r'[\u00A0\u00AD\u200B-\u200F\u202A-\u202E\u202F\u2060-\u2064\u2066-\u2069\uFEFF]',
        replaceWith: '',
        isBuiltin: true,
      ),
      PreprocessingRule(
        id: 'ig_ws',
        name: '删掉空白符号',
        findPattern: r'[ \t]+',
        replaceWith: '',
        isBuiltin: true,
      ),
      PreprocessingRule(
        id: 'ig_empty',
        name: '删掉空行',
        script: 'dropEmptyLines',
        isBuiltin: true,
      ),
      PreprocessingRule(
        id: 'ig_comma',
        name: '忽略逗号',
        findPattern: r'[,，]',
        replaceWith: '',
        enabled: false,
        isBuiltin: true,
      ),
      PreprocessingRule(
        id: 'ig_num',
        name: '忽略纯数字（数字改为占位符）',
        findPattern: r'[0-9]+',
        replaceWith: '<NUM>',
        enabled: false,
        isBuiltin: true,
      ),
      PreprocessingRule(
        id: 'ig_case',
        name: '大写全转成小写',
        script: 'lowercase',
        enabled: false,
        isBuiltin: true,
      ),
      PreprocessingRule(
        id: 'ig_ansi',
        name: '统一编码 ANSI',
        script: 'unifyAnsi',
        enabled: false,
        isBuiltin: true,
      ),
    ];

final ignoreRuleEnablesProvider =
    NotifierProvider<IgnoreRuleEnablesNotifier, Map<String, bool>>(
  IgnoreRuleEnablesNotifier.new,
);

class IgnoreRuleEnablesNotifier
    extends PersistentNotifier<Map<String, bool>> {
  @override
  String get key => PrefKeys.ignoreRuleEnables;

  @override
  Map<String, bool> get defaultValue => {
        for (final r in defaultIgnoreRules()) r.id: r.enabled,
      };

  @override
  Map<String, bool> decode(String raw) {
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    final out = {
      for (final r in defaultIgnoreRules()) r.id: r.enabled,
    };
    for (final e in saved.entries) {
      if (out.containsKey(e.key)) out[e.key] = e.value == true;
    }
    return out;
  }

  @override
  String encode(Map<String, bool> value) => jsonEncode(value);

  void setOne(String id, bool enabled) {
    update({...state, id: enabled});
  }
}

bool isIgnoreOn(Map<String, bool> enables, String id) {
  for (final r in defaultIgnoreRules()) {
    if (r.id == id) return enables[id] ?? r.enabled;
  }
  return false;
}

String unifyToAnsi(String text) {
  try {
    final bytes = gbk.encode(text);
    if (gbk.decode(bytes) == text) return text;
  } catch (_) {}
  final sb = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    try {
      final bytes = gbk.encode(ch);
      if (gbk.decode(bytes) != ch) continue;
      sb.write(ch);
    } catch (_) {}
  }
  return sb.toString();
}

String applyDiffIgnores(String text, Map<String, bool> enables) {
  var out = text;
  for (final rule in defaultIgnoreRules()) {
    final on = enables[rule.id] ?? rule.enabled;
    if (!on) continue;

    final script = rule.script;
    if (script != null) {
      switch (script) {
        case 'lowercase':
          out = out.toLowerCase();
          break;
        case 'dropEmptyLines':
          out = out
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .join('\n');
          break;
        case 'unifyAnsi':
          out = unifyToAnsi(out);
          break;
      }
      continue;
    }

    try {
      out = out.replaceAll(
        RegExp(rule.findPattern, multiLine: true),
        rule.replaceWith,
      );
    } catch (_) {}
  }
  return out;
}

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
    usedMyers = true;
    final ops = _myersDiff(idsA, idsB);
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

const int _myersMaxD = 5000;

List<(int, int)> _myersDiff(List<int> a, List<int> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0 && m == 0) return const [];
  if (n == 0) return [for (final id in b) (DiffOperation.insert.index, id)];
  if (m == 0) return [for (final id in a) (DiffOperation.delete.index, id)];

  final maxD = n + m;
  final offset = maxD;
  final v = List<int>.filled(2 * maxD + 1, 0);
  final trace = <List<int>>[];

  int idx(int k) => k + offset;

  var foundD = -1;
  outer:
  for (var d = 0; d <= maxD; d++) {
    if (d > _myersMaxD) {
      return [
        for (final id in a) (DiffOperation.delete.index, id),
        for (final id in b) (DiffOperation.insert.index, id),
      ];
    }
    trace.add(List<int>.from(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[idx(k - 1)] < v[idx(k + 1)])) {
        x = v[idx(k + 1)];
      } else {
        x = v[idx(k - 1)] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[idx(k)] = x;
      if (x >= n && y >= m) {
        foundD = d;
        break outer;
      }
    }
  }
  if (foundD < 0) {
    return [
      for (final id in a) (DiffOperation.delete.index, id),
      for (final id in b) (DiffOperation.insert.index, id),
    ];
  }

  final rev = <(int, int)>[];
  var x = n;
  var y = m;
  for (var d = foundD; d > 0; d--) {
    final vPrev = trace[d];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && vPrev[idx(k - 1)] < vPrev[idx(k + 1)])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = vPrev[idx(prevK)];
    final prevY = prevX - prevK;

    while (x > prevX && y > prevY) {
      x--;
      y--;
      rev.add((DiffOperation.equal.index, a[x]));
    }
    if (x == prevX) {
      y--;
      rev.add((DiffOperation.insert.index, b[y]));
    } else {
      x--;
      rev.add((DiffOperation.delete.index, a[x]));
    }
  }
  while (x > 0 && y > 0) {
    x--;
    y--;
    rev.add((DiffOperation.equal.index, a[x]));
  }
  while (x > 0) {
    x--;
    rev.add((DiffOperation.delete.index, a[x]));
  }
  while (y > 0) {
    y--;
    rev.add((DiffOperation.insert.index, b[y]));
  }

  return rev.reversed.toList();
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

final diffResultProvider = FutureProvider.autoDispose<DiffResult?>((ref) async {
  final sw = Stopwatch()..start();

  final original = ref.watch(preprocessedOriginalProvider);
  final modified = ref.watch(preprocessedModifiedProvider);
  if (original.isEmpty || modified.isEmpty) return null;

  final ignoreEnables = ref.watch(ignoreRuleEnablesProvider);
  final origNorm = applyDiffIgnores(original, ignoreEnables);
  final modNorm = applyDiffIgnores(modified, ignoreEnables);
  if (origNorm.isEmpty || modNorm.isEmpty) return null;

  ref.watch(importRevisionProvider);

  final tPrep = sw.elapsedMilliseconds;

  final payload = await compute(
    _computeInWorker,
    (
      original: origNorm,
      modified: modNorm,
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

int? rawLineForNormalizedLine(
  String raw, {
  required int normalizedLine,
  required Map<String, bool> ignoreEnables,
}) {
  final ignoreWhitespace = isIgnoreOn(ignoreEnables, 'ig_ws');
  final ignoreEmptyLines = isIgnoreOn(ignoreEnables, 'ig_empty');
  final ignoreInvisible = isIgnoreOn(ignoreEnables, 'ig_invisible');

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

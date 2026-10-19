import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';

/// 对比页按钮栏里的规则。
///
/// 复用 PreprocessingRule 数据结构。以下字段在按钮规则里无意义：
///   - enabled    写死 true
///   - scope      写死 both（点击时弹窗选哪侧，覆盖 scope）
///   - isBuiltin  写死 false
/// UI 上不显示这三个字段。
final toolbarRulesProvider =
    NotifierProvider<ToolbarRulesNotifier, List<PreprocessingRule>>(
  ToolbarRulesNotifier.new,
);

class ToolbarRulesNotifier
    extends PersistentNotifier<List<PreprocessingRule>> {
  @override
  String get key => PrefKeys.toolbarRules;

  @override
  List<PreprocessingRule> get defaultValue => const [];

  @override
  List<PreprocessingRule> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        _normalizeForToolbar(
          PreprocessingRule.fromJson(e as Map<String, dynamic>),
        ),
    ];
  }

  @override
  String encode(List<PreprocessingRule> value) =>
      jsonEncode([for (final r in value) r.toJson()]);

  /// 新增按钮。[row] 是按钮所属行（1~3），默认第 1 行。
  void add(PreprocessingRule rule, {int row = 1}) {
    final normalized = _normalizeForToolbar(rule);
    update([...state, normalized]);
    ref.read(toolbarOrderProvider.notifier).append(normalized.id);
    // 记录按钮所属行。
    ref
        .read(toolbarButtonRowsProvider.notifier)
        .setOne(normalized.id, row.clamp(1, 3));
  }

  void updateRule(PreprocessingRule rule) {
    final normalized = _normalizeForToolbar(rule);
    update([
      for (final r in state)
        if (r.id == normalized.id) normalized else r,
    ]);
  }

  void remove(String id) {
    update(state.where((r) => r.id != id).toList());
    ref.read(toolbarOrderProvider.notifier).removeId(id);
    // 顺便清掉这个按钮的颜色和行号设置，避免残留。
    ref.read(toolbarButtonColorsProvider.notifier).remove(id);
    ref.read(toolbarButtonRowsProvider.notifier).remove(id);
  }

  void setAll(List<PreprocessingRule> rules) {
    update(rules.map(_normalizeForToolbar).toList());
  }
}

/// 把规则里对按钮无意义的字段强制成固定值。
/// 直接构造新对象，避免 copyWith 改不了 isBuiltin 的问题。
PreprocessingRule _normalizeForToolbar(PreprocessingRule r) {
  return PreprocessingRule(
    id: r.id,
    name: r.name,
    kind: r.kind,
    findPattern: r.findPattern,
    replaceWith: r.replaceWith,
    scope: RuleScope.both,
    enabled: true,
    isBuiltin: false,
    script: r.script,
    findRegex: r.findRegex,
    findLiteral: r.findLiteral,
    findEscape: r.findEscape,
    replaceDollar: r.replaceDollar,
    replaceBackslash: r.replaceBackslash,
    replaceLiteral: r.replaceLiteral,
    replaceEscape: r.replaceEscape,
    presetId: r.presetId,
    params: r.params,
    jsScript: r.jsScript,
  );
}

/// 按钮顺序（持久化）。
final toolbarOrderProvider =
    NotifierProvider<ToolbarOrderNotifier, List<String>>(
  ToolbarOrderNotifier.new,
);

class ToolbarOrderNotifier extends PersistentNotifier<List<String>> {
  @override
  String get key => PrefKeys.toolbarOrder;

  @override
  List<String> get defaultValue => const [];

  @override
  List<String> decode(String raw) {
    if (raw.isEmpty) return const [];
    return raw.split('\u0000').where((s) => s.isNotEmpty).toList();
  }

  @override
  String encode(List<String> value) => value.join('\u0000');

  void setAll(List<String> ids) => update(List<String>.from(ids));

  void append(String id) {
    if (state.contains(id)) return;
    update([...state, id]);
  }

  void removeId(String id) {
    if (!state.contains(id)) return;
    update(state.where((s) => s != id).toList());
  }

  void reorder(int oldIndex, int newIndex) {
    final list = List<String>.from(state);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > list.length - 1) newIndex = list.length - 1;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    update(list);
  }
}

/// 合并按钮规则 + 顺序，返回排好序的列表。
final toolbarRulesOrderedProvider =
    Provider<List<PreprocessingRule>>((ref) {
  final rules = ref.watch(toolbarRulesProvider);
  final order = ref.watch(toolbarOrderProvider);

  final byId = <String, PreprocessingRule>{};
  for (final r in rules) byId[r.id] = r;

  final result = <PreprocessingRule>[];
  final seen = <String>{};
  for (final id in order) {
    final r = byId[id];
    if (r != null && !seen.contains(id)) {
      result.add(r);
      seen.add(id);
    }
  }
  // 不在 order 里的兜底补上。
  for (final r in rules) {
    if (!seen.contains(r.id)) result.add(r);
  }
  return result;
});

// ==================== 按钮所属行（新增） ====================

/// 按钮所属行的持久化 key。直接内联，避免改 pref_keys.dart。
const String _toolbarRowsKey = 'jianming.toolbar.rows';

/// 按钮所属行表：ruleId → 行号（1~3）。
/// 老数据没有这个表，读取时不在表里的按钮一律视为第 1 行（迁移即默认值）。
final toolbarButtonRowsProvider =
    NotifierProvider<ToolbarButtonRowsNotifier, Map<String, int>>(
  ToolbarButtonRowsNotifier.new,
);

class ToolbarButtonRowsNotifier
    extends PersistentNotifier<Map<String, int>> {
  @override
  String get key => _toolbarRowsKey;

  @override
  Map<String, int> get defaultValue => const {};

  @override
  Map<String, int> decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) {
      final n = v is int ? v : int.tryParse('$v') ?? 1;
      return MapEntry(k, n.clamp(1, 3));
    });
  }

  @override
  String encode(Map<String, int> value) => jsonEncode(value);

  /// 读取某个按钮的行号。不在表里的老按钮视为第 1 行。
  int rowOf(String ruleId) => state[ruleId] ?? 1;

  /// 设置某个按钮的行号。
  void setOne(String ruleId, int row) {
    final next = Map<String, int>.from(state);
    next[ruleId] = row.clamp(1, 3);
    update(next);
  }

  /// 批量写回行号（排序对话框保存时用）。
  void setMany(Map<String, int> rows) {
    final next = Map<String, int>.from(state);
    rows.forEach((id, row) => next[id] = row.clamp(1, 3));
    update(next);
  }

  /// 删除某个按钮的行记录。
  void remove(String ruleId) {
    if (!state.containsKey(ruleId)) return;
    final next = Map<String, int>.from(state);
    next.remove(ruleId);
    update(next);
  }

  /// 批量删除（排序对话框保存时清理已删除按钮）。
  void removeMany(Iterable<String> ids) {
    final next = Map<String, int>.from(state);
    var changed = false;
    for (final id in ids) {
      if (next.remove(id) != null) changed = true;
    }
    if (changed) update(next);
  }
}

/// 把按钮按行分好组：返回固定 3 个列表，依次是第 1/2/3 行内排好序的按钮。
/// 行号读 toolbarButtonRowsProvider，没有记录的按钮算第 1 行。
final toolbarRowsOrderedProvider =
    Provider<List<List<PreprocessingRule>>>((ref) {
  final ordered = ref.watch(toolbarRulesOrderedProvider);
  final rows = ref.watch(toolbarButtonRowsProvider);
  final result = List.generate(3, (_) => <PreprocessingRule>[]);
  for (final r in ordered) {
    final row = (rows[r.id] ?? 1).clamp(1, 3);
    result[row - 1].add(r);
  }
  return result;
});

// ==================== 按钮颜色（新增） ====================

/// 每个按钮的三个颜色。值为 null 表示用主题色（跟随深浅模式）。
class ToolbarButtonColor {
  const ToolbarButtonColor({
    this.bg,
    this.fg,
    this.border,
  });

  final Color? bg;
  final Color? fg;
  final Color? border;

  bool get isEmpty => bg == null && fg == null && border == null;

  ToolbarButtonColor copyWith({
    Color? bg,
    Color? fg,
    Color? border,
    bool clearBg = false,
    bool clearFg = false,
    bool clearBorder = false,
  }) =>
      ToolbarButtonColor(
        bg: clearBg ? null : (bg ?? this.bg),
        fg: clearFg ? null : (fg ?? this.fg),
        border: clearBorder ? null : (border ?? this.border),
      );

  Map<String, dynamic> toJson() => {
        if (bg != null) 'bg': _colorToHex(bg!),
        if (fg != null) 'fg': _colorToHex(fg!),
        if (border != null) 'border': _colorToHex(border!),
      };

  factory ToolbarButtonColor.fromJson(Map<String, dynamic> j) {
    return ToolbarButtonColor(
      bg: _hexToColor(j['bg'] as String?),
      fg: _hexToColor(j['fg'] as String?),
      border: _hexToColor(j['border'] as String?),
    );
  }
}

String _colorToHex(Color c) {
  final v = c.toARGB32() & 0xFFFFFF;
  return '#${v.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

Color? _hexToColor(String? s) {
  if (s == null || s.length != 7 || !s.startsWith('#')) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// 按钮颜色的持久化 key。直接内联，避免改 pref_keys.dart。
const String _toolbarColorsKey = 'jianming.toolbar.colors';

/// 按钮颜色表：ruleId → 三个颜色。
final toolbarButtonColorsProvider =
    NotifierProvider<ToolbarButtonColorsNotifier,
        Map<String, ToolbarButtonColor>>(
  ToolbarButtonColorsNotifier.new,
);

class ToolbarButtonColorsNotifier
    extends PersistentNotifier<Map<String, ToolbarButtonColor>> {
  @override
  String get key => _toolbarColorsKey;

  @override
  Map<String, ToolbarButtonColor> get defaultValue => const {};

  @override
  Map<String, ToolbarButtonColor> decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(
          k,
          ToolbarButtonColor.fromJson(v as Map<String, dynamic>),
        ));
  }

  @override
  String encode(Map<String, ToolbarButtonColor> value) =>
      jsonEncode(value.map((k, v) => MapEntry(k, v.toJson())));

  /// 设置某个按钮的颜色。传全 null 的 color 视为删除。
  void setOne(String ruleId, ToolbarButtonColor color) {
    final next = Map<String, ToolbarButtonColor>.from(state);
    if (color.isEmpty) {
      next.remove(ruleId);
    } else {
      next[ruleId] = color;
    }
    update(next);
  }

  /// 删除某个按钮的颜色记录。
  void remove(String ruleId) {
    if (!state.containsKey(ruleId)) return;
    final next = Map<String, ToolbarButtonColor>.from(state);
    next.remove(ruleId);
    update(next);
  }
}

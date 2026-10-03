import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/storage/pref_keys.dart';
import '../../../../../core/storage/persistent_notifier.dart';
import '../../../../preprocessing/domain/preprocessing_rule.dart';

/// 行编辑器顶部按钮栏里的规则。
///
/// **和对比页的 toolbarRulesProvider 完全独立**：
///   · 两套不同的 SharedPreferences key
///   · 两套不同的顺序列表
///   · 两套不同的颜色表
///   · 在一边新建/删除/改名/改色，另一边不受影响
///
/// 复用 PreprocessingRule 数据结构。以下字段在按钮规则里无意义：
///   - enabled    写死 true
///   - scope      写死 both
///   - isBuiltin  写死 false
final lineEditorRulesProvider =
    NotifierProvider<LineEditorRulesNotifier, List<PreprocessingRule>>(
  LineEditorRulesNotifier.new,
);

class LineEditorRulesNotifier
    extends PersistentNotifier<List<PreprocessingRule>> {
  @override
  String get key => PrefKeys.lineEditorRules;

  @override
  List<PreprocessingRule> get defaultValue => const [];

  @override
  List<PreprocessingRule> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return [
      for (final e in list)
        _normalizeForLineEditor(
          PreprocessingRule.fromJson(e as Map<String, dynamic>),
        ),
    ];
  }

  @override
  String encode(List<PreprocessingRule> value) =>
      jsonEncode([for (final r in value) r.toJson()]);

  void add(PreprocessingRule rule) {
    final normalized = _normalizeForLineEditor(rule);
    update([...state, normalized]);
    ref.read(lineEditorOrderProvider.notifier).append(normalized.id);
  }

  void updateRule(PreprocessingRule rule) {
    final normalized = _normalizeForLineEditor(rule);
    update([
      for (final r in state)
        if (r.id == normalized.id) normalized else r,
    ]);
  }

  void remove(String id) {
    update(state.where((r) => r.id != id).toList());
    ref.read(lineEditorOrderProvider.notifier).removeId(id);
    ref.read(lineEditorButtonColorsProvider.notifier).remove(id);
  }

  void setAll(List<PreprocessingRule> rules) {
    update(rules.map(_normalizeForLineEditor).toList());
  }
}

PreprocessingRule _normalizeForLineEditor(PreprocessingRule r) {
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

/// 行编辑器按钮顺序（持久化）。
final lineEditorOrderProvider =
    NotifierProvider<LineEditorOrderNotifier, List<String>>(
  LineEditorOrderNotifier.new,
);

class LineEditorOrderNotifier extends PersistentNotifier<List<String>> {
  @override
  String get key => PrefKeys.lineEditorOrder;

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
}

/// 合并按钮规则 + 顺序，返回排好序的列表。
final lineEditorRulesOrderedProvider =
    Provider<List<PreprocessingRule>>((ref) {
  final rules = ref.watch(lineEditorRulesProvider);
  final order = ref.watch(lineEditorOrderProvider);

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
  for (final r in rules) {
    if (!seen.contains(r.id)) result.add(r);
  }
  return result;
});

// ==================== 按钮颜色 ====================

class LineEditorButtonColor {
  const LineEditorButtonColor({
    this.bg,
    this.fg,
    this.border,
  });

  final Color? bg;
  final Color? fg;
  final Color? border;

  bool get isEmpty => bg == null && fg == null && border == null;

  LineEditorButtonColor copyWith({
    Color? bg,
    Color? fg,
    Color? border,
    bool clearBg = false,
    bool clearFg = false,
    bool clearBorder = false,
  }) =>
      LineEditorButtonColor(
        bg: clearBg ? null : (bg ?? this.bg),
        fg: clearFg ? null : (fg ?? this.fg),
        border: clearBorder ? null : (border ?? this.border),
      );

  Map<String, dynamic> toJson() => {
        if (bg != null) 'bg': _colorToHex(bg!),
        if (fg != null) 'fg': _colorToHex(fg!),
        if (border != null) 'border': _colorToHex(border!),
      };

  factory LineEditorButtonColor.fromJson(Map<String, dynamic> j) {
    return LineEditorButtonColor(
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

final lineEditorButtonColorsProvider =
    NotifierProvider<LineEditorButtonColorsNotifier,
        Map<String, LineEditorButtonColor>>(
  LineEditorButtonColorsNotifier.new,
);

class LineEditorButtonColorsNotifier
    extends PersistentNotifier<Map<String, LineEditorButtonColor>> {
  @override
  String get key => PrefKeys.lineEditorButtonColors;

  @override
  Map<String, LineEditorButtonColor> get defaultValue => const {};

  @override
  Map<String, LineEditorButtonColor> decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(
          k,
          LineEditorButtonColor.fromJson(v as Map<String, dynamic>),
        ));
  }

  @override
  String encode(Map<String, LineEditorButtonColor> value) =>
      jsonEncode(value.map((k, v) => MapEntry(k, v.toJson())));

  void setOne(String ruleId, LineEditorButtonColor color) {
    final next = Map<String, LineEditorButtonColor>.from(state);
    if (color.isEmpty) {
      next.remove(ruleId);
    } else {
      next[ruleId] = color;
    }
    update(next);
  }

  void remove(String ruleId) {
    if (!state.containsKey(ruleId)) return;
    final next = Map<String, LineEditorButtonColor>.from(state);
    next.remove(ruleId);
    update(next);
  }
}

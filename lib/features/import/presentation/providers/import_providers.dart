import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../preprocessing/application/builtin_rules.dart';
import '../../../preprocessing/application/preprocessing_service.dart';
import '../../../preprocessing/domain/preprocessing_rule.dart';
import '../../domain/import_source.dart';

/// Holds the *raw* text imported from a local file / clipboard.
/// Preprocessing produces the *processed* variant used by diff.
final originalRawTextProvider = StateProvider<String?>((ref) => null);
final modifiedRawTextProvider = StateProvider<String?>((ref) => null);

/// 导入文件的文件名（用于在导入卡片旁展示）。
final originalFileNameProvider = StateProvider<String?>((ref) => null);
final modifiedFileNameProvider = StateProvider<String?>((ref) => null);

/// 导入文件的真实磁盘路径（FilePicker 返回，可能为 null）。用于编辑后
/// “覆盖原文件 + 自动 .bak 备份”；拿不到路径时保存会降级为另存为。
final originalFilePathProvider = StateProvider<String?>((ref) => null);
final modifiedFilePathProvider = StateProvider<String?>((ref) => null);

/// Encoding label surfaced in the export footer.
final originalEncodingProvider = StateProvider<String>((ref) => 'UTF-8');
final modifiedEncodingProvider = StateProvider<String>((ref) => 'UTF-8');

/// Active diff engine (P0 toggles line ↔ char; semantic is P2).
final useCharEngineProvider = StateProvider<bool>((ref) => false);

/// Toggles "show processed text" vs "show original text" in the viewer.
/// PRD §2 Module 3.4 — diff is always computed on processed text.
final showProcessedTextProvider = StateProvider<bool>((ref) => false);

/// User-defined preprocessing rules (mutable list).
final userRulesProvider =
    StateNotifierProvider<UserRulesNotifier, List<PreprocessingRule>>(
  (ref) => UserRulesNotifier(),
);

/// Built-in rule enabled-states, keyed by rule id. Lets the user select which
/// built-in rules run during preprocessing (seeded from defaults).
final builtinRuleEnablesProvider =
    StateProvider<Map<String, bool>>((ref) {
  return <String, bool>{
    for (final r in BuiltinRules.all()) r.id: r.enabled,
  };
});

/// Built-in rules resolved against the user-selected enabled-states.
final builtinRulesWithStateProvider = Provider<List<PreprocessingRule>>((ref) {
  final overrides = ref.watch(builtinRuleEnablesProvider);
  return <PreprocessingRule>[
    for (final r in BuiltinRules.all())
      r.copyWith(enabled: overrides[r.id] ?? r.enabled),
  ];
});

class UserRulesNotifier extends StateNotifier<List<PreprocessingRule>> {
  UserRulesNotifier() : super(const []);

  void add(PreprocessingRule rule) => state = [...state, rule];

  void update(PreprocessingRule rule) => state = [
        for (final r in state)
          if (r.id == rule.id) rule else r,
      ];

  void remove(String id) =>
      state = state.where((r) => r.id != id).toList();

  void toggle(String id) => state = [
        for (final r in state)
          if (r.id == id) r.copyWith(enabled: !r.enabled) else r,
      ];

  void importFromJson(List<Map<String, dynamic>> json) =>
      state = json.map(PreprocessingRule.fromJson).toList();
}

/// Computed: produces preprocessed text for both sides.
final preprocessedOriginalProvider = Provider<String>((ref) {
  final raw = ref.watch(originalRawTextProvider);
  if (raw == null) return '';
  final rules = ref.watch(userRulesProvider);
  final builtins = ref.watch(builtinRulesWithStateProvider);
  return PreprocessingService(userRules: rules, builtinRules: builtins)
      .apply(raw, isOriginal: true);
});

final preprocessedModifiedProvider = Provider<String>((ref) {
  final raw = ref.watch(modifiedRawTextProvider);
  if (raw == null) return '';
  final rules = ref.watch(userRulesProvider);
  final builtins = ref.watch(builtinRulesWithStateProvider);
  return PreprocessingService(userRules: rules, builtinRules: builtins)
      .apply(raw, isOriginal: false);
});

/// Bumped whenever a new import succeeds — used by the viewer to know
/// a recomputation is needed.
final importRevisionProvider = StateProvider<int>((ref) => 0);

/// Currently selected import source (for UI affordances).
final selectedSourceProvider =
    StateProvider<ImportSource?>((ref) => null);

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shared_preferences_provider.dart';

/// 会持久化的 Notifier 基类。
///
/// 子类只需要实现 4 件事：
///   - [key]：prefs 里的键名（用 [PrefKeys] 里的常量）
///   - [defaultValue]：读不到 / 解码失败时的默认值
///   - [decode]：字符串 → T
///   - [encode]：T → 字符串
///
/// **修改值用 [update]，不要用 `state = v`**。后者只改内存、不写磁盘。
abstract class PersistentNotifier<T> extends Notifier<T> {
  String get key;
  T get defaultValue;
  T decode(String raw);
  String encode(T value);

  @override
  T build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final raw = prefs.getString(key);
    if (raw == null) return defaultValue;
    try {
      return decode(raw);
    } catch (_) {
      return defaultValue;
    }
  }

  /// 更新内存（UI 立刻刷新）+ 写磁盘（异步，不阻塞）。
  void update(T value) {
    state = value;
    final prefs = ref.read(sharedPreferencesProvider);
    unawaited(prefs.setString(key, encode(value)));
  }
}

// ==================== 常用类型的子类 ====================

/// 布尔。
class BoolPrefNotifier extends PersistentNotifier<bool> {
  BoolPrefNotifier({required this.key, required bool initial})
      : _initial = initial;

  @override
  final String key;
  final bool _initial;

  @override
  bool get defaultValue => _initial;

  @override
  bool decode(String raw) => raw == 'true';

  @override
  String encode(bool value) => value ? 'true' : 'false';
}

/// 浮点（字号等）。
class DoublePrefNotifier extends PersistentNotifier<double> {
  DoublePrefNotifier({required this.key, required double initial})
      : _initial = initial;

  @override
  final String key;
  final double _initial;

  @override
  double get defaultValue => _initial;

  @override
  double decode(String raw) => double.parse(raw);

  @override
  String encode(double value) => value.toString();
}

/// 字符串（规则文本等）。
class StringPrefNotifier extends PersistentNotifier<String> {
  StringPrefNotifier({required this.key, String initial = ''})
      : _initial = initial;

  @override
  final String key;
  final String _initial;

  @override
  String get defaultValue => _initial;

  @override
  String decode(String raw) => raw;

  @override
  String encode(String value) => value;
}

/// 字符串列表（收藏夹、自定义搜索文件夹等）。
/// 用 `\u0000`（NUL）当分隔符，因为文件路径里不会出现这个字符。
class StringListPrefNotifier extends PersistentNotifier<List<String>> {
  StringListPrefNotifier({required this.key, List<String> initial = const []})
      : _initial = initial;

  @override
  final String key;
  final List<String> _initial;

  @override
  List<String> get defaultValue => List<String>.from(_initial);

  @override
  List<String> decode(String raw) =>
      raw.isEmpty ? <String>[] : raw.split('\u0000');

  @override
  String encode(List<String> value) => value.join('\u0000');
}

/// 用 JSON 序列化的复杂对象（Map、List<自定义类> 等）。
class JsonPrefNotifier<T> extends PersistentNotifier<T> {
  JsonPrefNotifier({
    required this.key,
    required T initial,
    required T Function(Object? json) fromJson,
  })  : _initial = initial,
        _fromJson = fromJson;

  @override
  final String key;
  final T _initial;
  final T Function(Object? json) _fromJson;

  @override
  T get defaultValue => _initial;

  @override
  T decode(String raw) => _fromJson(jsonDecode(raw));

  @override
  String encode(T value) => jsonEncode(value);
}

/// 枚举（排序方式、搜索范围等）。存 `.name`，读时按 `values` 匹配。
class EnumPrefNotifier<T extends Enum> extends PersistentNotifier<T> {
  EnumPrefNotifier({
    required this.key,
    required this.values,
    required T initial,
  }) : _initial = initial;

  @override
  final String key;
  final List<T> values;
  final T _initial;

  @override
  T get defaultValue => _initial;

  @override
  T decode(String raw) =>
      values.firstWhere((e) => e.name == raw, orElse: () => _initial);

  @override
  String encode(T value) => value.name;
}

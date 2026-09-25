import '../../diff/domain/diff_result.dart';

/// 文本 → 第一个出现的 entry 下标。按 DiffResult 实例缓存。
///
/// 用途：编辑某行后，要按"内容"回到原来位置。原来的做法是 O(n) 线性搜索
/// （`for i in entries: if entries[i].text == 目标`）。这里预建索引，
/// 查询变成 O(1)。整个索引只建一次，diff 换新的才重建。
class DiffTextIndex {
  DiffTextIndex._(this._map);

  final Map<String, int> _map;

  static DiffResult? _cachedFor;
  static DiffTextIndex? _cached;

  /// 拿（或建）这份 diff 的索引。
  static DiffTextIndex of(DiffResult diff) {
    if (identical(_cachedFor, diff) && _cached != null) {
      return _cached!;
    }
    final map = <String, int>{};
    for (var i = 0; i < diff.entries.length; i++) {
      final t = diff.entries[i].text;
      if (t.isNotEmpty) {
        map.putIfAbsent(t, () => i);
      }
    }
    final idx = DiffTextIndex._(map);
    _cached = idx;
    _cachedFor = diff;
    return idx;
  }

  /// 找 [text] 第一次出现的 entry 下标。没找到返回 null。
  int? firstEntryOf(String text) {
    if (text.isEmpty) return null;
    return _map[text];
  }

  /// 手动失效。文本被改过、diff 会重算时调用。
  static void invalidate() {
    _cached = null;
    _cachedFor = null;
  }
}

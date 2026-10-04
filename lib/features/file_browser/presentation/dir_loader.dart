import 'dart:collection';
import 'dart:io';

import '../../reader/reader_load_log.dart';
import 'providers/file_browser_providers.dart';

// ==================== EntryInfo ====================

/// 目录里的一个条目（文件或文件夹）。
///
/// [size] 和 [modified] 允许为 null：
///   · null 表示"还没 stat"或"stat 失败"
///   · 非 null 表示已 stat 完成
///
/// 惰性 stat 期间，会先构造 size/modified 都是 null 的 EntryInfo，
/// 后台 stat 完成后原地更新这两个字段。
class EntryInfo {
  EntryInfo({
    required this.entity,
    required this.name,
    required this.isDir,
    this.size,
    this.modified,
  });

  final FileSystemEntity entity;
  final String name;
  final bool isDir;

  /// 文件大小（字节）。文件夹为 null。惰性 stat 期间为 null。
  int? size;

  /// 修改时间。惰性 stat 期间为 null。
  DateTime? modified;

  String get path => entity.path;
}

// ==================== 取消令牌 ====================

/// 用于中断正在进行的目录加载。
/// 用户切换目录 / 离开时，把旧的 token cancel 掉。
class LoadCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

// ==================== 目录缓存 ====================

/// LRU 目录缓存。
///
/// key = "path|sortField|sortAsc"
///
/// · 缓存的是"已经排好序的最终列表"
/// · 不同排序方式视为不同缓存条目
/// · 上限 200 个，超过淘汰最早访问的
/// · 内存态，App 重启后自动清空
class DirCache {
  DirCache._();
  static final DirCache instance = DirCache._();

  static const int capacity = 200;

  final LinkedHashMap<String, List<EntryInfo>> _map = LinkedHashMap();

  List<EntryInfo>? get(String key) {
    final v = _map.remove(key);
    if (v == null) return null;
    _map[key] = v; // LRU：移到末尾
    return v;
  }

  void put(String key, List<EntryInfo> entries) {
    _map.remove(key);
    if (_map.length >= capacity) {
      final oldest = _map.keys.first;
      _map.remove(oldest);
      ReaderLoadLog.instance.info('[DirCache] LRU 淘汰  $oldest');
    }
    _map[key] = entries;
  }

  /// 清掉某个目录的所有缓存（所有排序方式都清）。
  void invalidate(String path) {
    final prefix = '$path|';
    final keys = _map.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in keys) {
      _map.remove(k);
    }
    if (keys.isNotEmpty) {
      ReaderLoadLog.instance
          .info('[DirCache] 失效  $path  (${keys.length} 条)');
    }
  }

  /// 对该目录下所有排序方式的缓存，应用一次转换函数。
  /// 用于"App 内删文件后同步缓存"：把被删的项从所有排序的缓存里剔掉。
  void applyToAll(String path,
      List<EntryInfo> Function(List<EntryInfo>) transform) {
    final prefix = '$path|';
    final keys = _map.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in keys) {
      _map[k] = transform(_map[k]!);
    }
    if (keys.isNotEmpty) {
      ReaderLoadLog.instance
          .info('[DirCache] 同步删除到 ${keys.length} 条缓存  $path');
    }
  }

  void invalidateAll() {
    _map.clear();
    ReaderLoadLog.instance.info('[DirCache] 全部失效');
  }
}

// ==================== 加载 ====================

/// stat 批次大小。每批完成后回调一次 onUpdate。
const int _statBatchSize = 500;

/// 异步加载一个目录。
///
/// 三阶段：
///   1. Directory.list → 拿文件名列表（不含 size / modified）
///   2. 立即回调 onUpdate，UI 能显示列表（字段显示 "—"）
///   3. 分批 stat，每批完成回调 onUpdate（字段逐步填上）
///   4. 全部完成回调 onComplete
///
/// [cancelToken] 用于中断：用户切换目录时，caller 调 cancel()，
/// 本函数在关键点检查 isCancelled 并提前返回。
Future<void> loadDirectoryAsync({
  required String path,
  required SortField sortField,
  required bool sortAsc,
  required LoadCancelToken cancelToken,
  required void Function(List<EntryInfo> list) onUpdate,
  required void Function(List<EntryInfo> list) onComplete,
}) async {
  final log = ReaderLoadLog.instance;
  final t0 = DateTime.now();

  // ---------- 阶段 1：list ----------
  final dir = Directory(path);
  final raw = await dir.list(followLinks: false).toList();
  if (cancelToken.isCancelled) return;
  log.info(
      '[DirLoad] list 返回 ${raw.length} 项  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');

  // 过滤隐藏文件（保持原逻辑）
  raw.removeWhere((e) {
    final name = e.path.split('/').last;
    return name.startsWith('.');
  });

  // ---------- 阶段 2：构造 EntryInfo（size/modified 都是 null） ----------
  final entries = <EntryInfo>[];
  for (final e in raw) {
    final name = e.path.split('/').last;
    final isDir = e is Directory;
    entries.add(EntryInfo(
      entity: e,
      name: name,
      isDir: isDir,
    ));
  }

  // 首次回调：先按"文件夹优先 + 名称升序"排，让 UI 能立即显示。
  // 如果用户选的是名称升序，这就是最终顺序；否则 stat 完后会重排。
  final initialList = _sortEntries(entries, SortField.name, true);
  onUpdate(initialList);
  log.info(
      '[DirLoad] 首次回调  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');

  // ---------- 阶段 3：分批 stat ----------
  final totalBatches = (entries.length / _statBatchSize).ceil();
  var batchIndex = 0;

  for (var i = 0; i < entries.length; i += _statBatchSize) {
    if (cancelToken.isCancelled) return;

    final end = (i + _statBatchSize).clamp(0, entries.length);
    final batch = entries.sublist(i, end);

    await Future.wait(batch.map((e) async {
      try {
        final st = await e.entity.stat();
        e.modified = st.modified;
        if (!e.isDir) e.size = st.size;
      } catch (_) {
        // stat 失败：保持 null，UI 会显示 "—"
      }
    }));

    if (cancelToken.isCancelled) return;

    batchIndex++;
    final sortedNow = _sortEntries(entries, sortField, sortAsc);
    onUpdate(sortedNow);
    log.info(
        '[DirLoad] stat 批次 $batchIndex/$totalBatches  累计=${DateTime.now().difference(t0).inMilliseconds}ms');
  }

  // ---------- 阶段 4：完成 ----------
  if (cancelToken.isCancelled) return;
  final finalList = _sortEntries(entries, sortField, sortAsc);
  onComplete(finalList);
  log.info(
      '[DirLoad] 全部完成  总耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
}

/// 按排序方式对列表排序。不修改原列表，返回新列表。
List<EntryInfo> _sortEntries(
  List<EntryInfo> entries,
  SortField sortField,
  bool sortAsc,
) {
  final copy = List<EntryInfo>.from(entries);
  copy.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    int cmp;
    switch (sortField) {
      case SortField.name:
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SortField.modified:
        final at = a.modified?.millisecondsSinceEpoch ?? 0;
        final bt = b.modified?.millisecondsSinceEpoch ?? 0;
        cmp = at.compareTo(bt);
      case SortField.size:
        final as = a.size ?? 0;
        final bs = b.size ?? 0;
        cmp = as.compareTo(bs);
    }
    return sortAsc ? cmp : -cmp;
  });
  return copy;
}

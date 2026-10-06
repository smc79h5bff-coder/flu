import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/persistent_notifier.dart';
import '../../../../core/storage/shared_preferences_provider.dart';
import 'reader_models.dart';

// ==================== 文件唯一标识 ====================
//
// 直接用路径当 key。路径变了就算换书，路径没变就认为还是同一本。

String readerFileKey(String filePath) {
  return filePath;
}

/// 全局高亮（应用到所有书）在存储里的特殊 key。
/// 存在 `reader.highlights.__global__` 下。
const String kGlobalHighlightsKey = '__global__';

/// 每本书高亮的存储 key 前缀。
/// 存储结构：`reader.highlights.<fileKey>` = 那本书的高亮列表 JSON。
const String _highlightsKeyPrefix = 'reader.highlights.';

// ==================== 全局阅读设置（所有文件共享） ====================

final readerSettingsProvider =
    NotifierProvider<ReaderSettingsNotifier, ReaderSettings>(
  ReaderSettingsNotifier.new,
);

class ReaderSettingsNotifier extends PersistentNotifier<ReaderSettings> {
  @override
  String get key => 'reader.settings.v2';

  @override
  ReaderSettings get defaultValue => ReaderSettings.initial;

  @override
  ReaderSettings decode(String raw) => ReaderSettings.tryDecode(raw);

  @override
  String encode(ReaderSettings value) => value.encode();

  // ---- 通用 ----

  void setFontSize(double v) =>
      update(state.copyWith(fontSize: v.clamp(4.0, 60.0)));

  void setFontWeight(int v) =>
      update(state.copyWith(fontWeight: v.clamp(100, 900)));

  void setBgColor(int v) => update(state.copyWith(bgColor: v));


  void setReaderMode(int v) =>
    update(state.copyWith(readerMode: v.clamp(0, 1)));

  
  void toggleButtons() =>
      update(state.copyWith(showButtons: !state.showButtons));

/// 分页底部安全边距。范围 -100 ~ +300 像素。
///
///   · 正数：底部预留，防裁切。
///   · 0（默认）：精确，屏幕利用率最高。
///   · 负数：底部"榨"空间，多显示内容，可能裁切。
void setPageBottomSafePx(int v) => update(state.copyWith(
      pageBottomSafePx: v.clamp(-100, 300),
    ));
  /// 是否避让底部系统导航栏。true = 空出导航栏高度。
void setRespectSystemInsets(bool v) =>
    update(state.copyWith(respectSystemInsets: v));
  // ---- 上一文件按钮 ----

  void setTopBtnStyle(int v) => update(state.copyWith(topBtnStyle: v));
  void setTopBtnBgColor(int v) => update(state.copyWith(topBtnBgColor: v));
  void setTopBtnFgColor(int v) => update(state.copyWith(topBtnFgColor: v));
  void setTopBtnRingColor(int v) =>
      update(state.copyWith(topBtnRingColor: v));
  void setTopBtnRingWidth(double v) =>
      update(state.copyWith(topBtnRingWidth: v.clamp(0.5, 20.0)));
  void setTopBtnOpacity(double v) =>
      update(state.copyWith(topBtnOpacity: v.clamp(0.05, 1.0)));
  void setTopBtnScale(double v) =>
      update(state.copyWith(topBtnScale: v.clamp(0.2, 10.0)));
  void setTopBtnX(double v) =>
      update(state.copyWith(topBtnX: v.clamp(0.0, 1.0)));
  void setTopBtnY(double v) =>
      update(state.copyWith(topBtnY: v.clamp(0.0, 1.0)));

  // ---- 下一文件按钮 ----

  void setBottomBtnStyle(int v) => update(state.copyWith(bottomBtnStyle: v));
  void setBottomBtnBgColor(int v) =>
      update(state.copyWith(bottomBtnBgColor: v));
  void setBottomBtnFgColor(int v) =>
      update(state.copyWith(bottomBtnFgColor: v));
  void setBottomBtnRingColor(int v) =>
      update(state.copyWith(bottomBtnRingColor: v));
  void setBottomBtnRingWidth(double v) =>
      update(state.copyWith(bottomBtnRingWidth: v.clamp(0.5, 20.0)));
  void setBottomBtnOpacity(double v) =>
      update(state.copyWith(bottomBtnOpacity: v.clamp(0.05, 1.0)));
  void setBottomBtnScale(double v) =>
      update(state.copyWith(bottomBtnScale: v.clamp(0.2, 10.0)));
  void setBottomBtnX(double v) =>
      update(state.copyWith(bottomBtnX: v.clamp(0.0, 1.0)));
  void setBottomBtnY(double v) =>
      update(state.copyWith(bottomBtnY: v.clamp(0.0, 1.0)));

  // ---- 删除文件按钮 ----

  void setDelBtnStyle(int v) => update(state.copyWith(delBtnStyle: v));
  void setDelBtnBgColor(int v) =>
      update(state.copyWith(delBtnBgColor: v));
  void setDelBtnFgColor(int v) =>
      update(state.copyWith(delBtnFgColor: v));
  void setDelBtnRingColor(int v) =>
      update(state.copyWith(delBtnRingColor: v));
  void setDelBtnRingWidth(double v) =>
      update(state.copyWith(delBtnRingWidth: v.clamp(0.5, 20.0)));
  void setDelBtnOpacity(double v) =>
      update(state.copyWith(delBtnOpacity: v.clamp(0.05, 1.0)));
  void setDelBtnScale(double v) =>
      update(state.copyWith(delBtnScale: v.clamp(0.2, 10.0)));
  void setDelBtnX(double v) =>
      update(state.copyWith(delBtnX: v.clamp(0.0, 1.0)));
  void setDelBtnY(double v) =>
      update(state.copyWith(delBtnY: v.clamp(0.0, 1.0)));

  // ---- 菜单热区 ----

  void setHotZoneVisible(bool v) =>
      update(state.copyWith(hotZoneVisible: v));
  void setHotZoneStyle(int v) => update(state.copyWith(hotZoneStyle: v));
  void setHotZoneColor(int v) => update(state.copyWith(hotZoneColor: v));
  void setHotZoneOpacity(double v) =>
      update(state.copyWith(hotZoneOpacity: v.clamp(0.0, 1.0)));
  void setHotZoneBorderWidth(double v) =>
      update(state.copyWith(hotZoneBorderWidth: v.clamp(0.5, 20.0)));
  void setHotZoneX(double v) =>
      update(state.copyWith(hotZoneX: v.clamp(0.0, 1.0)));
  void setHotZoneY(double v) =>
      update(state.copyWith(hotZoneY: v.clamp(0.0, 1.0)));
  void setHotZoneW(double v) =>
      update(state.copyWith(hotZoneW: v.clamp(0.02, 1.0)));
  void setHotZoneH(double v) =>
      update(state.copyWith(hotZoneH: v.clamp(0.02, 1.0)));
}

// ==================== 阅读进度（每个文件一条） ====================

final readerProgressProvider =
    NotifierProvider<ReaderProgressNotifier, Map<String, ReaderProgress>>(
  ReaderProgressNotifier.new,
);

class ReaderProgressNotifier
    extends PersistentNotifier<Map<String, ReaderProgress>> {
  @override
  String get key => 'reader.progress.v1';

  @override
  Map<String, ReaderProgress> get defaultValue => const {};

  @override
  Map<String, ReaderProgress> decode(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) =>
        MapEntry(k, ReaderProgress.fromJson(v as Map<String, dynamic>)));
  }

  @override
  String encode(Map<String, ReaderProgress> value) =>
      jsonEncode(value.map((k, v) => MapEntry(k, v.toJson())));

  ReaderProgress? get(String fileKey) => state[fileKey];

  void set(String fileKey, int charOffset) {
    final next = Map<String, ReaderProgress>.from(state);
    next[fileKey] = ReaderProgress(
      charOffset: charOffset,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    update(next);
  }

  void remove(String fileKey) {
    if (!state.containsKey(fileKey)) return;
    final next = Map<String, ReaderProgress>.from(state);
    next.remove(fileKey);
    update(next);
  }
}

// ==================== 书签（每个文件一组） ====================

final readerBookmarksProvider = NotifierProvider<ReaderBookmarksNotifier,
    Map<String, List<ReaderBookmark>>>(ReaderBookmarksNotifier.new);

class ReaderBookmarksNotifier
    extends PersistentNotifier<Map<String, List<ReaderBookmark>>> {
  @override
  String get key => 'reader.bookmarks.v1';

  @override
  Map<String, List<ReaderBookmark>> get defaultValue => const {};

  @override
  Map<String, List<ReaderBookmark>> decode(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(
          k,
          (v as List<dynamic>)
              .map((e) => ReaderBookmark.fromJson(e as Map<String, dynamic>))
              .toList(),
        ));
  }

  @override
  String encode(Map<String, List<ReaderBookmark>> value) => jsonEncode(
        value.map(
            (k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      );

  List<ReaderBookmark> getFor(String fileKey) => state[fileKey] ?? const [];

  void add(String fileKey, ReaderBookmark bookmark) {
    final next = Map<String, List<ReaderBookmark>>.from(state);
    final list = List<ReaderBookmark>.from(next[fileKey] ?? const []);
    list.add(bookmark);
    list.sort((a, b) => a.charOffset.compareTo(b.charOffset));
    next[fileKey] = list;
    update(next);
  }

  void remove(String fileKey, String bookmarkId) {
    final current = state[fileKey];
    if (current == null) return;
    final next = Map<String, List<ReaderBookmark>>.from(state);
    final list = current.where((b) => b.id != bookmarkId).toList();
    if (list.isEmpty) {
      next.remove(fileKey);
    } else {
      next[fileKey] = list;
    }
    update(next);
  }

  void removeMany(String fileKey, Set<String> bookmarkIds) {
    final current = state[fileKey];
    if (current == null) return;
    final next = Map<String, List<ReaderBookmark>>.from(state);
    final list =
        current.where((b) => !bookmarkIds.contains(b.id)).toList();
    if (list.isEmpty) {
      next.remove(fileKey);
    } else {
      next[fileKey] = list;
    }
    update(next);
  }

  void updateOne(String fileKey, ReaderBookmark bookmark) {
    final current = state[fileKey];
    if (current == null) return;
    final next = Map<String, List<ReaderBookmark>>.from(state);
    next[fileKey] = [
      for (final b in current)
        if (b.id == bookmark.id) bookmark else b,
    ];
    update(next);
  }
}

// ==================== 高亮（按书拆 key 存储） ====================
//
// 存储结构：
//   reader.highlights.<fileKey>  = 那本书的高亮列表
//   reader.highlights.__global__ = 全局高亮（应用到所有书）
//
// 内存行为：
//   · 打开 App 时只加载全局高亮（见 readerGlobalHighlightsProvider）
//   · 打开某本书时，调 ensureLoaded(fileKey) 按需读那本书的高亮
//   · 改哪本书就只写哪个 key
//
// 本 provider 的 state 是"已经加载过的书"的缓存。从没打开过的书不在里面。
// 调用方在读取前应先 ensureLoaded(fileKey)。

final readerHighlightsProvider = NotifierProvider<ReaderHighlightsNotifier,
    Map<String, List<HighlightEntry>>>(ReaderHighlightsNotifier.new);

class ReaderHighlightsNotifier
    extends Notifier<Map<String, List<HighlightEntry>>> {
  @override
  Map<String, List<HighlightEntry>> build() => const {};

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  String _prefsKeyFor(String fileKey) => '$_highlightsKeyPrefix$fileKey';

  /// 确保某本书的高亮已加载到内存。幂等。
  ///
  /// 注意：如果 state 里已有这个 fileKey（哪怕值是空列表），认为是已加载，
  /// 不再重新读盘。这样才能区分"从未加载"和"加载了但是空的"。
  void ensureLoaded(String fileKey) {
    if (state.containsKey(fileKey)) return;
    final raw = _prefs.getString(_prefsKeyFor(fileKey));
    if (raw == null || raw.isEmpty) {
      state = {...state, fileKey: const <HighlightEntry>[]};
      return;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final entries = list
          .map((e) => HighlightEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      state = {...state, fileKey: entries};
    } catch (_) {
      state = {...state, fileKey: const <HighlightEntry>[]};
    }
  }

  /// 一次性加载所有书的高亮。管理页"全部书籍"模式下调用。
  /// 一次性代价比较大，之后都命中内存。
  void loadAll() {
    final next = Map<String, List<HighlightEntry>>.from(state);
    var changed = false;
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith(_highlightsKeyPrefix)) continue;
      final fileKey = key.substring(_highlightsKeyPrefix.length);
      if (fileKey == kGlobalHighlightsKey) continue;
      if (next.containsKey(fileKey)) continue;
      final raw = _prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        next[fileKey] = list
            .map((e) => HighlightEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        changed = true;
      } catch (_) {}
    }
    if (changed) state = next;
  }

  List<HighlightEntry> getFor(String fileKey) =>
      state[fileKey] ?? const [];

  Future<void> _persistOne(
    String fileKey,
    List<HighlightEntry> value,
  ) async {
    final next = Map<String, List<HighlightEntry>>.from(state);
    next[fileKey] = value;
    state = next;
    await _prefs.setString(
      _prefsKeyFor(fileKey),
      jsonEncode(value.map((e) => e.toJson()).toList()),
    );
  }

  /// 加一条高亮。如果同一关键词（且同为正则/非正则）已经有高亮，
  /// 替换它的样式（避免重复条目）。
  void addOrReplace(String fileKey, HighlightEntry entry) {
    final list = List<HighlightEntry>.from(state[fileKey] ?? const []);
    list.removeWhere(
      (e) => e.keyword == entry.keyword && e.isRegex == entry.isRegex,
    );
    list.add(entry);
    unawaited(_persistOne(fileKey, list));
  }

  void remove(String fileKey, String highlightId) {
    final current = state[fileKey];
    if (current == null) return;
    final list = current.where((h) => h.id != highlightId).toList();
    unawaited(_persistOne(fileKey, list));
  }

  void removeMany(String fileKey, Set<String> ids) {
    final current = state[fileKey];
    if (current == null) return;
    final list = current.where((h) => !ids.contains(h.id)).toList();
    unawaited(_persistOne(fileKey, list));
  }

  void updateOne(String fileKey, HighlightEntry entry) {
    final current = state[fileKey];
    if (current == null) return;
    final list = [
      for (final h in current)
        if (h.id == entry.id) entry else h,
    ];
    unawaited(_persistOne(fileKey, list));
  }

  /// 批量改分组（把 ids 里的高亮都改成 groupId）。groupId 为 null = 未分组。
  void setGroupMany(String fileKey, Set<String> ids, String? groupId) {
    final current = state[fileKey];
    if (current == null) return;
    final list = [
      for (final h in current)
        if (ids.contains(h.id))
          h.copyWith(groupId: groupId, clearGroup: groupId == null)
        else
          h,
    ];
    unawaited(_persistOne(fileKey, list));
  }

  /// 清空某文件的所有高亮
  void clearFile(String fileKey) {
    if (!state.containsKey(fileKey)) return;
    unawaited(_persistOne(fileKey, const []));
  }
}

// ==================== 全局高亮（应用到所有书） ====================
//
// 独立存储：`reader.highlights.__global__`。
// 打开 App 时就加载（因为每本书都要用它）。
// 只在"新建/编辑高亮"弹窗里创建，阅读器点色块加的高亮不会进这里。

final readerGlobalHighlightsProvider = NotifierProvider<
    ReaderGlobalHighlightsNotifier, List<HighlightEntry>>(
  ReaderGlobalHighlightsNotifier.new,
);

class ReaderGlobalHighlightsNotifier extends Notifier<List<HighlightEntry>> {
  @override
  List<HighlightEntry> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final raw = prefs.getString(
      '$_highlightsKeyPrefix$kGlobalHighlightsKey',
    );
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => HighlightEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void _persist(List<HighlightEntry> value) {
    state = value;
    final prefs = ref.read(sharedPreferencesProvider);
    unawaited(prefs.setString(
      '$_highlightsKeyPrefix$kGlobalHighlightsKey',
      jsonEncode(value.map((e) => e.toJson()).toList()),
    ));
  }

  void addOrReplace(HighlightEntry entry) {
    final list = List<HighlightEntry>.from(state);
    list.removeWhere(
      (e) => e.keyword == entry.keyword && e.isRegex == entry.isRegex,
    );
    list.add(entry);
    _persist(list);
  }

  void remove(String id) {
    _persist(state.where((e) => e.id != id).toList());
  }

  void removeMany(Set<String> ids) {
    _persist(state.where((e) => !ids.contains(e.id)).toList());
  }

  void updateOne(HighlightEntry entry) {
    _persist([
      for (final h in state)
        if (h.id == entry.id) entry else h,
    ]);
  }

  void setGroupMany(Set<String> ids, String? groupId) {
    _persist([
      for (final h in state)
        if (ids.contains(h.id))
          h.copyWith(groupId: groupId, clearGroup: groupId == null)
        else
          h,
    ]);
  }
}

// ==================== 高亮分组（全局共享） ====================
//
// 所有书共用一套分组。

final readerHighlightGroupsProvider =
    NotifierProvider<ReaderHighlightGroupsNotifier, List<HighlightGroup>>(
  ReaderHighlightGroupsNotifier.new,
);

class ReaderHighlightGroupsNotifier
    extends PersistentNotifier<List<HighlightGroup>> {
  @override
  String get key => 'reader.highlightGroups.v1';

  @override
  List<HighlightGroup> get defaultValue => const [];

  @override
  List<HighlightGroup> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => HighlightGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  String encode(List<HighlightGroup> value) =>
      jsonEncode(value.map((e) => e.toJson()).toList());

  HighlightGroup? byId(String? id) {
    if (id == null) return null;
    for (final g in state) {
      if (g.id == id) return g;
    }
    return null;
  }

  String nameOf(String? id) {
    if (id == null) return '未分组';
    return byId(id)?.name ?? '未分组';
  }

  /// 新建一个分组，返回它的 id。
  String create(String name) {
    final trimmed = name.trim();
    final id = 'g_${DateTime.now().microsecondsSinceEpoch}';
    final next = [
      ...state,
      HighlightGroup(
        id: id,
        name: trimmed.isEmpty ? '新分组' : trimmed,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
    update(next);
    return id;
  }

  void rename(String id, String newName) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    update([
      for (final g in state)
        if (g.id == id) g.copyWith(name: trimmed) else g,
    ]);
  }

  /// 删除分组。onDelete 由调用方决定怎么处理该分组下的高亮。
  void delete(String id) {
    update(state.where((g) => g.id != id).toList());
  }

  void reorder(int oldIndex, int newIndex) {
    final list = List<HighlightGroup>.from(state);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex < 0) newIndex = 0;
    if (newIndex > list.length - 1) newIndex = list.length - 1;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    update(list);
  }
}

// ==================== 色块配置（20 个，全局共享） ====================

final readerPaletteProvider =
    NotifierProvider<ReaderPaletteNotifier, List<HighlightPalette>>(
  ReaderPaletteNotifier.new,
);

class ReaderPaletteNotifier
    extends PersistentNotifier<List<HighlightPalette>> {
  @override
  String get key => 'reader.palette.v1';

  @override
  List<HighlightPalette> get defaultValue => HighlightPalette.defaults();

  @override
  List<HighlightPalette> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    final parsed = list
        .map((e) => HighlightPalette.fromJson(e as Map<String, dynamic>))
        .toList();
    // 保证 20 个槽位齐全（老数据可能少）
    final byIndex = {for (final p in parsed) p.index: p};
    final defaults = HighlightPalette.defaults();
    return [
      for (var i = 0; i < 20; i++) byIndex[i] ?? defaults[i],
    ];
  }

  @override
  String encode(List<HighlightPalette> value) =>
      jsonEncode(value.map((e) => e.toJson()).toList());

  HighlightPalette byIndex(int index) {
    for (final p in state) {
      if (p.index == index) return p;
    }
    return HighlightPalette.defaults()[index];
  }

  void updateOne(HighlightPalette palette) {
    update([
      for (final p in state)
        if (p.index == palette.index) palette else p,
    ]);
  }

  void resetToDefaults() => update(HighlightPalette.defaults());
}

// ========================
// ==================== 阅读器删除路径暂存（不持久化） ====================

/// 阅读器里删掉的文件的路径列表。
///
/// 阅读器删文件时往里塞；文件浏览器在返回时读取，处理完清空。
/// 只存内存，App 重启后自动重置为 []。
///
/// 用 [StateProvider] 而不是持久化，是因为这只是跨页面传递的临时数据，
/// 没必要写盘；就算写盘了反而会因为"崩溃残留"误删正确文件。
final readerDeletedPathsProvider =
    StateProvider<List<String>>((ref) => const <String>[]);
final readerFindHistoryProvider = NotifierProvider<ReaderFindHistoryNotifier,
    List<FindHistoryItem>>(ReaderFindHistoryNotifier.new);

class ReaderFindHistoryNotifier
    extends PersistentNotifier<List<FindHistoryItem>> {
  @override
  String get key => 'reader.findHistory.v1';

  @override
  List<FindHistoryItem> get defaultValue => const [];

  @override
  List<FindHistoryItem> decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => FindHistoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  String encode(List<FindHistoryItem> value) =>
      jsonEncode(value.map((e) => e.toJson()).toList());

  /// 最多保留 100 条；收藏项不占普通名额
  static const int _maxNonFav = 100;

  void add(String word) {
    final w = word.trim();
    if (w.isEmpty) return;
    final next = <FindHistoryItem>[
      FindHistoryItem(
        word: w,
        isFavorite: false,
        usedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      ...state.where((e) => e.word != w),
    ];
    final existingFav = state.any((e) => e.word == w && e.isFavorite);
    if (existingFav) {
      for (var i = 0; i < next.length; i++) {
        if (next[i].word == w) {
          next[i] = next[i].copyWith(isFavorite: true);
          break;
        }
      }
    }
    final favs = next.where((e) => e.isFavorite).toList();
    final nonFavs = next.where((e) => !e.isFavorite).toList();
    final kept = <FindHistoryItem>[
      ...favs,
      ...nonFavs.take(_maxNonFav),
    ];
    update(kept);
  }

  void toggleFavorite(String word) {
    update([
      for (final e in state)
        if (e.word == word) e.copyWith(isFavorite: !e.isFavorite) else e,
    ]);
  }

  void remove(String word) {
    update(state.where((e) => e.word != word).toList());
  }

  void clearNonFavorites() {
    update(state.where((e) => e.isFavorite).toList());
  }

  List<FindHistoryItem> sorted() {
    final copy = List<FindHistoryItem>.from(state);
    copy.sort((a, b) {
      if (a.isFavorite != b.isFavorite) {
        return a.isFavorite ? -1 : 1;
      }
      return b.usedAt.compareTo(a.usedAt);
    });
    return copy;
  }
}

/// 设置面板打开时临时为 true。控制顶部热区的可视化预览。
final readerHotZonePreviewProvider = StateProvider<bool>((ref) => false);
/// 当前阅读页的纯文本。给设置面板里的按钮位置预览用。
final readerPagePreviewProvider = StateProvider<String>((ref) => '');

// ==================== 高亮管理页显示设置（持久化） ====================
//
// 全部书籍模式 / 本书模式共用同一套设置。

class HighlightViewSettings {
  const HighlightViewSettings({
    this.showBookName = false,
  });

  /// 卡片底部是否显示书名。
  final bool showBookName;

  HighlightViewSettings copyWith({
    bool? showBookName,
  }) =>
      HighlightViewSettings(
        showBookName: showBookName ?? this.showBookName,
      );

  Map<String, dynamic> toJson() => {
        'showBookName': showBookName,
      };

  factory HighlightViewSettings.fromJson(Map<String, dynamic> j) =>
      HighlightViewSettings(
        showBookName: j['showBookName'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());

  static HighlightViewSettings tryDecode(String? s) {
    if (s == null || s.isEmpty) return const HighlightViewSettings();
    try {
      return HighlightViewSettings.fromJson(
          jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const HighlightViewSettings();
    }
  }
}

final highlightViewSettingsProvider = NotifierProvider<
    HighlightViewSettingsNotifier, HighlightViewSettings>(
  HighlightViewSettingsNotifier.new,
);

class HighlightViewSettingsNotifier
    extends PersistentNotifier<HighlightViewSettings> {
  @override
  String get key => 'reader.highlightView.v1';

  @override
  HighlightViewSettings get defaultValue => const HighlightViewSettings();

  @override
  HighlightViewSettings decode(String raw) =>
      HighlightViewSettings.tryDecode(raw);

  @override
  String encode(HighlightViewSettings value) => value.encode();

  void setShowBookName(bool v) =>
      update(state.copyWith(showBookName: v));
}

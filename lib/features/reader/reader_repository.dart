import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/persistent_notifier.dart';
import 'reader_models.dart';

// ==================== 文件唯一标识 ====================
//
// 直接用路径当 key。路径变了就算换书，路径没变就认为还是同一本。

String readerFileKey(String filePath) {
  return filePath;
}

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

/// 分页底部安全边距。范围 -20 ~ +30 像素。
///
///   · 正数：底部预留，防裁切。
///   · 0（默认）：精确，屏幕利用率最高。
///   · 负数：底部"榨"空间，多显示内容，可能裁切。
void setPageBottomSafePx(int v) => update(state.copyWith(
      pageBottomSafePx: v.clamp(-20, 30),
    ));
  
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

// ==================== 高亮（每个文件一组） ====================

final readerHighlightsProvider = NotifierProvider<ReaderHighlightsNotifier,
    Map<String, List<HighlightEntry>>>(ReaderHighlightsNotifier.new);

class ReaderHighlightsNotifier
    extends PersistentNotifier<Map<String, List<HighlightEntry>>> {
  @override
  String get key => 'reader.highlights.v1';

  @override
  Map<String, List<HighlightEntry>> get defaultValue => const {};

  @override
  Map<String, List<HighlightEntry>> decode(String raw) {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(
          k,
          (v as List<dynamic>)
              .map((e) =>
                  HighlightEntry.fromJson(e as Map<String, dynamic>))
              .toList(),
        ));
  }

  @override
  String encode(Map<String, List<HighlightEntry>> value) => jsonEncode(
        value.map(
            (k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      );

  List<HighlightEntry> getFor(String fileKey) =>
      state[fileKey] ?? const [];

  /// 加一条高亮。如果同一关键词已经有高亮，替换它的样式（避免重复条目）。
  void addOrReplace(String fileKey, HighlightEntry entry) {
    final next = Map<String, List<HighlightEntry>>.from(state);
    final list =
        List<HighlightEntry>.from(next[fileKey] ?? const []);
    list.removeWhere((e) => e.keyword == entry.keyword && !e.isRegex);
    list.add(entry);
    next[fileKey] = list;
    update(next);
  }

  void remove(String fileKey, String highlightId) {
    final current = state[fileKey];
    if (current == null) return;
    final next = Map<String, List<HighlightEntry>>.from(state);
    final list = current.where((h) => h.id != highlightId).toList();
    if (list.isEmpty) {
      next.remove(fileKey);
    } else {
      next[fileKey] = list;
    }
    update(next);
  }

  void removeMany(String fileKey, Set<String> ids) {
    final current = state[fileKey];
    if (current == null) return;
    final next = Map<String, List<HighlightEntry>>.from(state);
    final list = current.where((h) => !ids.contains(h.id)).toList();
    if (list.isEmpty) {
      next.remove(fileKey);
    } else {
      next[fileKey] = list;
    }
    update(next);
  }

  void updateOne(String fileKey, HighlightEntry entry) {
    final current = state[fileKey];
    if (current == null) return;
    final next = Map<String, List<HighlightEntry>>.from(state);
    next[fileKey] = [
      for (final h in current)
        if (h.id == entry.id) entry else h,
    ];
    update(next);
  }

  /// 批量改分组（把 ids 里的高亮都改成 groupId）。groupId 为 null = 未分组。
  void setGroupMany(String fileKey, Set<String> ids, String? groupId) {
    final current = state[fileKey];
    if (current == null) return;
    final next = Map<String, List<HighlightEntry>>.from(state);
    next[fileKey] = [
      for (final h in current)
        if (ids.contains(h.id))
          h.copyWith(groupId: groupId, clearGroup: groupId == null)
        else
          h,
    ];
    update(next);
  }

  /// 清空某文件的所有高亮
  void clearFile(String fileKey) {
    if (!state.containsKey(fileKey)) return;
    final next = Map<String, List<HighlightEntry>>.from(state);
    next.remove(fileKey);
    update(next);
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

// ==================== 查找历史（全局共享） ====================

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

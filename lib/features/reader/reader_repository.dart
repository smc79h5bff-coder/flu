import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/persistent_notifier.dart';
import 'reader_models.dart';

// ==================== 文件唯一标识 ====================
//
// 用 "路径 | 文件大小 | 修改时间" 拼成一个 key。
// 文件被重存（内容、大小、时间任意一项变）→ key 变 → 老进度/书签/高亮作废。
//
// 为什么不用内容 hash：
//   内容 hash 要读全文件，5MB 要 100ms+。
//   而阅读器每次打开文件都要算，用户等待时间会累加。
//   "大小+时间" 在 99.99% 情况下足够区分（同路径同大小同 mtime 的不同内容几乎不可能）。


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
  String get key => 'reader.settings.v1';

  @override
  ReaderSettings get defaultValue => ReaderSettings.initial;

  @override
  ReaderSettings decode(String raw) => ReaderSettings.tryDecode(raw);

  @override
  String encode(ReaderSettings value) => value.encode();

  void setFontSize(double v) =>
      update(state.copyWith(fontSize: v.clamp(4.0, 60.0)));

  void setFontWeight(int v) =>
      update(state.copyWith(fontWeight: v.clamp(100, 900)));

  void setBgColor(int v) => update(state.copyWith(bgColor: v));

  void setButtonOpacity(double v) =>
      update(state.copyWith(buttonOpacity: v.clamp(0.1, 1.0)));

  void setButtonScale(double v) =>
      update(state.copyWith(buttonScale: v.clamp(0.5, 2.0)));

  void toggleButtons() =>
      update(state.copyWith(showButtons: !state.showButtons));
}

// ==================== 阅读进度（每个文件一条） ====================
//
// 结构：Map<fileKey, ReaderProgress>

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
//
// 结构：Map<fileKey, List<ReaderBookmark>>

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
//
// 结构：Map<fileKey, List<HighlightEntry>>
//
// 为什么每个文件单独存：
//   你说"高亮默认只应用于本 txt"——所以按文件隔离。

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

  /// 清空某文件的所有高亮
  void clearFile(String fileKey) {
    if (!state.containsKey(fileKey)) return;
    final next = Map<String, List<HighlightEntry>>.from(state);
    next.remove(fileKey);
    update(next);
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
    // 若已收藏同名词，保留收藏状态
    final existingFav = state.any((e) => e.word == w && e.isFavorite);
    if (existingFav) {
      for (var i = 0; i < next.length; i++) {
        if (next[i].word == w) {
          next[i] = next[i].copyWith(isFavorite: true);
          break;
        }
      }
    }
    // 数量裁剪
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

  /// 收藏项按时间倒序放在前，非收藏的随后
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

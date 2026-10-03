import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';

/// 文件浏览器排序字段。
enum SortField { name, modified, size }

/// 搜索范围。
enum SearchScope { currentRecursive, custom }

/// 点击文本文件时的打开方式。
enum FileOpenMode {
  /// 阅读器：分页翻页，看小说用。
  reader,

  /// 旧编辑器：单个大 TextField，功能全，大文件卡。
  editor,

  /// 行编辑器：ListView.builder 虚拟化，大文件流畅。
  lineEditor,

  /// 每次弹窗问一次。
  ask,
}

final fileOpenModeProvider =
    NotifierProvider<FileOpenModeNotifier, FileOpenMode>(
  FileOpenModeNotifier.new,
);

class FileOpenModeNotifier extends EnumPrefNotifier<FileOpenMode> {
  FileOpenModeNotifier()
      : super(
          key: PrefKeys.fileOpenMode,
          values: FileOpenMode.values,
          initial: FileOpenMode.reader,
        );
}

/// 排序方式（持久化）。
final sortFieldProvider =
    NotifierProvider<SortFieldNotifier, SortField>(SortFieldNotifier.new);

class SortFieldNotifier extends EnumPrefNotifier<SortField> {
  SortFieldNotifier()
      : super(
          key: PrefKeys.sortField,
          values: SortField.values,
          initial: SortField.name,
        );
}

/// 排序方向（持久化）。
final sortAscProvider =
    NotifierProvider<SortAscNotifier, bool>(SortAscNotifier.new);

class SortAscNotifier extends BoolPrefNotifier {
  SortAscNotifier() : super(key: PrefKeys.sortAsc, initial: true);
}

/// 收藏夹目录（持久化）。
final favoritesProvider =
    NotifierProvider<FavoritesNotifier, List<String>>(FavoritesNotifier.new);

class FavoritesNotifier extends StringListPrefNotifier {
  FavoritesNotifier() : super(key: PrefKeys.favorites);

  bool contains(String path) => state.contains(path);

  void toggle(String path) {
    if (state.contains(path)) {
      update(state.where((p) => p != path).toList());
    } else {
      update([...state, path]);
    }
  }

  void remove(String path) {
    update(state.where((p) => p != path).toList());
  }
}


/// 最近移动/复制到的目录（持久化）。
final recentMoveTargetsProvider =
    NotifierProvider<RecentMoveTargetsNotifier, List<String>>(
  RecentMoveTargetsNotifier.new,
);

class RecentMoveTargetsNotifier extends StringListPrefNotifier {
  RecentMoveTargetsNotifier() : super(key: PrefKeys.recentMoveTargets);

  static const int _max = 10;

  void add(String path) {
    if (path.isEmpty) return;
    final next = <String>[path, ...state.where((s) => s != path)];
    if (next.length > _max) next.removeRange(_max, next.length);
    update(next);
  }

  void remove(String path) {
    update(state.where((s) => s != path).toList());
  }
}

/// 自定义搜索文件夹（持久化）。
final customSearchFoldersProvider =
    NotifierProvider<CustomSearchFoldersNotifier, List<String>>(
  CustomSearchFoldersNotifier.new,
);

class CustomSearchFoldersNotifier extends StringListPrefNotifier {
  CustomSearchFoldersNotifier() : super(key: PrefKeys.customSearchFolders);

  void setAll(List<String> folders) => update(List<String>.from(folders));
}

/// 上次浏览的路径（持久化）。
final lastPathProvider =
    NotifierProvider<LastPathNotifier, String>(LastPathNotifier.new);

class LastPathNotifier extends StringPrefNotifier {
  LastPathNotifier() : super(key: PrefKeys.lastPath);
}

/// 搜索范围（持久化）。
final searchScopeProvider =
    NotifierProvider<SearchScopeNotifier, SearchScope>(
  SearchScopeNotifier.new,
);

class SearchScopeNotifier extends EnumPrefNotifier<SearchScope> {
  SearchScopeNotifier()
      : super(
          key: PrefKeys.searchScope,
          values: SearchScope.values,
          initial: SearchScope.currentRecursive,
        );
}

// ==================== 搜索历史（持久化） ====================

/// 上限 30 条，去重（最新在前）。
final browserSearchHistoryProvider =
    NotifierProvider<BrowserSearchHistoryNotifier, List<String>>(
  BrowserSearchHistoryNotifier.new,
);

class BrowserSearchHistoryNotifier extends StringListPrefNotifier {
  BrowserSearchHistoryNotifier()
      : super(key: PrefKeys.browserSearchHistory);

  static const int _max = 30;

  void add(String q) {
    if (q.trim().isEmpty) return;
    final next = <String>[q, ...state.where((s) => s != q)];
    if (next.length > _max) next.removeRange(_max, next.length);
    update(next);
  }

  void remove(String q) {
    update(state.where((s) => s != q).toList());
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import '../../../../core/storage/persistent_notifier.dart';

/// 文件浏览器排序字段。
enum SortField { name, modified, size }

/// 搜索范围。
enum SearchScope { currentRecursive, custom }

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

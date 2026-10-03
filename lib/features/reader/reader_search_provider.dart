import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一条搜索结果（一行内的一个匹配）。
class ReaderSearchHit {
  const ReaderSearchHit({
    required this.globalStart,
    required this.globalEnd,
    required this.lineIndex,
    required this.startInLine,
    required this.endInLine,
    required this.pre,
    required this.preEllipsis,
    required this.match,
    required this.post,
    required this.postEllipsis,
  });

  final int globalStart;
  final int globalEnd;
  final int lineIndex;
  final int startInLine;
  final int endInLine;

  /// 显示用的前文（可能含从上一行借来的内容）。
  final String pre;
  /// 前文前面是否加省略号。
  final bool preEllipsis;
  /// 匹配词本身。
  final String match;
  /// 显示用的后文（可能含从下一行借来的内容）。
  final String post;
  /// 后文末尾是否加省略号。
  final bool postEllipsis;
}

/// 搜索页 + 半开条共享的状态。
class ReaderSearchState {
  const ReaderSearchState({
    this.fileKey = '',
    this.query = '',
    this.regex = false,
    this.caseSensitive = false,
    this.hits = const <ReaderSearchHit>[],
    this.currentPos = -1,
  });

  final String fileKey;
  final String query;
  final bool regex;
  final bool caseSensitive;
  final List<ReaderSearchHit> hits;
  final int currentPos;

  bool get hasSearch => query.isNotEmpty && hits.isNotEmpty;
}

final readerSearchProvider =
    NotifierProvider<ReaderSearchNotifier, ReaderSearchState>(
  ReaderSearchNotifier.new,
);

class ReaderSearchNotifier extends Notifier<ReaderSearchState> {
  @override
  ReaderSearchState build() => const ReaderSearchState();

  void setResult({
    required String fileKey,
    required String query,
    required bool regex,
    required bool caseSensitive,
    required List<ReaderSearchHit> hits,
    required int currentPos,
  }) {
    state = ReaderSearchState(
      fileKey: fileKey,
      query: query,
      regex: regex,
      caseSensitive: caseSensitive,
      hits: hits,
      currentPos: currentPos,
    );
  }

  void setCurrentPos(int pos) {
    state = ReaderSearchState(
      fileKey: state.fileKey,
      query: state.query,
      regex: state.regex,
      caseSensitive: state.caseSensitive,
      hits: state.hits,
      currentPos: pos,
    );
  }

  void clear() {
    state = const ReaderSearchState();
  }
}

import 'package:flutter/material.dart';

/// 在大文件、可变行高的惰性列表里，估算并跳转到某个 entry。
///
/// 旧版会利用 [rowKeysByEntry] 找"已经构建的行"来测实际像素/行比例，
/// 精确但代价是每行一个 GlobalKey——5 万行滚动时疯狂注册/注销，太贵。
///
/// 现在只按"目标行 / 总行数"的比例估算偏移，一次 jumpTo 到位。
/// 因为行高不均，落点会有偏差（几十行以内），用户滑一下就能看到目标。
/// 换来的是滚动路径上零 GlobalKey 开销。
class DiffScrollHelper {
  DiffScrollHelper({
    required this.scrollController,
    required this.totalRows,
    required this.entryToRow,
  });

  final ScrollController scrollController;
  final int Function() totalRows;
  final int Function(int entryIndex) entryToRow;

  Future<void> scrollToEntry(int entryIndex) async {
    final rows = totalRows();
    final targetRow = entryToRow(entryIndex);
    if (rows <= 0 || targetRow < 0) return;
    if (!scrollController.hasClients) return;

    final pos = scrollController.position;
    final maxExtent = pos.maxScrollExtent;
    if (maxExtent <= 0) return;

    final offset = (maxExtent * targetRow / rows).clamp(0.0, maxExtent);
    if ((pos.pixels - offset).abs() < 1) return;

    // 距离远用瞬移（避免长动画期间继续触发 rebuild），距离近用动画。
    final viewport = pos.viewportDimension;
    if ((pos.pixels - offset).abs() > viewport * 3) {
      pos.jumpTo(offset);
    } else {
      await scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }
}

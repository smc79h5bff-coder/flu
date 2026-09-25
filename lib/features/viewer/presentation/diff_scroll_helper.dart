import 'package:flutter/material.dart';

/// 大文件里的跳转工具。
///
/// - [jumpToEntry]：纯比例估算，瞬时无动画。给"上一处/下一处差异"用，
///   落点允许有偏差，用户滑一下就能看到目标。
/// - [jumpToEntryPrecise]：切视图专用。先粗跳，再用调用方提供的
///   [anchorKey]（视图挂在目标 entry 那一行上的临时 GlobalKey）做
///   精确对齐。收敛后由调用方撤销 key。
class DiffScrollHelper {
  DiffScrollHelper({
    required this.scrollController,
    required this.totalRows,
    required this.entryToRow,
    this.maxPreciseAttempts = 10,
  });

  final ScrollController scrollController;
  final int Function() totalRows;
  final int Function(int entryIndex) entryToRow;
  final int maxPreciseAttempts;

  /// 纯比例估算跳转，无动画。用于"上一处/下一处差异"。
  void jumpToEntry(int entryIndex) {
    final rows = totalRows();
    final targetRow = entryToRow(entryIndex);
    if (rows <= 0 || targetRow < 0) return;
    if (!scrollController.hasClients) return;
    final pos = scrollController.position;
    final maxExtent = pos.maxScrollExtent;
    if (maxExtent <= 0) return;
    final offset = (maxExtent * targetRow / rows).clamp(0.0, maxExtent);
    if ((pos.pixels - offset).abs() < 0.5) return;
    pos.jumpTo(offset);
  }

  /// 精准跳转：切视图时用。
  ///
  /// [anchorKey] 每次调用都从调用方拿最新值（因为调用方可能在迭代过程中
  /// 重建 key）。返回 null 或 currentContext 为 null 就继续迭代。
  ///
  /// 迭代流程：
  ///   1. 用比例估算跳到大致位置
  ///   2. 等一帧，让目标附近的行被 ListView 构建出来
  ///   3. 检查 anchorKey 是否已经有 context：
  ///        - 有 → ensureVisible 精确对齐到顶部（alignment 0.0）
  ///        - 没有 → 再粗跳一次（幂等），重复
  ///   4. 迭代到上限还没收敛就放弃，停在估算位置
  Future<void> jumpToEntryPrecise(
    int entryIndex, {
    required GlobalKey? Function() anchorKey,
  }) async {
    if (!scrollController.hasClients) return;
    final rows = totalRows();
    final targetRow = entryToRow(entryIndex);
    if (rows <= 0 || targetRow < 0) return;

    final pos = scrollController.position;
    final maxExtent = pos.maxScrollExtent;
    if (maxExtent <= 0) return;

    // 粗跳一次
    final roughOffset =
        (maxExtent * targetRow / rows).clamp(0.0, maxExtent);
    pos.jumpTo(roughOffset);

    for (var attempt = 0; attempt < maxPreciseAttempts; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!scrollController.hasClients) return;

      final ctx = anchorKey()?.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: Duration.zero,
          alignment: 0.0,
        );
        return;
      }

      // 目标还没被构建。每次迭代做一点微调，避免卡在同一个位置：
      // 第 1 次原位置，第 2 次向上找一屏，第 3 次向下找一屏……
      final viewport = scrollController.position.viewportDimension;
      final sign = attempt.isEven ? 1.0 : -1.0;
      final nudge = (attempt / 2).ceil() * viewport * 0.5 * sign;
      final next =
          (roughOffset + nudge).clamp(0.0, maxExtent);
      if ((scrollController.position.pixels - next).abs() < 0.5) {
        // 位置没动，跳不动了，放弃。
        return;
      }
      scrollController.position.jumpTo(next);
    }
    // 到达尝试上限，停在当前位置。
  }

  /// 无动画瞬时滚到文件最顶部。
  void jumpToTop() {
    if (!scrollController.hasClients) return;
    final pos = scrollController.position;
    if (pos.pixels == 0) return;
    pos.jumpTo(0);
  }
}

import 'package:flutter/material.dart';

/// 在大文件、可变行高的惰性列表里，精确定位到某个 entry。
///
/// 为什么需要它：
///   ListView.builder 只为屏幕上可见的行创建 widget。
///   从第 100 行跳到第 48000 行时，第 48000 行还没被渲染，
///   只能靠估算偏移量。但行高不均（有的行会折行），估算会偏很远。
///
/// 本类的做法：
///   1. 先估算并跳过去；
///   2. 等一帧让 Flutter 渲染新屏幕；
///   3. 检查目标 entry 是否已经被构建——是就用 ensureVisible 精确落位；
///   4. 不是就测一测"当前已构建的那些 entry 实际在哪个像素"，
///      用实测的「像素/行」比例修正估算，再跳一次；
///   5. 重复，最多 maxAttempts 次。
///
/// 距离越远，多迭代几次会自动收敛，比"固定步长 0.7 屏"快很多。
class DiffScrollHelper {
  DiffScrollHelper({
    required this.scrollController,
    required this.rowKeysByEntry,
    required this.totalRows,
    required this.entryToRow,
    this.maxAttempts = 40,
    this.frameDelay = const Duration(milliseconds: 30),
  });

  final ScrollController scrollController;
  final Map<int, GlobalKey> rowKeysByEntry;
  final int Function() totalRows;
  final int Function(int entryIndex) entryToRow;
  final int maxAttempts;
  final Duration frameDelay;

  Future<void> scrollToEntry(int entryIndex) async {
    // 快速路径：目标已经构建过了，直接 ensureVisible。
    if (_tryEnsureVisible(entryIndex)) return;

    final rows = totalRows();
    final targetRow = entryToRow(entryIndex);
    if (rows <= 0 || targetRow < 0) return;
    if (!scrollController.hasClients) return;

    final initialMax = scrollController.position.maxScrollExtent;
    if (initialMax <= 0) return;

    double offset =
        (initialMax * targetRow / rows).clamp(0.0, initialMax);

    for (var i = 0; i < maxAttempts; i++) {
      scrollController.jumpTo(offset);
      await Future<void>.delayed(frameDelay);
      if (!scrollController.hasClients) return;

      // 目标这次被构建出来了吗？
      if (_tryEnsureVisible(entryIndex)) return;

      // 还没。测一下实测的像素/行比例，修正估算。
      final measured = _measurePxPerRow(targetRow);
      final maxExtent = scrollController.position.maxScrollExtent;

      if (measured != null && measured > 0) {
        offset = (targetRow * measured).clamp(0.0, maxExtent);
      } else {
        // 一个已构建的条目都没测到（极端情况）。
        // 退回到"按行差比例推"：从当前位置往目标方向推进。
        final curRow =
            (scrollController.position.pixels / maxExtent) * rows;
        final deltaRows = targetRow - curRow;
        final pxPerRow = maxExtent / rows;
        offset = (scrollController.position.pixels + deltaRows * pxPerRow)
            .clamp(0.0, maxExtent);
      }

      if ((scrollController.position.pixels - offset).abs() < 1) {
        // 位置没动，可能已经到头了。
        return;
      }
    }
  }

  /// 目标 entry 已经构建 → 用 ensureVisible 精确落位。
  bool _tryEnsureVisible(int entryIndex) {
    final ctx = rowKeysByEntry[entryIndex]?.currentContext;
    if (ctx == null) return false;
    Scrollable.ensureVisible(
      ctx,
      duration: Duration.zero,
      alignment: 0.25,
    );
    return true;
  }

  /// 挑一个"行号离目标最近、且已经构建"的 entry，
  /// 用它当前的实际像素位置推算「像素/行」。
  ///
  /// 遍历时顺手把已经失效（currentContext 为 null）的 key 从 map 里删掉，
  /// 避免滚动一段时间后 map 膨胀到几万条，每次跳转都 O(n) 遍历一次。
  double? _measurePxPerRow(int targetRow) {
    if (!scrollController.hasClients) return null;
    final pixelsAtTop = scrollController.position.pixels;

    int? bestRow;
    double? bestPx;
    double bestDist = double.infinity;
    final stale = <int>[];

    for (final e in rowKeysByEntry.entries) {
      final ctx = e.value.currentContext;
      if (ctx == null) {
        stale.add(e.key);
        continue;
      }
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) {
        stale.add(e.key);
        continue;
      }

      final row = entryToRow(e.key);
      if (row <= 0) continue;

      final topDy = box.localToGlobal(Offset.zero).dy;
      final px = pixelsAtTop + topDy;
      if (px <= 0) continue;

      final dist = (row - targetRow).abs().toDouble();
      if (dist < bestDist) {
        bestDist = dist;
        bestRow = row;
        bestPx = px;
      }
    }

    for (final k in stale) {
      rowKeysByEntry.remove(k);
    }

    if (bestRow == null || bestPx == null || bestRow == 0) return null;
    return bestPx / bestRow;
  }
}

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../diff/domain/diff_result.dart';

/// Captures the rendered diff view as a long PNG for IM sharing.
/// PRD §2 Module 7 (P1).
class ImageExportService {
  const ImageExportService();

  Future<List<int>> exportLongImage({
    required GlobalKey rootViewKey,
    required DiffResult diff,
  }) async {
    throw UnimplementedError(
      'ImageExportService: use RenderRepaintBoundary.toImage + stitch.',
    );
  }
}

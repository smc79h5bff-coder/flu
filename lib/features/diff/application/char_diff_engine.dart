import 'package:diff_match_patch/diff_match_patch.dart';

import '../domain/diff_entry.dart';
import '../domain/diff_operation.dart';
import '../domain/diff_result.dart';
import 'diff_engine.dart';

/// Character-level diff using Google's diff-match-patch (Myers).
/// PRD §2 Module 4.
class CharDiffEngine implements DiffEngine {
  const CharDiffEngine();

  @override
  DiffResult compute(String original, String modified) {
    final dmp = DiffMatchPatch();
    final raw = dmp.diff(original, modified);

    final entries = <DiffEntry>[];
    for (final d in raw) {
      final op = _mapOp(d.operation);
      entries.add(DiffEntry(
        operation: op,
        text: d.text,
        oldText: op == DiffOperation.delete ? d.text : '',
        newText: op == DiffOperation.insert ? d.text : '',
      ));
    }
    return DiffResult(entries: entries, engineType: DiffEngineType.char);
  }

  DiffOperation _mapOp(int op) => switch (op) {
        DIFF_EQUAL => DiffOperation.equal,
        DIFF_INSERT => DiffOperation.insert,
        DIFF_DELETE => DiffOperation.delete,
        _ => DiffOperation.equal,
      };
}

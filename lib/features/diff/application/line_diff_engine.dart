import 'package:diff_match_patch/diff_match_patch.dart';

import '../domain/diff_entry.dart';
import '../domain/diff_operation.dart';
import '../domain/diff_result.dart';
import 'diff_engine.dart';

/// Line-level diff using Google's diff-match-patch (Myers O(ND)).
///
/// Replaces the previous Hirschberg O(m·n) implementation: on 20k-line
/// documents with a few hundred changes, dmp's two-stage line diff
/// (diffLinesToChars → diffMain → diffCharsToLines) is roughly 1000x faster
/// while still emitting one DiffEntry per line so downstream code keeps
/// working unchanged.
///
/// PRD §2 Module 4.
class LineDiffEngine implements DiffEngine {
  const LineDiffEngine();

  @override
  DiffResult compute(String original, String modified) {
    if (original.isEmpty && modified.isEmpty) {
      return const DiffResult(
        entries: <DiffEntry>[],
        engineType: DiffEngineType.line,
      );
    }

    final dmp = DiffMatchPatch();

    // Stage 1: map every distinct line to a single UTF-16 code unit.
    // Stage 2: run Myers diff over the two char strings (this is where the
    //          complexity drops from O(m*n) to O(N*D)).
    // Stage 3: map code units back to the original line strings.
    final lines = dmp.diffLinesToChars(original, modified);
    final chars1 = lines[0] as String;
    final chars2 = lines[1] as String;
    final lineArray = lines[2] as List<String>;

    final diffs = dmp.diffMain(chars1, chars2, false);
    dmp.diffCharsToLines(diffs, lineArray);

    final entries = <DiffEntry>[];
    for (final d in diffs) {
      final op = _mapOp(d.operation);
      _emitLines(entries, d.text, op);
    }

    return DiffResult(entries: entries, engineType: DiffEngineType.line);
  }

  /// Splits a multi-line diff chunk into per-line DiffEntry items so the
  /// renderer keeps seeing one entry per line (the previous contract).
  ///
  /// dmp emits chunks where each line ends with '\n' except the very last
  /// line of a document; we walk '\n' and emit one entry per segment,
  /// ignoring the trailing empty segment that a final '\n' would produce.
  void _emitLines(List<DiffEntry> out, String text, DiffOperation op) {
    if (text.isEmpty) return;
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        out.add(_mkEntry(op, text.substring(start, i)));
        start = i + 1;
      }
    }
    if (start < text.length) {
      out.add(_mkEntry(op, text.substring(start)));
    }
  }

  DiffEntry _mkEntry(DiffOperation op, String line) {
    switch (op) {
      case DiffOperation.equal:
        return DiffEntry(operation: op, text: line);
      case DiffOperation.insert:
        return DiffEntry(operation: op, text: line, newText: line);
      case DiffOperation.delete:
        return DiffEntry(operation: op, text: line, oldText: line);
      case DiffOperation.replace:
        // dmp never emits replace; kept for exhaustiveness.
        return DiffEntry(operation: op, text: line);
    }
  }

  DiffOperation _mapOp(int op) {
    switch (op) {
      case DIFF_EQUAL:
        return DiffOperation.equal;
      case DIFF_INSERT:
        return DiffOperation.insert;
      case DIFF_DELETE:
        return DiffOperation.delete;
      default:
        return DiffOperation.equal;
    }
  }
}
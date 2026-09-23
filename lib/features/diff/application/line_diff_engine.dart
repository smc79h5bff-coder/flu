import 'package:diff_match_patch/diff_match_patch.dart';

import '../domain/diff_entry.dart';
import '../domain/diff_operation.dart';
import '../domain/diff_result.dart';
import 'diff_engine.dart';

/// Line-level diff built on top of diff-match-patch's `diff()`.
///
/// The package version we depend on (diff_match_patch 0.4.1) only exposes
/// the plain character-level `diff()` method — it does NOT ship
/// `diffLinesToChars` / `diffCharsToLines`. To still get line-level speed
/// we do the "lines to chars" mapping ourselves:
///
///   1. Split both texts into lines.
///   2. Intern each distinct line to a single UTF-16 code unit.
///   3. Join the code units into two compact strings.
///   4. Run `dmp.diff()` on those strings — this is where the win is:
///      Myers sees one symbol per *line*, not one per *character*.
///   5. Map each diff chunk back to lines using the interned table.
///
/// Complexity is O(N_lines · D) instead of O(N_chars · D) — on a 20k-line
/// novel with a few hundred changes this is the difference between several
/// seconds and a few hundred milliseconds.
///
/// PRD §2 Module 4.
class LineDiffEngine implements DiffEngine {
  const LineDiffEngine();

  @override
  DiffResult compute(String original, String modified) {
    final a = original.isEmpty ? const <String>[] : original.split('\n');
    final b = modified.isEmpty ? const <String>[] : modified.split('\n');

    if (a.isEmpty && b.isEmpty) {
      return const DiffResult(
        entries: <DiffEntry>[],
        engineType: DiffEngineType.line,
      );
    }

    // Intern distinct lines to single code units (U+0000 is reserved as the
    // "separator" / "not a real symbol" sentinel, so symbols start at 1).
    final interned = <String, int>{};
    final table = <String>['']; // index 0 is a placeholder

    int intern(String line) {
      final hit = interned[line];
      if (hit != null) return hit;
      final id = table.length;
      table.add(line);
      interned[line] = id;
      return id;
    }

    final bufA = StringBuffer();
    for (final line in a) {
      bufA.writeCharCode(intern(line));
    }
    final bufB = StringBuffer();
    for (final line in b) {
      bufB.writeCharCode(intern(line));
    }

    final dmp = DiffMatchPatch();
    final diffs = dmp.diff(bufA.toString(), bufB.toString());

    final entries = <DiffEntry>[];
    for (final d in diffs) {
      final op = _mapOp(d.operation);
      // Each code unit corresponds to exactly one line.
      for (var i = 0; i < d.text.length; i++) {
        final line = table[d.text.codeUnitAt(i)];
        entries.add(_mkEntry(op, line));
      }
    }

    return DiffResult(entries: entries, engineType: DiffEngineType.line);
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

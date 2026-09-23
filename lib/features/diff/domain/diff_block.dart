/// One sparse diff block: a contiguous run of changed (or equal) lines from
/// both sides, addressed by line ranges instead of per-line entries.
///
/// Line ranges use Dart half-open interval convention: [start, end).
///
///   equal   : origLength > 0 && modLength > 0, line-by-line identical
///   insert  : origLength == 0 && modLength > 0
///   delete  : origLength > 0 && modLength == 0
///   replace : origLength > 0 && modLength > 0, content differs
///
/// This mirrors NMM's compact {b, c, d, e} representation (see Ld6/a.smali)
/// and is the basis for the later "sparse render" refactor: on a 20k-line
/// document with a few hundred changes we end up with a few hundred blocks
/// instead of tens of thousands of per-line entries.
class DiffBlock {
  const DiffBlock({
    required this.index,
    required this.kind,
    required this.origStart,
    required this.origEnd,
    required this.modStart,
    required this.modEnd,
  });

  /// Zero-based position in the full block list. Stable within one diff
  /// computation; used as the cross-view scroll anchor.
  final int index;

  final DiffBlockKind kind;

  /// Line range in the original document, [origStart, origEnd).
  final int origStart;
  final int origEnd;

  /// Line range in the modified document, [modStart, modEnd).
  final int modStart;
  final int modEnd;

  int get origLength => origEnd - origStart;
  int get modLength => modEnd - modStart;

  bool get isEqual => kind == DiffBlockKind.equal;

  @override
  String toString() => 'DiffBlock(#$index ${kind.name} '
      'orig=[$origStart,$origEnd) mod=[$modStart,$modEnd))';
}

enum DiffBlockKind { equal, insert, delete, replace }

/// Produces a [DiffBlockKind] from the two range lengths.
DiffBlockKind classifyBlock({
  required int origLength,
  required int modLength,
  bool equal = false,
}) {
  if (equal) return DiffBlockKind.equal;
  if (origLength == 0) return DiffBlockKind.insert;
  if (modLength == 0) return DiffBlockKind.delete;
  return DiffBlockKind.replace;
}
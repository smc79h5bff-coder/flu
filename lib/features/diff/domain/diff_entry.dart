import 'diff_operation.dart';

/// One atomic diff segment.
///
/// For char-level diff: `oldText`/`newText` are substrings; similarity = 1.0
/// (or 0.0 for pure add/del). For semantic-level: similarity carries the
/// cosine similarity score in [0, 1]; `operation == replace` when the
/// sentence was rewritten rather than added/removed.
class DiffEntry {
  const DiffEntry({
    required this.operation,
    required this.text,
    this.oldText = '',
    this.newText = '',
    this.similarity = 1.0,
  });

  final DiffOperation operation;

  /// Convenience text for rendering: equal→original, insert→new, delete→old,
  /// replace→new (old kept in `oldText`).
  final String text;
  final String oldText;
  final String newText;
  final double similarity;

  int get addedCount => operation == DiffOperation.insert ||
          operation == DiffOperation.replace
      ? newText.isEmpty ? text.length : newText.length
      : 0;

  int get deletedCount => operation == DiffOperation.delete ||
          operation == DiffOperation.replace
      ? oldText.isEmpty ? text.length : oldText.length
      : 0;

  @override
  String toString() => 'DiffEntry(${operation.name}, '
      'old="${oldText.trimRight()}", new="${newText.trimRight()}", sim=$similarity)';
}

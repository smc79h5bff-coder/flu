/// Single diff operation kind.
/// PRD §2 Module 5: green=add, red=delete, yellow=modify.
enum DiffOperation {
  /// Identical segment (no highlight).
  equal,

  /// Present in the new doc only.
  insert,

  /// Present in the old doc only.
  delete,

  /// Both sides have content but changed (semantic-level only).
  replace,
}

extension DiffOperationLabel on DiffOperation {
  String get symbol => switch (this) {
        DiffOperation.equal => ' ',
        DiffOperation.insert => '+',
        DiffOperation.delete => '-',
        DiffOperation.replace => '~',
      };
}

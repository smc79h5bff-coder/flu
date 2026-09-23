import 'dart:collection';

import 'diff_entry.dart';
import 'diff_operation.dart';

/// Output of a diff computation.
class DiffResult {
  const DiffResult({
    required this.entries,
    required this.engineType,
  });

  final List<DiffEntry> entries;
  final DiffEngineType engineType;

  int get addedCount =>
      entries.fold(0, (s, e) => s + e.addedCount);
  int get deletedCount =>
      entries.fold(0, (s, e) => s + e.deletedCount);
  int get modifiedCount =>
      entries.where((e) => e.operation == DiffOperation.replace).length;

  DiffStats get stats => DiffStats(
        added: addedCount,
        deleted: deletedCount,
        modified: modifiedCount,
        engineType: engineType,
      );
}

class DiffStats {
  const DiffStats({
    required this.added,
    required this.deleted,
    required this.modified,
    required this.engineType,
  });

  final int added;
  final int deleted;
  final int modified;
  final DiffEngineType engineType;

  String get summary => '+$added -$deleted ~$modified';

  @override
  String toString() => 'DiffStats($summary, ${engineType.name})';
}

/// Which algorithm produced this diff. PRD §2 Module 4.
enum DiffEngineType {
  char,
  line,
  semantic,
}

UnmodifiableListView<DiffEntry> wrapEntries(List<DiffEntry> list) =>
    UnmodifiableListView(list);

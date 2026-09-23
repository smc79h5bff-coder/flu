import '../domain/diff_result.dart';

/// Common diff engine contract. PRD §2 Module 4.
abstract interface class DiffEngine {
  DiffResult compute(String original, String modified);
}

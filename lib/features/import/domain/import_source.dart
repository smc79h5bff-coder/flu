import '../../parser/domain/parsed_document.dart';

/// Where the document came from. PRD §2 Module 1.
enum ImportSource { local, clipboard, cloud, ocr }

/// Supported cloud providers (P1).
enum CloudProvider { icloud, googleDrive, dropbox, oneDrive }

/// Bundles the parsed document with its origin metadata.
class ImportedDoc {
  const ImportedDoc({required this.parsed, required this.source});
  final ParsedDocument parsed;
  final ImportSource source;
}

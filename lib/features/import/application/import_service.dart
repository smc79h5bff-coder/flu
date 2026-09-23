import 'dart:io';
import 'dart:typed_data';

import '../../parser/application/document_parser.dart';
import '../domain/import_source.dart';

/// Facade for picking two documents from local FS / clipboard / cloud / OCR.
/// PRD §2 Module 1.
///
/// P0 stub: only local file picker is wired; cloud/OCR are P1 hooks.
class ImportService {
  const ImportService();

  /// Read a local file and parse it. Returns a fully-populated document.
  Future<ImportedDoc> importLocalFile(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final parsed = DocumentParser.parse(
      fileName: file.uri.pathSegments.last,
      bytes: Uint8List.fromList(bytes),
    );
    return ImportedDoc(parsed: parsed, source: ImportSource.local);
  }

  // P1 stubs — to be implemented when OCR / cloud plugins land.
  Future<ImportedDoc> importFromClipboard(String text) async {
    throw UnimplementedError('Clipboard import is P1.');
  }

  Future<ImportedDoc> importFromCloud(CloudProvider provider) async {
    throw UnimplementedError('Cloud import is P1.');
  }
}

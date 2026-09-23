import '../../preprocessing/domain/encoding_type.dart';
import 'document_format.dart';

/// Result of parsing a source file into a list of paragraphs + metadata.
///
/// Paragraphs are preserved per PRD §2 Module 2 so line-level diff has
/// meaningful boundaries. `encoding` is the *original* detected encoding —
/// preprocessing converts internal storage to UTF-16, but export must write
/// back using this encoding.
class ParsedDocument {
  const ParsedDocument({
    required this.fileName,
    required this.format,
    required this.encoding,
    required this.paragraphs,
    required this.byteSize,
  });

  final String fileName;
  final DocumentFormat format;
  final EncodingType encoding;
  final List<String> paragraphs;
  final int byteSize;

  String get plainText => paragraphs.join('\n');

  int get charCount => plainText.length;
}

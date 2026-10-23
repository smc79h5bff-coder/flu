import 'dart:typed_data';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';

class TxtParser {
  const TxtParser();

  Future<ParsedDocument> parse(
    String fileName,
    Uint8List bytes,
    EncodingType encoding,
  ) async {
    final decoded = await EncodingDetector.decodeChunkedAsync(bytes, encoding);
    final text = decoded.text;
    // Split on \n preserving non-empty paragraphs.
    final paragraphs = text
        .split(RegExp(r'\r?\n'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    return ParsedDocument(
      fileName: fileName,
      format: fileName.toLowerCase().endsWith('.md')
          ? DocumentFormat.markdown
          : DocumentFormat.txt,
      encoding: decoded.encoding,
      paragraphs: paragraphs,
      byteSize: bytes.length,
    );
  }
}

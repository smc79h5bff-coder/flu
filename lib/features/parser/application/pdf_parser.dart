import 'dart:typed_data';

import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';

/// PDF text extractor. Skeleton — wire `pdfx` or `sync_pdf_metadata` /
/// native `pdfium` plugin for ordered text stream extraction.
///
/// TODO(P1):
///   1. Open PDF via plugin.
///   2. For each page, read text in reading order.
///   3. Insert page separator paragraph ("--- Page N ---").
///   4. Detect encryption (encrypted PDF → throw with friendly message).
class PdfParser {
  const PdfParser();

  ParsedDocument parse(
    String fileName,
    Uint8List bytes,
    EncodingType encoding,
  ) {
    if (_isEncrypted(bytes)) {
      throw FormatException('Encrypted PDF is not supported.');
    }
    throw UnimplementedError(
      'PdfParser: wire a PDF text-extraction plugin (e.g. pdfx).',
    );
  }

  bool _isEncrypted(Uint8List bytes) {
    // PDF encryption flag: look for "/Encrypt" in first 4KB of trailer.
    final sample = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
    final asString = String.fromCharCodes(sample.where((b) => b < 128));
    return asString.contains('/Encrypt');
  }
}

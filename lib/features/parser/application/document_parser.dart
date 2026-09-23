import 'dart:typed_data';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';
import 'docx_parser.dart';
import 'pdf_parser.dart';
import 'txt_parser.dart';

/// Dispatches raw bytes to the format-specific parser.
/// PRD §2 Module 2.
class DocumentParser {
  const DocumentParser._();

  static ParsedDocument parse({
    required String fileName,
    required Uint8List bytes,
  }) {
    final format = _sniffFormat(fileName, bytes);
    final encoding = EncodingDetector.detect(bytes);

    switch (format) {
      case DocumentFormat.txt:
      case DocumentFormat.markdown:
        return TxtParser().parse(fileName, bytes, encoding);
      case DocumentFormat.docx:
        return DocxParser().parse(fileName, bytes, encoding);
      case DocumentFormat.pdf:
        return PdfParser().parse(fileName, bytes, encoding);
      case DocumentFormat.image:
        // P1: route through OCR service
        throw UnsupportedError('OCR route not wired in skeleton');
      case DocumentFormat.doc:
      case DocumentFormat.rtf:
      case DocumentFormat.html:
        throw UnsupportedError('$format parser not implemented yet');
      case DocumentFormat.unknown:
        throw FormatException('Cannot detect document format for $fileName');
    }
  }

  static DocumentFormat _sniffFormat(String name, Uint8List bytes) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.txt')) return DocumentFormat.txt;
    if (lower.endsWith('.md')) return DocumentFormat.markdown;
    if (lower.endsWith('.docx')) return DocumentFormat.docx;
    if (lower.endsWith('.doc')) return DocumentFormat.doc;
    if (lower.endsWith('.pdf')) return DocumentFormat.pdf;
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png')) {
      return DocumentFormat.image;
    }
    if (lower.endsWith('.rtf')) return DocumentFormat.rtf;
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return DocumentFormat.html;
    }
    // Sniff by magic bytes
    if (bytes.length >= 4) {
      if (bytes[0] == 0x25 && bytes[1] == 0x50) return DocumentFormat.pdf;
      if (bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04) {
        // ZIP container — could be docx
        return DocumentFormat.docx;
      }
    }
    return DocumentFormat.unknown;
  }
}

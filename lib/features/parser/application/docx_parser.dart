import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';

/// .docx (Office Open XML) parser.
///
/// Walks `word/document.xml` body in document order, extracting:
///   - Each `<w:p>` as one paragraph (text from `<w:t>`, tab from `<w:tab/>`,
///     newline from `<w:br/>` and `<w:cr/>`)
///   - Each `<w:tbl>` as one paragraph containing cells joined by `\t` and
///     rows joined by `\n` (structured table extraction preserves row/col
///     boundaries for diff purposes)
///   - `<w:sdt>` content controls are recursed into so their paragraphs
///     and tables are picked up at the right position in document order
///
/// Empty paragraphs (no text after walk) are skipped, matching TxtParser
/// semantics. OOXML is always UTF-8 (declared in the XML prolog), so we
/// ignore the sniffed encoding and force UTF-8.
class DocxParser {
  const DocxParser();

  static const String _wNs =
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

  ParsedDocument parse(
    String fileName,
    Uint8List bytes,
    EncodingType encoding,
  ) {
    final archive = _decodeZip(bytes);
    final xmlString = _readDocumentXml(archive);
    final doc = _parseXml(xmlString);

    final bodies = doc.findAllElements('body', namespace: _wNs);
    if (bodies.isEmpty) {
      throw FormatException('No <w:body> element in word/document.xml.');
    }

    final paragraphs = <String>[];
    _collectParagraphs(bodies.first, paragraphs);

    return ParsedDocument(
      fileName: fileName,
      format: DocumentFormat.docx,
      encoding: EncodingType.utf8, // OOXML spec mandates UTF-8.
      paragraphs: paragraphs,
      byteSize: bytes.length,
    );
  }

  /// Recursively walks `parent`'s element children, emitting one entry per
  /// `<w:p>` (paragraph) or `<w:tbl>` (table-as-paragraph) in document order.
  /// `<w:sdt>` content controls are descended into via `<w:sdtContent>`.
  void _collectParagraphs(XmlElement parent, List<String> out) {
    for (final child in parent.childElements) {
      switch (child.name.local) {
        case 'p':
          final text = _extractParagraphText(child);
          if (text.isNotEmpty) out.add(text);
          break;
        case 'tbl':
          final tableText = _extractTable(child);
          if (tableText.isNotEmpty) out.add(tableText);
          break;
        case 'sdt':
          for (final sdtContent
              in child.findElements('sdtContent', namespace: _wNs)) {
            _collectParagraphs(sdtContent, out);
          }
          break;
        // Other direct body children (sectPr, etc.) are ignored.
      }
    }
  }

  /// Walks descendants of `<w:p>` in document order, collecting text from
  /// `<w:t>`, tab from `<w:tab/>`, newline from `<w:br/>` and `<w:cr/>`.
  String _extractParagraphText(XmlElement paragraph) {
    final buf = StringBuffer();
    for (final node in paragraph.descendants) {
      if (node is! XmlElement) continue;
      switch (node.name.local) {
        case 't':
          buf.write(node.text);
          break;
        case 'tab':
          buf.write('\t');
          break;
        case 'br':
        case 'cr':
          buf.write('\n');
          break;
      }
    }
    return buf.toString();
  }

  /// Extracts a table as one paragraph: cells in a row joined by `\t`,
  /// rows joined by `\n`. Nested tables inside cells recurse via
  /// [_collectParagraphs] and become a single multi-line "cell paragraph".
  String _extractTable(XmlElement table) {
    final rows = <String>[];
    for (final tr in table.findElements('tr', namespace: _wNs)) {
      final cells = <String>[];
      for (final tc in tr.findElements('tc', namespace: _wNs)) {
        final cellParagraphs = <String>[];
        _collectParagraphs(tc, cellParagraphs);
        cells.add(cellParagraphs.join('\n'));
      }
      if (cells.isNotEmpty) rows.add(cells.join('\t'));
    }
    return rows.join('\n');
  }

  Archive _decodeZip(Uint8List bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } on Exception catch (e) {
      throw FormatException('Not a valid .docx (zip) file: $e');
    }
  }

  String _readDocumentXml(Archive archive) {
    final file = archive.findFile('word/document.xml');
    if (file == null) {
      throw FormatException(
        'word/document.xml not found inside .docx archive.',
      );
    }
    final content = file.content;
    final List<int> raw;
    if (content is List<int>) {
      raw = content;
    } else if (content is Uint8List) {
      raw = content;
    } else {
      // Fallback for older archive versions exposing InputStream.
      throw FormatException(
        'Unexpected document.xml content type: ${content.runtimeType}',
      );
    }
    try {
      return utf8.decode(raw);
    } on FormatException catch (e) {
      throw FormatException('word/document.xml is not valid UTF-8: $e');
    }
  }

  XmlDocument _parseXml(String xmlString) {
    try {
      return XmlDocument.parse(xmlString);
    } on Exception catch (e) {
      throw FormatException('Invalid XML in word/document.xml: $e');
    }
  }
}

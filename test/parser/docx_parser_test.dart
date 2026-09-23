import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docdiff/features/parser/application/docx_parser.dart';
import 'package:docdiff/features/parser/domain/document_format.dart';
import 'package:docdiff/features/preprocessing/domain/encoding_type.dart';
import 'package:flutter_test/flutter_test.dart';

const _wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/// Build a minimal in-memory .docx (zip with one word/document.xml entry).
Uint8List _buildDocx(String bodyXml) {
  final xml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="$_wNs">
  <w:body>
$bodyXml
  </w:body>
</w:document>''';
  final archive = Archive()
    ..addFile(ArchiveFile(
      'word/document.xml',
      utf8.encode(xml).length,
      utf8.encode(xml),
    ));
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? const <int>[]);
}

void main() {
  group('DocxParser', () {
    const parser = DocxParser();

    test('parses two simple paragraphs', () {
      final bytes = _buildDocx('''
<w:p><w:r><w:t>Hello</w:t></w:r></w:p>
<w:p><w:r><w:t>World</w:t></w:r></w:p>
''');
      final r = parser.parse('test.docx', bytes, EncodingType.utf8);

      expect(r.format, DocumentFormat.docx);
      expect(r.encoding, EncodingType.utf8);
      expect(r.paragraphs, ['Hello', 'World']);
      expect(r.plainText, 'Hello\nWorld');
    });

    test('skips empty paragraphs', () {
      final bytes = _buildDocx('''
<w:p><w:r><w:t>Only</w:t></w:r></w:p>
<w:p/>
<w:p><w:r></w:r></w:p>
''');
      final r = parser.parse('empty.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['Only']);
    });

    test('merges text across multiple runs in same paragraph', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r><w:t>Hel</w:t></w:r>
  <w:r><w:t>lo</w:t></w:r>
</w:p>
''');
      final r = parser.parse('runs.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['Hello']);
    });

    test('handles <w:tab/> and <w:br/>', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r><w:t>foo</w:t><w:tab/><w:t>bar</w:t></w:r>
</w:p>
<w:p>
  <w:r><w:t>line1</w:t><w:br/><w:t>line2</w:t></w:r>
</w:p>
''');
      final r = parser.parse('breaks.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['foo\tbar', 'line1\nline2']);
    });

    test('preserves whitespace inside <w:t> with xml:space="preserve"', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r><w:t xml:space="preserve">a  b</w:t></w:r>
</w:p>
''');
      final r = parser.parse('ws.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['a  b']);
    });

    test('ignores inline images and shape nodes (text only)', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r><w:t>before</w:t></w:r>
  <w:r><w:drawing><wp:inline xmlns:wp="x"><a:blip/></wp:inline></w:drawing></w:r>
  <w:r><w:t>after</w:t></w:r>
</w:p>
''');
      final r = parser.parse('img.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['beforeafter']);
    });

    test('byteSize equals input bytes length', () {
      final bytes = _buildDocx(
          '<w:p><w:r><w:t>x</w:t></w:r></w:p>');
      final r = parser.parse('sz.docx', bytes, EncodingType.utf8);

      expect(r.byteSize, bytes.length);
    });

    test('maps <w:cr/> to newline within the same paragraph', () {
      final bytes = _buildDocx('''
<w:p>
  <w:r><w:t>line1</w:t><w:cr/><w:t>line2</w:t></w:r>
</w:p>
''');
      final r = parser.parse('cr.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['line1\nline2']);
    });

    test('extracts a simple 2x2 table as one paragraph', () {
      final bytes = _buildDocx('''
<w:tbl>
  <w:tr>
    <w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc>
  </w:tr>
  <w:tr>
    <w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>d</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
''');
      final r = parser.parse('tbl.docx', bytes, EncodingType.utf8);

      // cells in a row → '\t', rows → '\n'
      expect(r.paragraphs, ['a\tb\nc\td']);
    });

    test('cell with multiple paragraphs joins them with newline', () {
      final bytes = _buildDocx('''
<w:tbl>
  <w:tr>
    <w:tc>
      <w:p><w:r><w:t>line1</w:t></w:r></w:p>
      <w:p><w:r><w:t>line2</w:t></w:r></w:p>
    </w:tc>
  </w:tr>
</w:tbl>
''');
      final r = parser.parse('multi.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['line1\nline2']);
    });

    test('preserves document order: paragraph → table → paragraph', () {
      final bytes = _buildDocx('''
<w:p><w:r><w:t>before</w:t></w:r></w:p>
<w:tbl>
  <w:tr>
    <w:tc><w:p><w:r><w:t>c1</w:t></w:r></w:p></w:tc>
    <w:tc><w:p><w:r><w:t>c2</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
<w:p><w:r><w:t>after</w:t></w:r></w:p>
''');
      final r = parser.parse('order.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['before', 'c1\tc2', 'after']);
    });

    test('skips empty table rows', () {
      final bytes = _buildDocx('''
<w:tbl>
  <w:tr></w:tr>
  <w:tr>
    <w:tc><w:p><w:r><w:t>x</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
''');
      final r = parser.parse('emptyrow.docx', bytes, EncodingType.utf8);

      // empty row contributes nothing; only the second row survives.
      expect(r.paragraphs, ['x']);
    });

    test('nested table inside a cell collapses to a multi-line cell', () {
      final bytes = _buildDocx('''
<w:tbl>
  <w:tr>
    <w:tc>
      <w:tbl>
        <w:tr>
          <w:tc><w:p><w:r><w:t>n1</w:t></w:r></w:p></w:tc>
          <w:tc><w:p><w:r><w:t>n2</w:t></w:r></w:p></w:tc>
        </w:tr>
      </w:tbl>
    </w:tc>
    <w:tc><w:p><w:r><w:t>outer</w:t></w:r></w:p></w:tc>
  </w:tr>
</w:tbl>
''');
      final r = parser.parse('nested.docx', bytes, EncodingType.utf8);

      // The nested table becomes a single "paragraph" string inside the
      // outer cell: 'n1\tn2'. That cell + 'outer' are then joined with \t.
      expect(r.paragraphs, ['n1\tn2\touter']);
    });

    test('descends into <w:sdt> content controls', () {
      final bytes = _buildDocx('''
<w:sdt>
  <w:sdtContent>
    <w:p><w:r><w:t>sdt paragraph</w:t></w:r></w:p>
  </w:sdtContent>
</w:sdt>
<w:p><w:r><w:t>plain</w:t></w:r></w:p>
''');
      final r = parser.parse('sdt.docx', bytes, EncodingType.utf8);

      expect(r.paragraphs, ['sdt paragraph', 'plain']);
    });

    test('throws FormatException on non-zip bytes', () {
      expect(
        () => parser.parse('bad.docx',
            Uint8List.fromList([1, 2, 3, 4, 5]), EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when word/document.xml is missing', () {
      final archive = Archive()
        ..addFile(ArchiveFile('foo/bar.xml', 1, [0x78]));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
      expect(
        () => parser.parse('noxml.docx', bytes, EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on malformed XML', () {
      final archive = Archive()
        ..addFile(ArchiveFile(
          'word/document.xml',
          5,
          utf8.encode('<<bad'),
        ));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive) ?? const []);
      expect(
        () => parser.parse('badxml.docx', bytes, EncodingType.utf8),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

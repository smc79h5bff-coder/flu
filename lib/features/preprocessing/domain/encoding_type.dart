/// Text encoding kind detected by [EncodingDetector].
/// PRD §2 Module 3.1: UTF-8 / GBK / GB18030 / Big5 / Shift-JIS.
enum EncodingType {
  utf8,
  utf8bom,
  gbk,
  gb18030,
  big5,
  shiftJis,
  ascii,
  binary,
  unknown,
}

extension EncodingTypeX on EncodingType {
  String get label => switch (this) {
        EncodingType.utf8 => 'UTF-8',
        EncodingType.utf8bom => 'UTF-8 (BOM)',
        EncodingType.gbk => 'GBK',
        EncodingType.gb18030 => 'GB18030',
        EncodingType.big5 => 'Big5',
        EncodingType.shiftJis => 'Shift-JIS',
        EncodingType.ascii => 'ASCII',
        EncodingType.binary => 'Binary',
        EncodingType.unknown => 'Unknown',
      };

  /// Codecs are wired in [EncodingDetector.decode] (uses dart:convert +
  /// fallback heuristic for non-UTF-8 families).
}

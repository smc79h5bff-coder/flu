/// Text encoding kind detected by [EncodingDetector].
enum EncodingType {
  utf8,
  utf8bom,
  utf16le,
  utf16be,
  gbk,
  gb2312,
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
        EncodingType.utf16le => 'UTF-16 LE',
        EncodingType.utf16be => 'UTF-16 BE',
        EncodingType.gbk => 'GBK',
        EncodingType.gb2312 => 'GB2312',
        EncodingType.gb18030 => 'GB18030',
        EncodingType.big5 => 'Big5',
        EncodingType.shiftJis => 'Shift-JIS',
        EncodingType.ascii => 'ASCII',
        EncodingType.binary => 'Binary',
        EncodingType.unknown => 'Unknown',
      };
}

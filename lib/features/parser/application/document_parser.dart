import 'dart:typed_data';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';
import 'docx_parser.dart';
import 'txt_parser.dart';

/// Dispatches raw bytes to the format-specific parser.
///
/// 判定规则（按用户确认的策略）：
///   1. 后缀在 [_binaryExtensions] 白名单里 → 真二进制，走专门解析器
///      （当前一律提示"暂不支持"）。
///   2. 其它所有后缀 / 无后缀 → 一律按纯文本处理，不管内容是不是文本。
///
/// 只看后缀，不嗅魔数。用户手动把 zip 改名为 .txt 时按文本读，读出乱码
/// 也认——宁可给出可对比的结果，也不做"看起来像二进制就拒绝"的猜测。
class DocumentParser {
  const DocumentParser._();

  /// 真二进制格式的后缀白名单。命中这些后缀才走专门解析器。
  /// 其余后缀一律按 txt 处理。
  ///
  /// 分类：文档 / 表格 / 演示 / PDF / 图片 / 音频 / 视频 / 压缩包 /
  ///       可执行 / 字体 / 数据库。
  static const Set<String> _binaryExtensions = {
    // 文档
    '.docx', '.doc', '.rtf', '.odt', '.wps',
    // 表格 / 演示
    '.xlsx', '.xls', '.ods', '.pptx', '.ppt', '.odp',
    // PDF
    '.pdf',
    // 图片
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.svg',
    // 音频
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a',
    // 视频
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
    // 压缩包
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz',
    '.jar', '.apk', '.ipa', '.iso',
    // 可执行
    '.exe', '.dll', '.so', '.bin', '.deb', '.rpm',
    // 字体
    '.ttf', '.otf', '.woff', '.woff2',
    // 数据库
    '.db', '.sqlite', '.sqlite3',
  };

  static ParsedDocument parse({
    required String fileName,
    required Uint8List bytes,
  }) {
    final ext = _extOf(fileName);

    if (_binaryExtensions.contains(ext)) {
      throw UnsupportedError(
        '暂不支持对比 ${ext.isEmpty ? "此类型" : ext} 格式文件。',
      );
    }

    // 其它一切按文本处理。
    final encoding = EncodingDetector.detect(bytes);
    return TxtParser().parse(fileName, bytes, encoding);
  }

  /// 取小写后缀（含点）。无后缀返回空字符串。
  /// 特殊处理 `.tar.gz` 之类只取最后一段（`.gz`），因为 `.tar` 和 `.gz`
  /// 都在白名单里，取哪一段都会命中；返回 `.gz` 更简单。
  static String _extOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    // 目录分隔符之后没点：视为无后缀（比如路径里带点但文件名不带）。
    final slash = fileName.lastIndexOf('/');
    if (slash > dot) return '';
    return fileName.substring(dot).toLowerCase();
  }
}

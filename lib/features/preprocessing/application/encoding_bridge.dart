import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../reader/reader_load_log.dart';

/// Android 原生编码解码桥接。非 Android 平台不启用，调用方回落 Dart 包。
///
/// 走系统 ICU（`java.nio.charset.Charset`），覆盖 GBK / GB2312 / GB18030 /
/// Big5 / Shift-JIS 全码表。对非法字节输出 U+FFFD，不会像第三方 Dart 包那样
/// 静默错位。
class EncodingBridge {
  EncodingBridge._();

  static const MethodChannel _channel = MethodChannel('docdiff/encoding');

  /// 当前平台是否启用原生解码。目前只做 Android。
  static bool get isSupported => Platform.isAndroid;

  /// 用系统 ICU 解码 [bytes]。
  ///
  /// 返回 `null` 表示原生调用失败（channel 未注册、原生抛异常、非法编码名），
  /// 调用方需要回落 Dart 包。
  static Future<String?> decode(Uint8List bytes, String charset) async {
    final log = ReaderLoadLog.instance;
    if (!isSupported) {
      log.info('[Enc-Bridge] skip isSupported=$isSupported, charset=$charset');
      return null;
    }
    try {
      log.info('[Enc-Bridge] invoke charset=$charset bytes=${bytes.length}');
      final r = await _channel.invokeMethod<String>('decode', {
        'bytes': bytes,
        'charset': charset,
      });
      log.info('[Enc-Bridge] success charset=$charset chars=${r?.length ?? 0}');
      return r;
    } on PlatformException catch (e) {
      log.info('[Enc-Bridge] PlatformException charset=$charset code=${e.code} msg=${e.message}');
      return null;
    } on MissingPluginException catch (e) {
      log.info('[Enc-Bridge] MissingPluginException charset=$charset ($e)');
      return null;
    } catch (e) {
      log.info('[Enc-Bridge] Exception charset=$charset ($e)');
      return null;
    }
  }
}

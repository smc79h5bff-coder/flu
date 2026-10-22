import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../parser/application/document_parser.dart';
import '../../preprocessing/domain/encoding_type.dart';

/// 分享进来的两个文件解析完成后的结果。
class ShareIntakePayload {
  const ShareIntakePayload({
    required this.leftText,
    required this.rightText,
    required this.leftName,
    required this.rightName,
    required this.leftEncoding,
    required this.rightEncoding,
    required this.leftTempPath,
    required this.rightTempPath,
    required this.sessionDir,
  });

  final String leftText;
  final String rightText;
  final String leftName;
  final String rightName;
  final String leftEncoding;
  final String rightEncoding;
  final String leftTempPath;
  final String rightTempPath;

  /// 本次分享专属的缓存目录，对比页关闭后整目录删除。
  final String sessionDir;
}

/// 分享校验失败（提示语直接给用户看）。
class ShareIntakeException implements Exception {
  const ShareIntakeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 从其他 App 分享进来的文件 → 校验 → 复制 → 解析 → 进入对比页。
///
/// 只处理 Android 的 ACTION_SEND / ACTION_SEND_MULTIPLE。
/// 原生侧：MainActivity.kt 通过 MethodChannel `docdiff/share_intent` 把缓存好的
/// 文件列表喂给 Flutter。这里不引入第三方分享插件，避免 Fluter 3.47 的
/// kernel snapshot 兼容性问题。
class ShareIntakeCoordinator {
  ShareIntakeCoordinator._();

  static final ShareIntakeCoordinator instance = ShareIntakeCoordinator._();

  static const int maxBytes = 5 * 1024 * 1024;
  static const Duration _maxCacheAge = Duration(days: 3);
  static const Duration _aggregateWindow = Duration(milliseconds: 400);

  static const MethodChannel _channel = MethodChannel('docdiff/share_intent');

  static const Set<String> _binaryExtensions = {
    '.docx', '.doc', '.rtf', '.odt', '.wps',
    '.xlsx', '.xls', '.ods', '.pptx', '.ppt', '.odp',
    '.pdf',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.svg',
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a',
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz',
    '.jar', '.apk', '.ipa', '.iso',
    '.exe', '.dll', '.so', '.bin', '.deb', '.rpm',
    '.ttf', '.otf', '.woff', '.woff2',
    '.db', '.sqlite', '.sqlite3',
  };

  bool _started = false;
  bool _busy = false;
  Timer? _aggregateTimer;
  final List<_ShareItem> _buffer = <_ShareItem>[];

  String? _lastSignature;
  DateTime? _lastSignatureAt;

  Future<void> Function(ShareIntakePayload)? _onReady;
  Future<void> Function(String)? _onRejected;

  /// 启动监听。必须在 MaterialApp 之内、权限门之外调用。
  Future<void> start({
    required Future<void> Function(ShareIntakePayload) onReady,
    required Future<void> Function(String) onRejected,
  }) async {
    if (!Platform.isAndroid || _started) return;
    _started = true;
    _onReady = onReady;
    _onRejected = onRejected;

    // 清理旧缓存，不阻塞启动。
    unawaited(_cleanupOldSessions());

    _channel.setMethodCallHandler(_onNativeCall);

    // 冷启动时 MainActivity 已经在 configureFlutterEngine 之前收到 intent 并填好
    // pendingShares，那时我们的 handler 还没注册，所以主动拉一次。
    // 原生侧会在 getPendingShares 后清空，保证下次拉不到重复数据。
    final initial = await _poll();
    if (initial.isNotEmpty) _onBatch(initial);
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'onSharesPending') {
      final items = await _poll();
      if (items.isNotEmpty) _onBatch(items);
    }
  }

  Future<List<_ShareItem>> _poll() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('getPendingShares');
      if (raw == null) return const [];
      return raw
          .map((e) => _ShareItem(
                path: e['path'] as String? ?? '',
                name: e['name'] as String? ?? '',
              ))
          .where((e) => e.path.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void _onBatch(List<_ShareItem> batch) {
    if (batch.isEmpty) return;
    for (final f in batch) {
      if (_buffer.any((e) => e.path == f.path)) continue;
      _buffer.add(f);
    }
    _aggregateTimer?.cancel();
    _aggregateTimer = Timer(_aggregateWindow, () => unawaited(_drain()));
  }

  Future<void> _drain() async {
    if (_busy) {
      _aggregateTimer?.cancel();
      _aggregateTimer = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_drain()),
      );
      return;
    }
    final files = List<_ShareItem>.of(_buffer);
    _buffer.clear();
    if (files.isEmpty) return;

    _busy = true;
    try {
      // 10 秒内同签名视为重复投递（冷启动 initial + 热启动事件各投一次）。
      final signature = (files.map((f) => f.path).toList()..sort()).join('|');
      final now = DateTime.now();
      final lastAt = _lastSignatureAt;
      if (signature == _lastSignature &&
          lastAt != null &&
          now.difference(lastAt) < const Duration(seconds: 10)) {
        return;
      }

      final payload = await _buildPayload(files);
      _lastSignature = signature;
      _lastSignatureAt = now;
      final cb = _onReady;
      if (cb != null) await cb(payload);
    } on ShareIntakeException catch (e) {
      await _reject(e.message);
    } catch (e) {
      await _reject('处理分享文件失败：$e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _reject(String message) async {
    final cb = _onRejected;
    if (cb != null) await cb(message);
  }

  Future<ShareIntakePayload> _buildPayload(List<_ShareItem> files) async {
    if (files.length != 2) {
      if (files.isEmpty) {
        throw const ShareIntakeException(
          '没有收到文件。请一次选择两个文本文件分享（纯文本/链接不支持）',
        );
      }
      throw ShareIntakeException(
        '请一次分享两个文本文件（当前收到 ${files.length} 个）',
      );
    }

    final rawLeft = files[0].path;
    final rawRight = files[1].path;
    if (rawLeft == rawRight) {
      throw const ShareIntakeException(
        '两个文件被系统合并成同一个，请换一个分享来源再试',
      );
    }

    final leftName = files[0].name.isEmpty ? p.basename(rawLeft) : files[0].name;
    final rightName = files[1].name.isEmpty ? p.basename(rawRight) : files[1].name;
    if (leftName.toLowerCase() == rightName.toLowerCase()) {
      throw const ShareIntakeException('两个文件同名，无法区分，请改名后再分享');
    }

    _checkExtension(leftName);
    _checkExtension(rightName);
    await _checkSizeAndContent(rawLeft, leftName);
    await _checkSizeAndContent(rawRight, rightName);

    final session = await _newSessionDir();
    final leftCopy = p.join(session.path, leftName);
    final rightCopy = p.join(session.path, rightName);

    try {
      await File(rawLeft).copy(leftCopy);
      await File(rawRight).copy(rightCopy);
    } catch (e) {
      await cleanupSession(session.path);
      throw ShareIntakeException('复制分享文件失败：$e');
    }

    final parsed = await compute(
      _parsePairInWorker,
      (leftPath: leftCopy, rightPath: rightCopy),
    );

    return ShareIntakePayload(
      leftText: parsed.leftText,
      rightText: parsed.rightText,
      leftName: parsed.leftName,
      rightName: parsed.rightName,
      leftEncoding: parsed.leftEncoding,
      rightEncoding: parsed.rightEncoding,
      leftTempPath: leftCopy,
      rightTempPath: rightCopy,
      sessionDir: session.path,
    );
  }

  void _checkExtension(String name) {
    final ext = p.extension(name).toLowerCase();
    if (_binaryExtensions.contains(ext)) {
      final label = ext.isEmpty ? '该文件' : ext.substring(1).toUpperCase();
      throw ShareIntakeException(
        '$label 不是文本文件，只支持 .txt / .md / .log 等文本类型',
      );
    }
  }

  Future<void> _checkSizeAndContent(String path, String name) async {
    final file = File(path);
    final length = await file.length();
    if (length > maxBytes) {
      throw ShareIntakeException(
        '$name 有 ${_fmtSize(length)}，超过 ${_fmtSize(maxBytes)} 上限',
      );
    }
    if (length == 0) {
      throw ShareIntakeException('$name 是空文件');
    }

    final raf = await file.open();
    try {
      final head = await raf.read(8192);
      if (!_looksLikeText(head)) {
        throw ShareIntakeException('$name 不是文本文件，已拒绝对比');
      }
    } finally {
      await raf.close();
    }
  }

  static bool _looksLikeText(Uint8List bytes) {
    if (bytes.length >= 2) {
      final b0 = bytes[0];
      final b1 = bytes[1];
      final utf16 = (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF);
      if (utf16) return true;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) return false;
    }
    return true;
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  // ==================== 缓存目录 ====================

  static Future<Directory> _sessionsRoot() async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'share_compare'));
  }

  static Future<Directory> _newSessionDir() async {
    final root = await _sessionsRoot();
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final dir = Directory(
      p.join(root.path, DateTime.now().millisecondsSinceEpoch.toString()),
    );
    await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _cleanupOldSessions() async {
    try {
      final root = await _sessionsRoot();
      if (!await root.exists()) return;
      final now = DateTime.now();
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > _maxCacheAge) {
            await entity.delete(recursive: true);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 对比页退出后删掉本次会话的临时文件。
  static Future<void> cleanupSession(String? dir) async {
    if (dir == null || dir.isEmpty) return;
    try {
      final d = Directory(dir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

class _ShareItem {
  const _ShareItem({required this.path, required this.name});

  final String path;
  final String name;
}

({String leftText, String rightText, String leftName, String rightName,
    String leftEncoding, String rightEncoding}) _parsePairInWorker(
  ({String leftPath, String rightPath}) paths,
) {
  final leftBytes = File(paths.leftPath).readAsBytesSync();
  final rightBytes = File(paths.rightPath).readAsBytesSync();

  final left = DocumentParser.parse(
    fileName: p.basename(paths.leftPath),
    bytes: leftBytes,
  );
  final right = DocumentParser.parse(
    fileName: p.basename(paths.rightPath),
    bytes: rightBytes,
  );

  return (
    leftText: left.plainText,
    rightText: right.plainText,
    leftName: left.fileName,
    rightName: right.fileName,
    leftEncoding: left.encoding.label,
    rightEncoding: right.encoding.label,
  );
}

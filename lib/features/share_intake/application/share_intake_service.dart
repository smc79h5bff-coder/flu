import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../parser/application/document_parser.dart';
import '../../preprocessing/domain/encoding_type.dart';

/// 分享进来的两个文件解析完成后的结果（全部在内存里，可直接灌进 provider）。
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
class ShareIntakeCoordinator {
  ShareIntakeCoordinator._();

  static final ShareIntakeCoordinator instance = ShareIntakeCoordinator._();

  /// 单文件上限 5MB（文本对比再大首屏会明显卡）。
  static const int maxBytes = 5 * 1024 * 1024;

  /// 分享可能分好几帧投递，聚合一小段时间再判定数量，避免误报。
  static const Duration _aggregateWindow = Duration(milliseconds: 500);

  static const Duration _maxCacheAge = Duration(days: 3);

  /// 明确是二进制的后缀：直接拒绝，省得读文件。
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
  final List<SharedMediaFile> _buffer = <SharedMediaFile>[];
  StreamSubscription<List<SharedMediaFile>>? _subscription;

  Future<void> Function(ShareIntakePayload)? _onReady;
  Future<void> Function(String)? _onRejected;

  /// 防重复投递：记录上一批文件的路径签名。
  String? _lastSignature;
  DateTime? _lastSignatureAt;

  /// 启动监听。必须在 MaterialApp 之内、权限门之外调用。
  Future<void> start({
    required Future<void> Function(ShareIntakePayload) onReady,
    required Future<void> Function(String) onRejected,
  }) async {
    if (!Platform.isAndroid || _started) return;
    _started = true;
    _onReady = onReady;
    _onRejected = onRejected;

    // 不阻塞启动；失败了也不影响主流程。
    unawaited(cleanupOldSessions());

    try {
      _subscription = ReceiveSharingIntent.instance.getMediaStream().listen(
        _onBatch,
        onError: (Object e) {
          unawaited(_reject('读取分享内容失败：$e'));
        },
      );
      final initial =
          await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isNotEmpty) _onBatch(initial);
    } catch (e) {
      // 插件不可用（例如非 Android 宿主）时静默忽略。
    }
  }

  void _onBatch(List<SharedMediaFile> batch) {
    if (batch.isEmpty) return;
    // 冷启动时 getInitialMedia 和 stream 可能把同一批文件各投一次，按路径去重。
    for (final f in batch) {
      if (_buffer.any((e) => e.path == f.path)) continue;
      _buffer.add(f);
    }
    _aggregateTimer?.cancel();
    _aggregateTimer = Timer(_aggregateWindow, () => unawaited(_drain()));
  }

  Future<void> _drain() async {
    if (_busy) {
      // 正在处理上一批（比如确认弹窗/解析中），稍后再试，别丢文件。
      _aggregateTimer?.cancel();
      _aggregateTimer =
          Timer(const Duration(milliseconds: 300), () => unawaited(_drain()));
      return;
    }
    final files = List<SharedMediaFile>.of(_buffer);
    _buffer.clear();
    if (files.isEmpty) return;

    _busy = true;
    try {
      // 同一批文件可能被 stream 和 initial 各投一次；10 秒内同签名直接忽略。
      final signature = (files.map((f) => f.path).toList()..sort()).join('|');
      final now = DateTime.now();
      final lastAt = _lastSignatureAt;
      if (signature == _lastSignature &&
          lastAt != null &&
          now.difference(lastAt) < const Duration(seconds: 10)) {
        return;
      }

      // 消费掉初始数据，否则从后台回到前台会重复触发。
      ReceiveSharingIntent.instance.reset();
      final payload = await _buildPayload(files);
      // 只有真正处理成功才记账，避免用户改名重发被当成重复投递。
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

  Future<ShareIntakePayload> _buildPayload(
      List<SharedMediaFile> files) async {
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
    if (rawLeft.isEmpty || rawRight.isEmpty) {
      throw const ShareIntakeException('没能读取到分享的文件，请重试');
    }

    // 系统/插件会按显示名先落到缓存里，同名会互相覆盖 —— 先挡住。
    if (rawLeft == rawRight) {
      throw const ShareIntakeException('两个文件同名，无法区分，请改名后再分享');
    }

    final leftName = p.basename(rawLeft);
    final rightName = p.basename(rawRight);
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

    // 插件把内容落到了 App 缓存里；已经复制到自己目录后，原副本可以立刻删掉，
    // 否则同名分享会互相覆盖、缓存越积越多。只删缓存内的文件，绝不动用户真实文件。
    await _deleteSourceCopyIfInCache(rawLeft);
    await _deleteSourceCopyIfInCache(rawRight);

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

  /// 内容嗅探：UTF-16 BOM 放行；其余出现 0x00 判为二进制。
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

  /// 清理超过 3 天的分享缓存（只动自己的子目录）。
  static Future<void> cleanupOldSessions() async {
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

  /// 只删除位于 App 缓存目录里的分享副本；
  /// 某些 App 会直接给 file:// 真实路径，那种绝不能删。
  static Future<void> _deleteSourceCopyIfInCache(String path) async {
    try {
      final tmp = await getTemporaryDirectory();
      final root = p.normalize(tmp.path);
      final target = p.normalize(path);
      if (!p.isWithin(root, target)) return;
      if (p.isWithin(p.join(root, 'share_compare'), target)) return;
      await File(target).delete();
    } catch (_) {}
  }
}

/// isolate 里跑完整解析（读字节 + 编码检测 + 拆段）。
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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// 编辑保存的结果。
class EditSaveResult {
  const EditSaveResult({required this.savedPath, this.backupPath});

  final String savedPath;

  /// 自动生成的 `.bak` 备份路径；若原文件不存在则无备份。
  final String? backupPath;
}

/// 编辑保存服务。
///
/// - 若 [targetPath] 非空且存在，则先写 `<path>.bak`（已存在则加时间戳）生成
///   自动备份，再用 UTF-8 覆盖原文件。
/// - 若 [targetPath] 为空（导入时拿不到真实路径），走 [saveAs] 让用户另存。
class EditSaver {
  const EditSaver();

  /// 覆盖原文件 + 自动 .bak 备份。返回实际保存路径与备份路径。
  Future<EditSaveResult> saveOverwrite(String targetPath, String newText) async {
    final file = File(targetPath);
    String? backupPath;
    if (await file.exists()) {
      final bak = _uniqueBackupPath(targetPath);
      await File(bak).writeAsString(await file.readAsString(), flush: true);
      backupPath = bak;
    }
    await file.writeAsBytes(_encode(newText), flush: true);
    return EditSaveResult(savedPath: targetPath, backupPath: backupPath);
  }

  /// 用户选择位置另存。取消返回 null。
  Future<EditSaveResult?> saveAs(String newText, {String fileName = 'docdiff.txt'}) async {
    final friendly = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final out = await FilePicker.saveFile(
      fileName: friendly,
      bytes: _encode(newText),
      mimeType: 'text/plain',
      dialogTitle: '保存编辑结果',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (out == null) return null;
    return EditSaveResult(savedPath: out.toString());
  }

  /// 若 `.bak` 已存在则生成带时间戳的 `.bak`。
  String _uniqueBackupPath(String targetPath) {
    final base = '$targetPath.bak';
    if (!File(base).existsSync()) return base;
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${targetPath}_$ts.bak';
  }

  Uint8List _encode(String text) => Uint8List.fromList(utf8.encode(text));
}
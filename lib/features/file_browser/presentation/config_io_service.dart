import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置导入导出。
///
/// 导出：把 SharedPreferences 里所有 key（除跳过清单）写成 JSON，
///       让用户选位置保存。
/// 导入：让用户选 JSON 文件，读取后覆盖写入 SharedPreferences。
///       导入后需要用户手动重启 App 才生效。
class ConfigIoService {
  ConfigIoService._();
  static final ConfigIoService instance = ConfigIoService._();

  /// JSON 结构版本号。未来结构改了升这个数字。
  static const int _formatVersion = 1;

  /// 永远不导出、不导入的 key。
  ///
  /// 分三类：
  ///   1. 设备 / 路径相关（换设备没意义）
  ///   2. 历史记录（跟当前文档相关，换设备没意义）
  ///   3. 按钮颜色（有意跳过，避免 key 名不一致引发的问题）
  static const Set<String> _skipKeys = {
    'jianming.browser.lastPath',
    'jianming.browser.favorites',
    'jianming.browser.searchFolders',
    'jianming.browser.searchScope',
    'jianming.browser.sortField',
    'jianming.browser.recentMoveTargets',
    'jianming.browser.sortAsc',
    'jianming.viewer.findHistory',
    'jianming.browser.searchHistory',
    'jianming.toolbar.colors',
  };

  /// 导出配置。返回 true 表示保存成功，false 表示用户取消。
  Future<bool> export() async {
    final prefs = await SharedPreferences.getInstance();
    final data = <String, String>{};
    for (final k in prefs.getKeys()) {
      if (_skipKeys.contains(k)) continue;
      final v = prefs.get(k);
      if (v == null) continue;
      data[k] = v.toString();
    }

    final payload = <String, dynamic>{
      'version': _formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': data,
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(payload);
    final bytes = Uint8List.fromList(utf8.encode(jsonStr));

    final out = await FilePicker.saveFile(
      fileName:
          'docdiff-config-${DateTime.now().millisecondsSinceEpoch}.json',
      bytes: bytes,
      mimeType: 'application/json',
      dialogTitle: '保存配置',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    return out != null;
  }

  /// 导入配置。
  ///
  /// 返回值：
  ///   - (ok: true,  message: null)  导入成功
  ///   - (ok: false, message: null)  用户取消
  ///   - (ok: false, message: "...") 导入失败，附带错误信息
  Future<({bool ok, String? message})> import() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选择配置文件',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked.isEmpty) {
      return (ok: false, message: null);
    }

    final file = picked.single;
    final path = file.path;
    if (path == null) {
      return (ok: false, message: '无法读取文件');
    }

    try {
      final bytes = await File(path).readAsBytes();
      final jsonStr = utf8.decode(bytes);
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) {
        return (ok: false, message: '文件格式不对，请选择本 App 导出的配置文件');
      }

      final version = decoded['version'];
      if (version is! int) {
        return (ok: false, message: '文件格式不对，请选择本 App 导出的配置文件');
      }
      if (version > _formatVersion) {
        return (ok: false, message: '配置文件来自更新版本的 App，无法导入');
      }

      final rawData = decoded['data'];
      if (rawData is! Map) {
        return (ok: false, message: '配置文件已损坏');
      }

      final prefs = await SharedPreferences.getInstance();
      // 只覆盖策略：遍历 data 逐条写。不清空旧 key。
      for (final entry in rawData.entries) {
        final k = entry.key.toString();
        if (_skipKeys.contains(k)) continue;
        final v = entry.value;
        if (v == null) continue;
        await prefs.setString(k, v.toString());
      }
      return (ok: true, message: null);
    } catch (e) {
      return (ok: false, message: '导入失败：$e');
    }
  }
}

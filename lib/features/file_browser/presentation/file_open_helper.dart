import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

/// 非文本非压缩包文件：让用户选「打开方式」还是「分享」。
Future<void> showOpenOrShareSheet(
  BuildContext context,
  String path,
  String name,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.insert_drive_file_outlined, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('用其他 App 打开'),
            subtitle: const Text(
              '把这个文件交给能处理它的 App',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => Navigator.pop(c, 'open'),
          ),
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('分享到其他 App'),
            subtitle: const Text(
              '发给别人 / 上传到网盘 / 存到别处',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => Navigator.pop(c, 'share'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('取消'),
            onTap: () => Navigator.pop(c),
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );

  if (!context.mounted) return;

  if (action == 'open') {
    await _openWith(path, context);
  } else if (action == 'share') {
    await _shareFiles([path], context);
  }
}

/// zip / tar 文件：三选一。
/// 返回 'open' / 'share' / 'expand' / null。
Future<String?> showOpenOrShareOrExpandSheet(
  BuildContext context,
  String path,
  String name,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.folder_zip, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.unfold_more),
            title: const Text('一键展开'),
            subtitle: const Text(
              '在列表里展开压缩包内容，可直接浏览',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => Navigator.pop(c, 'expand'),
          ),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('用其他 App 打开'),
            subtitle: const Text(
              '交给能处理压缩包的 App',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => Navigator.pop(c, 'open'),
          ),
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('分享到其他 App'),
            subtitle: const Text(
              '把压缩包本身发给别人',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () => Navigator.pop(c, 'share'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('取消'),
            onTap: () => Navigator.pop(c),
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );

  if (!context.mounted) return null;
  if (action == 'open') {
    await _openWith(path, context);
    return 'open';
  }
  if (action == 'share') {
    await _shareFiles([path], context);
    return 'share';
  }
  return action; // 'expand' 或 null
}

Future<void> _openWith(String path, BuildContext context) async {
  try {
    final result = await OpenFilex.open(
      path,
      type: 'application/octet-stream',
    );
    if (result.type == ResultType.done) return;
    if (!context.mounted) return;
    final msg = switch (result.type) {
      ResultType.noAppToOpen => '手机里没有能打开这种格式的 App',
      ResultType.fileNotFound => '文件不存在或已被删除',
      ResultType.permissionDenied => '没有权限访问这个文件',
      _ => '打开失败：${result.message}',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('打开失败：$e')),
    );
  }
}

Future<void> _shareFiles(List<String> paths, BuildContext context) async {
  if (paths.isEmpty) return;
  try {
    final files = paths.map((p) => XFile(p)).toList();
    final text = paths.length == 1 ? paths.first.split('/').last : null;
    await Share.shareXFiles(files, text: text);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('分享失败：$e')),
    );
  }
}

Future<void> shareMany(List<String> paths, BuildContext context) async {
  await _shareFiles(paths, context);
}

/// 直接用系统 App 选择器打开。跳过"打开方式 / 分享"两选一菜单。
Future<void> openFileWithSystemPicker(
  String path,
  BuildContext context,
) async {
  await _openWith(path, context);
}

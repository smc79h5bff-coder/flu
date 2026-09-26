import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../parser/application/document_parser.dart';
import '../../parser/domain/parsed_document.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../../help/presentation/help_screen.dart';
import '../../rules/presentation/rules_management_screen.dart';
import '../../viewer/presentation/diff_viewer_screen.dart';
import '../../viewer/presentation/providers/diff_viewer_providers.dart';
import 'providers/import_providers.dart';

/// 导入页只显示这 4 条忽略项。
const _importScreenIgnoreIds = {'ig_ws', 'ig_empty', 'ig_nl', 'ig_ansi'};

const _importIgnoreSubtitles = <String, String>{
  'ig_ws': null.toString().isEmpty ? '' : '去掉所有空格和 Tab 后对比',
  'ig_empty': '去掉空白行后对比',
  'ig_nl': r'统一 \r\n / \r / \n 三种换行格式',
  'ig_ansi': '已是 ANSI(GBK) 不处理；非 ANSI 转 ANSI 并删除无法转换的字符',
};

class ImportScreen extends ConsumerWidget {
  const ImportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasOriginal = ref.watch(originalRawTextProvider) != null;
    final hasModified = ref.watch(modifiedRawTextProvider) != null;
    final canStart = hasOriginal && hasModified;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DocDiff'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: '另存备份（原/修改版 + 编码）',
            onPressed: () => _saveBackup(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.rule),
            tooltip: '预处理规则',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RulesManagementScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: '使用说明',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const HelpScreen(),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '选择两份文档开始对比：支持查找、逐行编辑与自动备份、'
                      '三种视图、忽略选项及横屏。右上角 ? 查看完整说明。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _DocSlot(label: '原文档', isOriginal: true),
          const SizedBox(height: 12),
          _DocSlot(label: '修改版文档', isOriginal: false),
          const SizedBox(height: 16),
          const _IgnoreSettings(),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.compare_arrows),
            label: const Text('开始对比'),
            onPressed: canStart ? () => _startCompare(context, ref) : null,
          ),
          const SizedBox(height: 12),
          Text(
            '本地导入支持 TXT / DOCX。点击标签，左右对比其差异。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  void _startCompare(BuildContext context, WidgetRef ref) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const DiffViewerScreen(),
      ),
    );
  }

  Future<void> _saveBackup(BuildContext context, WidgetRef ref) async {
    final original = ref.read(originalRawTextProvider);
    final modified = ref.read(modifiedRawTextProvider);
    if (original == null && modified == null) {
      _showError(context, '还没有可备份的文档，请先导入文件。');
      return;
    }

    final originalEnc = ref.read(originalEncodingProvider);
    final modifiedEnc = ref.read(modifiedEncodingProvider);
    final buf = StringBuffer()
      ..writeln('# DocDiff 备份 #')
      ..writeln('# 时间: ${DateTime.now().toIso8601String()} #')
      ..writeln('## 原文档 (编码: $originalEnc) ##')
      ..writeln(original ?? '')
      ..writeln()
      ..writeln('## 修改版文档 (编码: $modifiedEnc) ##')
      ..writeln(modified ?? '');
    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));

    final uri = await FilePicker.saveFile(
      fileName: 'docdiff-backup-${DateTime.now().millisecondsSinceEpoch}.txt',
      bytes: bytes,
      mimeType: 'text/plain',
      dialogTitle: '另存备份',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (uri != null && context.mounted) {
      _showError(context, '备份已保存。');
    }
  }

  void _showError(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }
}

class _DocSlot extends ConsumerWidget {
  const _DocSlot({required this.label, required this.isOriginal});

  final String label;
  final bool isOriginal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(isOriginal
        ? originalRawTextProvider
        : modifiedRawTextProvider);
    final encoding = ref.watch(isOriginal
        ? originalEncodingProvider
        : modifiedEncodingProvider);
    final fileName = ref.watch(isOriginal
        ? originalFileNameProvider
        : modifiedFileNameProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: Theme.of(context).textTheme.titleMedium),
                      if (fileName != null && fileName.isNotEmpty)
                        Text(
                          fileName,
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (text != null)
                  TextButton(
                    onPressed: () => _clear(ref),
                    child: const Text('清除'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (text == null)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.upload_file),
                      label: const Text('本地文件'),
                      onPressed: () => _pickFile(context, ref),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.content_paste),
                      label: const Text('粘贴文本'),
                      onPressed: () => _paste(context, ref),
                    ),
                  ),
                ],
              )
            else
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${text.length} 字符 · $encoding',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      text.length > 200
                          ? '${text.substring(0, 200)}…'
                          : text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile(BuildContext context, WidgetRef ref) async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;

    final picked = files.single;
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final bytes = await picked.readAsBytes();
      final result = await compute(
        _parseInWorker,
        (fileName: picked.name, bytes: bytes),
      );
      _store(
        ref,
        text: result.plainText,
        encoding: result.encoding.label,
        fileName: result.fileName,
        filePath: picked.path,
      );
    } catch (e) {
      _showError(context, '导入失败：$e');
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<void> _paste(BuildContext context, WidgetRef ref) async {
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text;
    } catch (_) {
      text = null;
    }
    if (text == null || text.trim().isEmpty) {
      _showError(context, '剪贴板没有可粘贴的文本，请先复制内容再试。');
      return;
    }
    _store(
      ref,
      text: text,
      encoding: 'UTF-8',
      fileName: '剪贴板文本',
    );
    _showError(context, '已从剪贴板导入该份文档。');
  }

  void _store(
    WidgetRef ref, {
    required String text,
    required String encoding,
    required String fileName,
    String? filePath,
  }) {
    if (isOriginal) {
      ref.read(originalRawTextProvider.notifier).state = text;
      ref.read(originalEncodingProvider.notifier).state = encoding;
      ref.read(originalFileNameProvider.notifier).state = fileName;
      ref.read(originalFilePathProvider.notifier).state = filePath;
    } else {
      ref.read(modifiedRawTextProvider.notifier).state = text;
      ref.read(modifiedEncodingProvider.notifier).state = encoding;
      ref.read(modifiedFileNameProvider.notifier).state = fileName;
      ref.read(modifiedFilePathProvider.notifier).state = filePath;
    }
    ref.read(importRevisionProvider.notifier).state++;
  }

  void _clear(WidgetRef ref) {
    if (isOriginal) {
      ref.read(originalRawTextProvider.notifier).state = null;
      ref.read(originalEncodingProvider.notifier).state = 'UTF-8';
      ref.read(originalFileNameProvider.notifier).state = null;
      ref.read(originalFilePathProvider.notifier).state = null;
    } else {
      ref.read(modifiedRawTextProvider.notifier).state = null;
      ref.read(modifiedEncodingProvider.notifier).state = 'UTF-8';
      ref.read(modifiedFileNameProvider.notifier).state = null;
      ref.read(modifiedFilePathProvider.notifier).state = null;
    }
  }

  void _showError(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }
}

ParsedDocument _parseInWorker(
    ({String fileName, Uint8List bytes}) input) {
  return DocumentParser.parse(
    fileName: input.fileName,
    bytes: input.bytes,
  );
}

class _IgnoreSettings extends ConsumerWidget {
  const _IgnoreSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ignoreEnables = ref.watch(ignoreRuleEnablesProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  '比较设置',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            for (final r in defaultIgnoreRules())
              if (_importScreenIgnoreIds.contains(r.id))
                _IgnoreSwitch(
                  title: r.name,
                  subtitle: _importIgnoreSubtitles[r.id],
                  value: ignoreEnables[r.id] ?? r.enabled,
                  onChanged: (v) => ref
                      .read(ignoreRuleEnablesProvider.notifier)
                      .setOne(r.id, v),
                ),
          ],
        ),
      ),
    );
  }
}

class _IgnoreSwitch extends StatelessWidget {
  const _IgnoreSwitch({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!,
              style: Theme.of(context).textTheme.labelSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
      value: value,
      onChanged: onChanged,
    );
  }
}

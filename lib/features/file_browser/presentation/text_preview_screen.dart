import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';

/// 纯文本预览页。点击文件浏览器里的文本文件进入。
/// 只支持文本类扩展名；其它文件显示"暂不支持预览"。
/// 超过 100KB 只读前 100KB，末尾提示已截断。
class TextPreviewScreen extends StatefulWidget {
  const TextPreviewScreen({
    super.key,
    required this.filePath,
    required this.fileName,
  });

  final String filePath;
  final String fileName;

  @override
  State<TextPreviewScreen> createState() => _TextPreviewScreenState();
}

class _TextPreviewScreenState extends State<TextPreviewScreen> {
  static const int _maxBytes = 100 * 1024;

  /// 支持的文本扩展名。不在列表里的文件显示"暂不支持预览"。
  static const Set<String> _textExts = {
    '.txt', '.md', '.markdown', '.log', '.lst', '.diz', '.nfo',
    '.json', '.xml', '.yaml', '.yml', '.toml', '.ini', '.conf', '.cfg',
    '.csv', '.tsv',
    '.sh', '.bash', '.zsh', '.bat', '.cmd', '.ps1',
    '.py', '.js', '.ts', '.java', '.kt', '.dart', '.c', '.cpp', '.cc',
    '.h', '.hpp', '.cs', '.go', '.rs', '.rb', '.php', '.lua', '.smali',
    '.html', '.htm', '.css', '.scss',
    '.diff', '.patch',
  };

  bool _loading = true;
  String? _text;
  String? _error;
  bool _truncated = false;
  String _encodingLabel = '';
  int _totalBytes = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isSupportedExt {
    final lower = widget.fileName.toLowerCase();
    for (final ext in _textExts) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  Future<void> _load() async {
    if (!_isSupportedExt) {
      setState(() {
        _loading = false;
        _error = '暂不支持预览此类型文件';
      });
      return;
    }

    try {
      final file = File(widget.filePath);
      final length = await file.length();
      _totalBytes = length;

      final toRead = length > _maxBytes ? _maxBytes : length;
      _truncated = length > _maxBytes;

      // 流式读前 toRead 字节，避免大文件一次性读入内存。
      final chunks = <int>[];
      await for (final chunk in file.openRead(0, toRead)) {
        chunks.addAll(chunk);
      }
      final bytes = Uint8List.fromList(chunks);

      final encoding = EncodingDetector.detect(bytes);
      final text = EncodingDetector.decodeChunked(bytes, encoding);

      if (!mounted) return;
      setState(() {
        _text = text;
        _encodingLabel = encoding.label;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
  title: Text(
    widget.fileName,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  ),
  actions: [
    if (_truncated)
      IconButton(
        icon: const Icon(Icons.edit),
        tooltip: '编辑全文',
        onPressed: () {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => SingleFileEditorScreen(
                filePath: widget.filePath,
                fileName: widget.fileName,
              ),
            ),
          );
        },
      ),
  ],
),
      
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.info_outline, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    final text = _text ?? '';
    final s = Theme.of(context).colorScheme;

    return Column(
      children: [
        // 文件信息条
        Container(
          width: double.infinity,
          color: s.surfaceVariant.withOpacity(0.4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            '$_encodingLabel · ${_fmtSize(_totalBytes)}'
            '${_truncated ? ' · 已截断，仅显示前 100 KB' : ''}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              text.isEmpty ? '(空文件)' : text,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

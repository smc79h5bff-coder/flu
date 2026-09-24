import 'dart:io';

import 'package:flutter/material.dart';

/// 选中两个文件后弹出的“角色确认”面板。
/// 用户指定哪个是原文件、哪个是修改版。
/// 返回 (originalPath, modifiedPath)，取消返回 null。
class RoleConfirmDialog extends StatefulWidget {
  const RoleConfirmDialog({
    super.key,
    required this.fileA,
    required this.fileB,
  });

  final File fileA;
  final File fileB;

  @override
  State<RoleConfirmDialog> createState() => _RoleConfirmDialogState();
}

class _RoleConfirmDialogState extends State<RoleConfirmDialog> {
  /// true = fileA 是原文件；false = fileB 是原文件。
  bool _aIsOriginal = true;

  String _name(File f) => f.path.split('/').last;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final original = _aIsOriginal ? widget.fileA : widget.fileB;
    final modified = _aIsOriginal ? widget.fileB : widget.fileA;

    return AlertDialog(
      title: const Text('确认对比角色'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _slot(
            context,
            label: '原文件',
            name: _name(original),
            color: s.error,
          ),
          const SizedBox(height: 12),
          _slot(
            context,
            label: '修改版',
            name: _name(modified),
            color: s.primary,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.swap_horiz),
            label: const Text('交换'),
            onPressed: () => setState(() => _aIsOriginal = !_aIsOriginal),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _aIsOriginal
                ? (original: widget.fileA, modified: widget.fileB)
                : (original: widget.fileB, modified: widget.fileA),
          ),
          child: const Text('开始对比'),
        ),
      ],
    );
  }

  Widget _slot(
    BuildContext context, {
    required String label,
    required String name,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        border: Border(left: BorderSide(color: color, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

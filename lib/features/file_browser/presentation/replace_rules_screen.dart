import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';

/// 关键词 / 正则 替换规则的编辑器页。
///
/// 两种模式共用一套 UI，只是 provider 和提示文字不同：
///   - 关键词规则：普通文字匹配，特殊字符自动转义
///   - 正则规则：每行是正则表达式
///
/// 每行一条，格式：
///   xxx              删除 xxx
///   xxx->=>yyy       把 xxx 换成 yyy
class ReplaceRulesScreen extends ConsumerStatefulWidget {
  const ReplaceRulesScreen({required this.isRegex, super.key});

  /// false = 关键词规则；true = 正则规则。
  final bool isRegex;

  @override
  ConsumerState<ReplaceRulesScreen> createState() =>
      _ReplaceRulesScreenState();
}

class _ReplaceRulesScreenState extends ConsumerState<ReplaceRulesScreen> {
  late final TextEditingController _ctrl;
  bool _dirty = false;

  String get _title => widget.isRegex ? '正则规则' : '关键词规则';

  StateProvider<String> get _provider =>
      widget.isRegex ? regexRulesTextProvider : keywordRulesTextProvider;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(_provider));
    _ctrl.addListener(() {
      if (!_dirty) setState(() => _dirty = true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    ref.read(_provider.notifier).state = _ctrl.text;
    setState(() => _dirty = false);
    ref.read(importRevisionProvider.notifier).state++;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$_title 已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final lineCount =
        _ctrl.text.isEmpty ? 0 : _ctrl.text.split('\n').length;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('放弃修改？'),
            content: const Text('还有未保存的修改，返回将丢失。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('放弃'),
              ),
            ],
          ),
        );
        if (ok == true && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title),
          actions: [
            TextButton.icon(
              onPressed: _dirty ? _save : null,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('保存'),
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: s.surfaceVariant.withOpacity(0.4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                widget.isRegex
                    ? '每行一条正则。用 ->=> 分隔“匹配”和“替换”：\n'
                        r'  \d+->=>数字      把连续数字换成“数字”' '\n'
                        r'  \d+              删除连续数字' '\n'
                        '  非法正则会被跳过，不影响其它行。'
                    : '每行一条。用 ->=> 分隔“匹配”和“替换”：\n'
                        '  xx小说网->=>起点      把“xx小说网”换成“起点”\n'
                        '  xx小说网             删除“xx小说网”\n'
                        '  特殊字符（. * + ? 等）按普通文字处理。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: s.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: TextField(
                  controller: _ctrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    hintText: '每行一条规则…',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(8),
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              color: s.surface,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                '共 $lineCount 行${_dirty ? " · 未保存" : ""}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

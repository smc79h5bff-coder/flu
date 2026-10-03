import 'package:flutter/material.dart';

/// "选择行范围"弹窗的返回结果。
/// start / end 都是 1-based 行号，action 是 'copy' / 'cut' / 'delete'。
typedef LineRangeResult = ({int start, int end, String action});

/// 选择行范围弹窗。
///
/// 输入：全部行内容 + 用户点击时的起点 / 终点行号。
/// 用户可以在弹窗里：
///   · 修改起点 / 终点行号（输入框），点刷新按钮或按回车生效
///   · 看到起点 / 终点附近各 5 行预览（相距 < 10 行时合并成一个预览）
///   · 选一个操作：复制 / 剪切 / 删除
///   · 取消
///
/// 返回：LineRangeResult（用户选了操作）或 null（用户取消）。
class LineRangeSelectorDialog extends StatefulWidget {
  const LineRangeSelectorDialog({
    super.key,
    required this.lines,
    required this.initialStart,
    required this.initialEnd,
  });

  final List<String> lines;
  final int initialStart; // 1-based
  final int initialEnd; // 1-based

  @override
  State<LineRangeSelectorDialog> createState() =>
      _LineRangeSelectorDialogState();
}

class _LineRangeSelectorDialogState extends State<LineRangeSelectorDialog> {
  late final TextEditingController _startCtrl;
  late final TextEditingController _endCtrl;

  /// 当前生效的起止行号（1-based），已经 clamp 过。
  late int _start;
  late int _end;

  /// 用户输入了但还没点刷新的标记。
  bool _dirty = false;

  /// 输入超范围的提示文本（null = 无提示）。
  String? _rangeError;

  int get _total => widget.lines.length;

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart.clamp(1, _total);
    _end = widget.initialEnd.clamp(1, _total);
    if (_start > _end) {
      final t = _start;
      _start = _end;
      _end = t;
    }
    _startCtrl = TextEditingController(text: _start.toString());
    _endCtrl = TextEditingController(text: _end.toString());
    _startCtrl.addListener(_onInputChanged);
    _endCtrl.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _startCtrl.removeListener(_onInputChanged);
    _endCtrl.removeListener(_onInputChanged);
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    if (!_dirty) {
      setState(() => _dirty = true);
    }
  }

  /// 读输入框，clamp，自动交换，更新 _start / _end。
  void _applyInput() {
    final rawStart = int.tryParse(_startCtrl.text.trim()) ?? _start;
    final rawEnd = int.tryParse(_endCtrl.text.trim()) ?? _end;
    final outOfRange = rawStart < 1 ||
        rawStart > _total ||
        rawEnd < 1 ||
        rawEnd > _total;

    var s = rawStart.clamp(1, _total);
    var e = rawEnd.clamp(1, _total);
    if (s > e) {
      final t = s;
      s = e;
      e = t;
    }

    // 回填输入框（因为 clamp 或交换可能改了值）。
    // 临时摘掉 listener 避免触发 setState 循环。
    _startCtrl.removeListener(_onInputChanged);
    _endCtrl.removeListener(_onInputChanged);
    _startCtrl.text = s.toString();
    _endCtrl.text = e.toString();
    _startCtrl.selection =
        TextSelection.collapsed(offset: _startCtrl.text.length);
    _endCtrl.selection =
        TextSelection.collapsed(offset: _endCtrl.text.length);
    _startCtrl.addListener(_onInputChanged);
    _endCtrl.addListener(_onInputChanged);

    setState(() {
      _start = s;
      _end = e;
      _dirty = false;
      _rangeError = outOfRange
          ? '输入超出范围（本文件共 $_total 行），已调整到有效值'
          : null;
    });
  }

  /// 点操作按钮前，若用户改了输入框但没点刷新，先应用一次。
  void _ensureApplied() {
    if (_dirty) _applyInput();
  }

  /// 起点终点相距 < 10 行时合并预览。
  bool get _merged => _end - _start < 10;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(8),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      title: const Text('选择行范围'),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- 输入行 ----------
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _startCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '起点',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                    ),
                    onSubmitted: (_) => _applyInput(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _endCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '终点',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                    ),
                    onSubmitted: (_) => _applyInput(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '刷新预览',
                  icon: const Icon(Icons.refresh),
                  onPressed: _applyInput,
                ),
              ],
            ),

            // ---------- 错误提示 ----------
            if (_rangeError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _rangeError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // ---------- 预览区 ----------
            Expanded(child: _buildPreview(s)),

            const SizedBox(height: 8),
            const Divider(height: 1),

            // ---------- 统计 ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                '共 ${_end - _start + 1} 行（本文件共 $_total 行）',
                style: TextStyle(fontSize: 12, color: s.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => _submit('copy'),
          child: const Text('复制'),
        ),
        TextButton(
          onPressed: () => _submit('cut'),
          child: const Text('剪切'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          onPressed: () => _submit('delete'),
          child: const Text('删除'),
        ),
      ],
    );
  }

  void _submit(String action) {
    _ensureApplied();
    Navigator.pop(
      context,
      (start: _start, end: _end, action: action),
    );
  }

  /// 预览区。
  /// · 合并模式：从 max(1, start-2) 到 min(total, end+2)，起点/终点行加标记。
  /// · 分开模式：两段，各显示起点 / 终点附近的 5 行。
  Widget _buildPreview(ColorScheme s) {
    if (_merged) {
      return _previewBlock(
        title: '预览',
        from: (_start - 2).clamp(1, _total),
        to: (_end + 2).clamp(1, _total),
        s: s,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _previewBlock(
            title: '起点预览',
            from: (_start - 2).clamp(1, _total),
            to: (_start + 2).clamp(1, _total),
            s: s,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _previewBlock(
            title: '终点预览',
            from: (_end - 2).clamp(1, _total),
            to: (_end + 2).clamp(1, _total),
            s: s,
          ),
        ),
      ],
    );
  }

  Widget _previewBlock({
    required String title,
    required int from,
    required int to,
    required ColorScheme s,
  }) {
    final rows = <Widget>[];
    for (var i = from; i <= to; i++) {
      final lineText = widget.lines[i - 1];
      final isStart = i == _start;
      final isEnd = i == _end;
      final inRange = i >= _start && i <= _end;

      Color? bg;
      Color? leftBar;
      if (isStart) {
        bg = Colors.blue.withValues(alpha: 0.10);
        leftBar = Colors.blue;
      } else if (isEnd) {
        bg = Colors.blue.withValues(alpha: 0.10);
        leftBar = Colors.orange;
      } else if (inRange) {
        bg = Colors.blue.withValues(alpha: 0.06);
      }

      rows.add(
        Container(
          color: bg,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 22,
                color: leftBar ?? Colors.transparent,
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 36,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '$i',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    lineText.isEmpty ? '（空行）' : lineText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: s.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: s.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

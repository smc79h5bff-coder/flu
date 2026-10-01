import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../file_browser/presentation/single_file_editor_screen.dart';
import 'reader_models.dart';
import 'reader_pagination.dart';
import 'reader_repository.dart';
import 'reader_screen.dart';

// ==================== 设置面板 ====================

Future<void> showReaderSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _ReaderSettingsSheet(),
  );
}

class _ReaderSettingsSheet extends ConsumerStatefulWidget {
  const _ReaderSettingsSheet();

  @override
  ConsumerState<_ReaderSettingsSheet> createState() =>
      _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends ConsumerState<_ReaderSettingsSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(readerHotZonePreviewProvider.notifier).state = true;
      }
    });
  }

  @override
  void dispose() {
    ref.read(readerHotZonePreviewProvider.notifier).state = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(readerSettingsProvider);
    final n = ref.read(readerSettingsProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('阅读设置',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                _sliderHeader('字号', s.fontSize.toStringAsFixed(0)),
                Row(
                  children: [
                    const Text('4', style: TextStyle(fontSize: 11)),
                    Expanded(
                      child: Slider(
                        min: 4,
                        max: 60,
                        value: s.fontSize.clamp(4, 60),
                        onChanged: n.setFontSize,
                      ),
                    ),
                    const Text('60', style: TextStyle(fontSize: 11)),
                  ],
                ),
                _numberInput(
                  value: s.fontSize.toStringAsFixed(0),
                  onSubmitted: (v) {
                    final d = double.tryParse(v);
                    if (d != null) n.setFontSize(d);
                  },
                ),
                const SizedBox(height: 12),
                _sliderHeader('字重', s.fontWeight.toString()),
                Row(
                  children: [
                    const Text('100', style: TextStyle(fontSize: 11)),
                    Expanded(
                      child: Slider(
                        min: 100,
                        max: 900,
                        divisions: 8,
                        value: s.fontWeight.toDouble().clamp(100, 900),
                        onChanged: (v) => n.setFontWeight(v.round()),
                      ),
                    ),
                    const Text('900', style: TextStyle(fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 12),
                _sliderHeader('背景颜色', ''),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _bgSwatch(
                      color: Color(ReaderSettings.bgCream),
                      label: '米黄',
                      selected: s.bgColor == ReaderSettings.bgCream,
                      onTap: () => n.setBgColor(ReaderSettings.bgCream),
                    ),
                    const SizedBox(width: 12),
                    _bgSwatch(
                      color: Color(ReaderSettings.bgWhite),
                      label: '白色',
                      selected: s.bgColor == ReaderSettings.bgWhite,
                      onTap: () => n.setBgColor(ReaderSettings.bgWhite),
                    ),
                    const SizedBox(width: 12),
                    _bgSwatch(
                      color: Color(ReaderSettings.bgGreen),
                      label: '护眼绿',
                      selected: s.bgColor == ReaderSettings.bgGreen,
                      onTap: () => n.setBgColor(ReaderSettings.bgGreen),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 8),
                _sliderHeader(
                    '顶部菜单热区',
                    '${s.topHotZoneHeight.toStringAsFixed(0)} px'),
                Slider(
                  min: 20,
                  max: 200,
                  value: s.topHotZoneHeight.clamp(20, 200),
                  onChanged: n.setTopHotZone,
                ),
                const Text(
                  '点屏幕顶部这一条（透明）打开菜单。数值越小越难点到，'
                  '越大越容易误触。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('浮动按钮',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Switch(
                      value: s.showButtons,
                      onChanged: (_) => n.toggleButtons(),
                    ),
                  ],
                ),
                if (s.showButtons) ...[
                  const SizedBox(height: 8),
                  const Text('按钮位置预览',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _miniPreview(context, s),
                  const SizedBox(height: 12),
                  _sliderHeader(
                      '按钮透明度',
                      '${(s.buttonOpacity * 100).toStringAsFixed(0)}%'),
                  Slider(
                    min: 0.1,
                    max: 1.0,
                    value: s.buttonOpacity.clamp(0.1, 1.0),
                    onChanged: n.setButtonOpacity,
                  ),
                  _sliderHeader(
                      '按钮大小', '${s.buttonScale.toStringAsFixed(1)}×'),
                  Slider(
                    min: 0.2,
                    max: 10.0,
                    value: s.buttonScale.clamp(0.2, 10.0),
                    onChanged: n.setButtonScale,
                  ),
                  const SizedBox(height: 8),
                  const Text('上按钮位置',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  _sliderHeader(
                      '横向 X', '${(s.topBtnX * 100).toStringAsFixed(0)}%'),
                  Slider(
                    min: 0.0,
                    max: 1.0,
                    value: s.topBtnX.clamp(0.0, 1.0),
                    onChanged: (v) => n.update(
                        ref.read(readerSettingsProvider).copyWith(topBtnX: v)),
                  ),
                  _sliderHeader(
                      '纵向 Y', '${(s.topBtnY * 100).toStringAsFixed(0)}%'),
                  Slider(
                    min: 0.0,
                    max: 1.0,
                    value: s.topBtnY.clamp(0.0, 1.0),
                    onChanged: (v) => n.update(
                        ref.read(readerSettingsProvider).copyWith(topBtnY: v)),
                  ),
                  const SizedBox(height: 8),
                  const Text('下按钮位置',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  _sliderHeader(
                      '横向 X', '${(s.bottomBtnX * 100).toStringAsFixed(0)}%'),
                  Slider(
                    min: 0.0,
                    max: 1.0,
                    value: s.bottomBtnX.clamp(0.0, 1.0),
                    onChanged: (v) => n.update(ref
                        .read(readerSettingsProvider)
                        .copyWith(bottomBtnX: v)),
                  ),
                  _sliderHeader(
                      '纵向 Y', '${(s.bottomBtnY * 100).toStringAsFixed(0)}%'),
                  Slider(
                    min: 0.0,
                    max: 1.0,
                    value: s.bottomBtnY.clamp(0.0, 1.0),
                    onChanged: (v) => n.update(ref
                        .read(readerSettingsProvider)
                        .copyWith(bottomBtnY: v)),
                  ),
                ],
                const SizedBox(height: 20),
                Center(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sliderHeader(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          if (value.isNotEmpty)
            Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue)),
        ],
      ),
    );
  }

  Widget _numberInput({
    required String value,
    required ValueChanged<String> onSubmitted,
  }) {
    return SizedBox(
      width: 80,
      child: TextFormField(
        initialValue: value,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
        onFieldSubmitted: onSubmitted,
      ),
    );
  }

  Widget _bgSwatch({
    required Color color,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              border: Border.all(
                color: selected ? Colors.blue : Colors.black12,
                width: selected ? 3 : 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.blue)
                : null,
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

Widget _miniPreview(BuildContext context, ReaderSettings s) {
  final screenSize = MediaQuery.of(context).size;
  const previewWidth = 180.0;
  final previewHeight = previewWidth * screenSize.height / screenSize.width;

  return Center(
    child: Container(
      width: previewWidth,
      height: previewHeight,
      decoration: BoxDecoration(
        color: Color(s.bgColor),
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(6),
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final scale = w / screenSize.width;
          final btnSize = 50.0 * s.buttonScale * scale;
          final topLeft = Offset(
            s.topBtnX * w - btnSize / 2,
            s.topBtnY * h - btnSize / 2,
          );
          final botLeft = Offset(
            s.bottomBtnX * w - btnSize / 2,
            s.bottomBtnY * h - btnSize / 2,
          );

          Widget dot(Offset pos, IconData icon) {
            return Positioned(
              left: pos.dx,
              top: pos.dy,
              child: Opacity(
                opacity: s.buttonOpacity,
                child: Container(
                  width: btnSize,
                  height: btnSize,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon,
                      color: Colors.white, size: btnSize * 0.6),
                ),
              ),
            );
          }

          return Stack(
            children: [
              dot(topLeft, Icons.keyboard_arrow_up),
              dot(botLeft, Icons.keyboard_arrow_down),
            ],
          );
        },
      ),
    ),
  );
}

// ==================== 查找栏 ====================

Future<void> showReaderFindBar(
  BuildContext context,
  String fileKey,
  String text,
  void Function(int charOffset) onJump,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ReaderFindSheet(
      fileKey: fileKey,
      text: text,
      onJump: onJump,
    ),
  );
}

class _ReaderFindSheet extends ConsumerStatefulWidget {
  const _ReaderFindSheet({
    required this.fileKey,
    required this.text,
    required this.onJump,
  });

  final String fileKey;
  final String text;
  final void Function(int charOffset) onJump;

  @override
  ConsumerState<_ReaderFindSheet> createState() => _ReaderFindSheetState();
}

class _ReaderFindSheetState extends ConsumerState<_ReaderFindSheet> {
  final _ctrl = TextEditingController();
  List<KeywordMatch> _matches = const [];
  int _pos = -1;
  bool _searching = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String word) async {
    if (word.isEmpty) {
      setState(() {
        _matches = const [];
        _pos = -1;
      });
      return;
    }
    setState(() => _searching = true);
    final split = splitLinesWithOffsets(widget.text);
    final matches = findKeyword(
      lines: split.lines,
      lineStarts: split.lineStarts,
      keyword: word,
    );
    if (!mounted) return;
    setState(() {
      _matches = matches;
      _pos = matches.isEmpty ? -1 : 0;
      _searching = false;
    });
    ref.read(readerFindHistoryProvider.notifier).add(word);
    if (matches.isNotEmpty) widget.onJump(matches[0].globalStart);
  }

  void _next() {
    if (_matches.isEmpty) return;
    setState(() => _pos = (_pos + 1) % _matches.length);
    widget.onJump(_matches[_pos].globalStart);
  }

  void _prev() {
    if (_matches.isEmpty) return;
    setState(() => _pos = (_pos - 1 + _matches.length) % _matches.length);
    widget.onJump(_matches[_pos].globalStart);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = ref.read(readerFindHistoryProvider.notifier).sorted();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            12, 12, 12, 12 + MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: '查找…',
                        isDense: true,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.search),
                        suffixText: _matches.isEmpty
                            ? null
                            : '${_pos + 1}/${_matches.length}',
                      ),
                      onSubmitted: _search,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _matches.isEmpty ? null : _prev,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward),
                    onPressed: _matches.isEmpty ? null : _next,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    icon: _searching
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search, size: 16),
                    label: const Text('搜索'),
                    onPressed: _searching
                        ? null
                        : () => _search(_ctrl.text.trim()),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => ref
                        .read(readerFindHistoryProvider.notifier)
                        .clearNonFavorites(),
                    child: const Text('清空非收藏'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(),
              const Text('历史（收藏优先）',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Expanded(
                child: sorted.isEmpty
                    ? const Center(child: Text('还没有搜索记录'))
                    : ListView.builder(
                        itemCount: sorted.length,
                        itemBuilder: (_, i) {
                          final item = sorted[i];
                          return ListTile(
                            dense: true,
                            leading: IconButton(
                              icon: Icon(
                                item.isFavorite
                                    ? Icons.star
                                    : Icons.star_border,
                                color: item.isFavorite
                                    ? Colors.amber
                                    : null,
                              ),
                              onPressed: () => ref
                                  .read(readerFindHistoryProvider.notifier)
                                  .toggleFavorite(item.word),
                            ),
                            title: Text(item.word),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => ref
                                  .read(readerFindHistoryProvider.notifier)
                                  .remove(item.word),
                            ),
                            onTap: () {
                              _ctrl.text = item.word;
                              _search(item.word);
                            },
                          );
                        },
                      ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 色块配置页 ====================

Future<void> openPaletteEdit(BuildContext context, int index) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PaletteEditScreen(paletteIndex: index),
    ),
  );
}

class PaletteEditScreen extends ConsumerStatefulWidget {
  const PaletteEditScreen({super.key, required this.paletteIndex});

  final int paletteIndex;

  @override
  ConsumerState<PaletteEditScreen> createState() => _PaletteEditScreenState();
}

class _PaletteEditScreenState extends ConsumerState<PaletteEditScreen> {
  late String _name;
  late bool _isGradient;
  late Color _color1;
  late Color _color2;
  late Color _textColor;
  String? _defaultGroupId;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final p =
        ref.read(readerPaletteProvider.notifier).byIndex(widget.paletteIndex);
    _name = p.name;
    _isGradient = p.isGradient;
    _color1 = Color(p.colors.first);
    _color2 =
        p.colors.length > 1 ? Color(p.colors[1]) : Color(p.colors.first);
    _textColor = Color(p.textColor);
    _defaultGroupId = p.defaultGroupId;
    _loaded = true;
  }

  void _save() {
    final colors = _isGradient
        ? <int>[_color1.toARGB32(), _color2.toARGB32()]
        : <int>[_color1.toARGB32()];
    final stops = _isGradient ? <double>[0.0, 1.0] : <double>[0.0];
    final updated = HighlightPalette(
      index: widget.paletteIndex,
      name: _name.trim().isEmpty ? '色块 ${widget.paletteIndex + 1}' : _name,
      colors: colors,
      stops: stops,
      angle: 0.0,
      textColor: _textColor.toARGB32(),
      defaultGroupId: _defaultGroupId,
    );
    ref.read(readerPaletteProvider.notifier).updateOne(updated);
    Navigator.pop(context);
  }

  void _resetToDefault() {
    final defaults = HighlightPalette.defaults();
    final d = defaults[widget.paletteIndex];
    setState(() {
      _name = d.name;
      _isGradient = false;
      _color1 = Color(d.colors.first);
      _color2 = Color(d.colors.first);
      _textColor = Color(d.textColor);
      _defaultGroupId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final groups = ref.watch(readerHighlightGroupsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('编辑色块 ${widget.paletteIndex + 1}'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('名称'),
          TextField(
            controller: TextEditingController(text: _name)
              ..selection =
                  TextSelection.collapsed(offset: _name.length),
            onChanged: (v) => _name = v,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('样式：'),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('纯色'),
                selected: !_isGradient,
                onSelected: (_) => setState(() => _isGradient = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('上下渐变'),
                selected: _isGradient,
                onSelected: (_) => setState(() => _isGradient = true),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _colorRow('背景色', _color1, (c) => setState(() => _color1 = c)),
          if (_isGradient) ...[
            const SizedBox(height: 8),
            _colorRow(
                '背景色 2', _color2, (c) => setState(() => _color2 = c)),
          ],
          const SizedBox(height: 8),
          _colorRow(
              '文字颜色', _textColor, (c) => setState(() => _textColor = c)),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 8),
          const Text('默认分组',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            '用这个色块加的高亮，默认归到这个分组。',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            value: _defaultGroupId,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('未分组'),
              ),
              for (final g in groups)
                DropdownMenuItem<String?>(
                  value: g.id,
                  child: Text(g.name),
                ),
            ],
            onChanged: (v) => setState(() => _defaultGroupId = v),
          ),
          const SizedBox(height: 24),
          const Text('预览'),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 16, color: Colors.black),
                children: [
                  const TextSpan(text: '这是一个 '),
                  WidgetSpan(
                    child: Container(
                      decoration: BoxDecoration(
                        color: _isGradient ? null : _color1,
                        gradient: _isGradient
                            ? LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [_color1, _color2],
                              )
                            : null,
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Text(
                        '关键词',
                        style: TextStyle(color: _textColor),
                      ),
                    ),
                  ),
                  const TextSpan(text: ' 的示例。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            '⚠️ 修改只影响以后新加的高亮，已有的保持原样。\n'
            '     如需修改已有高亮，去管理页。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _resetToDefault,
            child: const Text('恢复该色块默认'),
          ),
        ],
      ),
    );
  }

  Widget _colorRow(String label, Color color, ValueChanged<Color> onPick) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: () => _pickColor(color, onPick),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickColor(Color initial, ValueChanged<Color> onPick) async {
    final result = await showDialog<Color>(
      context: context,
      builder: (_) => _SimpleColorPicker(initial: initial),
    );
    if (result != null) onPick(result);
  }
}

// ==================== 简易取色器 ====================

class _SimpleColorPicker extends StatefulWidget {
  const _SimpleColorPicker({required this.initial});
  final Color initial;

  @override
  State<_SimpleColorPicker> createState() => _SimpleColorPickerState();
}

class _SimpleColorPickerState extends State<_SimpleColorPicker> {
  late double _r;
  late double _g;
  late double _b;
  late TextEditingController _hexCtrl;

  @override
  void initState() {
    super.initState();
    _r = widget.initial.r * 255;
    _g = widget.initial.g * 255;
    _b = widget.initial.b * 255;
    _hexCtrl = TextEditingController(
      text:
          '#${widget.initial.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}',
    );
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  Color get _current =>
      Color.fromARGB(255, _r.round(), _g.round(), _b.round());

  void _syncHex() {
    _hexCtrl.text =
        '#${_current.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择颜色'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 60,
              decoration: BoxDecoration(
                color: _current,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(height: 8),
            _slider('R', _r, Colors.red,
                (v) => setState(() { _r = v; _syncHex(); })),
            _slider('G', _g, Colors.green,
                (v) => setState(() { _g = v; _syncHex(); })),
            _slider('B', _b, Colors.blue,
                (v) => setState(() { _b = v; _syncHex(); })),
            TextField(
              controller: _hexCtrl,
              decoration: const InputDecoration(
                labelText: 'HEX',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) {
                final s = v.startsWith('#') ? v.substring(1) : v;
                if (s.length == 6) {
                  final n = int.tryParse(s, radix: 16);
                  if (n != null) {
                    setState(() {
                      _r = ((n >> 16) & 0xFF).toDouble();
                      _g = ((n >> 8) & 0xFF).toDouble();
                      _b = (n & 0xFF).toDouble();
                    });
                  }
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _current),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _slider(
      String label, double v, Color c, ValueChanged<double> onCh) {
    return Row(
      children: [
        SizedBox(width: 16, child: Text(label)),
        Expanded(
          child: Slider(
            min: 0,
            max: 255,
            value: v,
            activeColor: c,
            onChanged: onCh,
          ),
        ),
        SizedBox(width: 40, child: Text(v.round().toString())),
      ],
    );
  }
}

// ==================== 书签 / 高亮 管理页 ====================

Future<int?> openBookmarkHighlightManager(
  BuildContext context,
  String fileKey,
  String fileName,
) {
  return Navigator.of(context).push<int>(
    MaterialPageRoute<int>(
      builder: (_) => BookmarkHighlightManager(
        fileKey: fileKey,
        fileName: fileName,
      ),
    ),
  );
}

class BookmarkHighlightManager extends ConsumerStatefulWidget {
  const BookmarkHighlightManager({
    super.key,
    required this.fileKey,
    required this.fileName,
  });

  final String fileKey;
  final String fileName;

  @override
  ConsumerState<BookmarkHighlightManager> createState() =>
      _BookmarkHighlightManagerState();
}

class _BookmarkHighlightManagerState
    extends ConsumerState<BookmarkHighlightManager>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  final Set<String> _selectedBookmarks = {};
  final Set<String> _selectedHighlights = {};
  bool _selectionMode = false;

  /// 当前勾选"显示"的分组 id（null 表示"未分组"）。
  /// 空集 = 全部显示。默认全选。
  Set<String?> _visibleGroupIds = <String?>{};

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() => setState(() {
          _selectionMode = false;
          _selectedBookmarks.clear();
          _selectedHighlights.clear();
        }));
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bookmarks =
        ref.watch(readerBookmarksProvider)[widget.fileKey] ?? const [];
    final allHighlights =
        ref.watch(readerHighlightsProvider)[widget.fileKey] ?? const [];
    final groups = ref.watch(readerHighlightGroupsProvider);

    // 过滤高亮
    final highlights = _visibleGroupIds.isEmpty
        ? allHighlights
        : allHighlights
            .where((h) => _visibleGroupIds.contains(h.groupId))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('书签与高亮 · ${widget.fileName}'),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selectionMode = false;
                  _selectedBookmarks.clear();
                  _selectedHighlights.clear();
                }),
              )
            : null,
        actions: [
          if (_selectionMode)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除所选',
              onPressed: _deleteSelected,
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.filter_list),
              tooltip: '按分组过滤',
              onPressed: () => _showFilterSheet(groups),
            ),
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '批量选择',
              onPressed: () => setState(() => _selectionMode = true),
            ),
          ],
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: '书签 (${bookmarks.length})'),
            Tab(text: '高亮 (${highlights.length})'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildBookmarks(bookmarks),
          _buildHighlights(highlights),
        ],
      ),
    );
  }

  Future<void> _showFilterSheet(List<HighlightGroup> groups) async {
    // 收集当前文件里出现过的 groupId（含 null）
    final all =
        ref.read(readerHighlightsProvider)[widget.fileKey] ?? const [];
    final usedIds = <String?>{};
    for (final h in all) {
      usedIds.add(h.groupId);
    }

    final initial = _visibleGroupIds.isEmpty
        ? <String?>{...usedIds}
        : Set<String?>.from(_visibleGroupIds);

    final result = await showModalBottomSheet<Set<String?>>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _GroupFilterSheet(
        groups: groups,
        usedIds: usedIds,
        initial: initial,
      ),
    );

    if (result == null) return;

    // 全部勾选 = 不过滤
    if (result.length == usedIds.length) {
      setState(() => _visibleGroupIds = <String?>{});
    } else {
      setState(() => _visibleGroupIds = result);
    }
  }

  Future<void> _openGroupManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const GroupManagerScreen(),
      ),
    );
  }

  void _deleteSelected() {
    if (_tab.index == 0) {
      if (_selectedBookmarks.isEmpty) return;
      ref
          .read(readerBookmarksProvider.notifier)
          .removeMany(widget.fileKey, Set<String>.from(_selectedBookmarks));
      setState(() {
        _selectedBookmarks.clear();
        _selectionMode = false;
      });
    } else {
      if (_selectedHighlights.isEmpty) return;
      ref
          .read(readerHighlightsProvider.notifier)
          .removeMany(widget.fileKey, Set<String>.from(_selectedHighlights));
      setState(() {
        _selectedHighlights.clear();
        _selectionMode = false;
      });
    }
  }

  Widget _buildBookmarks(List<ReaderBookmark> bookmarks) {
    if (bookmarks.isEmpty) {
      return const Center(child: Text('还没有书签'));
    }
    return ListView.builder(
      itemCount: bookmarks.length,
      itemBuilder: (_, i) {
        final b = bookmarks[i];
        final selected = _selectedBookmarks.contains(b.id);
        return ListTile(
          leading: _selectionMode
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleBookmark(b.id),
                )
              : const Icon(Icons.bookmark),
          title: Text(
            b.displayName.isEmpty ? '(空)' : b.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '位置 ${b.charOffset}',
            style: const TextStyle(fontSize: 11),
          ),
          onTap: _selectionMode
              ? () => _toggleBookmark(b.id)
              : () async {
                  final r = await openBookmarkEdit(context, b);
                  if (r != null && mounted) {
                    if (r.action == 'delete') {
                      ref
                          .read(readerBookmarksProvider.notifier)
                          .remove(widget.fileKey, b.id);
                    } else if (r.action == 'save' && r.bookmark != null) {
                      ref
                          .read(readerBookmarksProvider.notifier)
                          .updateOne(widget.fileKey, r.bookmark!);
                    } else if (r.action == 'jump') {
                      Navigator.pop(context, b.charOffset);
                    }
                  }
                },
          onLongPress:
              _selectionMode ? null : () => _enterBookmarkSelection(b.id),
        );
      },
    );
  }

  void _toggleBookmark(String id) {
    setState(() {
      if (_selectedBookmarks.contains(id)) {
        _selectedBookmarks.remove(id);
      } else {
        _selectedBookmarks.add(id);
      }
    });
  }

  void _enterBookmarkSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedBookmarks.add(id);
    });
  }

  Widget _buildHighlights(List<HighlightEntry> highlights) {
    if (highlights.isEmpty) {
      return const Center(child: Text('还没有高亮'));
    }
    return ListView.builder(
      itemCount: highlights.length,
      itemBuilder: (_, i) {
        final h = highlights[i];
        final selected = _selectedHighlights.contains(h.id);
        final bg = Color(h.colors.first);
        return ListTile(
          leading: _selectionMode
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleHighlight(h.id),
                )
              : Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.black26),
                  ),
                ),
          title: Text(h.displayName),
          subtitle: Text(
            '关键词：${h.keyword}',
            style: const TextStyle(fontSize: 11),
          ),
          onTap: _selectionMode
              ? () => _toggleHighlight(h.id)
              : () async {
                  final r = await openHighlightEdit(context, h);
                  if (r != null && mounted) {
                    if (r.action == 'delete') {
                      ref
                          .read(readerHighlightsProvider.notifier)
                          .remove(widget.fileKey, h.id);
                    } else if (r.action == 'save' && r.entry != null) {
                      ref
                          .read(readerHighlightsProvider.notifier)
                          .updateOne(widget.fileKey, r.entry!);
                    }
                  }
                },
          onLongPress: _selectionMode
              ? null
              : () => _enterHighlightSelection(h.id),
          trailing: _selectionMode
              ? null
              : IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => ref
                      .read(readerHighlightsProvider.notifier)
                      .remove(widget.fileKey, h.id),
                ),
        );
      },
    );
  }

  void _toggleHighlight(String id) {
    setState(() {
      if (_selectedHighlights.contains(id)) {
        _selectedHighlights.remove(id);
      } else {
        _selectedHighlights.add(id);
      }
    });
  }

  void _enterHighlightSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedHighlights.add(id);
    });
  }
}

// ==================== 分组过滤面板 ====================

class _GroupFilterSheet extends StatefulWidget {
  const _GroupFilterSheet({
    required this.groups,
    required this.usedIds,
    required this.initial,
  });

  final List<HighlightGroup> groups;
  final Set<String?> usedIds;
  final Set<String?> initial;

  @override
  State<_GroupFilterSheet> createState() => _GroupFilterSheetState();
}

class _GroupFilterSheetState extends State<_GroupFilterSheet> {
  late Set<String?> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<String?>.from(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    // 构造可见的选项：未分组 + 所有出现过的分组
    final entries = <({String? id, String name, int count})>[];
    if (widget.usedIds.contains(null)) {
      entries.add((id: null, name: '未分组', count: 0));
    }
    for (final g in widget.groups) {
      if (widget.usedIds.contains(g.id)) {
        entries.add((id: g.id, name: g.name, count: 0));
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('显示哪些分组',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('当前文件还没有高亮')),
              )
            else
              ...entries.map((e) {
                final checked = _selected.contains(e.id);
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: checked,
                  title: Text(e.name),
                  onChanged: (_) {
                    setState(() {
                      if (checked) {
                        _selected.remove(e.id);
                      } else {
                        _selected.add(e.id);
                      }
                    });
                  },
                );
              }),
            const Divider(),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.select_all, size: 18),
                  label: const Text('全选'),
                  onPressed: () {
                    setState(() {
                      _selected = Set<String?>.from(widget.usedIds);
                    });
                  },
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: const Text('管理分组'),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const GroupManagerScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 分组管理页 ====================

class GroupManagerScreen extends ConsumerStatefulWidget {
  const GroupManagerScreen({super.key});

  @override
  ConsumerState<GroupManagerScreen> createState() =>
      _GroupManagerScreenState();
}

class _GroupManagerScreenState extends ConsumerState<GroupManagerScreen> {
  Future<void> _createGroup() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '分组名',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    ref.read(readerHighlightGroupsProvider.notifier).create(name);
  }

  Future<void> _renameGroup(HighlightGroup g) async {
    final ctrl = TextEditingController(text: g.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    ref.read(readerHighlightGroupsProvider.notifier).rename(g.id, name);
  }

  Future<void> _deleteGroup(HighlightGroup g) async {
    // 统计该分组下的高亮数
    final all = ref.read(readerHighlightsProvider);
    var count = 0;
    for (final list in all.values) {
      for (final h in list) {
        if (h.groupId == g.id) count++;
      }
    }

    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除「${g.name}」分组？'),
        content: Text(
          '该分组下有 $count 条高亮。\n'
          '删除分组后，这些高亮怎么办？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'detach'),
            child: const Text('保留，变未分组'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, 'delete'),
            child: const Text('连同高亮删除'),
          ),
        ],
      ),
    );
    if (choice == null) return;

    // 清掉色块里指向这个分组的 defaultGroupId
    final palette = ref.read(readerPaletteProvider);
    final paletteNotifier = ref.read(readerPaletteProvider.notifier);
    for (final p in palette) {
      if (p.defaultGroupId == g.id) {
        paletteNotifier.updateOne(p.copyWith(clearDefaultGroup: true));
      }
    }

    final highlightsNotifier = ref.read(readerHighlightsProvider.notifier);
    if (choice == 'detach') {
      final all = ref.read(readerHighlightsProvider);
      for (final entry in all.entries) {
        for (final h in entry.value) {
          if (h.groupId == g.id) {
            highlightsNotifier.updateOne(
              entry.key,
              h.copyWith(clearGroup: true),
            );
          }
        }
      }
    } else if (choice == 'delete') {
      final all = ref.read(readerHighlightsProvider);
      for (final entry in all.entries) {
        final ids = entry.value
            .where((h) => h.groupId == g.id)
            .map((h) => h.id)
            .toSet();
        if (ids.isNotEmpty) {
          highlightsNotifier.removeMany(entry.key, ids);
        }
      }
    }

    ref.read(readerHighlightGroupsProvider.notifier).delete(g.id);
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(readerHighlightGroupsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('分组管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建分组',
            onPressed: _createGroup,
          ),
        ],
      ),
      body: groups.isEmpty
          ? const Center(child: Text('还没有分组，点右上角 + 新建'))
          : ReorderableListView.builder(
              itemCount: groups.length,
              onReorder: (oldIndex, newIndex) {
                ref
                    .read(readerHighlightGroupsProvider.notifier)
                    .reorder(oldIndex, newIndex);
              },
              itemBuilder: (_, i) {
                final g = groups[i];
                return ListTile(
                  key: ValueKey(g.id),
                  leading: const Icon(Icons.drag_handle),
                  title: Text(g.name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: '改名',
                        onPressed: () => _renameGroup(g),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: '删除',
                        onPressed: () => _deleteGroup(g),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// ==================== 高亮编辑页 ====================

class HighlightEditResult {
  const HighlightEditResult({required this.action, this.entry});
  final String action; // 'save' | 'delete'
  final HighlightEntry? entry;
}

Future<HighlightEditResult?> openHighlightEdit(
  BuildContext context,
  HighlightEntry entry,
) {
  return Navigator.of(context).push<HighlightEditResult>(
    MaterialPageRoute(
      builder: (_) => _HighlightEditScreen(entry: entry),
    ),
  );
}

class _HighlightEditScreen extends ConsumerStatefulWidget {
  const _HighlightEditScreen({required this.entry});
  final HighlightEntry entry;

  @override
  ConsumerState<_HighlightEditScreen> createState() =>
      _HighlightEditScreenState();
}

class _HighlightEditScreenState
    extends ConsumerState<_HighlightEditScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _kwCtrl;
  late Color _color1;
  late Color _color2;
  late bool _isGradient;
  late Color _textColor;
  String? _groupId;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _nameCtrl = TextEditingController(text: e.displayName);
    _kwCtrl = TextEditingController(text: e.keyword);
    _isGradient = e.colors.length > 1;
    _color1 = Color(e.colors.first);
    _color2 =
        e.colors.length > 1 ? Color(e.colors[1]) : Color(e.colors.first);
    _textColor = Color(e.textColor);
    _groupId = e.groupId;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _kwCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final kw = _kwCtrl.text.trim();
    if (kw.isEmpty) return;
    final colors = _isGradient
        ? <int>[_color1.toARGB32(), _color2.toARGB32()]
        : <int>[_color1.toARGB32()];
    final stops = _isGradient ? <double>[0.0, 1.0] : <double>[0.0];

    final updated = widget.entry.copyWith(
      keyword: kw,
      colors: colors,
      stops: stops,
      textColor: _textColor.toARGB32(),
      name: _nameCtrl.text.trim(),
      groupId: _groupId,
      clearGroup: _groupId == null,
    );
    Navigator.pop(context, HighlightEditResult(action: 'save', entry: updated));
  }

  void _delete() {
    Navigator.pop(context, const HighlightEditResult(action: 'delete'));
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(readerHighlightGroupsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑高亮'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('高亮名'),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              hintText: '默认与关键词相同',
            ),
          ),
          const SizedBox(height: 12),
          const Text('关键词'),
          TextField(
            controller: _kwCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('样式：'),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('纯色'),
                selected: !_isGradient,
                onSelected: (_) => setState(() => _isGradient = false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('渐变'),
                selected: _isGradient,
                onSelected: (_) => setState(() => _isGradient = true),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _colorRow('背景色', _color1, (c) => setState(() => _color1 = c)),
          if (_isGradient) ...[
            const SizedBox(height: 8),
            _colorRow(
                '背景色 2', _color2, (c) => setState(() => _color2 = c)),
          ],
          const SizedBox(height: 8),
          _colorRow(
              '文字颜色', _textColor, (c) => setState(() => _textColor = c)),
          const SizedBox(height: 16),
          const Text('分组'),
          const SizedBox(height: 4),
          DropdownButtonFormField<String?>(
            value: _groupId,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('未分组'),
              ),
              for (final g in groups)
                DropdownMenuItem<String?>(
                  value: g.id,
                  child: Text(g.name),
                ),
            ],
            onChanged: (v) => setState(() => _groupId = v),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            label: const Text('删除这条高亮',
                style: TextStyle(color: Colors.red)),
            onPressed: _delete,
          ),
        ],
      ),
    );
  }

  Widget _colorRow(String label, Color color, ValueChanged<Color> onPick) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: () async {
            final result = await showDialog<Color>(
              context: context,
              builder: (_) => _SimpleColorPicker(initial: color),
            );
            if (result != null) onPick(result);
          },
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== 书签编辑页 ====================

class BookmarkEditResult {
  const BookmarkEditResult({required this.action, this.bookmark});
  final String action; // 'save' | 'delete' | 'jump'
  final ReaderBookmark? bookmark;
}

Future<BookmarkEditResult?> openBookmarkEdit(
  BuildContext context,
  ReaderBookmark bookmark,
) {
  return Navigator.of(context).push<BookmarkEditResult>(
    MaterialPageRoute(
      builder: (_) => _BookmarkEditScreen(bookmark: bookmark),
    ),
  );
}

class _BookmarkEditScreen extends StatefulWidget {
  const _BookmarkEditScreen({required this.bookmark});
  final ReaderBookmark bookmark;

  @override
  State<_BookmarkEditScreen> createState() => _BookmarkEditScreenState();
}

class _BookmarkEditScreenState extends State<_BookmarkEditScreen> {
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.bookmark.displayName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final updated = widget.bookmark.copyWith(
      name: _nameCtrl.text.trim(),
    );
    Navigator.pop(context,
        BookmarkEditResult(action: 'save', bookmark: updated));
  }

  void _delete() {
    Navigator.pop(context, const BookmarkEditResult(action: 'delete'));
  }

  void _jump() {
    Navigator.pop(context, const BookmarkEditResult(action: 'jump'));
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bookmark;
    String time = '';
    if (b.createdAt > 0) {
      final t = DateTime.fromMillisecondsSinceEpoch(b.createdAt);
      String two(int n) => n < 10 ? '0$n' : '$n';
      time = '${t.year}-${two(t.month)}-${two(t.day)} '
          '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑书签'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('书签名'),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          const Text('位置预览'),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              b.preview.isEmpty ? '(空)' : b.preview,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
          if (time.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('创建时间：$time',
                style:
                    const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.my_location),
            label: const Text('跳到这个位置'),
            onPressed: _jump,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            label: const Text('删除这个书签',
                style: TextStyle(color: Colors.red)),
            onPressed: _delete,
          ),
        ],
      ),
    );
  }
}

// ==================== 编辑衔接 ====================

Future<void> openEditorAndReturn(
  BuildContext context,
  String filePath,
  String fileName,
  VoidCallback onReturn,
) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SingleFileEditorScreen(
        filePath: filePath,
        fileName: fileName,
      ),
    ),
  );
  onReturn();
}

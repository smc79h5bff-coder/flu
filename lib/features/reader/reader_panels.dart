import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../file_browser/presentation/single_file_editor_screen.dart';
import 'reader_models.dart';
import 'reader_pagination.dart';
import 'reader_repository.dart';
import 'reader_screen.dart';

// ==================== 设置面板 ====================

Future<void> showReaderSettingsSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
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
  Widget build(BuildContext context) {
    final s = ref.watch(readerSettingsProvider);
    final n = ref.read(readerSettingsProvider.notifier);
    final pagePreview = ref.watch(readerPagePreviewProvider);

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            // ==================== 顶部把手 + 标题 ====================
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
            const Text('阅读设置',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),

            // ==================== 固定预览区 ====================
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '点击预览可放大查看',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '所有参数改动实时反映到预览。',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                  _miniPreview(context, s, pagePreview),
                ],
              ),
            ),

            const SizedBox(height: 4),
            const Divider(height: 1),

            // ==================== 滚动设置区 ====================
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---------- 字号 ----------
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

                    // ---------- 字重 ----------
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

                    // ---------- 背景色 ----------
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

                    // ---------- 悬浮按钮总开关 ----------
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
                    if (!s.showButtons)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          '已关闭。点击原按钮位置会走正常翻页 / 打开菜单逻辑。',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ),

                    if (s.showButtons) ...[
                      // ---------- 上一文件按钮 ----------
                      _sectionTitle('上一文件按钮'),
                      _buttonStyleChooser(
                        style: s.topBtnStyle,
                        onChanged: n.setTopBtnStyle,
                      ),
                      if (s.topBtnStyle == 0) ...[
                        _colorRow(
                          context: context,
                          label: '背景色',
                          color: Color(s.topBtnBgColor),
                          onPick: n.setTopBtnBgColor,
                        ),
                        _colorRow(
                          context: context,
                          label: '箭头色',
                          color: Color(s.topBtnFgColor),
                          onPick: n.setTopBtnFgColor,
                        ),
                      ] else ...[
                        _colorRow(
                          context: context,
                          label: '圆环颜色',
                          color: Color(s.topBtnRingColor),
                          onPick: n.setTopBtnRingColor,
                        ),
                        _sliderHeader('圆环粗细',
                            '${s.topBtnRingWidth.toStringAsFixed(1)} px'),
                        Slider(
                          min: 0.5,
                          max: 20,
                          value: s.topBtnRingWidth.clamp(0.5, 20),
                          onChanged: n.setTopBtnRingWidth,
                        ),
                      ],
                      _sliderHeader(
                          '透明度',
                          '${(s.topBtnOpacity * 100).toStringAsFixed(0)}%'),
                      Slider(
                        min: 0.05,
                        max: 1.0,
                        value: s.topBtnOpacity.clamp(0.05, 1.0),
                        onChanged: n.setTopBtnOpacity,
                      ),
                      _sliderHeader(
                          '大小', '${s.topBtnScale.toStringAsFixed(1)}×'),
                      Slider(
                        min: 0.2,
                        max: 10.0,
                        value: s.topBtnScale.clamp(0.2, 10.0),
                        onChanged: n.setTopBtnScale,
                      ),
                      _sliderHeader(
                          '横向 X',
                          '${(s.topBtnX * 100).toStringAsFixed(0)}%'),
                      Slider(
                        min: 0.0,
                        max: 1.0,
                        value: s.topBtnX.clamp(0.0, 1.0),
                        onChanged: n.setTopBtnX,
                      ),
                      _sliderHeader(
                          '纵向 Y',
                          '${(s.topBtnY * 100).toStringAsFixed(0)}%'),
                      Slider(
                        min: 0.0,
                        max: 1.0,
                        value: s.topBtnY.clamp(0.0, 1.0),
                        onChanged: n.setTopBtnY,
                      ),
                      const SizedBox(height: 12),

                      // ---------- 下一文件按钮 ----------
                      _sectionTitle('下一文件按钮'),
                      _buttonStyleChooser(
                        style: s.bottomBtnStyle,
                        onChanged: n.setBottomBtnStyle,
                      ),
                      if (s.bottomBtnStyle == 0) ...[
                        _colorRow(
                          context: context,
                          label: '背景色',
                          color: Color(s.bottomBtnBgColor),
                          onPick: n.setBottomBtnBgColor,
                        ),
                        _colorRow(
                          context: context,
                          label: '箭头色',
                          color: Color(s.bottomBtnFgColor),
                          onPick: n.setBottomBtnFgColor,
                        ),
                      ] else ...[
                        _colorRow(
                          context: context,
                          label: '圆环颜色',
                          color: Color(s.bottomBtnRingColor),
                          onPick: n.setBottomBtnRingColor,
                        ),
                        _sliderHeader('圆环粗细',
                            '${s.bottomBtnRingWidth.toStringAsFixed(1)} px'),
                        Slider(
                          min: 0.5,
                          max: 20,
                          value: s.bottomBtnRingWidth.clamp(0.5, 20),
                          onChanged: n.setBottomBtnRingWidth,
                        ),
                      ],
                      _sliderHeader(
                          '透明度',
                          '${(s.bottomBtnOpacity * 100).toStringAsFixed(0)}%'),
                      Slider(
                        min: 0.05,
                        max: 1.0,
                        value: s.bottomBtnOpacity.clamp(0.05, 1.0),
                        onChanged: n.setBottomBtnOpacity,
                      ),
                      _sliderHeader(
                          '大小', '${s.bottomBtnScale.toStringAsFixed(1)}×'),
                      Slider(
                        min: 0.2,
                        max: 10.0,
                        value: s.bottomBtnScale.clamp(0.2, 10.0),
                        onChanged: n.setBottomBtnScale,
                      ),
                      _sliderHeader(
                          '横向 X',
                          '${(s.bottomBtnX * 100).toStringAsFixed(0)}%'),
                      Slider(
                        min: 0.0,
                        max: 1.0,
                        value: s.bottomBtnX.clamp(0.0, 1.0),
                        onChanged: n.setBottomBtnX,
                      ),
                      _sliderHeader(
                          '纵向 Y',
                          '${(s.bottomBtnY * 100).toStringAsFixed(0)}%'),
                      Slider(
                        min: 0.0,
                        max: 1.0,
                        value: s.bottomBtnY.clamp(0.0, 1.0),
                        onChanged: n.setBottomBtnY,
                      ),
                    ],

                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 8),

                    // ---------- 菜单热区 ----------
                    _sectionTitle('菜单热区'),
                    Text(
                      '点击此区域 → 打开顶部菜单；点击其它区域 → 翻下一页。',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        const Text('在阅读页显示热区',
                            style: TextStyle(fontSize: 13)),
                        const Spacer(),
                        Switch(
                          value: s.hotZoneVisible,
                          onChanged: n.setHotZoneVisible,
                        ),
                      ],
                    ),
                    Text(
                      '关掉后依旧能点，只是不画出来。',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 8),

                    const Text('显示样式', style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('整块填色'),
                          selected: s.hotZoneStyle == 0,
                          onSelected: (_) => n.setHotZoneStyle(0),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('分界线'),
                          selected: s.hotZoneStyle == 1,
                          onSelected: (_) => n.setHotZoneStyle(1),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    _colorRow(
                      context: context,
                      label: s.hotZoneStyle == 0 ? '填充颜色' : '边框颜色',
                      color: Color(s.hotZoneColor),
                      onPick: n.setHotZoneColor,
                    ),

                    if (s.hotZoneStyle == 1) ...[
                      _sliderHeader('边框粗细',
                          '${s.hotZoneBorderWidth.toStringAsFixed(1)} px'),
                      Slider(
                        min: 0.5,
                        max: 20,
                        value: s.hotZoneBorderWidth.clamp(0.5, 20),
                        onChanged: n.setHotZoneBorderWidth,
                      ),
                    ],

                    _sliderHeader(
                        '透明度',
                        '${(s.hotZoneOpacity * 100).toStringAsFixed(0)}%'),
                    Slider(
                      min: 0.0,
                      max: 1.0,
                      value: s.hotZoneOpacity.clamp(0.0, 1.0),
                      onChanged: n.setHotZoneOpacity,
                    ),

                    if (s.hotZoneStyle == 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          'ⓘ 贴屏幕边的边框不显示，比如热区贴顶时只画下边那条线。',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey.shade600),
                        ),
                      ),

                    _sliderHeader(
                        '横向 X',
                        '${(s.hotZoneX * 100).toStringAsFixed(0)}%'),
                    Slider(
                      min: 0.0,
                      max: 1.0,
                      value: s.hotZoneX.clamp(0.0, 1.0),
                      onChanged: n.setHotZoneX,
                    ),
                    _sliderHeader(
                        '纵向 Y',
                        '${(s.hotZoneY * 100).toStringAsFixed(0)}%'),
                    Slider(
                      min: 0.0,
                      max: 1.0,
                      value: s.hotZoneY.clamp(0.0, 1.0),
                      onChanged: n.setHotZoneY,
                    ),
                    _sliderHeader(
                        '宽度', '${(s.hotZoneW * 100).toStringAsFixed(0)}%'),
                    Slider(
                      min: 0.02,
                      max: 1.0,
                      value: s.hotZoneW.clamp(0.02, 1.0),
                      onChanged: n.setHotZoneW,
                    ),
                    _sliderHeader(
                        '高度', '${(s.hotZoneH * 100).toStringAsFixed(0)}%'),
                    Slider(
                      min: 0.02,
                      max: 1.0,
                      value: s.hotZoneH.clamp(0.02, 1.0),
                      onChanged: n.setHotZoneH,
                    ),

                    const SizedBox(height: 24),
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
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _buttonStyleChooser({
    required int style,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Text('样式', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 12),
          ChoiceChip(
            label: const Text('纯色圆'),
            selected: style == 0,
            onSelected: (_) => onChanged(0),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('圆环'),
            selected: style == 1,
            onSelected: (_) => onChanged(1),
          ),
        ],
      ),
    );
  }

  Widget _colorRow({
    required BuildContext context,
    required String label,
    required Color color,
    required ValueChanged<int> onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(
            '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2)}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () async {
              final picked = await showDialog<Color>(
                context: context,
                builder: (_) => _SimpleColorPicker(initial: color),
              );
              if (picked != null) onPick(picked.toARGB32());
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

// ==================== 预览图 ====================

Widget _miniPreview(
  BuildContext context,
  ReaderSettings s,
  String pageText, {
  double previewWidth = 110,
  bool tapToEnlarge = true,
}) {
  final screenSize = MediaQuery.of(context).size;
  final previewHeight = previewWidth * screenSize.height / screenSize.width;

  Widget inner = Container(
    width: previewWidth,
    height: previewHeight,
    decoration: BoxDecoration(
      color: Color(s.bgColor),
      border: Border.all(color: Colors.grey.shade400),
      borderRadius: BorderRadius.circular(6),
    ),
    clipBehavior: Clip.antiAlias,
    child: LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final scale = w / screenSize.width;

        final sampleText = pageText.isNotEmpty
            ? pageText
            : '正文示例。正文示例。正文示例。\n'
                '正文示例。正文示例。\n'
                '正文示例。正文示例。正文示例。\n'
                '正文示例。';

        return Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 4.0 * scale,
                  vertical: 2.0 * scale,
                ),
                child: Text(
                  sampleText,
                  style: TextStyle(
                    fontSize: s.fontSize * scale,
                    height: 1.1,
                    color: const Color(0xFF222222),
                  ),
                  softWrap: true,
                  overflow: TextOverflow.clip,
                ),
              ),
            ),

            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _HotZonePainter(
                    x: s.hotZoneX,
                    y: s.hotZoneY,
                    w: s.hotZoneW,
                    h: s.hotZoneH,
                    color: Color(s.hotZoneColor),
                    opacity: s.hotZoneVisible ? s.hotZoneOpacity : 0.5,
                    borderWidth: s.hotZoneStyle == 1
                        ? s.hotZoneBorderWidth * scale
                        : 0,
                    fill: s.hotZoneStyle == 0,
                    previewOnly: !s.hotZoneVisible,
                  ),
                ),
              ),
            ),

            if (s.showButtons) ...[
              _previewButton(
                scale: scale,
                screenW: screenSize.width,
                screenH: screenSize.height,
                centerX: s.topBtnX * w,
                centerY: s.topBtnY * h,
                btnSize: 50.0 * s.topBtnScale * scale,
                opacity: s.topBtnOpacity,
                style: s.topBtnStyle,
                bg: Color(s.topBtnBgColor),
                fg: Color(s.topBtnFgColor),
                ringColor: Color(s.topBtnRingColor),
                ringWidth: s.topBtnRingWidth * scale,
                icon: Icons.keyboard_arrow_up,
              ),
              _previewButton(
                scale: scale,
                screenW: screenSize.width,
                screenH: screenSize.height,
                centerX: s.bottomBtnX * w,
                centerY: s.bottomBtnY * h,
                btnSize: 50.0 * s.bottomBtnScale * scale,
                opacity: s.bottomBtnOpacity,
                style: s.bottomBtnStyle,
                bg: Color(s.bottomBtnBgColor),
                fg: Color(s.bottomBtnFgColor),
                ringColor: Color(s.bottomBtnRingColor),
                ringWidth: s.bottomBtnRingWidth * scale,
                icon: Icons.keyboard_arrow_down,
              ),
            ],
          ],
        );
      },
    ),
  );

  if (!tapToEnlarge) return Center(child: inner);

  return Center(
    child: GestureDetector(
      onTap: () => _showFullPreview(context, s, pageText),
      child: inner,
    ),
  );
}

Future<void> _showFullPreview(
  BuildContext context,
  ReaderSettings s,
  String pageText,
) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.75),
    builder: (ctx) {
      final screenSize = MediaQuery.of(ctx).size;
      final w = screenSize.width * 0.72;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(ctx),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _miniPreview(
                ctx,
                s,
                pageText,
                previewWidth: w,
                tapToEnlarge: false,
              ),
              const SizedBox(height: 12),
              const Text(
                '点任意位置关闭',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _previewButton({
  required double scale,
  required double screenW,
  required double screenH,
  required double centerX,
  required double centerY,
  required double btnSize,
  required double opacity,
  required int style,
  required Color bg,
  required Color fg,
  required Color ringColor,
  required double ringWidth,
  required IconData icon,
}) {
  final size = btnSize < 8 ? 8.0 : btnSize;
  final left = centerX - size / 2;
  final top = centerY - size / 2;

  Widget body;
  if (style == 0) {
    body = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: fg, size: size * 0.6),
    );
  } else {
    body = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ringColor,
          width: ringWidth < 0.5 ? 0.5 : ringWidth,
        ),
      ),
    );
  }

  return Positioned(
    left: left,
    top: top,
    child: IgnorePointer(
      child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: body),
    ),
  );
}

class _HotZonePainter extends CustomPainter {
  _HotZonePainter({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.color,
    required this.opacity,
    required this.borderWidth,
    required this.fill,
    this.previewOnly = false,
  });

  final double x;
  final double y;
  final double w;
  final double h;
  final Color color;
  final double opacity;
  final double borderWidth;
  final bool fill;
  final bool previewOnly;

  @override
  void paint(Canvas canvas, Size size) {
    final left = (x - w / 2) * size.width;
    final top = (y - h / 2) * size.height;
    final right = (x + w / 2) * size.width;
    final bottom = (y + h / 2) * size.height;

    final rect = Rect.fromLTRB(left, top, right, bottom);

    final effectiveColor = previewOnly
        ? Colors.grey.withValues(alpha: opacity.clamp(0.0, 1.0) * 0.6)
        : color.withValues(alpha: opacity.clamp(0.0, 1.0));

    if (fill && !previewOnly) {
      canvas.drawRect(rect, Paint()..color = effectiveColor);
      return;
    }

    final paint = Paint()
      ..color = effectiveColor
      ..strokeWidth = borderWidth > 0 ? borderWidth : 1.0
      ..style = PaintingStyle.stroke;

    final touchLeft = left <= 1;
    final touchTop = top <= 1;
    final touchRight = right >= size.width - 1;
    final touchBottom = bottom >= size.height - 1;

    if (previewOnly) {
      _drawDashedLine(canvas, Offset(left, top), Offset(right, top), paint);
      _drawDashedLine(canvas, Offset(right, top), Offset(right, bottom), paint);
      _drawDashedLine(canvas, Offset(right, bottom), Offset(left, bottom), paint);
      _drawDashedLine(canvas, Offset(left, bottom), Offset(left, top), paint);
      return;
    }

    if (!touchLeft) {
      canvas.drawLine(Offset(left, top), Offset(left, bottom), paint);
    }
    if (!touchTop) {
      canvas.drawLine(Offset(left, top), Offset(right, top), paint);
    }
    if (!touchRight) {
      canvas.drawLine(Offset(right, top), Offset(right, bottom), paint);
    }
    if (!touchBottom) {
      canvas.drawLine(Offset(left, bottom), Offset(right, bottom), paint);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashWidth = 4.0;
    const dashSpace = 3.0;
    final totalDistance = (p2 - p1).distance;
    if (totalDistance <= 0) return;
    final direction = (p2 - p1) / totalDistance;
    var distance = 0.0;
    while (distance < totalDistance) {
      final end = distance + dashWidth > totalDistance
          ? totalDistance
          : distance + dashWidth;
      canvas.drawLine(
        p1 + direction * distance,
        p1 + direction * end,
        paint,
      );
      distance = end + dashSpace;
    }
  }

  @override
  bool shouldRepaint(_HotZonePainter old) =>
      old.x != x ||
      old.y != y ||
      old.w != w ||
      old.h != h ||
      old.color != color ||
      old.opacity != opacity ||
      old.borderWidth != borderWidth ||
      old.fill != fill ||
      old.previewOnly != previewOnly;
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
  late List<Color> _colors;
  late List<double> _stops;
  late Color _textColor;
  String? _defaultGroupId;
  bool _loaded = false;

  int _editorKey = 0;

  @override
  void initState() {
    super.initState();
    final p =
        ref.read(readerPaletteProvider.notifier).byIndex(widget.paletteIndex);
    _name = p.name;
    _isGradient = p.colors.length > 1;
    _colors = p.colors.map((c) => Color(c)).toList();
    if (_colors.isEmpty) _colors = [const Color(0xFFFFEB3B)];
    _stops = List<double>.from(p.stops);
    if (_stops.length != _colors.length) {
      _stops = [
        for (var i = 0; i < _colors.length; i++)
          _colors.length == 1 ? 0.0 : i / (_colors.length - 1),
      ];
    }
    _textColor = Color(p.textColor);
    _defaultGroupId = p.defaultGroupId;
    _loaded = true;
  }

  void _save() {
    final colors = _isGradient
        ? _colors.map((c) => c.toARGB32()).toList()
        : <int>[_colors.first.toARGB32()];
    final stops = _isGradient ? List<double>.from(_stops) : <double>[0.0];
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
      _colors = [Color(d.colors.first)];
      _stops = const [0.0];
      _textColor = Color(d.textColor);
      _defaultGroupId = null;
      _editorKey++;
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
                onSelected: (_) => setState(() {
                  _isGradient = false;
                  if (_colors.length > 1) {
                    _colors = [_colors.first];
                    _stops = const [0.0];
                  }
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('上下渐变'),
                selected: _isGradient,
                onSelected: (_) => setState(() {
                  _isGradient = true;
                  if (_colors.length < 2) {
                    final c1 = _colors.first;
                    final hsl = HSLColor.fromColor(c1);
                    final c2 = hsl
                        .withLightness(
                            (hsl.lightness - 0.2).clamp(0.0, 1.0))
                        .toColor();
                    _colors = [c1, c2];
                    _stops = const [0.0, 1.0];
                  }
                }),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_isGradient)
            _colorRow('背景色', _colors.first,
                (c) => setState(() => _colors = [c]))
          else
            _GradientEditor(
              key: ValueKey(_editorKey),
              colors: _colors,
              stops: _stops,
              onChanged: (colors, stops) {
                setState(() {
                  _colors = colors;
                  _stops = stops;
                });
              },
            ),
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
                        color: _isGradient ? null : _colors.first,
                        gradient: _isGradient
                            ? LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: _colors,
                                stops: _stops.length == _colors.length
                                    ? _stops
                                    : null,
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

// ==================== 渐变色编辑器 ====================

class _GradientEditor extends StatefulWidget {
  const _GradientEditor({
    super.key,
    required this.colors,
    required this.stops,
    required this.onChanged,
    this.maxColors = 5,
    this.minColors = 2,
  });

  final List<Color> colors;
  final List<double> stops;
  final void Function(List<Color> colors, List<double> stops) onChanged;
  final int maxColors;
  final int minColors;

  @override
  State<_GradientEditor> createState() => _GradientEditorState();
}

class _GradientEditorState extends State<_GradientEditor> {
  late List<Color> _colors;
  late List<double> _stops;

  int? _draggingIndex;

  static const double _barWidth = 60;
  static const double _barHeight = 240;
  static const double _dotSize = 26;
  static const double _minGap = 0.02;

  @override
  void initState() {
    super.initState();
    _colors = List<Color>.from(widget.colors);
    _stops = List<double>.from(widget.stops);
    _normalize();
  }

  void _normalize() {
    if (_colors.length < 2) {
      while (_colors.length < 2) {
        _colors.add(_colors.isEmpty ? Colors.red : _colors.last);
      }
    }
    if (_stops.length != _colors.length) {
      _stops = [
        for (var i = 0; i < _colors.length; i++)
          i / (_colors.length - 1),
      ];
    }
    for (var i = 1; i < _stops.length; i++) {
      if (_stops[i] <= _stops[i - 1]) {
        _stops[i] = _stops[i - 1] + _minGap;
      }
    }
    if (_stops.last > 1.0) {
      final n = _stops.length;
      for (var i = 0; i < n; i++) {
        _stops[i] = i / (n - 1);
      }
    }
  }

  void _emit() {
    widget.onChanged(
      List<Color>.from(_colors),
      List<double>.from(_stops),
    );
  }

  double _dotTop(int i) => _stops[i] * (_barHeight - _dotSize);
  double _dotCenterY(int i) => _dotTop(i) + _dotSize / 2;

  int _nearestDot(double localY) {
    var bestI = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < _colors.length; i++) {
      final d = (localY - _dotCenterY(i)).abs();
      if (d < bestDist) {
        bestDist = d;
        bestI = i;
      }
    }
    return bestI;
  }

  void _onPanStart(DragStartDetails d) {
    final i = _nearestDot(d.localPosition.dy);
    setState(() => _draggingIndex = i);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final i = _draggingIndex;
    if (i == null) return;
    final localY = d.localPosition.dy;
    var stop = (localY - _dotSize / 2) / (_barHeight - _dotSize);
    final lower = i == 0 ? 0.0 : _stops[i - 1] + _minGap;
    final upper =
        i == _colors.length - 1 ? 1.0 : _stops[i + 1] - _minGap;
    if (upper < lower) {
      stop = lower;
    } else {
      stop = stop.clamp(lower, upper);
    }
    setState(() => _stops[i] = stop);
    _emit();
  }

  void _onPanEnd(DragEndDetails d) {
    setState(() => _draggingIndex = null);
  }

  void _onTapUp(TapUpDetails d) {
    final i = _nearestDot(d.localPosition.dy);
    final dist = (d.localPosition.dy - _dotCenterY(i)).abs();
    if (dist < _dotSize) {
      _pickColor(i);
    }
  }

  Future<void> _pickColor(int i) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (_) => _SimpleColorPicker(initial: _colors[i]),
    );
    if (picked == null) return;
    setState(() => _colors[i] = picked);
    _emit();
  }

  void _addColor() {
    if (_colors.length >= widget.maxColors) return;
    var bestI = 0;
    var bestGap = 0.0;
    for (var i = 0; i < _stops.length - 1; i++) {
      final gap = _stops[i + 1] - _stops[i];
      if (gap > bestGap) {
        bestGap = gap;
        bestI = i;
      }
    }
    if (bestGap < _minGap * 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('间隔太小，无法插入新颜色')),
      );
      return;
    }
    final newStop = (_stops[bestI] + _stops[bestI + 1]) / 2;
    final newColor =
        Color.lerp(_colors[bestI], _colors[bestI + 1], 0.5) ?? _colors[bestI];
    setState(() {
      _stops.insert(bestI + 1, newStop);
      _colors.insert(bestI + 1, newColor);
    });
    _emit();
  }

  void _removeColor(int i) {
    if (_colors.length <= widget.minColors) return;
    setState(() {
      _colors.removeAt(i);
      _stops.removeAt(i);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _barWidth,
              height: _barHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                onTapUp: _onTapUp,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: _dotSize / 2,
                      width: _barWidth,
                      height: _barHeight - _dotSize,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: _colors,
                            stops: _stops,
                          ),
                          border: Border.all(color: Colors.black26),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                    for (var i = 0; i < _colors.length; i++)
                      Positioned(
                        left: _barWidth / 2 - _dotSize / 2,
                        top: _dotTop(i),
                        child: IgnorePointer(
                          child: Container(
                            width: _dotSize,
                            height: _dotSize,
                            decoration: BoxDecoration(
                              color: _colors[i],
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _draggingIndex == i
                                    ? Colors.blue
                                    : Colors.white,
                                width: _draggingIndex == i ? 3 : 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(width: 16),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _colors.length; i++) _colorEntry(i),
                  const SizedBox(height: 8),
                  if (_colors.length < widget.maxColors)
                    TextButton.icon(
                      onPressed: _addColor,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('加一色'),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '拖动色条上的圆点改位置，点圆点改颜色，点右侧 [×] 删除。'
          '（顶部 = 高亮的上边缘）',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _colorEntry(int i) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '${i + 1}',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          InkWell(
            onTap: () => _pickColor(i),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _colors[i],
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.black26),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '位置 ${(_stops[i] * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (_colors.length > widget.minColors)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: '删除此色',
              visualDensity: VisualDensity.compact,
              onPressed: () => _removeColor(i),
            ),
        ],
      ),
    );
  }
}

// ==================== 高亮管理页 ====================

/// 一条高亮 + 它所属的文件路径。
typedef _HighlightItem = ({String fileKey, HighlightEntry entry});

/// 选中集合的 key：(fileKey, entryId)。
typedef _HighlightKey = (String fileKey, String entryId);

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
  final Set<_HighlightKey> _selectedHighlights = {};

  bool _selectionMode = false;

  /// 区间选择锚点（书签用 id，高亮用 (fileKey,id)）。
  String? _anchorBookmarkId;
  _HighlightKey? _anchorHighlightKey;

  /// 筛选：显示哪些分组。空集 = 全部显示。
  Set<String?> _visibleGroupIds = <String?>{};

  /// 筛选：是否显示全部书籍。false = 仅本书。
  bool _allBooksMode = false;

  @override
  void initState() {
    super.initState();
    // Tab 顺序：0 = 高亮（默认显示），1 = 书签
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() => setState(() {
          _selectionMode = false;
          _selectedBookmarks.clear();
          _selectedHighlights.clear();
          _anchorBookmarkId = null;
          _anchorHighlightKey = null;
        }));
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  bool get _isHighlightTab => _tab.index == 0;
  bool get _isBookmarkTab => _tab.index == 1;

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedBookmarks.clear();
      _selectedHighlights.clear();
      _anchorBookmarkId = null;
      _anchorHighlightKey = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bookmarks =
        ref.watch(readerBookmarksProvider)[widget.fileKey] ?? const [];
    final allMap = ref.watch(readerHighlightsProvider);
    final groups = ref.watch(readerHighlightGroupsProvider);
    final viewSettings = ref.watch(highlightViewSettingsProvider);

    // 高亮：先按范围（本书 / 全部），再按分组过滤
    final highlightsRaw = _allBooksMode
        ? <_HighlightItem>[
            for (final e in allMap.entries)
              for (final h in e.value) (fileKey: e.key, entry: h),
          ]
        : <_HighlightItem>[
            for (final h in (allMap[widget.fileKey] ?? const <HighlightEntry>[]))
              (fileKey: widget.fileKey, entry: h),
          ];

    final highlights = _visibleGroupIds.isEmpty
        ? highlightsRaw
        : highlightsRaw
            .where((h) => _visibleGroupIds.contains(h.entry.groupId))
            .toList();

    final selectedCount =
        _isBookmarkTab ? _selectedBookmarks.length : _selectedHighlights.length;

    final allCount =
        _isBookmarkTab ? bookmarks.length : highlights.length;
    final allSelected = allCount > 0 && selectedCount == allCount;

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) _exitSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selectionMode
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '取消选择',
                  onPressed: _exitSelection,
                )
              : null,
          titleSpacing: 0,
          title: TabBar(
            controller: _tab,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(text: '高亮 (${highlights.length})'),
              Tab(text: '书签 (${bookmarks.length})'),
            ],
          ),
          actions: _selectionMode
              ? [
                  IconButton(
                    icon: Icon(
                      allSelected ? Icons.deselect : Icons.select_all,
                    ),
                    tooltip: allSelected ? '全不选' : '全选',
                    onPressed: () {
                      setState(() {
                        if (_isBookmarkTab) {
                          if (allSelected) {
                            _selectedBookmarks.clear();
                          } else {
                            _selectedBookmarks
                              ..clear()
                              ..addAll(bookmarks.map((b) => b.id));
                          }
                        } else {
                          if (allSelected) {
                            _selectedHighlights.clear();
                          } else {
                            _selectedHighlights
                              ..clear()
                              ..addAll(highlights
                                  .map((h) => (h.fileKey, h.entry.id)));
                          }
                        }
                      });
                    },
                  ),
                  if (_isHighlightTab)
                    IconButton(
                      icon: const Icon(Icons.folder_outlined),
                      tooltip: '移入分组',
                      onPressed: selectedCount == 0
                          ? null
                          : () => _moveToGroup(),
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '删除所选',
                    onPressed: selectedCount == 0 ? null : _deleteSelected,
                  ),
                ]
              : [
                  // 筛选：只有高亮 Tab 才有意义（按分组筛 / 按范围筛）
                  if (_isHighlightTab)
                    IconButton(
                      icon: const Icon(Icons.filter_list),
                      tooltip: '筛选（分组 / 范围）',
                      onPressed: () => _showFilterSheet(groups),
                    ),
                 
                
                
                
                
                // 批量选择：长按在高亮 Tab 打开显示设置
// （不用 IconButton，因为它的 tooltip 会截获长按）
InkWell(
  onTap: () => setState(() => _selectionMode = true),
  onLongPress: _isHighlightTab
      ? _showHighlightViewSettings
      : null,
  child: const SizedBox(
    width: 48,
    height: kToolbarHeight,
    child: Icon(Icons.checklist),
  ),
),

// 占位：让正常模式下 actions 的宽度和选中模式一致，
    // 这样切进/切出选中模式时 TabBar 不会左右跳。
    if (_isHighlightTab) const SizedBox(width: 48),
if (_isBookmarkTab) const SizedBox(width: 48),
                
                ],
        ),
        body: TabBarView(
          controller: _tab,
          children: [
            _buildHighlights(highlights, viewSettings),
            _buildBookmarks(bookmarks),
          ],
        ),
      ),
    );
  }

  // ==================== 显示设置弹窗 ====================

  Future<void> _showHighlightViewSettings() async {
    await showDialog<void>(
      context: context,
      builder: (c) => Consumer(
        builder: (c, ref, _) {
          final s = ref.watch(highlightViewSettingsProvider);
          final n = ref.read(highlightViewSettingsProvider.notifier);
          return AlertDialog(
            insetPadding: const EdgeInsets.all(8),
            title: const Text('高亮卡片显示设置'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(c).size.height * 0.7,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('卡片内容',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示书名'),
                      subtitle: const Text(
                        '在卡片底部显示这条高亮所属的书名。'
                        '「本书模式」和「全部书籍模式」都受这个开关控制。',
                        style: TextStyle(fontSize: 11),
                      ),
                      value: s.showBookName,
                      onChanged: n.setShowBookName,
                    ),
                    const SizedBox(height: 12),
                    const Divider(),
                    const SizedBox(height: 8),
                    Text(
                      '更多设置项（高亮名大小、书名字号/颜色/背景、'
                      '删除按钮大小等）后续会加到这里。',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ==================== 筛选弹窗 ====================

  Future<void> _showFilterSheet(List<HighlightGroup> groups) async {
    final all =
        ref.read(readerHighlightsProvider)[widget.fileKey] ?? const [];
    final usedIds = <String?>{};
    for (final h in all) {
      usedIds.add(h.groupId);
    }

    final initialGroups = _visibleGroupIds.isEmpty
        ? <String?>{...usedIds}
        : Set<String?>.from(_visibleGroupIds);

    final result = await showModalBottomSheet<
        ({bool allBooks, Set<String?> groups})>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _HighlightFilterSheet(
        groups: groups,
        usedIds: usedIds,
        initialGroups: initialGroups,
        initialAllBooks: _allBooksMode,
      ),
    );

    if (result == null) return;
    setState(() {
      _allBooksMode = result.allBooks;
      if (result.groups.length == usedIds.length) {
        _visibleGroupIds = <String?>{};
      } else {
        _visibleGroupIds = result.groups;
      }
    });
  }

  // ==================== 批量删除 / 移入分组 ====================

  void _deleteSelected() {
    if (_isBookmarkTab) {
      if (_selectedBookmarks.isEmpty) return;
      ref
          .read(readerBookmarksProvider.notifier)
          .removeMany(widget.fileKey, Set<String>.from(_selectedBookmarks));
      setState(() {
        _selectedBookmarks.clear();
        _selectionMode = false;
        _anchorBookmarkId = null;
      });
    } else {
      if (_selectedHighlights.isEmpty) return;
      // 按 bookKey 分组，逐本处理
      final byBook = <String, Set<String>>{};
      for (final (fileKey, id) in _selectedHighlights) {
        (byBook[fileKey] ??= <String>{}).add(id);
      }
      final notifier = ref.read(readerHighlightsProvider.notifier);
      for (final e in byBook.entries) {
        notifier.removeMany(e.key, e.value);
      }
      setState(() {
        _selectedHighlights.clear();
        _selectionMode = false;
        _anchorHighlightKey = null;
      });
    }
  }

  Future<void> _moveToGroup() async {
    if (_selectedHighlights.isEmpty) return;
    final groups = ref.read(readerHighlightGroupsProvider);

    final picked = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('移入分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, ''),
            child: const Row(
              children: [
                Icon(Icons.folder_off_outlined, size: 20),
                SizedBox(width: 10),
                Text('未分组'),
              ],
            ),
          ),
          for (final g in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, g.id),
              child: Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, '__new__'),
            child: const Row(
              children: [
                Icon(Icons.create_new_folder_outlined, size: 20),
                SizedBox(width: 10),
                Text('新建分组…'),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );

    if (picked == null || !mounted) return;

    String? groupId;
    if (picked == '__new__') {
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
      groupId =
          ref.read(readerHighlightGroupsProvider.notifier).create(name);
    } else if (picked == '') {
      groupId = null;
    } else {
      groupId = picked;
    }

    // 按 bookKey 分组处理
    final byBook = <String, Set<String>>{};
    for (final (fileKey, id) in _selectedHighlights) {
      (byBook[fileKey] ??= <String>{}).add(id);
    }
    final notifier = ref.read(readerHighlightsProvider.notifier);
    for (final e in byBook.entries) {
      notifier.setGroupMany(e.key, e.value, groupId);
    }

    if (!mounted) return;
    setState(() {
      _selectedHighlights.clear();
      _selectionMode = false;
      _anchorHighlightKey = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(groupId == null ? '已移出分组' : '已移入分组'),
      ),
    );
  }

  // ==================== 书签列表 ====================

  Widget _buildBookmarks(List<ReaderBookmark> bookmarks) {
    if (bookmarks.isEmpty) {
      return const Center(child: Text('还没有书签'));
    }
    return ListView.builder(
      itemCount: bookmarks.length,
      itemBuilder: (_, i) {
        final b = bookmarks[i];
        final selected = _selectedBookmarks.contains(b.id);

        return _selectionTile(
          selected: selected,
          child: ListTile(
            leading: const Icon(Icons.bookmark),
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
            onLongPress: () => _onLongPressBookmark(b.id, bookmarks),
          ),
        );
      },
    );
  }

  void _onLongPressBookmark(String id, List<ReaderBookmark> all) {
    if (!_selectionMode) {
      setState(() {
        _selectionMode = true;
        _selectedBookmarks.add(id);
        _anchorBookmarkId = id;
      });
      return;
    }
    if (_anchorBookmarkId != null) {
      final ids = all.map((b) => b.id).toList();
      final from = ids.indexOf(_anchorBookmarkId!);
      final to = ids.indexOf(id);
      if (from >= 0 && to >= 0) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        setState(() {
          for (var i = lo; i <= hi; i++) {
            _selectedBookmarks.add(ids[i]);
          }
          _anchorBookmarkId = id;
        });
        return;
      }
    }
    setState(() {
      _selectedBookmarks.add(id);
      _anchorBookmarkId = id;
    });
  }

  void _toggleBookmark(String id) {
    setState(() {
      if (_selectedBookmarks.contains(id)) {
        _selectedBookmarks.remove(id);
        if (_selectedBookmarks.isEmpty) {
          _selectionMode = false;
          _anchorBookmarkId = null;
        }
      } else {
        _selectedBookmarks.add(id);
        _anchorBookmarkId = id;
      }
    });
  }

  // ==================== 高亮网格 ====================

  Widget _buildHighlights(
    List<_HighlightItem> highlights,
    HighlightViewSettings viewSettings,
  ) {
    if (highlights.isEmpty) {
      return const Center(child: Text('还没有高亮'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 1.5,
      ),
      itemCount: highlights.length,
      itemBuilder: (_, i) {
        final item = highlights[i];
        final h = item.entry;
        final key = (item.fileKey, h.id);
        final selected = _selectedHighlights.contains(key);
        final bookName = item.fileKey.split('/').last;

        return _HighlightCard(
          entry: h,
          bookName: bookName,
          showBookName: viewSettings.showBookName,
          selected: selected,
          selectionMode: _selectionMode,
          onTap: _selectionMode
              ? () => _toggleHighlight(key)
              : () async {
                  final r = await openHighlightEdit(
                    context,
                    h,
                    fileKey: item.fileKey,
                  );
                  if (r != null && mounted) {
                    if (r.action == 'delete') {
                      ref
                          .read(readerHighlightsProvider.notifier)
                          .remove(item.fileKey, h.id);
                    } else if (r.action == 'save' && r.entry != null) {
                      ref
                          .read(readerHighlightsProvider.notifier)
                          .updateOne(item.fileKey, r.entry!);
                    }
                  }
                },
          onLongPress: () => _onLongPressHighlight(key, highlights),
          onDelete: () => _confirmDeleteHighlight(item),
        );
      },
    );
  }

  Future<void> _confirmDeleteHighlight(_HighlightItem item) async {
    final h = item.entry;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这条高亮？'),
        content: Text('关键词：${h.keyword}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      ref
          .read(readerHighlightsProvider.notifier)
          .remove(item.fileKey, h.id);
    }
  }

  void _onLongPressHighlight(
    _HighlightKey key,
    List<_HighlightItem> all,
  ) {
    if (!_selectionMode) {
      setState(() {
        _selectionMode = true;
        _selectedHighlights.add(key);
        _anchorHighlightKey = key;
      });
      return;
    }
    if (_anchorHighlightKey != null) {
      final keys = all.map((h) => (h.fileKey, h.entry.id)).toList();
      final from = keys.indexOf(_anchorHighlightKey!);
      final to = keys.indexOf(key);
      if (from >= 0 && to >= 0) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        setState(() {
          for (var i = lo; i <= hi; i++) {
            _selectedHighlights.add(keys[i]);
          }
          _anchorHighlightKey = key;
        });
        return;
      }
    }
    setState(() {
      _selectedHighlights.add(key);
      _anchorHighlightKey = key;
    });
  }

  void _toggleHighlight(_HighlightKey key) {
    setState(() {
      if (_selectedHighlights.contains(key)) {
        _selectedHighlights.remove(key);
        if (_selectedHighlights.isEmpty) {
          _selectionMode = false;
          _anchorHighlightKey = null;
        }
      } else {
        _selectedHighlights.add(key);
        _anchorHighlightKey = key;
      }
    });
  }

  Widget _selectionTile({
    required bool selected,
    required Widget child,
  }) {
    if (!selected) return child;
    final s = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: s.primary.withValues(alpha: 0.08),
        border: Border.all(color: s.primary, width: 2),
      ),
      child: child,
    );
  }
}

// ==================== 高亮卡片 ====================

/// 网格里一个高亮卡片。
/// 上块：名字 + 删除按钮（选中模式下换成右上角的对勾，删除按钮隐藏）。
/// 中块：高亮样式的预览（只有文字本身带背景色）。
/// 下块：书名（可选，受 highlightViewSettings.showBookName 控制）。
class _HighlightCard extends StatelessWidget {
  const _HighlightCard({
    required this.entry,
    required this.bookName,
    required this.showBookName,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
  });

  final HighlightEntry entry;
  final String bookName;
  final bool showBookName;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? s.primary.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.black12, width: 0.5),
        ),
        padding: const EdgeInsets.fromLTRB(6, 3, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 上块：名字 + 删除/对勾
            SizedBox(
              height: 22,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      entry.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (selectionMode)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: selected
                          ? Icon(
                              Icons.check_circle,
                              size: 18,
                              color: s.primary,
                            )
                          : null,
                    )
                  else
                    InkWell(
                      onTap: onDelete,
                      borderRadius: BorderRadius.circular(11),
                      child: const SizedBox(
                        width: 22,
                        height: 22,
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            // 中块：预览（占满剩余空间）
            Expanded(child: _preview()),
            // 下块：书名（可选，接在卡片底部）
            if (showBookName) ...[
              const SizedBox(height: 2),
              Text(
                bookName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    final colors = entry.colors.map((c) => Color(c)).toList();
    final stops =
        entry.stops.length == colors.length ? entry.stops : null;
    final isGradient = colors.length > 1;

    // 只有文字本身有背景色，其它区域透明（跟阅读器里一致）。
    return Center(
      child: Container(
        decoration: BoxDecoration(
          color: isGradient ? null : colors.first,
          gradient: isGradient
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: colors,
                  stops: stops,
                )
              : null,
          borderRadius: BorderRadius.circular(2),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          entry.keyword,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(entry.textColor),
            fontSize: 11,
            height: 1.15,
          ),
        ),
      ),
    );
  }
}

// ==================== 高亮筛选面板（范围 + 分组） ====================

class _HighlightFilterSheet extends StatefulWidget {
  const _HighlightFilterSheet({
    required this.groups,
    required this.usedIds,
    required this.initialGroups,
    required this.initialAllBooks,
  });

  final List<HighlightGroup> groups;
  final Set<String?> usedIds;
  final Set<String?> initialGroups;
  final bool initialAllBooks;

  @override
  State<_HighlightFilterSheet> createState() => _HighlightFilterSheetState();
}

class _HighlightFilterSheetState extends State<_HighlightFilterSheet> {
  late Set<String?> _selected;
  late bool _allBooks;

  @override
  void initState() {
    super.initState();
    _selected = Set<String?>.from(widget.initialGroups);
    _allBooks = widget.initialAllBooks;
  }

  @override
  Widget build(BuildContext context) {
    final entries = <({String? id, String name})>[];
    if (widget.usedIds.contains(null)) {
      entries.add((id: null, name: '未分组'));
    }
    for (final g in widget.groups) {
      if (widget.usedIds.contains(g.id)) {
        entries.add((id: g.id, name: g.name));
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
            const Text('显示范围',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            RadioListTile<bool>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: false,
              groupValue: _allBooks,
              title: const Text('仅本书'),
              onChanged: (v) => setState(() => _allBooks = v ?? false),
            ),
            RadioListTile<bool>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: true,
              groupValue: _allBooks,
              title: const Text('全部书籍'),
              subtitle: const Text(
                '显示 App 里所有书的高亮',
                style: TextStyle(fontSize: 11),
              ),
              onChanged: (v) => setState(() => _allBooks = v ?? false),
            ),
            const Divider(),
            const SizedBox(height: 4),
            const Text('显示哪些分组',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: Text('当前没有高亮')),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.3,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final e in entries)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: _selected.contains(e.id),
                          title: Text(e.name),
                          onChanged: (_) {
                            setState(() {
                              if (_selected.contains(e.id)) {
                                _selected.remove(e.id);
                              } else {
                                _selected.add(e.id);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ),
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
                    onPressed: () => Navigator.pop(
                      context,
                      (allBooks: _allBooks, groups: _selected),
                    ),
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
  HighlightEntry entry, {
  required String fileKey,
}) {
  return Navigator.of(context).push<HighlightEditResult>(
    MaterialPageRoute(
      builder: (_) => _HighlightEditScreen(
        entry: entry,
        fileKey: fileKey,
      ),
    ),
  );
}

class _HighlightEditScreen extends ConsumerStatefulWidget {
  const _HighlightEditScreen({
    required this.entry,
    required this.fileKey,
  });

  final HighlightEntry entry;
  final String fileKey;

  @override
  ConsumerState<_HighlightEditScreen> createState() =>
      _HighlightEditScreenState();
}

class _HighlightEditScreenState
    extends ConsumerState<_HighlightEditScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _kwCtrl;
  late bool _isGradient;
  late List<Color> _colors;
  late List<double> _stops;
  late Color _textColor;
  String? _groupId;

  int _editorKey = 0;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _nameCtrl = TextEditingController(text: e.displayName);
    _kwCtrl = TextEditingController(text: e.keyword);
    _isGradient = e.colors.length > 1;
    _colors = e.colors.map((c) => Color(c)).toList();
    if (_colors.isEmpty) _colors = [const Color(0xFFFFEB3B)];
    _stops = List<double>.from(e.stops);
    if (_stops.length != _colors.length) {
      _stops = [
        for (var i = 0; i < _colors.length; i++)
          _colors.length == 1 ? 0.0 : i / (_colors.length - 1),
      ];
    }
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
        ? _colors.map((c) => c.toARGB32()).toList()
        : <int>[_colors.first.toARGB32()];
    final stops = _isGradient ? List<double>.from(_stops) : <double>[0.0];

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
    final fileName = widget.fileKey.split('/').last;

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
          // ---------- 作用文件信息 ----------
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.black12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: widget.fileKey));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('路径已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Text(
                    widget.fileKey,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '长按路径可复制',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

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
                onSelected: (_) => setState(() {
                  _isGradient = false;
                  if (_colors.length > 1) {
                    _colors = [_colors.first];
                    _stops = const [0.0];
                  }
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('渐变'),
                selected: _isGradient,
                onSelected: (_) => setState(() {
                  _isGradient = true;
                  if (_colors.length < 2) {
                    final c1 = _colors.first;
                    final hsl = HSLColor.fromColor(c1);
                    final c2 = hsl
                        .withLightness(
                            (hsl.lightness - 0.2).clamp(0.0, 1.0))
                        .toColor();
                    _colors = [c1, c2];
                    _stops = const [0.0, 1.0];
                  }
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!_isGradient)
            _colorRow('背景色', _colors.first,
                (c) => setState(() => _colors = [c]))
          else
            _GradientEditor(
              key: ValueKey(_editorKey),
              colors: _colors,
              stops: _stops,
              onChanged: (colors, stops) {
                setState(() {
                  _colors = colors;
                  _stops = stops;
                });
              },
            ),
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

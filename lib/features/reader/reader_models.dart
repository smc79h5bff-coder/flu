import 'dart:convert';

/// ==================== 阅读进度 ====================
/// 每个文件一条。文件内容变了（hash 变）→ 进度作废。
class ReaderProgress {
  const ReaderProgress({
    required this.charOffset,
    required this.updatedAt,
  });

  /// 全文字符偏移（不是行号，因为行号会因字体而变）
  final int charOffset;

  /// 最后更新时间（epoch 毫秒）
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'o': charOffset,
        't': updatedAt,
      };

  factory ReaderProgress.fromJson(Map<String, dynamic> j) => ReaderProgress(
        charOffset: (j['o'] as num?)?.toInt() ?? 0,
        updatedAt: (j['t'] as num?)?.toInt() ?? 0,
      );

  String encode() => jsonEncode(toJson());

  static ReaderProgress? tryDecode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return ReaderProgress.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// ==================== 书签 ====================
class ReaderBookmark {
  const ReaderBookmark({
    required this.id,
    required this.charOffset,
    required this.preview,
    required this.createdAt,
    this.name = '',
  });

  final String id;

  /// 全文偏移
  final int charOffset;

  /// 该位置前后几个字，给用户认
  final String preview;

  final int createdAt;

  /// 书签名（用户可编辑）。空 = 显示 preview。
  final String name;

  /// 显示用名字
  String get displayName => name.isEmpty ? preview : name;

  Map<String, dynamic> toJson() => {
        'i': id,
        'o': charOffset,
        'p': preview,
        't': createdAt,
        if (name.isNotEmpty) 'n': name,
      };

  factory ReaderBookmark.fromJson(Map<String, dynamic> j) => ReaderBookmark(
        id: j['i'] as String,
        charOffset: (j['o'] as num).toInt(),
        preview: j['p'] as String? ?? '',
        createdAt: (j['t'] as num?)?.toInt() ?? 0,
        name: j['n'] as String? ?? '',
      );

  ReaderBookmark copyWith({
    int? charOffset,
    String? preview,
    String? name,
  }) =>
      ReaderBookmark(
        id: id,
        charOffset: charOffset ?? this.charOffset,
        preview: preview ?? this.preview,
        createdAt: createdAt,
        name: name ?? this.name,
      );
}

/// ==================== 高亮色块（配置） ====================
///
/// 20 个色块槽位。用户长按色块 → 改配置。
/// 色块只是"新建高亮时的模板"，改它不影响已有高亮。
///
/// 第一版：colors 只存 1 个（纯色）或 2 个（渐变）。
/// 未来：colors 最多 5 个，stops 自定义，angle 任意角度。
class HighlightPalette {
  const HighlightPalette({
    required this.index,
    required this.name,
    required this.colors,
    required this.stops,
    required this.angle,
    required this.textColor,
    this.defaultGroupId,
  });

  /// 槽位号 0-19
  final int index;

  /// 用户起的名，如 "人物"、"伏笔"
  final String name;

  /// 颜色列表（ARGB int）。
  /// 长度 1 = 纯色；长度 2 = 渐变（第一版）；未来最多 5。
  final List<int> colors;

  /// 每个颜色在 0.0-1.0 之间的位置。和 colors 一一对应。
  /// 纯色时 = [0.0]；渐变时 = [0.0, 1.0]（第一版固定均匀）。
  final List<double> stops;

  /// 渐变角度（0-360）。0=从上到下；90=从左到右。纯色时忽略。
  final double angle;

  /// 文字颜色
  final int textColor;

  /// 用这个色块加的高亮默认归到哪个分组。null = 未分组。
  final String? defaultGroupId;

  bool get isGradient => colors.length > 1;

  Map<String, dynamic> toJson() => {
        'i': index,
        'n': name,
        'c': colors,
        's': stops,
        'a': angle,
        't': textColor,
        if (defaultGroupId != null) 'dg': defaultGroupId,
      };

  factory HighlightPalette.fromJson(Map<String, dynamic> j) {
    final rawColors = (j['c'] as List?)?.cast<num>() ??
        <num>[(j['b1'] as num?)?.toInt() ?? 0xFFFFEB3B];
    final rawStops = (j['s'] as List?)?.cast<num>() ?? <num>[0.0];
    return HighlightPalette(
      index: (j['i'] as num).toInt(),
      name: j['n'] as String? ?? '色块 ${(j['i'] as num).toInt() + 1}',
      colors: rawColors.map((e) => e.toInt()).toList(),
      stops: rawStops.map((e) => e.toDouble()).toList(),
      angle: (j['a'] as num?)?.toDouble() ?? 0.0,
      textColor: (j['t'] as num?)?.toInt() ?? 0xFF000000,
      defaultGroupId: j['dg'] as String?,
    );
  }

  HighlightPalette copyWith({
    String? name,
    List<int>? colors,
    List<double>? stops,
    double? angle,
    int? textColor,
    String? defaultGroupId,
    bool clearDefaultGroup = false,
  }) =>
      HighlightPalette(
        index: index,
        name: name ?? this.name,
        colors: colors ?? this.colors,
        stops: stops ?? this.stops,
        angle: angle ?? this.angle,
        textColor: textColor ?? this.textColor,
        defaultGroupId:
            clearDefaultGroup ? null : (defaultGroupId ?? this.defaultGroupId),
      );

  /// 20 个默认色块（全部纯色）
  static List<HighlightPalette> defaults() {
    const presets = <(String, int, int)>[
      ('重点', 0xFFFFCDD2, 0xFF000000),
      ('人物', 0xFFBBDEFB, 0xFF000000),
      ('环境', 0xFFC8E6C9, 0xFF000000),
      ('伏笔', 0xFFFFF9C4, 0xFF000000),
      ('对话', 0xFFF8BBD0, 0xFF000000),
      ('动作', 0xFFD1C4E9, 0xFF000000),
      ('心理', 0xFFB2DFDB, 0xFF000000),
      ('时间', 0xFFFFE0B2, 0xFF000000),
      ('地点', 0xFFDCEDC8, 0xFF000000),
      ('道具', 0xFFFFCCBC, 0xFF000000),
      ('情感', 0xFFF0F4C3, 0xFF000000),
      ('冲突', 0xFFFFAB91, 0xFF000000),
      ('转折', 0xFFCE93D8, 0xFF000000),
      ('回忆', 0xFFB3E5FC, 0xFF000000),
      ('预言', 0xFFFFF59D, 0xFF000000),
      ('谜题', 0xFFA5D6A7, 0xFF000000),
      ('线索', 0xFFFFE082, 0xFF000000),
      ('悬念', 0xFFEF9A9A, 0xFF000000),
      ('意象', 0xFF80DEEA, 0xFF000000),
      ('摘抄', 0xFFE1BEE7, 0xFF000000),
    ];
    return [
      for (var i = 0; i < presets.length; i++)
        HighlightPalette(
          index: i,
          name: presets[i].$1,
          colors: [presets[i].$2],
          stops: const [0.0],
          angle: 0.0,
          textColor: presets[i].$3,
        ),
    ];
  }
}

/// ==================== 高亮分组 ====================
///
/// 全局共享。所有书共用同一套分组。
class HighlightGroup {
  const HighlightGroup({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'i': id,
        'n': name,
        't': createdAt,
      };

  factory HighlightGroup.fromJson(Map<String, dynamic> j) => HighlightGroup(
        id: j['i'] as String,
        name: j['n'] as String? ?? '未命名分组',
        createdAt: (j['t'] as num?)?.toInt() ?? 0,
      );

  HighlightGroup copyWith({String? name}) => HighlightGroup(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
      );
}

/// ==================== 高亮条目 ====================
///
/// 一个关键词在高亮后生成一条。
/// 存的是"当时的颜色快照"——改色块配置不影响已有高亮。
/// 未来加正则高亮，把 keyword 当正则解析。
class HighlightEntry {
  const HighlightEntry({
    required this.id,
    required this.keyword,
    required this.colors,
    required this.stops,
    required this.angle,
    required this.textColor,
    required this.createdAt,
    this.isRegex = false,
    this.name = '',
    this.groupId,
  });

  final String id;
  final String keyword;

  /// 颜色快照
  final List<int> colors;
  final List<double> stops;
  final double angle;
  final int textColor;

  final int createdAt;
  final bool isRegex;

  /// 高亮名（用户可编辑）。空 = 显示 keyword。
  final String name;

  /// 所属分组 id。null = 未分组。
  final String? groupId;

  /// 显示用名字
  String get displayName => name.isEmpty ? keyword : name;

  Map<String, dynamic> toJson() => {
        'i': id,
        'k': keyword,
        'c': colors,
        's': stops,
        'a': angle,
        't': textColor,
        't0': createdAt,
        if (isRegex) 'r': true,
        if (name.isNotEmpty) 'n': name,
        if (groupId != null) 'g': groupId,
      };

  factory HighlightEntry.fromJson(Map<String, dynamic> j) {
    final rawColors = (j['c'] as List?)?.cast<num>() ??
        <num>[(j['b1'] as num?)?.toInt() ?? 0xFFFFEB3B];
    final rawStops = (j['s'] as List?)?.cast<num>() ?? <num>[0.0];
    return HighlightEntry(
      id: j['i'] as String,
      keyword: j['k'] as String,
      colors: rawColors.map((e) => e.toInt()).toList(),
      stops: rawStops.map((e) => e.toDouble()).toList(),
      angle: (j['a'] as num?)?.toDouble() ?? 0.0,
      textColor: (j['t'] as num).toInt(),
      createdAt: (j['t0'] as num?)?.toInt() ?? 0,
      isRegex: j['r'] as bool? ?? false,
      name: j['n'] as String? ?? '',
      groupId: j['g'] as String?,
    );
  }

  HighlightEntry copyWith({
    String? keyword,
    List<int>? colors,
    List<double>? stops,
    double? angle,
    int? textColor,
    bool? isRegex,
    String? name,
    String? groupId,
    bool clearGroup = false,
  }) =>
      HighlightEntry(
        id: id,
        keyword: keyword ?? this.keyword,
        colors: colors ?? this.colors,
        stops: stops ?? this.stops,
        angle: angle ?? this.angle,
        textColor: textColor ?? this.textColor,
        createdAt: createdAt,
        isRegex: isRegex ?? this.isRegex,
        name: name ?? this.name,
        groupId: clearGroup ? null : (groupId ?? this.groupId),
      );
}

/// ==================== 全局阅读设置 ====================
///
/// 悬浮按钮：上、下、删除，三个。样式 / 颜色 / 透明度 / 大小 / 位置各自独立。
/// 菜单热区：任意位置的矩形，可显示/隐藏样式。
class ReaderSettings {
  const ReaderSettings({
    required this.fontSize,
    required this.fontWeight,
    required this.bgColor,
    required this.showButtons,
    required this.readerMode,

    // ====== 上一文件按钮 ======
    required this.topBtnStyle,
    required this.topBtnBgColor,
    required this.topBtnFgColor,
    required this.topBtnRingColor,
    required this.topBtnRingWidth,
    required this.topBtnOpacity,
    required this.topBtnScale,
    required this.topBtnX,
    required this.topBtnY,

    // ====== 下一文件按钮 ======
    required this.bottomBtnStyle,
    required this.bottomBtnBgColor,
    required this.bottomBtnFgColor,
    required this.bottomBtnRingColor,
    required this.bottomBtnRingWidth,
    required this.bottomBtnOpacity,
    required this.bottomBtnScale,
    required this.bottomBtnX,
    required this.bottomBtnY,

    // ====== 删除文件按钮 ======
    required this.delBtnStyle,
    required this.delBtnBgColor,
    required this.delBtnFgColor,
    required this.delBtnRingColor,
    required this.delBtnRingWidth,
    required this.delBtnOpacity,
    required this.delBtnScale,
    required this.delBtnX,
    required this.delBtnY,

    // ====== 菜单热区 ======
    required this.hotZoneVisible,
    required this.hotZoneStyle,
    required this.hotZoneColor,
    required this.hotZoneOpacity,
    required this.hotZoneBorderWidth,
    required this.hotZoneX,
    required this.hotZoneY,
    required this.hotZoneW,
    required this.hotZoneH,
  });

  /// 4.0 - 60.0
  final double fontSize;

  /// 100 - 900（100=极细，400=正常，900=最粗）
  final int fontWeight;

  /// 背景色 ARGB
  final int bgColor;

  /// 浮动按钮总开关。关了之后按钮彻底不显示、不可点，
  /// 点击原位置会走正常逻辑（顶部菜单 / 翻页）。
  final bool showButtons;

  /// 阅读模式：0 = 分页，1 = 滚动。
  final int readerMode;

  // ==================== 上一文件按钮 ====================

  /// 样式：0 = 纯色圆（有箭头），1 = 圆环（无箭头、无填充）。
  final int topBtnStyle;
  final int topBtnBgColor;    // 纯色圆背景色
  final int topBtnFgColor;    // 纯色圆箭头色
  final int topBtnRingColor;  // 圆环颜色
  final double topBtnRingWidth;
  final double topBtnOpacity;
  final double topBtnScale;
  final double topBtnX;       // 0.0-1.0 相对屏幕宽
  final double topBtnY;       // 0.0-1.0 相对屏幕高

  // ==================== 下一文件按钮 ====================

  final int bottomBtnStyle;
  final int bottomBtnBgColor;
  final int bottomBtnFgColor;
  final int bottomBtnRingColor;
  final double bottomBtnRingWidth;
  final double bottomBtnOpacity;
  final double bottomBtnScale;
  final double bottomBtnX;
  final double bottomBtnY;

  // ==================== 删除文件按钮 ====================
  //
  // 和上/下文件按钮完全同构：三种样式开关、三组颜色、透明度、
  // 大小、位置，全部独立可配。图标固定用自定义垃圾桶（不随配置变）。

  /// 样式：0 = 纯色圆（有垃圾桶图标），1 = 圆环（也有垃圾桶图标）。
  final int delBtnStyle;
  final int delBtnBgColor;    // 纯色圆背景色
  final int delBtnFgColor;    // 纯色圆图标色
  final int delBtnRingColor;  // 圆环颜色（兼图标色）
  final double delBtnRingWidth;
  final double delBtnOpacity;
  final double delBtnScale;
  final double delBtnX;
  final double delBtnY;

  // ==================== 菜单热区 ====================
  //
  // 热区是一个矩形，中心在 (hotZoneX, hotZoneY)（0-1 相对屏幕内容区），
  // 宽高分别是 hotZoneW、hotZoneH（0-1 相对屏幕内容区）。
  //
  // 点击热区 → 打开顶部菜单；其它区域 → 翻下一页（或按悬浮按钮逻辑）。

  /// 是否在阅读页里把热区样式画出来。关掉后依旧可以点，只是看不见。
  final bool hotZoneVisible;

  /// 样式：0 = 整块填色，1 = 分界线（四周一圈线，贴屏幕的边不画）。
  final int hotZoneStyle;
  final int hotZoneColor;
  final double hotZoneOpacity;
  final double hotZoneBorderWidth; // 分界线样式的线粗
  final double hotZoneX;
  final double hotZoneY;
  final double hotZoneW;
  final double hotZoneH;

  static const int bgCream = 0xFFFAF7EC;
  static const int bgWhite = 0xFFFFFFFF;
  static const int bgGreen = 0xFFC7EDCC;

  static const ReaderSettings initial = ReaderSettings(
    fontSize: 17.0,
    fontWeight: 400,
    bgColor: bgCream,
    showButtons: true,
    readerMode: 0,

    topBtnStyle: 0,
    topBtnBgColor: 0x59000000, // 黑 35%，接近原来的样子
    topBtnFgColor: 0xFFFFFFFF,
    topBtnRingColor: 0xFF3D7CFF,
    topBtnRingWidth: 2.0,
    topBtnOpacity: 0.7,
    topBtnScale: 1.0,
    topBtnX: 0.90,
    topBtnY: 0.15,

    bottomBtnStyle: 0,
    bottomBtnBgColor: 0x59000000,
    bottomBtnFgColor: 0xFFFFFFFF,
    bottomBtnRingColor: 0xFF3D7CFF,
    bottomBtnRingWidth: 2.0,
    bottomBtnOpacity: 0.7,
    bottomBtnScale: 1.0,
    bottomBtnX: 0.90,
    bottomBtnY: 0.85,

    // 删除按钮：左下角，半透明红。
    delBtnStyle: 0,
    delBtnBgColor: 0x59B00020,
    delBtnFgColor: 0xFFFFFFFF,
    delBtnRingColor: 0xFFB00020,
    delBtnRingWidth: 2.0,
    delBtnOpacity: 0.7,
    delBtnScale: 1.0,
    delBtnX: 0.10,
    delBtnY: 0.85,

    hotZoneVisible: false,
    hotZoneStyle: 1,
    hotZoneColor: 0xFFFF0000,
    hotZoneOpacity: 0.6,
    hotZoneBorderWidth: 1.5,
    hotZoneX: 0.5,
    hotZoneY: 0.03,
    hotZoneW: 1.0,
    hotZoneH: 0.06,
  );

  Map<String, dynamic> toJson() => {
        'fs': fontSize,
        'fw': fontWeight,
        'bg': bgColor,
        'sb': showButtons,
        'rm': readerMode,

        'tbs': topBtnStyle,
        'tbb': topBtnBgColor,
        'tbf': topBtnFgColor,
        'tbr': topBtnRingColor,
        'tbrw': topBtnRingWidth,
        'tbo': topBtnOpacity,
        'tbscl': topBtnScale,
        'tx': topBtnX,
        'ty': topBtnY,

        'bbs': bottomBtnStyle,
        'bbb': bottomBtnBgColor,
        'bbf': bottomBtnFgColor,
        'bbr': bottomBtnRingColor,
        'bbrw': bottomBtnRingWidth,
        'bbo': bottomBtnOpacity,
        'bbscl': bottomBtnScale,
        'bx': bottomBtnX,
        'by': bottomBtnY,

        'dbs': delBtnStyle,
        'dbb': delBtnBgColor,
        'dbf': delBtnFgColor,
        'dbr': delBtnRingColor,
        'dbrw': delBtnRingWidth,
        'dbo': delBtnOpacity,
        'dbscl': delBtnScale,
        'dx': delBtnX,
        'dy': delBtnY,

        'hv': hotZoneVisible,
        'hs': hotZoneStyle,
        'hc': hotZoneColor,
        'ho': hotZoneOpacity,
        'hbw': hotZoneBorderWidth,
        'hx': hotZoneX,
        'hy': hotZoneY,
        'hw': hotZoneW,
        'hh': hotZoneH,
      };

  factory ReaderSettings.fromJson(Map<String, dynamic> j) => ReaderSettings(
        fontSize: (j['fs'] as num?)?.toDouble() ?? 17.0,
        fontWeight: (j['fw'] as num?)?.toInt() ?? 400,
        bgColor: (j['bg'] as num?)?.toInt() ?? bgCream,
        showButtons: j['sb'] as bool? ?? true,
        readerMode: (j['rm'] as num?)?.toInt() ?? 0,

        topBtnStyle: (j['tbs'] as num?)?.toInt() ?? 0,
        topBtnBgColor: (j['tbb'] as num?)?.toInt() ?? 0x59000000,
        topBtnFgColor: (j['tbf'] as num?)?.toInt() ?? 0xFFFFFFFF,
        topBtnRingColor: (j['tbr'] as num?)?.toInt() ?? 0xFF3D7CFF,
        topBtnRingWidth: (j['tbrw'] as num?)?.toDouble() ?? 2.0,
        topBtnOpacity: (j['tbo'] as num?)?.toDouble() ?? 0.7,
        topBtnScale: (j['tbscl'] as num?)?.toDouble() ?? 1.0,
        topBtnX: (j['tx'] as num?)?.toDouble() ?? 0.90,
        topBtnY: (j['ty'] as num?)?.toDouble() ?? 0.15,

        bottomBtnStyle: (j['bbs'] as num?)?.toInt() ?? 0,
        bottomBtnBgColor: (j['bbb'] as num?)?.toInt() ?? 0x59000000,
        bottomBtnFgColor: (j['bbf'] as num?)?.toInt() ?? 0xFFFFFFFF,
        bottomBtnRingColor: (j['bbr'] as num?)?.toInt() ?? 0xFF3D7CFF,
        bottomBtnRingWidth: (j['bbrw'] as num?)?.toDouble() ?? 2.0,
        bottomBtnOpacity: (j['bbo'] as num?)?.toDouble() ?? 0.7,
        bottomBtnScale: (j['bbscl'] as num?)?.toDouble() ?? 1.0,
        bottomBtnX: (j['bx'] as num?)?.toDouble() ?? 0.90,
        bottomBtnY: (j['by'] as num?)?.toDouble() ?? 0.85,

        delBtnStyle: (j['dbs'] as num?)?.toInt() ?? 0,
        delBtnBgColor: (j['dbb'] as num?)?.toInt() ?? 0x59B00020,
        delBtnFgColor: (j['dbf'] as num?)?.toInt() ?? 0xFFFFFFFF,
        delBtnRingColor: (j['dbr'] as num?)?.toInt() ?? 0xFFB00020,
        delBtnRingWidth: (j['dbrw'] as num?)?.toDouble() ?? 2.0,
        delBtnOpacity: (j['dbo'] as num?)?.toDouble() ?? 0.7,
        delBtnScale: (j['dbscl'] as num?)?.toDouble() ?? 1.0,
        delBtnX: (j['dx'] as num?)?.toDouble() ?? 0.10,
        delBtnY: (j['dy'] as num?)?.toDouble() ?? 0.85,

        hotZoneVisible: j['hv'] as bool? ?? false,
        hotZoneStyle: (j['hs'] as num?)?.toInt() ?? 1,
        hotZoneColor: (j['hc'] as num?)?.toInt() ?? 0xFFFF0000,
        hotZoneOpacity: (j['ho'] as num?)?.toDouble() ?? 0.6,
        hotZoneBorderWidth: (j['hbw'] as num?)?.toDouble() ?? 1.5,
        hotZoneX: (j['hx'] as num?)?.toDouble() ?? 0.5,
        hotZoneY: (j['hy'] as num?)?.toDouble() ?? 0.03,
        hotZoneW: (j['hw'] as num?)?.toDouble() ?? 1.0,
        hotZoneH: (j['hh'] as num?)?.toDouble() ?? 0.06,
      );

  ReaderSettings copyWith({
    double? fontSize,
    int? fontWeight,
    int? bgColor,
    bool? showButtons,
    int? readerMode,

    int? topBtnStyle,
    int? topBtnBgColor,
    int? topBtnFgColor,
    int? topBtnRingColor,
    double? topBtnRingWidth,
    double? topBtnOpacity,
    double? topBtnScale,
    double? topBtnX,
    double? topBtnY,

    int? bottomBtnStyle,
    int? bottomBtnBgColor,
    int? bottomBtnFgColor,
    int? bottomBtnRingColor,
    double? bottomBtnRingWidth,
    double? bottomBtnOpacity,
    double? bottomBtnScale,
    double? bottomBtnX,
    double? bottomBtnY,

    int? delBtnStyle,
    int? delBtnBgColor,
    int? delBtnFgColor,
    int? delBtnRingColor,
    double? delBtnRingWidth,
    double? delBtnOpacity,
    double? delBtnScale,
    double? delBtnX,
    double? delBtnY,

    bool? hotZoneVisible,
    int? hotZoneStyle,
    int? hotZoneColor,
    double? hotZoneOpacity,
    double? hotZoneBorderWidth,
    double? hotZoneX,
    double? hotZoneY,
    double? hotZoneW,
    double? hotZoneH,
  }) =>
      ReaderSettings(
        fontSize: fontSize ?? this.fontSize,
        fontWeight: fontWeight ?? this.fontWeight,
        bgColor: bgColor ?? this.bgColor,
        showButtons: showButtons ?? this.showButtons,
        readerMode: readerMode ?? this.readerMode,

        topBtnStyle: topBtnStyle ?? this.topBtnStyle,
        topBtnBgColor: topBtnBgColor ?? this.topBtnBgColor,
        topBtnFgColor: topBtnFgColor ?? this.topBtnFgColor,
        topBtnRingColor: topBtnRingColor ?? this.topBtnRingColor,
        topBtnRingWidth: topBtnRingWidth ?? this.topBtnRingWidth,
        topBtnOpacity: topBtnOpacity ?? this.topBtnOpacity,
        topBtnScale: topBtnScale ?? this.topBtnScale,
        topBtnX: topBtnX ?? this.topBtnX,
        topBtnY: topBtnY ?? this.topBtnY,

        bottomBtnStyle: bottomBtnStyle ?? this.bottomBtnStyle,
        bottomBtnBgColor: bottomBtnBgColor ?? this.bottomBtnBgColor,
        bottomBtnFgColor: bottomBtnFgColor ?? this.bottomBtnFgColor,
        bottomBtnRingColor: bottomBtnRingColor ?? this.bottomBtnRingColor,
        bottomBtnRingWidth: bottomBtnRingWidth ?? this.bottomBtnRingWidth,
        bottomBtnOpacity: bottomBtnOpacity ?? this.bottomBtnOpacity,
        bottomBtnScale: bottomBtnScale ?? this.bottomBtnScale,
        bottomBtnX: bottomBtnX ?? this.bottomBtnX,
        bottomBtnY: bottomBtnY ?? this.bottomBtnY,

        delBtnStyle: delBtnStyle ?? this.delBtnStyle,
        delBtnBgColor: delBtnBgColor ?? this.delBtnBgColor,
        delBtnFgColor: delBtnFgColor ?? this.delBtnFgColor,
        delBtnRingColor: delBtnRingColor ?? this.delBtnRingColor,
        delBtnRingWidth: delBtnRingWidth ?? this.delBtnRingWidth,
        delBtnOpacity: delBtnOpacity ?? this.delBtnOpacity,
        delBtnScale: delBtnScale ?? this.delBtnScale,
        delBtnX: delBtnX ?? this.delBtnX,
        delBtnY: delBtnY ?? this.delBtnY,

        hotZoneVisible: hotZoneVisible ?? this.hotZoneVisible,
        hotZoneStyle: hotZoneStyle ?? this.hotZoneStyle,
        hotZoneColor: hotZoneColor ?? this.hotZoneColor,
        hotZoneOpacity: hotZoneOpacity ?? this.hotZoneOpacity,
        hotZoneBorderWidth: hotZoneBorderWidth ?? this.hotZoneBorderWidth,
        hotZoneX: hotZoneX ?? this.hotZoneX,
        hotZoneY: hotZoneY ?? this.hotZoneY,
        hotZoneW: hotZoneW ?? this.hotZoneW,
        hotZoneH: hotZoneH ?? this.hotZoneH,
      );

  String encode() => jsonEncode(toJson());

  static ReaderSettings tryDecode(String? s) {
    if (s == null || s.isEmpty) return initial;
    try {
      return ReaderSettings.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return initial;
    }
  }
}

/// ==================== 查找历史项 ====================
class FindHistoryItem {
  const FindHistoryItem({
    required this.word,
    required this.isFavorite,
    required this.usedAt,
  });

  final String word;
  final bool isFavorite;
  final int usedAt;

  FindHistoryItem copyWith({bool? isFavorite, int? usedAt}) =>
      FindHistoryItem(
        word: word,
        isFavorite: isFavorite ?? this.isFavorite,
        usedAt: usedAt ?? this.usedAt,
      );

  Map<String, dynamic> toJson() => {
        'w': word,
        'f': isFavorite,
        't': usedAt,
      };

  factory FindHistoryItem.fromJson(Map<String, dynamic> j) => FindHistoryItem(
        word: j['w'] as String,
        isFavorite: j['f'] as bool? ?? false,
        usedAt: (j['t'] as num?)?.toInt() ?? 0,
      );
}

/// ==================== 渲染单元 ====================
///
/// 普通行：一个逻辑行 = 一个 RenderUnit。
/// 超长行（一屏放不下）：拆成多个 RenderUnit，每段高度 ≤ 一页。
class RenderUnit {
  const RenderUnit({
    required this.lineIndex,
    required this.charStart,
    required this.charEnd,
    required this.height,
  });

  final int lineIndex;
  final int charStart;
  final int charEnd;
  final double height;

  @override
  String toString() =>
      'RenderUnit(line=$lineIndex, [$charStart,$charEnd), h=$height)';
}

/// ==================== 分页结果 ====================
class PaginationResult {
  const PaginationResult({
    required this.pageStarts,
    required this.renderUnits,
    required this.lineStarts,
    required this.totalChars,
  });

  /// 每页的起始 RenderUnit 索引。
  final List<int> pageStarts;

  /// 所有渲染单元，按顺序排列。
  final List<RenderUnit> renderUnits;

  /// 每个逻辑行的字符起始偏移。
  final List<int> lineStarts;

  /// 全文总字符数。
  final int totalChars;

  int get pageCount => pageStarts.length;
}

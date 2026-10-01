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
class ReaderSettings {
  const ReaderSettings({
    required this.fontSize,
    required this.fontWeight,
    required this.bgColor,
    required this.buttonOpacity,
    required this.buttonScale,
    required this.showButtons,
    required this.topBtnX,
    required this.topBtnY,
    required this.bottomBtnX,
    required this.bottomBtnY,
    required this.topHotZoneHeight,
  });

  /// 4.0 - 60.0
  final double fontSize;

  /// 100 - 900（100=极细，400=正常，900=最粗）
  final int fontWeight;

  /// 背景色 ARGB
  final int bgColor;

  /// 浮动按钮透明度 0.1 - 1.0
  final double buttonOpacity;

  /// 浮动按钮整体缩放 0.3 - 5.0（最大约屏幕宽 60%）
  final double buttonScale;

  /// 浮动按钮是否显示
  final bool showButtons;

  /// 上按钮 X 位置（0.0-1.0 相对屏幕宽）
  final double topBtnX;

  /// 上按钮 Y 位置（0.0-1.0 相对屏幕高）
  final double topBtnY;

  /// 下按钮 X 位置
  final double bottomBtnX;

  /// 下按钮 Y 位置
  final double bottomBtnY;

  /// 顶部菜单热区高度（像素，20-200）
  final double topHotZoneHeight;

  static const int bgCream = 0xFFFAF7EC;
  static const int bgWhite = 0xFFFFFFFF;
  static const int bgGreen = 0xFFC7EDCC;

  static const ReaderSettings initial = ReaderSettings(
    fontSize: 17.0,
    fontWeight: 400,
    bgColor: bgCream,
    buttonOpacity: 0.7,
    buttonScale: 1.0,
    showButtons: true,
    topBtnX: 0.90,
    topBtnY: 0.15,
    bottomBtnX: 0.90,
    bottomBtnY: 0.85,
    topHotZoneHeight: 40.0,
  );

  Map<String, dynamic> toJson() => {
        'fs': fontSize,
        'fw': fontWeight,
        'bg': bgColor,
        'op': buttonOpacity,
        'sc': buttonScale,
        'sb': showButtons,
        'tx': topBtnX,
        'ty': topBtnY,
        'bx': bottomBtnX,
        'by': bottomBtnY,
        'th': topHotZoneHeight,
      };

  factory ReaderSettings.fromJson(Map<String, dynamic> j) => ReaderSettings(
        fontSize: (j['fs'] as num?)?.toDouble() ?? 17.0,
        fontWeight: (j['fw'] as num?)?.toInt() ?? 400,
        bgColor: (j['bg'] as num?)?.toInt() ?? bgCream,
        buttonOpacity: (j['op'] as num?)?.toDouble() ?? 0.7,
        buttonScale: (j['sc'] as num?)?.toDouble() ?? 1.0,
        showButtons: j['sb'] as bool? ?? true,
        topBtnX: (j['tx'] as num?)?.toDouble() ?? 0.90,
        topBtnY: (j['ty'] as num?)?.toDouble() ?? 0.15,
        bottomBtnX: (j['bx'] as num?)?.toDouble() ?? 0.90,
        bottomBtnY: (j['by'] as num?)?.toDouble() ?? 0.85,
        topHotZoneHeight: (j['th'] as num?)?.toDouble() ?? 40.0,
      );

  ReaderSettings copyWith({
    double? fontSize,
    int? fontWeight,
    int? bgColor,
    double? buttonOpacity,
    double? buttonScale,
    bool? showButtons,
    double? topBtnX,
    double? topBtnY,
    double? bottomBtnX,
    double? bottomBtnY,
    double? topHotZoneHeight,
  }) =>
      ReaderSettings(
        fontSize: fontSize ?? this.fontSize,
        fontWeight: fontWeight ?? this.fontWeight,
        bgColor: bgColor ?? this.bgColor,
        buttonOpacity: buttonOpacity ?? this.buttonOpacity,
        buttonScale: buttonScale ?? this.buttonScale,
        showButtons: showButtons ?? this.showButtons,
        topBtnX: topBtnX ?? this.topBtnX,
        topBtnY: topBtnY ?? this.topBtnY,
        bottomBtnX: bottomBtnX ?? this.bottomBtnX,
        bottomBtnY: bottomBtnY ?? this.bottomBtnY,
        topHotZoneHeight: topHotZoneHeight ?? this.topHotZoneHeight,
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

/// ==================== 分页结果 ====================
class PaginationResult {
  const PaginationResult({
    required this.pageStarts,
    required this.lineStarts,
    required this.lineHeights,
    required this.totalChars,
  });

  /// 每页的起始行号
  final List<int> pageStarts;

  /// 每行在全文的起始字符偏移
  final List<int> lineStarts;

  /// 每行的估算高度（像素）
  final List<double> lineHeights;

  /// 全文总字符数
  final int totalChars;

  int get pageCount => pageStarts.length;
}

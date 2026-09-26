import 'package:flutter_js/flutter_js.dart';

/// JS 运行时封装。
///
/// 用途：让用户在规则里写 JavaScript 处理文本。
///
/// 约定：
///   - 脚本里有变量 `text`，是输入的整段文本。
///   - 脚本最后一行应该是表达式，值作为输出文本返回。
///   - 返回非字符串时会被 toString。
///   - 抛异常时返回原文本，并记下错误信息。
///
/// 性能注意：
///   - 引擎单例，初始化一次。
///   - 每次调用都在同一个 runtime 上跑，不要频繁创建。
///   - 大文本 + 复杂脚本会慢。脚本尽量放在规则顺序末尾。
class JsRuntime {
  JsRuntime._();

  static final JsRuntime instance = JsRuntime._();

  JavascriptRuntime? _runtime;
  bool _initializing = false;

  /// 最近一次执行的错误信息。null 表示没有错误。
  String? lastError;

  /// 确保引擎已就绪。同步。
  void ensureReady() {
    if (_runtime != null) return;
    _doInit();
  }

  void _doInit() {
    if (_initializing) return;
    _initializing = true;
    try {
      _runtime = getJavascriptRuntime();
      // 注入一些常用辅助，省得用户每次都写。
      _runtime!.evaluate(r'''
        var __lines = null;
        function getLines() {
          if (__lines === null) __lines = text.split('\n');
          return __lines;
        }
        function joinLines(arr) {
          return arr.join('\n');
        }
      ''');
    } finally {
      _initializing = false;
    }
  }

  /// 执行一段 JS 脚本，输入 [text]，返回处理后的文本。
  ///
  /// 出错时返回原文本，错误信息写入 [lastError]。
  String run(String script, String text) {
    lastError = null;
    ensureReady();
    final rt = _runtime;
    if (rt == null) {
      lastError = 'JS 引擎未初始化';
      return text;
    }

    try {
      // 把 text 注入成 JS 变量。用 JSON 编码避免转义问题。
      rt.evaluate('var text = ${_jsonString(text)};');

      // 执行用户脚本。
      final wrapped = _wrapScript(script);

      final result = rt.evaluate(wrapped);

      if (result.isError) {
        lastError = result.stringResult;
        return text;
      }

      final v = result.stringResult;
      if (v.isEmpty && script.trim().isNotEmpty) {
        // 脚本没有 return，可能写成了语句而非表达式。
        lastError = '脚本没有返回值';
        return text;
      }
      return v;
    } catch (e) {
      lastError = e.toString();
      return text;
    }
  }

  /// 把用户脚本包成 IIFE，最后一行变成 return。
  String _wrapScript(String script) {
    final lines = script.split('\n');
    // 去掉尾部空行。
    var end = lines.length - 1;
    while (end >= 0 && lines[end].trim().isEmpty) {
      end--;
    }
    if (end < 0) return '(function(){ return text; })()';

    final before = lines.sublist(0, end).join('\n');
    final last = lines[end];

    // 最后一行是否已经是 return / 语句结尾。
    final trimmed = last.trim();
    if (trimmed.startsWith('return ') || trimmed == 'return') {
      return '(function(){\n$before\n$last\n})()';
    }

    // 最后一行是表达式 → 包成 return。
    return '(function(){\n$before\nreturn ($last);\n})()';
  }

  /// 把字符串安全地嵌进 JS。用 JSON 编码。
  String _jsonString(String s) {
    final sb = StringBuffer('"');
    for (final rune in s.runes) {
      switch (rune) {
        case 0x22:
          sb.write(r'\"');
          break;
        case 0x5C:
          sb.write(r'\\');
          break;
        case 0x0A:
          sb.write(r'\n');
          break;
        case 0x0D:
          sb.write(r'\r');
          break;
        case 0x09:
          sb.write(r'\t');
          break;
        case 0x08:
          sb.write(r'\b');
          break;
        case 0x0C:
          sb.write(r'\f');
          break;
        default:
          if (rune < 0x20) {
            sb.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            sb.writeCharCode(rune);
          }
      }
    }
    sb.write('"');
    return sb.toString();
  }

  /// 释放引擎。一般不用调。
  void dispose() {
    _runtime?.dispose();
    _runtime = null;
  }
}

/// 一份 JS 脚本模板。UI 里"新建 JS 规则"时预填这个。
const String defaultJsTemplate = r'''
// text 是输入文本。
// 最后一行是你的处理结果（表达式）。
//
// 例子：
//   去掉重复行：
//     [...new Set(text.split('\n'))].join('\n')
//
//   每行前加行号：
//     text.split('\n').map((l, i) => `${i + 1}. ${l}`).join('\n')
//
//   只保留含"第X章"的行：
//     text.split('\n').filter(l => /^第\d+章/.test(l)).join('\n')
//
//   删除空行：
//     text.split('\n').filter(l => l.trim()).join('\n')

text.split('\n').filter(l => l.trim()).join('\n')
''';

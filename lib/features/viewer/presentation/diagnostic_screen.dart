import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import 'providers/diff_viewer_providers.dart';

// ==================== 诊断工具 ====================

class ViewerDiag {
  ViewerDiag._();
  static final List<({String tag, int ms})> _entries = [];
  static final Stopwatch _sw = Stopwatch()..start();

  static void reset() {
    _entries.clear();
    _sw.reset();
    _sw.start();
  }

  static void mark(String tag) {
    _entries.add((tag: tag, ms: _sw.elapsedMilliseconds));
  }

  static List<({String tag, int ms})> get entries =>
      List.unmodifiable(_entries);
}

/// 本次会话的操作历史。
class DiagHistory {
  DiagHistory._();
  static const int _max = 500;
  static final List<({DateTime time, String msg})> _entries = [];

  static void record(String msg) {
    _entries.add((time: DateTime.now(), msg: msg));
    if (_entries.length > _max) _entries.removeAt(0);
  }

  static List<({DateTime time, String msg})> get entries =>
      List.unmodifiable(_entries);

  static void clear() => _entries.clear();
}

final diagPerfEnabledProvider = StateProvider<bool>((ref) => false);
final diagFileEnabledProvider = StateProvider<bool>((ref) => false);
final diagTimeEnabledProvider = StateProvider<bool>((ref) => false);
final diagHistoryEnabledProvider = StateProvider<bool>((ref) => false);

String dumpChars(String s, {Set<int> diffAt = const {}}) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final mark = diffAt.contains(i) ? '★' : ' ';
    String vis;
    if (c == 0x0D) {
      vis = r'\r';
    } else if (c == 0x0A) {
      vis = r'\n';
    } else if (c == 0x09) {
      vis = r'\t';
    } else if (c == 0x20) {
      vis = '␣';
    } else if (c == 0x3000) {
      vis = '全角空格';
    } else if (c == 0xA0) {
      vis = 'NBSP';
    } else if (c == 0x200B) {
      vis = 'ZWSP';
    } else if (c == 0x200C) {
      vis = 'ZWNJ';
    } else if (c == 0x200D) {
      vis = 'ZWJ';
    } else if (c == 0xFEFF) {
      vis = 'BOM';
    } else if (c == 0x2028) {
      vis = '行分隔符';
    } else if (c == 0x2029) {
      vis = '段分隔符';
    } else if (c < 0x20 || c == 0x7F) {
      vis = '控制字符';
    } else {
      vis = String.fromCharCode(c);
    }
    sb.writeln(
        '$mark[$i] $vis  U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}');
  }
  return sb.toString();
}

Map<String, int> charStats(String s) {
  var crlf = 0;
  var lf = 0;
  var cr = 0;
  var fwSpace = 0;
  var nbsp = 0;
  var zwsp = 0;
  var bom = 0;
  var tab = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x0A) {
      if (i > 0 && s.codeUnitAt(i - 1) == 0x0D) {
        crlf++;
      } else {
        lf++;
      }
    } else if (c == 0x0D) {
      cr++;
    } else if (c == 0x3000) {
      fwSpace++;
    } else if (c == 0xA0) {
      nbsp++;
    } else if (c == 0x200B) {
      zwsp++;
    } else if (c == 0xFEFF) {
      bom++;
    } else if (c == 0x09) {
      tab++;
    }
  }
  return {
    'CRLF(\\r\\n)': crlf,
    'LF(\\n)': lf,
    'CR(\\r)': cr,
    '全角空格 U+3000': fwSpace,
    'NBSP U+00A0': nbsp,
    'ZWSP U+200B': zwsp,
    'BOM U+FEFF': bom,
    'Tab': tab,
  };
}

// ==================== 诊断页 ====================

class DiagnosticScreen extends ConsumerWidget {
  const DiagnosticScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断'),
        actions: [
          TextButton(
            onPressed: () {
              DiagHistory.clear();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('历史已清空')),
              );
            },
            child: const Text('清空历史'),
          ),
        ],
      ),
      body: ListView(
        children: [
          DiagRow(
            title: '性能',
            subtitle: '最近一次 diff 的耗时与行数',
            enabled: ref.watch(diagPerfEnabledProvider),
            onToggle: (v) =>
                ref.read(diagPerfEnabledProvider.notifier).state = v,
            onTap: () => _showPerf(context, ref),
          ),
          DiagRow(
            title: '文件',
            subtitle: '两份文件的行数、特殊字符统计、前 20 行预览',
            enabled: ref.watch(diagFileEnabledProvider),
            onToggle: (v) =>
                ref.read(diagFileEnabledProvider.notifier).state = v,
            onTap: () => _showFile(context, ref),
          ),
          DiagRow(
            title: '耗时',
            subtitle: '本次渲染各阶段的耗时明细',
            enabled: ref.watch(diagTimeEnabledProvider),
            onToggle: (v) =>
                ref.read(diagTimeEnabledProvider.notifier).state = v,
            onTap: () => _showTime(context, ref),
          ),
          DiagRow(
            title: '历史',
            subtitle: '本次会话的操作记录（${DiagHistory.entries.length} 条）',
            enabled: ref.watch(diagHistoryEnabledProvider),
            onToggle: (v) =>
                ref.read(diagHistoryEnabledProvider.notifier).state = v,
            onTap: () => _showHistory(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _showPerf(BuildContext context, WidgetRef ref) async {
    final perf = ref.read(lastDiffPerfProvider);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('性能', style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.6,
          child: perf == null
              ? const Center(child: Text('还没有 diff 结果'))
              : SingleChildScrollView(
                  child: SelectableText(
                    perf.oneLine,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFile(BuildContext context, WidgetRef ref) async {
    final orig = ref.read(preprocessedOriginalProvider);
    final mod = ref.read(preprocessedModifiedProvider);
    final oStats = charStats(orig);
    final mStats = charStats(mod);
    final oLines = orig.split('\n');
    final mLines = mod.split('\n');

    const preview = 20;

    Widget statBlock(String title, Map<String, int> stats) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          for (final e in stats.entries)
            Text('  ${e.key}: ${e.value}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      );
    }

    Widget lineBlock(String title, List<String> lines) {
      final sb = StringBuffer();
      for (var i = 0; i < lines.length && i < preview; i++) {
        final t = lines[i];
        final shown = t.length > 40 ? '${t.substring(0, 40)}…' : t;
        final w = t.runes.length;
        sb.writeln('${(i + 1).toString().padLeft(3)} [$w] $shown');
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(
            sb.toString(),
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 11, height: 1.4),
          ),
        ],
      );
    }

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('文件诊断', style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.8,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '左总长 ${orig.length}（行 ${oLines.length}）  '
                  '右总长 ${mod.length}（行 ${mLines.length}）',
                  style: const TextStyle(fontSize: 12),
                ),
                const Divider(),
                statBlock('左边特殊字符', oStats),
                const SizedBox(height: 8),
                statBlock('右边特殊字符', mStats),
                const Divider(),
                lineBlock('左边前 $preview 行', oLines),
                const SizedBox(height: 12),
                lineBlock('右边前 $preview 行', mLines),
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
      ),
    );
  }

  Future<void> _showTime(BuildContext context, WidgetRef ref) async {
    final entries = ViewerDiag.entries;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('耗时诊断', style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.6,
          child: entries.isEmpty
              ? const Center(child: Text('还没有记录'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (ctx, i) {
                    final e = entries[i];
                    final prev = i == 0 ? 0 : entries[i - 1].ms;
                    final delta = e.ms - prev;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '+${delta}ms  (累计 ${e.ms}ms)  ${e.tag}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showHistory(BuildContext context, WidgetRef ref) async {
    final entries = DiagHistory.entries;

    String fmt(DateTime t) {
      String two(int n) => n < 10 ? '0$n' : '$n';
      return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    }

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: const Text('历史', style: TextStyle(fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.75,
          child: entries.isEmpty
              ? const Center(child: Text('还没有记录'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (ctx, i) {
                    final e = entries[entries.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${fmt(e.time)}  ',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              e.msg,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class DiagRow extends StatelessWidget {
  const DiagRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onToggle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          enabled: enabled,
          title: Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: enabled ? null : s.onSurface.withOpacity(0.4),
            ),
          ),
          subtitle: Text(
            enabled ? subtitle : '关闭',
            style: TextStyle(
              fontSize: 12,
              color: enabled ? s.onSurfaceVariant : s.outline,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (enabled)
                Icon(Icons.chevron_right, color: s.onSurfaceVariant),
              const SizedBox(width: 4),
              Switch(
                value: enabled,
                onChanged: onToggle,
              ),
            ],
          ),
          onTap: enabled ? onTap : null,
        ),
        const Divider(height: 1),
      ],
    );
  }
}

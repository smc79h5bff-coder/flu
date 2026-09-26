/// Aho-Corasick 多模式字符串替换器。
///
/// 一次扫描 O(n + m) 找出所有模式（n 文本长度，m 匹配数），
/// 用于替换/删除多个关键词——比 N 个正则交替快得多。
///
/// 语义：
/// - 非重叠匹配（找到一次后从匹配起点之后继续）。
/// - 同一位置多个模式命中时，最长模式优先。
/// - 空模式会被忽略。
class AhoCorasick {
  AhoCorasick({
    required this.patterns,
    required this.replacements,
  }) : assert(patterns.length == replacements.length) {
    _build();
  }

  final List<String> patterns;
  final List<String> replacements;

  /// Trie 子节点：nodeId -> (charCode -> childNodeId)。
  final List<Map<int, int>> _children = <Map<int, int>>[<int, int>{}];

  /// 失败指针：nodeId -> failNodeId。
  final List<int> _fail = <int>[0];

  /// 每个节点终止的模式下标列表（含通过 fail 继承的）。
  final List<List<int>> _output = <List<int>>[<int>[]];

  void _build() {
    // 1. 建 trie
    for (var i = 0; i < patterns.length; i++) {
      final p = patterns[i];
      if (p.isEmpty) continue;
      var node = 0;
      for (final code in p.codeUnits) {
        node = _children[node].putIfAbsent(code, () {
          _children.add(<int, int>{});
          _fail.add(0);
          _output.add(<int>[]);
          return _children.length - 1;
        });
      }
      _output[node].add(i);
    }

    // 2. 建 fail 指针（BFS）
    final queue = <int>[];
    // 根的直接子节点：fail 指向根
    for (final child in _children[0].values) {
      _fail[child] = 0;
      queue.add(child);
    }

    var head = 0;
    while (head < queue.length) {
      final node = queue[head++];
      _children[node].forEach((code, child) {
        // 找 child 的 fail：沿 node 的 fail 链找有 code 转移的节点
        var f = _fail[node];
        while (f != 0 && _children[f][code] == null) {
          f = _fail[f];
        }
        final next = _children[f][code];
        _fail[child] = (next != null && next != child) ? next : 0;
        // 继承 fail 节点的 output（此时 fail 的 output 已完整）
        _output[child] = <int>[
          ..._output[child],
          ..._output[_fail[child]],
        ];
        queue.add(child);
      });
    }
  }

  /// 单次扫描，替换所有匹配。重叠时按最长模式优先，非重叠。
  String replaceAll(String text) {
    if (text.isEmpty || patterns.isEmpty) return text;

    final buf = StringBuffer();
    var last = 0;
    var pos = 0;
    var node = 0;

    while (pos < text.length) {
      final code = text.codeUnitAt(pos);
      // 沿 fail 链回退，直到找到有 code 转移的节点或回到根
      while (node != 0 && _children[node][code] == null) {
        node = _fail[node];
      }
      node = _children[node][code] ?? 0;

      final outs = _output[node];
      if (outs.isNotEmpty) {
        // 同一位置可能有多个模式终止，选最长的
        var bestLen = 0;
        var bestIdx = -1;
        for (final pi in outs) {
          final len = patterns[pi].length;
          if (len > bestLen) {
            bestLen = len;
            bestIdx = pi;
          }
        }
        final matchStart = pos - bestLen + 1;
        if (matchStart >= last) {
          buf.write(text.substring(last, matchStart));
          buf.write(replacements[bestIdx]);
          last = pos + 1;
        }
        // 非重叠：重置到根
        node = 0;
      }
      pos++;
    }

    if (last < text.length) {
      buf.write(text.substring(last));
    }
    return buf.toString();
  }
}

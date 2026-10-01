/// Aho-Corasick 多模式字符串替换器（方案 D：行号优先）。
///
/// 语义：
/// - 所有模式（删除 + 替换）合成一棵树，一次扫描。
/// - 同一位置多条模式命中时，**选优先级最小（行号最小）的那条**。
/// - 命中后跳到匹配结束位置继续扫。
/// - 新产生的文本不再参与后续匹配。
/// - 空模式会被忽略。
///
/// [priorities] 与 [patterns] 一一对应，数值越小越优先。
/// 对于"规则表"场景，priority 等于该规则在文本里的物理行号。
class AhoCorasick {
  AhoCorasick({
    required this.patterns,
    required this.replacements,
    required this.priorities,
  })  : assert(patterns.length == replacements.length),
        assert(patterns.length == priorities.length) {
    _build();
  }

  final List<String> patterns;
  final List<String> replacements;

  /// 每条模式的优先级，数值越小越优先。
  final List<int> priorities;

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
    for (final child in _children[0].values) {
      _fail[child] = 0;
      queue.add(child);
    }

    var head = 0;
    while (head < queue.length) {
      final node = queue[head++];
      _children[node].forEach((code, child) {
        var f = _fail[node];
        while (f != 0 && _children[f][code] == null) {
          f = _fail[f];
        }
        final next = _children[f][code];
        _fail[child] = (next != null && next != child) ? next : 0;
        _output[child] = <int>[
          ..._output[child],
          ..._output[_fail[child]],
        ];
        queue.add(child);
      });
    }
  }


/// 扫描文本，把每个匹配通过回调返回。
///
/// 相比 replaceAll，这个不物化结果列表、不做替换，内存零开销。
/// 匹配按"结束位置升序"输出（AC 的天然顺序）。
///
/// - [onMatch] 参数：(start, end, patternIndex)
/// - 跨行匹配不做处理，调用方自己判断。
void findAllMatches(
  String text,
  void Function(int start, int end, int patternIndex) onMatch,
) {
  if (text.isEmpty || patterns.isEmpty) return;

  var node = 0;
  for (var pos = 0; pos < text.length; pos++) {
    final code = text.codeUnitAt(pos);
    while (node != 0 && _children[node][code] == null) {
      node = _fail[node];
    }
    node = _children[node][code] ?? 0;
    final outs = _output[node];
    if (outs.isEmpty) continue;
    for (final pi in outs) {
      final len = patterns[pi].length;
      final start = pos - len + 1;
      if (start < 0) continue;
      onMatch(start, pos + 1, pi);
    }
  }
}
  
  /// 单次扫描，按"行号最小优先"替换所有匹配。非重叠、贪心。
  String replaceAll(String text) {
    if (text.isEmpty || patterns.isEmpty) return text;

    // 第 1 遍：AC 扫描，记录所有候选 (start, patternIndex)。
    // 用 List 而非 Map，位置是连续整数，O(1) 访问。
    final candidatesByStart =
        List<List<int>?>.filled(text.length, null);
    var node = 0;
    for (var pos = 0; pos < text.length; pos++) {
      final code = text.codeUnitAt(pos);
      while (node != 0 && _children[node][code] == null) {
        node = _fail[node];
      }
      node = _children[node][code] ?? 0;
      final outs = _output[node];
      if (outs.isEmpty) continue;
      for (final pi in outs) {
        final len = patterns[pi].length;
        final start = pos - len + 1;
        if (start < 0) continue;
        (candidatesByStart[start] ??= <int>[]).add(pi);
      }
    }

    // 第 2 遍：从位置 0 贪心选。
    final buf = StringBuffer();
    var last = 0;
    var pos = 0;
    while (pos < text.length) {
      final list = candidatesByStart[pos];
      if (list == null || list.isEmpty) {
        pos++;
        continue;
      }
      // 选优先级最小（行号最小）。
      var best = list[0];
      for (var k = 1; k < list.length; k++) {
        if (priorities[list[k]] < priorities[best]) {
          best = list[k];
        }
      }
      final len = patterns[best].length;
      buf.write(text.substring(last, pos));
      buf.write(replacements[best]);
      last = pos + len;
      pos = last;
    }
    if (last < text.length) {
      buf.write(text.substring(last));
    }
    return buf.toString();
  }
}

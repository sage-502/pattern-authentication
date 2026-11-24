class PatternCatalogState {
  final List<Map<String, dynamic>> patterns;
  final int bundledCount;
  final bool migrated;
  const PatternCatalogState(this.patterns, this.bundledCount, this.migrated);
}

class PatternCatalog {
  static const _legacyDefaults = [
    [1, 2, 5, 8],
    [2, 3, 6, 9],
    [7, 4, 5, 6],
    [1, 3, 5, 7],
  ];
  static const _previousNodes = [
    [1, 2, 3, 6],
    [1, 4, 8, 6, 3],
    [1, 5, 9, 8, 7, 3],
    [2, 1, 4, 7, 8, 9],
    [2, 3, 6, 9, 8, 7],
    [2, 1, 3, 6],
    [3, 2, 1, 4, 7, 8],
    [3, 6, 9, 8, 7],
    [3, 6, 9, 8, 7, 4, 1],
    [4, 1, 2, 3, 6, 9],
    [4, 1, 7, 8],
    [4, 7, 1, 2],
    [5, 2, 3, 6, 9, 8, 7],
    [5, 4, 1, 2, 3, 6, 9],
    [5, 3, 7, 8],
    [6, 3, 2, 1, 4, 7],
    [6, 5, 1, 9],
    [6, 5, 9, 1],
    [7, 4, 1, 2],
    [7, 8, 9, 6, 3],
    [7, 8, 9, 5, 1, 2, 3],
    [8, 7, 4, 1, 2, 3],
    [8, 7, 9, 6],
    [8, 9, 7, 4],
    [9, 6, 3, 2, 1],
    [9, 5, 7, 3],
    [9, 5, 3, 7],
  ];
  static const _previousSupplemental = {6, 11, 12, 15, 17, 18, 23, 24, 26, 27};
  static const _nodes = [
    [8, 5, 2],
    [2, 5, 8],
    [6, 5, 4],
    [4, 5, 6],
    [1, 5, 9],
    [9, 5, 1],
    [3, 5, 7],
    [7, 5, 3],
    [2, 1, 3, 6],
    [2, 3, 1, 4],
    [4, 1, 7, 8],
    [4, 7, 1, 2],
    [5, 1, 9, 8],
    [5, 9, 1, 2],
    [5, 3, 7, 8],
    [5, 7, 3, 2],
    [3, 6, 9, 8, 7],
    [7, 4, 1, 2],
    [1, 4, 8, 6, 3],
    [1, 5, 9, 8, 7, 3],
  ];
  static const _directions = [
    '↑',
    '↓',
    '←',
    '→',
    '↘',
    '↖',
    '↙',
    '↗',
    '→',
    '←',
    '↓',
    '↑',
    '↘',
    '↖',
    '↙',
    '↗',
  ];
  static int get bundledCount => _nodes.length;

  static List<Map<String, dynamic>> defaults() => [
        for (var i = 0; i < _nodes.length; i++)
          {
            'name': '${(i + 1).toString().padLeft(2, '0')} · '
                '${i < 8 ? 'SHORT ${_directions[i]}' : i < 16 ? 'LONG ${_directions[i]}' : '혼합'}',
            'nodes': List<int>.of(_nodes[i]),
            'goal': i < 8
                ? 2
                : i < 16
                    ? 5
                    : 3,
          },
      ];

  static int? recommendedGoal(Map<String, dynamic> pattern) =>
      (pattern['goal'] as num?)?.toInt();

  static PatternCatalogState resolve(Object? saved) {
    if (saved is! List) {
      return PatternCatalogState(defaults(), bundledCount, false);
    }
    final existing =
        saved.map((item) => Map<String, dynamic>.from(item as Map)).toList();
    if (existing.isEmpty) {
      return PatternCatalogState(defaults(), bundledCount, true);
    }
    if (existing.length == 1 &&
        existing.first['name'] == '기본 패턴' &&
        _sameNodes(existing.first['nodes'], _legacyDefaults.first)) {
      return PatternCatalogState(defaults(), bundledCount, true);
    }
    if (_hasPreviousPrefix(existing)) {
      return PatternCatalogState(
        [...defaults(), ...existing.skip(_previousNodes.length)],
        bundledCount,
        true,
      );
    }
    if (_hasLegacyPrefix(existing)) {
      return PatternCatalogState(
        [...defaults(), ...existing.skip(_legacyDefaults.length)],
        bundledCount,
        true,
      );
    }
    if (_hasPrefix(existing, defaults())) {
      return PatternCatalogState(existing, bundledCount, false);
    }
    return PatternCatalogState(existing, 0, false);
  }

  static bool _hasPreviousPrefix(List<Map<String, dynamic>> patterns) {
    if (patterns.length < _previousNodes.length) return false;
    for (var i = 0; i < _previousNodes.length; i++) {
      final name = '${(i + 1).toString().padLeft(2, '0')} · '
          '${_previousSupplemental.contains(i + 1) ? '보완' : '일반'}';
      if (patterns[i]['name'] != name ||
          !_sameNodes(patterns[i]['nodes'], _previousNodes[i])) {
        return false;
      }
    }
    return true;
  }

  static bool _hasLegacyPrefix(List<Map<String, dynamic>> patterns) {
    if (patterns.length < _legacyDefaults.length) return false;
    for (var i = 0; i < _legacyDefaults.length; i++) {
      if (patterns[i]['name'] != '기본 패턴 ${i + 1}' ||
          !_sameNodes(patterns[i]['nodes'], _legacyDefaults[i])) {
        return false;
      }
    }
    return true;
  }

  static bool _hasPrefix(
    List<Map<String, dynamic>> patterns,
    List<Map<String, dynamic>> prefix,
  ) {
    if (patterns.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (patterns[i]['name'] != prefix[i]['name'] ||
          !_sameNodes(patterns[i]['nodes'], prefix[i]['nodes'] as List<int>)) {
        return false;
      }
    }
    return true;
  }

  static bool _sameNodes(Object? value, List<int> expected) {
    if (value is! List || value.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (value[i] != expected[i]) return false;
    }
    return true;
  }
}

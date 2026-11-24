import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/pattern_catalog.dart';

void main() {
  test('20 research patterns retain order, direction, count and Android rules',
      () {
    const sequences = [
      '8-5-2',
      '2-5-8',
      '6-5-4',
      '4-5-6',
      '1-5-9',
      '9-5-1',
      '3-5-7',
      '7-5-3',
      '2-1-3-6',
      '2-3-1-4',
      '4-1-7-8',
      '4-7-1-2',
      '5-1-9-8',
      '5-9-1-2',
      '5-3-7-8',
      '5-7-3-2',
      '3-6-9-8-7',
      '7-4-1-2',
      '1-4-8-6-3',
      '1-5-9-8-7-3',
    ];
    const directions = [
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
    final patterns = PatternCatalog.defaults();
    expect(patterns.length, 20);
    expect(sequences.toSet().length, 20);
    for (var i = 0; i < patterns.length; i++) {
      final nodes = (patterns[i]['nodes'] as List).cast<int>();
      expect(nodes.join('-'), sequences[i], reason: 'pattern ${i + 1}');
      expect(PatternRules.normalize(nodes), nodes, reason: 'pattern ${i + 1}');
      expect(
          PatternCatalog.recommendedGoal(patterns[i]),
          i < 8
              ? 2
              : i < 16
                  ? 5
                  : 3);
      expect(
          patterns[i]['name'],
          contains(i < 8
              ? 'SHORT ${directions[i]}'
              : i < 16
                  ? 'LONG ${directions[i]}'
                  : '혼합'));
    }
  });

  test('previous 27 defaults migrate while user patterns survive', () {
    const previous = [
      '1-2-3-6',
      '1-4-8-6-3',
      '1-5-9-8-7-3',
      '2-1-4-7-8-9',
      '2-3-6-9-8-7',
      '2-1-3-6',
      '3-2-1-4-7-8',
      '3-6-9-8-7',
      '3-6-9-8-7-4-1',
      '4-1-2-3-6-9',
      '4-1-7-8',
      '4-7-1-2',
      '5-2-3-6-9-8-7',
      '5-4-1-2-3-6-9',
      '5-3-7-8',
      '6-3-2-1-4-7',
      '6-5-1-9',
      '6-5-9-1',
      '7-4-1-2',
      '7-8-9-6-3',
      '7-8-9-5-1-2-3',
      '8-7-4-1-2-3',
      '8-7-9-6',
      '8-9-7-4',
      '9-6-3-2-1',
      '9-5-7-3',
      '9-5-3-7',
    ];
    const supplemental = {6, 11, 12, 15, 17, 18, 23, 24, 26, 27};
    final old = [
      for (var i = 0; i < previous.length; i++)
        {
          'name':
              '${(i + 1).toString().padLeft(2, '0')} · ${supplemental.contains(i + 1) ? '보완' : '일반'}',
          'nodes': previous[i].split('-').map(int.parse).toList(),
        },
      {
        'name': '내 패턴',
        'nodes': [1, 2, 4, 7]
      },
    ];
    final resolved = PatternCatalog.resolve(old);
    expect(resolved.migrated, true);
    expect(resolved.bundledCount, 20);
    expect(resolved.patterns.length, 21);
    expect(resolved.patterns.last, old.last);
    expect(PatternCatalog.resolve(resolved.patterns).migrated, false);
  });

  test('older 4 defaults migrate but an independent list is preserved', () {
    final old = [
      {
        'name': '기본 패턴 1',
        'nodes': [1, 2, 5, 8]
      },
      {
        'name': '기본 패턴 2',
        'nodes': [2, 3, 6, 9]
      },
      {
        'name': '기본 패턴 3',
        'nodes': [7, 4, 5, 6]
      },
      {
        'name': '기본 패턴 4',
        'nodes': [1, 3, 5, 7]
      },
      {
        'name': '내 패턴',
        'nodes': [1, 2, 4, 7]
      },
    ];
    expect(PatternCatalog.resolve(old).patterns.last, old.last);
    expect(PatternCatalog.resolve(old).patterns.length, 21);
    final custom = [old.last];
    final unchanged = PatternCatalog.resolve(custom);
    expect(unchanged.patterns, custom);
    expect(unchanged.bundledCount, 0);
    expect(unchanged.migrated, false);
  });
}

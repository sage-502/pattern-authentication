import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/device_identity.dart';
import 'package:pattern_sensor_collector/export_filename.dart';
import 'package:pattern_sensor_collector/storage.dart';

void main() {
  test('installation UID is stable and old settings survive', () async {
    final root = await Directory.systemTemp.createTemp('identity_test_');
    addTearDown(() => root.delete(recursive: true));
    final store = SessionStorage(root);
    await store.saveSettings({'device': 'phone A', 'goal': 7});
    final first = await store.ensureDeviceIdentity();
    final again = await store.ensureDeviceIdentity();
    expect(first.uid, again.uid);
    expect(first.tag, hasLength(16));
    final settings = await store.loadSettings();
    expect(settings['device'], 'phone A');
    expect(settings['goal'], 7);
    expect(settings['device_uid'], first.uid);
  });

  test('ZIP names are safe and differ by installation and request', () {
    final a = DeviceIdentity(uuidV4());
    final b = DeviceIdentity(uuidV4());
    final first = uuidV4().replaceAll('-', '');
    final second = uuidV4().replaceAll('-', '');
    final time = DateTime.utc(2026, 11, 4, 12, 3, 2, 7);
    String name(DeviceIdentity device, String request) =>
        exportFilename(device, time, request,
            participantId: 'P1', patternId: '1-2-5-8');
    expect(name(a, first), isNot(name(b, first)));
    expect(name(a, first), isNot(name(a, second)));
    final local = time.toLocal();
    final stamp = '${local.month.toString().padLeft(2, '0')}'
        '${local.day.toString().padLeft(2, '0')}_'
        '${local.hour.toString().padLeft(2, '0')}'
        '${local.minute.toString().padLeft(2, '0')}';
    expect(name(a, first), contains('_${stamp}_'));
    expect(
        name(a, first),
        matches(RegExp(
            r'^P1_[0-9a-f]{8}_1-2-5-8_[0-9a-f]{12}_[0-9]{4}_[0-9]{4}_[0-9a-f]{12}\.zip$')));
    expect(name(a, first).length, lessThan(90));
    expect(name(a, first), isNot(contains('/')));
    expect(name(a, first), isNot(contains('\\')));
    expect(
        exportFilename(a, time, first,
            participantId: 'P2', patternId: '1-2-5-8'),
        isNot(name(a, first)));
    expect(
        exportFilename(a, time, first,
            participantId: 'P1', patternId: '2-3-6-9'),
        isNot(name(a, first)));
    expect(safeParticipantToken('A/B'), isNot(safeParticipantToken('A:B')));
    expect(safeParticipantToken('연구/1'), startsWith('연구_1_'));
    expect(safeDeviceLabel('CON'), 'device');
    expect(safeDeviceLabel('가나다'), 'device');
  });
}

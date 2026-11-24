import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/enrollment_repository.dart';
import 'package:pattern_sensor_collector/enrollment_screen.dart';
import 'package:pattern_sensor_collector/storage.dart';

class _MemoryRepository extends EnrollmentRepository {
  final EnrollmentProfile profile;
  _MemoryRepository(this.profile) : super(SessionStorage(Directory.systemTemp));

  @override
  Future<List<EnrollmentProfile>> getUsers() async => [profile];

  @override
  Future<EnrollmentProfile?> getUser(String userId) async => profile;
}

void main() {
  testWidgets('management includes a draft user and opens its profile',
      (tester) async {
    final now = DateTime.utc(2026, 11, 17);
    final repository = _MemoryRepository(EnrollmentProfile(
      userId: 'user001',
      displayName: '사용자 A',
      createdAt: now,
      updatedAt: now,
      hasPattern: false,
      regripAcknowledged: false,
      patternVerifierRef: null,
      records: const [],
    ));

    await tester.pumpWidget(MaterialApp(
      home:
          UserManagementScreen(repository: repository, deviceId: 'test-device'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('사용자 A · user001'), findsOneWidget);
    expect(find.textContaining('등록 중 · 0/10'), findsOneWidget);
    expect(find.textContaining('모델 미학습'), findsOneWidget);

    await tester.tap(find.text('사용자 A · user001'));
    await tester.pumpAndSettle();
    expect(find.text('등록 상태: 등록 중'), findsOneWidget);
    expect(find.text('패턴 설정: 진행 전'), findsOneWidget);
    expect(find.text('모델 상태: 미학습'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('등록 이어서 진행'), 300);
    expect(find.text('등록 이어서 진행'), findsOneWidget);
  });
}

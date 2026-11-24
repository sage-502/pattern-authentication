import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pattern_sensor_collector/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('설정에서 패턴 선택과 입력 대기 화면까지 이동', (tester) async {
    await tester.pumpWidget(const app.CollectorApp(legacyCollector: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('초기 설정'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'PTEST');
    await tester.enterText(find.byType(TextField).at(1), 'phoneTEST');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('다음 →'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다음 →'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('패턴 선택 / 생성'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('입력 화면으로 →'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('입력 화면으로 →'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('입력 시작'), findsOneWidget);
  });
}

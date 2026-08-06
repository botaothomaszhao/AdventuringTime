import 'package:adventuring_time/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('应用可构建：直接进入主界面', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AdventuringTimeApp()));
    await tester.pump();
    // 无人物时显示空状态与"新增人物"
    expect(find.text('新增人物'), findsWidgets);
    expect(find.text('地图'), findsOneWidget);
  });
}

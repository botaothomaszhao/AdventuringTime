import 'package:adventuring_time/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('应用可构建', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AdventuringTimeApp()));
    expect(find.text('探索的时光'), findsOneWidget);
  });
}

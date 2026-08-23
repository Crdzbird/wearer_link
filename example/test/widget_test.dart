import 'package:flutter_test/flutter_test.dart';
import 'package:wearer_link_example/main.dart';

void main() {
  testWidgets('demo renders the status card', (tester) async {
    await tester.pumpWidget(const WearerLinkDemo());
    expect(find.textContaining('Companion:'), findsOneWidget);
  });
}

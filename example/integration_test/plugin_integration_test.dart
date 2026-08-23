// Runs on a real device/emulator: `flutter test integration_test`.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wearer_link/wearer_link.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('isSupported and companion status respond', (tester) async {
    final link = WearerLink.instance;
    // Must not throw on any device, watch paired or not.
    final supported = await link.isSupported;
    final status = await link.getCompanionStatus();
    if (!supported) {
      expect(status.state, WearerConnectionState.unsupported);
    } else {
      expect(status.state, isNot(WearerConnectionState.unsupported));
    }
  });
}

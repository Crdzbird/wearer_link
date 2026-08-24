/// Test support for apps built on wearer_link.
///
/// [WearerLinkFake.pair] returns two fully linked in-memory endpoints so
/// both sides of a phone ⇄ watch protocol can be unit-tested on the Dart
/// VM — no emulators, no hardware:
///
/// ```dart
/// import 'package:wearer_link/testing.dart';
///
/// final (phone, watch) = WearerLinkFake.pair();
/// watch.messages.listen(expectAsync1((e) => expect(e.path, '/ping')));
/// await phone.sendMessage('/ping', payload);
/// ```
///
/// Injected events run through the production dispatch machinery, and the
/// harness reproduces the delivery contract: reachability loss, the
/// pending queue + `deliveredWhileDead` replay after [WearerLinkFake.simulateColdStart],
/// background-handler invocation, stream teardown on link loss, and the
/// per-platform capability matrix.
library;

export 'src/fake.dart' show WearerFakePlatform, WearerLinkFake;

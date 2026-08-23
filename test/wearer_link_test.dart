import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearer_link/src/messages.g.dart';
import 'package:wearer_link/wearer_link.dart';

class _FakeHost extends WearerLinkHostApi {
  final sent = <(String, Uint8List)>[];
  final synced = <(String, Uint8List)>[];
  List<WearerEventDto> pending = [];
  int drainCalls = 0;
  Object? throwOnSend;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<CompanionStatusDto> getCompanionStatus() async => CompanionStatusDto(
        state: ConnectionStateDto.reachable,
        nodes: ['node-1'],
      );

  @override
  Future<void> sendMessage(String path, Uint8List payload) async {
    if (throwOnSend case final e?) throw e;
    sent.add((path, payload));
  }

  @override
  Future<void> syncData(String path, Uint8List payload) async =>
      synced.add((path, payload));

  @override
  Future<void> transferData(String path, Uint8List payload) async =>
      synced.add((path, payload));

  @override
  Future<void> launchCompanion() async {}

  @override
  Future<List<WearerEventDto>> drainPendingEvents() async {
    drainCalls++;
    final out = pending;
    pending = [];
    return out;
  }
}

WearerEventDto _event(
  String id,
  WearerEventKindDto kind, {
  bool dead = true,
}) =>
    WearerEventDto(
      id: id,
      kind: kind,
      path: '/p',
      payload: Uint8List.fromList([1, 2]),
      sourceNodeId: 'n',
      timestampMillis: 42,
      deliveredWhileDead: dead,
    );

void main() {
  test('companion status maps DTO to model', () async {
    final link = WearerLink.forTest(_FakeHost());
    final status = await link.getCompanionStatus();
    expect(status.state, WearerConnectionState.reachable);
    expect(status.isReachable, isTrue);
    expect(status.nodes, ['node-1']);
  });

  test('sendJson utf8/json-encodes the payload', () async {
    final host = _FakeHost();
    await WearerLink.forTest(host).sendJson('/cmd', {'a': 1});
    expect(host.sent.single.$1, '/cmd');
    expect(jsonDecode(utf8.decode(host.sent.single.$2)), {'a': 1});
  });

  test('pending events are replayed once, routed by kind', () async {
    final host = _FakeHost()
      ..pending = [
        _event('m1', WearerEventKindDto.message),
        _event('d1', WearerEventKindDto.data),
      ];
    final link = WearerLink.forTest(host);

    final messages = <WearerEvent>[];
    final data = <WearerEvent>[];
    link.messages.listen(messages.add);
    link.dataEvents.listen(data.add);
    await pumpEventQueue();

    expect(messages.single.id, 'm1');
    expect(messages.single.deliveredWhileDead, isTrue);
    expect(data.single.id, 'd1');

    // A second subscription must not re-drain.
    link.messages.listen((_) {});
    await link.replayPendingEvents();
    await pumpEventQueue();
    expect(host.drainCalls, 1);
  });

  test('PlatformException codes map to typed WearerLinkException', () async {
    final host = _FakeHost()
      ..throwOnSend = PlatformException(code: 'unreachable', message: 'off');
    final link = WearerLink.forTest(host);
    await expectLater(
      link.sendMessage('/x', Uint8List(0)),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.unreachable),
      ),
    );

    host.throwOnSend = PlatformException(code: 'weird');
    await expectLater(
      link.sendMessage('/x', Uint8List(0)),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.unknown),
      ),
    );
  });
}

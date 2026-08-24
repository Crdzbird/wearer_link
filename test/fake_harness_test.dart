import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wearer_link/testing.dart';
import 'package:wearer_link/wearer_link.dart';

/// Background handler used by the cold-start test. Must be top-level.
Future<void> fakeBackgroundHandler(WearerEvent event) async {
  backgroundHandled.add(event);
}

final backgroundHandled = <WearerEvent>[];

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  routerAndTypedTests();

  test('pair delivers messages both ways', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final atWatch = <WearerEvent>[];
    final atPhone = <WearerEvent>[];
    watch.messages.listen(atWatch.add);
    phone.messages.listen(atPhone.add);
    await pumpEventQueue();

    await phone.sendMessage('/ping', _bytes('from phone'));
    await watch.sendMessage('/pong', _bytes('from watch'));
    await pumpEventQueue();

    expect(atWatch.single.path, '/ping');
    expect(utf8.decode(atWatch.single.payload), 'from phone');
    expect(atPhone.single.path, '/pong');
    expect(atWatch.single.sourceNodeId, phone.nodeId);
  });

  test('request round trip resolves with the reply payload', () async {
    final (phone, watch) = WearerLinkFake.pair();
    watch.setRequestHandler(
      (request) async => _bytes(utf8.decode(request.payload).toUpperCase()),
    );

    final reply = await phone.sendRequest('/echo', _bytes('hello'));
    expect(utf8.decode(reply), 'HELLO');
  });

  test('request without a handler fails with noHandler', () async {
    final (phone, _) = WearerLinkFake.pair();
    await expectLater(
      phone.sendRequest('/echo', Uint8List(0)),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.noHandler),
      ),
    );
  });

  test('unreachable link fails sends and queues transfers', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final received = <WearerEvent>[];
    watch.dataEvents.listen(received.add);
    await pumpEventQueue();

    phone.setReachable(false);
    await expectLater(
      phone.sendMessage('/ping', Uint8List(0)),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.unreachable),
      ),
    );

    // transferData survives unreachability and arrives on reconnect.
    await phone.transferData('/note', _bytes('queued'));
    await pumpEventQueue();
    expect(received, isEmpty);

    phone.setReachable(true);
    await pumpEventQueue();
    expect(utf8.decode(received.single.payload), 'queued');
  });

  test('cold start queues events and replays them flagged', () async {
    final (phone, watch) = WearerLinkFake.pair();
    watch.messages.listen((_) {});
    await pumpEventQueue();

    watch.simulateKill();
    await phone.sendMessage('/while-dead', _bytes('x'));
    await phone.transferData('/also-dead', _bytes('y'));
    await pumpEventQueue();

    final relaunched = watch.relaunch();
    final replayed = <WearerEvent>[];
    relaunched.messages.listen(replayed.add);
    relaunched.dataEvents.listen(replayed.add);
    await pumpEventQueue();

    expect(replayed, hasLength(2));
    expect(replayed.every((e) => e.deliveredWhileDead), isTrue);
    expect(replayed.map((e) => e.path), containsAll(['/while-dead', '/also-dead']));
  });

  test('background handler runs for dead-endpoint events and acks them',
      () async {
    backgroundHandled.clear();
    final (phone, watch) = WearerLinkFake.pair();
    await watch.registerBackgroundHandler(fakeBackgroundHandler);

    watch.simulateKill();
    await phone.sendMessage('/bg', _bytes('wake up'));
    await pumpEventQueue();

    expect(backgroundHandled.single.path, '/bg');
    expect(backgroundHandled.single.deliveredWhileDead, isTrue);

    // Acked out of the queue: nothing replays on the next launch.
    final replayed = <WearerEvent>[];
    watch.relaunch().messages.listen(replayed.add);
    await pumpEventQueue();
    expect(replayed, isEmpty);
  });

  test('sync data is readable and deletable across the pair', () async {
    final (phone, watch) = WearerLinkFake.pair();
    await watch.syncData('/counter', _bytes('{"value":3}'));

    expect(utf8.decode((await phone.readSyncData('/counter'))!), '{"value":3}');
    expect(await watch.readSyncData('/counter'), isNull,
        reason: 'readSyncData returns the counterpart\'s value, not our own');

    await watch.deleteSyncData('/counter');
    expect(await phone.readSyncData('/counter'), isNull);
  });

  test('streams: open, echo, orderly close', () async {
    final (phone, watch) = WearerLinkFake.pair();
    watch.incomingStreams.listen((stream) {
      stream.data.listen(
        (chunk) => stream.send(_bytes(utf8.decode(chunk).toUpperCase())),
      );
    });
    await pumpEventQueue();

    final stream = await phone.openStream('/live');
    final echoed = <String>[];
    stream.data.listen((chunk) => echoed.add(utf8.decode(chunk)));
    await stream.send(_bytes('chunk 1'));
    await stream.send(_bytes('chunk 2'));
    await pumpEventQueue();

    expect(echoed, ['CHUNK 1', 'CHUNK 2']);
    await stream.close();
    await pumpEventQueue();
    expect(stream.isClosed, isTrue);
    await stream.done;
  });

  test('link loss tears open streams down with an error', () async {
    final (phone, watch) = WearerLinkFake.pair();
    watch.incomingStreams.listen((_) {});
    await pumpEventQueue();

    final stream = await phone.openStream('/live');
    phone.setReachable(false);
    await pumpEventQueue();

    expect(stream.isClosed, isTrue);
    await expectLater(stream.done, throwsStateError);
  });

  test('delivery toggle diverts to the queue and replays on re-enable',
      () async {
    final (phone, watch) = WearerLinkFake.pair();
    final received = <WearerEvent>[];
    watch.messages.listen(received.add);
    await pumpEventQueue();

    await watch.setEventDeliveryEnabled(false);
    await phone.sendMessage('/muted', _bytes('x'));
    await pumpEventQueue();
    expect(received, isEmpty);

    await watch.setEventDeliveryEnabled(true);
    await pumpEventQueue();
    expect(received.single.path, '/muted');
    expect(received.single.deliveredWhileDead, isTrue);
  });

  test('file transfer copies bytes across', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final files = <WearerEvent>[];
    watch.fileEvents.listen(files.add);
    await pumpEventQueue();

    final source = await File(
      '${Directory.systemTemp.path}/wearer_fake_src.txt',
    ).writeAsString('file body');
    await phone.transferFile('/doc', source.path);
    await pumpEventQueue();

    expect(files.single.path, '/doc');
    expect(await File(files.single.filePath!).readAsString(), 'file body');
  });

  test('capability matrix follows the simulated platform', () async {
    final (iphone, wear) = WearerLinkFake.pair(
      a: WearerFakePlatform.iPhone,
      b: WearerFakePlatform.wearOs,
    );

    final phoneCaps = await iphone.getCapabilities();
    expect(phoneCaps.companionLaunch, WearerCompanionLaunch.workoutOnly);
    expect(phoneCaps.complicationPush, isTrue);
    expect(phoneCaps.surfaceUpdate, isFalse);

    final wearCaps = await wear.getCapabilities();
    expect(wearCaps.companionLaunch, WearerCompanionLaunch.foreground);
    expect(wearCaps.surfaceUpdate, isTrue);

    await expectLater(
      wear.updateComplication(Uint8List(0)),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.unsupported),
      ),
    );
  });
}

// ---- M6.2–6.4: router, typed codecs, reachability helpers -----------------

class _Counter {
  const _Counter(this.value);
  final int value;
  Map<String, Object?> toJson() => {'value': value};
  static _Counter fromJson(Map<String, Object?> json) =>
      _Counter(json['value'] as int);
}

void routerAndTypedTests() {
  test('router: exact beats wildcard, longest wildcard wins', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final hits = <String>[];
    watch.on('/a/b', (e) => hits.add('exact'));
    watch.on('/a/*', (e) => hits.add('short'));
    watch.on('/a/b/*', (e) => hits.add('long'));
    await pumpEventQueue();

    await phone.sendMessage('/a/b', Uint8List(0));
    await phone.sendMessage('/a/b/c', Uint8List(0));
    await phone.sendMessage('/a/x', Uint8List(0));
    await phone.sendMessage('/elsewhere', Uint8List(0));
    await pumpEventQueue();

    expect(hits, ['exact', 'long', 'short']);
  });

  test('router: routed events still reach global streams; cancel works',
      () async {
    final (phone, watch) = WearerLinkFake.pair();
    final routed = <WearerEvent>[];
    final global = <WearerEvent>[];
    final cancel = watch.on('/x', routed.add);
    watch.messages.listen(global.add);
    await pumpEventQueue();

    await phone.sendMessage('/x', Uint8List(0));
    await pumpEventQueue();
    expect(routed, hasLength(1));
    expect(global, hasLength(1));

    cancel();
    await phone.sendMessage('/x', Uint8List(0));
    await pumpEventQueue();
    expect(routed, hasLength(1));
    expect(global, hasLength(2));
  });

  test('request routes win over the global handler', () async {
    final (phone, watch) = WearerLinkFake.pair();
    watch.setRequestHandler((req) async => _bytes('global'));
    watch.onRequestPath('/special', (req) async => _bytes('routed'));

    expect(utf8.decode(await phone.sendRequest('/special', Uint8List(0))),
        'routed');
    expect(utf8.decode(await phone.sendRequest('/other', Uint8List(0))),
        'global');
  });

  test('typed send/receive/request round-trips through codecs', () async {
    final (phone, watch) = WearerLinkFake.pair();
    for (final link in [phone, watch]) {
      link.registerCodec<_Counter>(
        WearerJsonCodec(_Counter.fromJson),
      );
    }

    final received = <int>[];
    watch.onTyped<_Counter>('/count', (value, _) => received.add(value.value));
    watch.onRequestPath('/double', (req) async {
      final value = _Counter.fromJson(
        jsonDecode(utf8.decode(req.payload)) as Map<String, Object?>,
      );
      return _bytes(jsonEncode(_Counter(value.value * 2).toJson()));
    });
    await pumpEventQueue();

    await phone.sendTyped('/count', const _Counter(7));
    await pumpEventQueue();
    expect(received, [7]);

    final doubled = await phone.sendRequestTyped<_Counter, _Counter>(
      '/double',
      const _Counter(21),
    );
    expect(doubled.value, 42);
  });

  test('missing codec throws a clear StateError', () async {
    final (phone, _) = WearerLinkFake.pair();
    expect(
      () => phone.sendTyped('/x', const _Counter(1)),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('registerCodec<_Counter>'))),
    );
  });

  test('whenReachable resolves on reconnect and times out honestly',
      () async {
    final (phone, _) = WearerLinkFake.pair();
    await phone.whenReachable(); // already reachable: immediate

    phone.setReachable(false);
    await expectLater(
      phone.whenReachable(timeout: const Duration(milliseconds: 50)),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.unreachable),
      ),
    );

    final waiting = phone.whenReachable(timeout: const Duration(seconds: 5));
    phone.setReachable(true);
    await waiting; // resolves via the connectionState event
  });

  test('queueIfUnreachable downgrades to a queued transfer', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final data = <WearerEvent>[];
    watch.dataEvents.listen(data.add);
    await pumpEventQueue();

    phone.setReachable(false);
    await phone.sendMessage(
      '/cmd',
      _bytes('later'),
      queueIfUnreachable: true,
    ); // no throw
    expect(data, isEmpty);

    phone.setReachable(true);
    await pumpEventQueue();
    expect(data.single.path, '/cmd');
    expect(utf8.decode(data.single.payload), 'later');
  });
}

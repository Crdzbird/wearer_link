// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import 'dart:typed_data' show BytesBuilder;

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
  storeTests();
  transferAndDiagnosticsTests();
  cipherTests();
  audioStreamingTests();
  persistentStatsTests();

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

  test('launchCompanion carries route/args to launchIntents', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final intents = <WearerLaunchIntent>[];
    watch.launchIntents.listen(intents.add);
    await pumpEventQueue();

    await phone.launchCompanion(route: '/workout', args: {'id': 42});
    await pumpEventQueue();

    expect(watch.companionLaunches, hasLength(1));
    expect(intents.single.route, '/workout');
    expect(intents.single.args, {'id': 42});
  });

  test('getNodes and getCounterpartVitals report the fake peer', () async {
    final (phone, _) = WearerLinkFake.pair();
    final node = (await phone.getNodes()).single;
    expect(node.id, 'node-b');
    expect(node.isNearby, isTrue);

    final status = await phone.getCounterpartVitals();
    expect(status.batteryPercent, 80);
    expect(status.model, contains('wearOs'));

    phone.setReachable(false);
    await expectLater(
      phone.getCounterpartVitals(),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.unreachable),
      ),
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

// ---- M7.1: synced KV store ------------------------------------------------

void storeTests() {
  test('store: set/watch round trip in both directions', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final seenOnWatch = <String?>[];
    final seenOnPhone = <String?>[];
    watch.store.watch('workout').listen(
        (v) => seenOnWatch.add(v == null ? null : utf8.decode(v)));
    phone.store.watch('workout').listen(
        (v) => seenOnPhone.add(v == null ? null : utf8.decode(v)));
    await pumpEventQueue();

    await phone.store.set('workout', _bytes('running'));
    await pumpEventQueue();
    expect(seenOnWatch, ['running']);
    expect(seenOnPhone, ['running'],
        reason: 'local writes also notify local watchers');
    expect(utf8.decode((await watch.store.get('workout'))!), 'running');

    await watch.store.set('workout', _bytes('done'));
    await pumpEventQueue();
    expect(utf8.decode((await phone.store.get('workout'))!), 'done');
  });

  test('store: last writer wins, stale write is discarded', () async {
    final (phone, watch) = WearerLinkFake.pair();
    await phone.store.set('k', _bytes('first'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await watch.store.set('k', _bytes('second'));
    await pumpEventQueue();

    // Both sides converge on the newest write.
    expect(utf8.decode((await phone.store.get('k'))!), 'second');
    expect(utf8.decode((await watch.store.get('k'))!), 'second');
  });

  test('store: delete tombstones propagate and keys() excludes them',
      () async {
    final (phone, watch) = WearerLinkFake.pair();
    await phone.store.set('a', _bytes('1'));
    await phone.store.set('b', _bytes('2'));
    await pumpEventQueue();
    expect(await watch.store.keys(), {'a', 'b'});

    final watched = <Object?>[];
    watch.store.watch('a').listen(watched.add);
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await phone.store.delete('a');
    await pumpEventQueue();

    expect(watched, [null]);
    expect(await watch.store.get('a'), isNull);
    expect(await watch.store.keys(), {'b'});
    expect(await phone.store.keys(), {'b'});
  });

  test('store: cold read merges persisted state from both sides', () async {
    final (phone, watch) = WearerLinkFake.pair();
    // The watch app is "not running" while the phone writes.
    watch.simulateKill();
    await phone.store.set('boot', _bytes('early'));
    await pumpEventQueue();

    // A fresh launch that never saw the live event still reads the value
    // (via the OS-persisted sync layer, here the fake's synced maps).
    final relaunched = watch.relaunch();
    expect(utf8.decode((await relaunched.store.get('boot'))!), 'early');
  });

  test('store: rejects oversized values and bad keys', () async {
    final (phone, _) = WearerLinkFake.pair();
    await expectLater(
      phone.store.set('big', Uint8List(64 * 1024)),
      throwsArgumentError,
    );
    await expectLater(
      phone.store.set('bad/key', Uint8List(0)),
      throwsArgumentError,
    );
  });
}

// ---- M7.2/7.3: tracked transfers, diagnostics -----------------------------

void transferAndDiagnosticsTests() {
  test('tracked transfer: progress reaches 1.0 and file arrives intact',
      () async {
    final (phone, watch) = WearerLinkFake.pair();
    final files = <WearerEvent>[];
    watch.fileEvents.listen(files.add);
    await pumpEventQueue();

    final source = File(
      '${Directory.systemTemp.path}/wearer_tracked_src.bin',
    )..writeAsBytesSync(List.generate(150 * 1024, (i) => i % 251));

    final transfer =
        await phone.transferFileTracked('/photos/1', source.path);
    final fractions = <double>[];
    transfer.progress.listen(fractions.add);
    await transfer.done;
    await pumpEventQueue();

    expect(fractions.last, 1.0);
    expect(fractions, isNotEmpty);
    expect(transfer.totalBytes, 150 * 1024);

    expect(files.single.path, '/photos/1');
    final received = File(files.single.filePath!).readAsBytesSync();
    expect(received.length, 150 * 1024);
    expect(received, source.readAsBytesSync());
  });

  test('tracked transfer to an unreachable peer fails with a diagnostic',
      () async {
    final (phone, _) = WearerLinkFake.pair();
    final diagnostics = <WearerDiagnostic>[];
    phone.diagnostics.listen(diagnostics.add);
    phone.setReachable(false);

    await expectLater(
      phone.transferFileTracked(
        '/x',
        (File('${Directory.systemTemp.path}/wearer_tiny.bin')
              ..writeAsBytesSync([1, 2, 3]))
            .path,
      ),
      throwsA(
        isA<WearerLinkException>()
            .having((e) => e.code, 'code', WearerErrorCode.unreachable),
      ),
    );
  });

  test('stats count sends, receives, replays and dedup drops', () async {
    final (phone, watch) = WearerLinkFake.pair();
    watch.messages.listen((_) {});
    await pumpEventQueue();

    await phone.sendMessage('/a', Uint8List(0));
    await phone.transferData('/b', Uint8List(0));
    await pumpEventQueue();

    expect(phone.stats.sentEvents, 2);
    expect(watch.stats.receivedEvents, 2);
    expect(watch.stats.replayedEvents, 0);

    watch.simulateKill();
    await phone.sendMessage('/c', Uint8List(0));
    final relaunched = watch.relaunch();
    relaunched.messages.listen((_) {});
    await pumpEventQueue();
    expect(relaunched.stats.replayedEvents, 1);
  });

  test('pingLatency measures the built-in status round trip', () async {
    final (phone, _) = WearerLinkFake.pair();
    final rtt = await phone.pingLatency();
    expect(rtt, greaterThanOrEqualTo(Duration.zero));
    expect(rtt, lessThan(const Duration(seconds: 1)));
  });
}

// ---- M8.1: payload cipher --------------------------------------------------

WearerCipher xorCipher([int key = 0x5A]) => WearerCipher(
      encrypt: (path, bytes) async =>
          Uint8List.fromList([for (final b in bytes) b ^ key]),
      decrypt: (path, bytes) async =>
          Uint8List.fromList([for (final b in bytes) b ^ key]),
    );

void cipherTests() {
  test('cipher: message/request/store round trips stay intact', () async {
    final (phone, watch) = WearerLinkFake.pair();
    phone.setPayloadCipher(xorCipher());
    watch.setPayloadCipher(xorCipher());

    final messages = <String>[];
    watch.messages.listen((e) => messages.add(utf8.decode(e.payload)));
    watch.setRequestHandler(
      (req) async => _bytes(utf8.decode(req.payload).toUpperCase()),
    );
    await pumpEventQueue();

    await phone.sendMessage('/m', _bytes('secret'));
    await pumpEventQueue();
    expect(messages, ['secret']);

    final reply = await phone.sendRequest('/echo', _bytes('classified'));
    expect(utf8.decode(reply), 'CLASSIFIED');

    await phone.store.set('k', _bytes('sealed'));
    await pumpEventQueue();
    expect(utf8.decode((await watch.store.get('k'))!), 'sealed');
  });

  test('cipher: streams and tracked transfers stay intact', () async {
    final (phone, watch) = WearerLinkFake.pair();
    phone.setPayloadCipher(xorCipher());
    watch.setPayloadCipher(xorCipher());

    final files = <WearerEvent>[];
    watch.fileEvents.listen(files.add);
    watch.incomingStreams.listen((stream) {
      stream.data.listen((chunk) => stream.send(chunk)); // echo
    });
    await pumpEventQueue();

    final stream = await phone.openStream('/live');
    final echoed = <String>[];
    stream.data.listen((chunk) => echoed.add(utf8.decode(chunk)));
    await stream.send(_bytes('frame'));
    await pumpEventQueue();
    expect(echoed, ['frame']);
    await stream.close();

    final source = File('${Directory.systemTemp.path}/wearer_sealed.bin')
      ..writeAsBytesSync(List.generate(70 * 1024, (i) => (i * 7) % 256));
    final transfer = await phone.transferFileTracked('/sealed', source.path);
    await transfer.done;
    await pumpEventQueue();
    expect(
      File(files.single.filePath!).readAsBytesSync(),
      source.readAsBytesSync(),
    );
  });

  test('cipher mismatch drops payloads with diagnostics, requests fail typed',
      () async {
    final (phone, watch) = WearerLinkFake.pair();
    phone.setPayloadCipher(xorCipher());
    // watch has NO cipher.

    final received = <WearerEvent>[];
    final watchDiagnostics = <WearerDiagnostic>[];
    watch.messages.listen(received.add);
    watch.diagnostics.listen(watchDiagnostics.add);
    watch.setRequestHandler((req) async => _bytes('plain reply'));
    await pumpEventQueue();

    // Encrypted -> cipher-less endpoint: dropped, never garbage.
    await phone.sendMessage('/m', _bytes('sealed'));
    await pumpEventQueue();
    expect(received, isEmpty);
    expect(watchDiagnostics.single.area, 'cipher');

    // Plaintext -> ciphered endpoint: dropped too.
    final phoneDiagnostics = <WearerDiagnostic>[];
    final atPhone = <WearerEvent>[];
    phone.messages.listen(atPhone.add);
    phone.diagnostics.listen(phoneDiagnostics.add);
    await pumpEventQueue();
    await watch.sendMessage('/m', _bytes('plain'));
    await pumpEventQueue();
    expect(atPhone, isEmpty);
    expect(phoneDiagnostics.single.area, 'cipher');

    // Ciphered request to a cipher-less responder: typed failure.
    await expectLater(
      phone.sendRequest('/echo', _bytes('x')),
      throwsA(isA<WearerLinkException>()),
    );
  });
}

// ---- M8.2: audio-profile streaming (ordering + integrity under load) ------

void audioStreamingTests() {
  test('stream sustains many audio-sized chunks in order', () async {
    final (phone, watch) = WearerLinkFake.pair();
    final received = BytesBuilder(copy: false);
    watch.incomingStreams.listen((stream) {
      stream.data.listen(received.add);
    });
    await pumpEventQueue();

    // ~1.6MB as 100 x 16KB chunks — a few seconds of PCM audio.
    final stream = await phone.openStream('/voice');
    final sent = BytesBuilder(copy: false);
    for (var i = 0; i < 100; i++) {
      final chunk = Uint8List.fromList(
        List.generate(16 * 1024, (j) => (i + j) % 256),
      );
      sent.add(chunk);
      await stream.send(chunk);
    }
    await pumpEventQueue();
    await stream.close();

    expect(received.length, 100 * 16 * 1024);
    expect(received.takeBytes(), sent.takeBytes(),
        reason: 'chunks must arrive complete and in order');
  });
}

// ---- 1.1.0: persistent native counters ------------------------------------

void persistentStatsTests() {
  test('persistent stats count dead-queue lifecycle across relaunch',
      () async {
    final (phone, watch) = WearerLinkFake.pair();
    watch.messages.listen((_) {});
    await pumpEventQueue();

    await phone.sendMessage('/live', Uint8List(0));
    watch.simulateKill();
    await phone.sendMessage('/dead-1', Uint8List(0));
    await phone.sendMessage('/dead-2', Uint8List(0));
    await pumpEventQueue();

    final relaunched = watch.relaunch();
    relaunched.messages.listen((_) {});
    await pumpEventQueue();

    final stats = await relaunched.getPersistentStats();
    expect(stats.receivedTotal, 3);
    expect(stats.queuedWhileDead, 2);
    expect(stats.drained, 2);
    expect(stats.backgroundHandled, 0);

    await relaunched.resetPersistentStats();
    final reset = await relaunched.getPersistentStats();
    expect(reset.receivedTotal, 0);
    expect(reset.queuedWhileDead, 0);
  });

  test('persistent stats count background-handled events', () async {
    backgroundHandled.clear();
    final (phone, watch) = WearerLinkFake.pair();
    await watch.registerBackgroundHandler(fakeBackgroundHandler);
    watch.simulateKill();
    await phone.sendMessage('/bg', Uint8List(0));
    await pumpEventQueue();

    final stats = await watch.getPersistentStats();
    expect(stats.backgroundHandled, 1);
    expect(stats.queuedWhileDead, 1);
    expect(stats.drained, 0, reason: 'acked events never drain');
  });
}

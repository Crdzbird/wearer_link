// The fake is test infrastructure by definition; it drives the facade's
// test seam from library code.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';

import '../wearer_link.dart';
import 'messages.g.dart';

/// Which device a [WearerLinkFake] endpoint pretends to be. Drives the
/// capability matrix (and nothing else — wire behavior is uniform).
enum WearerFakePlatform {
  /// An Android phone: foreground companion launch, no watch-face surfaces.
  androidPhone,

  /// A Wear OS watch: foreground launch + tile/complication updates.
  wearOs,

  /// An iPhone: workout-only launch, complication push.
  iPhone,
}

/// In-memory two-endpoint harness: everything `WearerLink` does, with no
/// platform underneath, so both sides of a phone ⇄ watch protocol can be
/// unit-tested on the Dart VM.
///
/// ```dart
/// final (phone, watch) = WearerLinkFake.pair();
/// watch.messages.listen(...);
/// await phone.sendMessage('/ping', payload);
///
/// phone.setReachable(false);               // simulate range loss
/// watch.simulateKill();                    // events now queue (or hit the
/// final relaunched = watch.relaunch();     //  background handler); replay
/// ```                                      //  on the relaunched instance
///
/// Injected events run through the production dispatch code (routing,
/// dedup, stream bookkeeping) — the fake replaces only the platform.
class WearerLinkFake extends WearerLink {
  WearerLinkFake._(_FakeHost host)
      : _fakeHost = host,
        super.forTest(host) {
    host.attach(this);
  }

  final _FakeHost _fakeHost;

  /// Two endpoints joined by an in-memory link, reachable and alive.
  /// Node ids are `node-a` / `node-b`.
  static (WearerLinkFake, WearerLinkFake) pair({
    WearerFakePlatform a = WearerFakePlatform.androidPhone,
    WearerFakePlatform b = WearerFakePlatform.wearOs,
  }) {
    final wire = _FakeWire();
    final hostA = _FakeHost(wire, 'node-a', a);
    final hostB = _FakeHost(wire, 'node-b', b);
    wire
      ..a = hostA
      ..b = hostB;
    return (WearerLinkFake._(hostA), WearerLinkFake._(hostB));
  }

  /// This endpoint's node id as seen by the counterpart.
  String get nodeId => _fakeHost.nodeId;

  /// Whether the link is currently reachable (shared by both endpoints).
  bool get isReachable => _fakeHost.wire.reachable;

  /// Flip link reachability. Both endpoints get a connection-state event;
  /// dropping the link tears down open streams (as the platforms do) and
  /// holds queued transfers until it comes back.
  void setReachable(bool reachable) => _fakeHost.wire.setReachable(reachable);

  /// `launchCompanion` calls received by this endpoint, for assertions.
  List<DateTime> get companionLaunches =>
      List.unmodifiable(_fakeHost.companionLaunches);

  /// `updateComplication` payloads this endpoint's counterpart pushed.
  List<Uint8List> get complicationPushes =>
      List.unmodifiable(_fakeHost.complicationPushes);

  /// The fake keeps a direct reference to the handler instead of the
  /// production callback-handle round trip (which needs a real Dart VM
  /// embedding); the top-level-function requirement is still enforced so
  /// tests catch what would break on-device.
  @override
  Future<void> registerBackgroundHandler(WearerBackgroundHandler handler) {
    if (PluginUtilities.getCallbackHandle(handler) == null) {
      throw ArgumentError(
        'handler must be a top-level or static function '
        '(closures and instance methods cannot run in a background isolate)',
      );
    }
    _fakeHost.backgroundHandler = handler;
    return Future.value();
  }

  @override
  Future<void> clearBackgroundHandler() {
    _fakeHost.backgroundHandler = null;
    return Future.value();
  }

  /// Kill this endpoint: from now on inbound events divert to the
  /// persistent queue — or run its registered background handler — exactly
  /// like a killed app. This instance stays dead; bring the "app" back
  /// with [relaunch].
  void simulateKill() => _fakeHost.detach();

  /// The endpoint's next launch after [simulateKill]: a fresh instance
  /// sharing the persisted state, so first listens replay queued events
  /// with `deliveredWhileDead: true`.
  WearerLinkFake relaunch() {
    if (_fakeHost.alive) {
      throw StateError('relaunch() requires simulateKill() first');
    }
    return WearerLinkFake._(_fakeHost);
  }
}

// ---------------------------------------------------------------------------

/// State shared by the two endpoints.
class _FakeWire {
  late _FakeHost a;
  late _FakeHost b;

  bool reachable = true;

  _FakeHost other(_FakeHost self) => identical(self, a) ? b : a;

  void setReachable(bool value) {
    if (reachable == value) return;
    reachable = value;
    for (final host in [a, b]) {
      if (!value) host.dropStreams('link lost');
      host.pushConnectionState();
      if (value) host.flushOutbox();
    }
  }
}

class _FakeHost extends WearerLinkHostApi {
  _FakeHost(this.wire, this.nodeId, this.platform);

  final _FakeWire wire;
  final String nodeId;
  final WearerFakePlatform platform;

  /// The currently-attached facade; null while "the app is killed".
  WearerLinkFake? link;

  bool deliveryEnabled = true;
  final pendingQueue = <WearerEventDto>[];
  final outbox = <void Function()>[]; // queued transfers awaiting reachability
  final syncedByMe = <String, Uint8List>{};
  final companionLaunches = <DateTime>[];
  final complicationPushes = <Uint8List>[];
  WearerBackgroundHandler? backgroundHandler;
  final openStreams = <String, String>{}; // id -> path
  int _eventSeq = 0;

  static const _maxMessageBytes = 56 * 1024;

  void attach(WearerLinkFake newLink) => link = newLink;

  void detach() => link = null;

  bool get alive => link != null;

  _FakeHost get other => wire.other(this);

  // -- inbound delivery -----------------------------------------------------

  /// Deliver [dto] into this endpoint through the same decision tree the
  /// native listener services use: gate -> live -> background -> queue.
  void receive(WearerEventDto dto) {
    receivedTotal++;
    if (!deliveryEnabled) {
      queuedWhileDead++;
      pendingQueue.add(_asDead(dto));
      return;
    }
    final live = link;
    if (live != null) {
      switch (dto.kind) {
        case WearerEventKindDto.message:
          live.debugFlutterApi.onMessage(dto);
        case WearerEventKindDto.data:
          live.debugFlutterApi.onDataChanged(dto);
        case WearerEventKindDto.file:
          live.debugFlutterApi.onFileReceived(dto);
      }
      return;
    }
    // App is "killed": persist first (crash-safe in production), then the
    // background handler's completion acks it back out of the queue.
    final dead = _asDead(dto);
    queuedWhileDead++;
    pendingQueue.add(dead);
    final handler = backgroundHandler;
    if (handler != null) {
      handler(WearerEvent.fromDto(dead)).then((_) {
        pendingQueue.removeWhere((e) => e.id == dead.id);
        backgroundHandledTotal++;
      }).catchError((_) {/* stays queued for the next launch */});
    }
  }

  WearerEventDto _asDead(WearerEventDto dto) => WearerEventDto(
        id: dto.id,
        kind: dto.kind,
        path: dto.path,
        payload: dto.payload,
        sourceNodeId: dto.sourceNodeId,
        timestampMillis: dto.timestampMillis,
        deliveredWhileDead: true,
        filePath: dto.filePath,
      );

  WearerEventDto _event(
    WearerEventKindDto kind,
    String path,
    Uint8List payload, {
    String? filePath,
  }) =>
      WearerEventDto(
        id: '$nodeId-${_eventSeq++}',
        kind: kind,
        path: path,
        payload: payload,
        sourceNodeId: nodeId,
        timestampMillis: DateTime.now().millisecondsSinceEpoch,
        deliveredWhileDead: false,
        filePath: filePath,
      );

  void pushConnectionState() {
    link?.debugFlutterApi.onConnectionStateChanged(_status());
  }

  CompanionStatusDto _status() => CompanionStatusDto(
        state: wire.reachable
            ? ConnectionStateDto.reachable
            : ConnectionStateDto.unreachable,
        nodes: wire.reachable ? [other.nodeId] : [],
      );

  void flushOutbox() {
    final queued = List.of(outbox);
    outbox.clear();
    for (final deliver in queued) {
      deliver();
    }
  }

  void dropStreams(String reason) {
    for (final id in List.of(openStreams.keys)) {
      openStreams.remove(id);
      link?.debugFlutterApi.onStreamClosed(id, reason);
    }
  }

  void _requireReachable() {
    if (!wire.reachable) {
      throw PlatformException(
        code: 'unreachable',
        message: 'Fake link is unreachable.',
      );
    }
  }

  // -- WearerLinkHostApi ----------------------------------------------------

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<CompanionStatusDto> getCompanionStatus() async => _status();

  @override
  Future<void> sendMessage(
    String path,
    Uint8List payload,
    String? nodeId,
  ) async {
    _requireReachable();
    other.receive(_event(WearerEventKindDto.message, path, payload));
  }

  @override
  Future<Uint8List> sendRequest(
    String path,
    Uint8List payload,
    String? nodeId,
  ) async {
    _requireReachable();
    final counterpart = other;
    if (!counterpart.deliveryEnabled) {
      throw PlatformException(
        code: 'sendFailed',
        message: 'Counterpart delivery is disabled.',
      );
    }
    final live = counterpart.link;
    if (live == null) {
      throw PlatformException(
        code: 'noHandler',
        message: 'Counterpart app is not running.',
      );
    }
    try {
      return await live.debugFlutterApi.onRequest(
        counterpart._event(WearerEventKindDto.message, path, payload),
      );
    } on PlatformException {
      rethrow;
    } catch (e) {
      throw PlatformException(code: 'sendFailed', message: '$e');
    }
  }

  @override
  Future<void> syncData(String path, Uint8List payload) async {
    syncedByMe[path] = payload;
    final dto = _event(WearerEventKindDto.data, path, payload);
    if (wire.reachable) {
      other.receive(dto);
    } else {
      // Latest-per-path: replace any queued value for the same path.
      outbox.add(() => other.receive(dto));
    }
  }

  @override
  Future<Uint8List?> readSyncData(String path) async =>
      other.syncedByMe[path];

  @override
  Future<void> deleteSyncData(String path) async => syncedByMe.remove(path);

  @override
  Future<Uint8List?> readOwnSyncData(String path) async => syncedByMe[path];

  int receivedTotal = 0;
  int queuedWhileDead = 0;
  int drainedTotal = 0;
  int backgroundHandledTotal = 0;
  final statsSince = DateTime.now();

  @override
  Future<PersistentStatsDto> getPersistentStats() async => PersistentStatsDto(
        receivedTotal: receivedTotal,
        queuedWhileDead: queuedWhileDead,
        drained: drainedTotal,
        backgroundHandled: backgroundHandledTotal,
        sinceMillis: statsSince.millisecondsSinceEpoch,
      );

  @override
  Future<void> resetPersistentStats() async {
    receivedTotal = 0;
    queuedWhileDead = 0;
    drainedTotal = 0;
    backgroundHandledTotal = 0;
  }

  @override
  Future<List<String>> listSyncPaths(String prefix) async => {
        ...syncedByMe.keys,
        ...other.syncedByMe.keys,
      }.where((p) => p.startsWith(prefix)).toList();

  @override
  Future<void> transferData(String path, Uint8List payload) async {
    // Size-unlimited by contract (oversized payloads ride the blob route
    // natively); observable result is identical, so deliver directly.
    final dto = _event(WearerEventKindDto.data, path, payload);
    if (wire.reachable) {
      other.receive(dto);
    } else {
      outbox.add(() => other.receive(dto));
    }
  }

  @override
  Future<void> transferFile(
    String path,
    String filePath,
    String? nodeId,
  ) async {
    final source = File(filePath);
    if (!source.existsSync()) {
      throw PlatformException(
        code: 'sendFailed',
        message: 'No such file: $filePath',
      );
    }
    final bytes = source.readAsBytesSync();
    void deliver() {
      final dest = File(
        '${Directory.systemTemp.path}/wearer_fake_${other.nodeId}_'
        '${DateTime.now().microsecondsSinceEpoch}',
      )..writeAsBytesSync(bytes);
      other.receive(
        other._event(
          WearerEventKindDto.file,
          path,
          Uint8List(0),
          filePath: dest.path,
        ),
      );
    }

    if (wire.reachable) {
      deliver();
    } else {
      outbox.add(deliver);
    }
  }

  @override
  Future<void> launchCompanion(String? route, String? argsJson) async {
    switch (platform) {
      case WearerFakePlatform.androidPhone:
      case WearerFakePlatform.wearOs:
        _requireReachable();
      case WearerFakePlatform.iPhone:
        break; // workout-only launch: background-style, no reachability need
    }
    other.companionLaunches.add(DateTime.now());
    if (route != null || argsJson != null) {
      final payload = Uint8List.fromList(
        utf8.encode(jsonEncode({'route': route, 'args': argsJson})),
      );
      other.receive(_event(WearerEventKindDto.data, '/__wllaunch', payload));
    }
  }

  @override
  Future<List<WearerNodeDto>> getNodes() async => [
        WearerNodeDto(
          id: other.nodeId,
          displayName: 'Fake ${other.platform.name}',
          isNearby: wire.reachable,
        ),
      ];

  @override
  Future<CounterpartVitalsDto> getCounterpartVitals(String? nodeId) async {
    _requireReachable();
    return CounterpartVitalsDto(
      batteryPercent: 80,
      isCharging: false,
      model: 'Fake ${other.platform.name}',
      osVersion: 'fake-1.0',
    );
  }

  @override
  Future<void> updateComplication(Uint8List payload) async {
    if (platform != WearerFakePlatform.iPhone) {
      throw PlatformException(
        code: 'unsupported',
        message: 'Complication push is watchOS-only.',
      );
    }
    other.complicationPushes.add(payload);
  }

  @override
  Future<void> requestSurfaceUpdate(String component) async {
    if (platform != WearerFakePlatform.wearOs) {
      throw PlatformException(
        code: 'unsupported',
        message: 'Surface updates are Wear OS-only.',
      );
    }
  }

  @override
  Future<List<WearerEventDto>> drainPendingEvents() async {
    final drained = List.of(pendingQueue);
    drainedTotal += drained.length;
    pendingQueue.clear();
    return drained;
  }

  @override
  Future<WearerCapabilitiesDto> getCapabilities() async {
    final isPhoneToWatch = platform == WearerFakePlatform.iPhone;
    return WearerCapabilitiesDto(
      message: true,
      request: true,
      syncData: true,
      transferData: true,
      transferFile: true,
      stream: true,
      companionLaunch: isPhoneToWatch
          ? CompanionLaunchDto.workoutOnly
          : CompanionLaunchDto.foreground,
      complicationPush: isPhoneToWatch,
      surfaceUpdate: platform == WearerFakePlatform.wearOs,
      backgroundWake: true,
      maxMessageBytes: _maxMessageBytes,
    );
  }

  @override
  Future<void> setEventDeliveryEnabled(bool enabled) async {
    deliveryEnabled = enabled;
    if (!enabled) dropStreams('delivery disabled');
  }

  @override
  Future<bool> isEventDeliveryEnabled() async => deliveryEnabled;

  @override
  Future<String> openStream(String path, String? nodeId) async {
    _requireReachable();
    if (!deliveryEnabled) {
      throw PlatformException(
        code: 'unsupported',
        message: 'Event delivery is disabled.',
      );
    }
    final counterpart = other;
    if (!counterpart.alive || !counterpart.deliveryEnabled) {
      throw PlatformException(
        code: 'sendFailed',
        message: 'Counterpart refused the stream.',
      );
    }
    final id = 'stream-$nodeId-${_eventSeq++}';
    openStreams[id] = path;
    counterpart.openStreams[id] = path;
    link?.debugFlutterApi.onStreamOpened(id, path, counterpart.nodeId, false);
    counterpart.link?.debugFlutterApi.onStreamOpened(
      id,
      path,
      this.nodeId,
      true,
    );
    return id;
  }

  @override
  Future<void> sendStreamData(String streamId, Uint8List data) async {
    if (!openStreams.containsKey(streamId)) {
      throw PlatformException(
        code: 'sendFailed',
        message: 'Stream $streamId is not open.',
      );
    }
    _requireReachable();
    other.link?.debugFlutterApi.onStreamData(streamId, data);
  }

  @override
  Future<void> closeStream(String streamId) async {
    if (openStreams.remove(streamId) == null) return;
    link?.debugFlutterApi.onStreamClosed(streamId, null);
    if (other.openStreams.remove(streamId) != null) {
      other.link?.debugFlutterApi.onStreamClosed(streamId, null);
    }
  }
}

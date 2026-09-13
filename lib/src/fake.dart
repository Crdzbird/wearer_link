// The fake is test infrastructure by definition; it drives the facade's
// test seam from library code.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';

import '../wearer_link.dart';
import 'dto_copy.dart';
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

/// In-memory harness: everything `WearerLink` does, with no platform
/// underneath, so both sides of a phone ⇄ watch protocol can be unit-tested
/// on the Dart VM.
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
/// [network] builds more than two endpoints — a phone with several watches,
/// as Android allows — so fan-out and partial delivery can be tested:
///
/// ```dart
/// final [phone, watchA, watchB] = WearerLinkFake.network([
///   WearerFakePlatform.androidPhone,
///   WearerFakePlatform.wearOs,
///   WearerFakePlatform.wearOs,
/// ]);
/// phone.failSendsTo(watchB.nodeId);        // watchB starts rejecting sends
/// final report = await phone.sendMessage('/ping', payload);
/// report.delivered;                        // [watchA.nodeId]
/// report.failures.single.nodeId;           // watchB.nodeId
/// ```
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
    final endpoints = network([a, b]);
    return (endpoints[0], endpoints[1]);
  }

  /// Any number of endpoints on one in-memory network, every endpoint
  /// seeing every other as a counterpart — the shape of the Wear OS node
  /// network, where a phone can be paired with several watches at once.
  ///
  /// Node ids are `node-a`, `node-b`, `node-c`, … in the order given.
  /// Requires at least two platforms.
  static List<WearerLinkFake> network(List<WearerFakePlatform> platforms) {
    if (platforms.length < 2) {
      throw ArgumentError.value(
        platforms,
        'platforms',
        'a network needs at least two endpoints',
      );
    }
    final wire = _FakeWire();
    for (var i = 0; i < platforms.length; i++) {
      wire.hosts.add(_FakeHost(wire, _nodeIdFor(i), platforms[i]));
    }
    return wire.hosts.map(WearerLinkFake._).toList();
  }

  static String _nodeIdFor(int index) => index < 26
      ? 'node-${String.fromCharCode(97 + index)}'
      : 'node-$index';

  /// This endpoint's node id as seen by the counterpart.
  String get nodeId => _fakeHost.nodeId;

  /// Whether the link is currently reachable (shared by both endpoints).
  bool get isReachable => _fakeHost.wire.reachable;

  /// Flip link reachability. Both endpoints get a connection-state event;
  /// dropping the link tears down open streams (as the platforms do) and
  /// holds queued transfers until it comes back.
  void setReachable(bool reachable) => _fakeHost.wire.setReachable(reachable);

  /// Identity this endpoint stamps on what it sends, mirroring the native
  /// manifest/Info.plist resolution. Defaults to the node id.
  ///
  /// ```dart
  /// phone.setLinkIdentity(linkId: 'com.acme.fitness', protocolVersion: 3);
  /// ```
  void setLinkIdentity({String? linkId, int? protocolVersion}) {
    if (linkId != null) {
      _fakeHost
        ..linkId = linkId
        ..identityIsExplicit = true;
    }
    if (protocolVersion != null) {
      _fakeHost
        ..protocolVersion = protocolVersion
        ..identityIsExplicit = true;
    }
  }

  /// Make this endpoint send unlabelled, standing in for a counterpart on a
  /// pre-2.2 build so the lenient path can be tested.
  void sendUnlabelled({bool unlabelled = true}) =>
      _fakeHost.stampIdentity = !unlabelled;

  /// Node ids of every other endpoint on this network.
  List<String> get counterpartNodeIds =>
      _fakeHost.others.map((h) => h.nodeId).toList();

  /// Take one node off the air without touching the rest of the network.
  ///
  /// An unreachable node is not a send target at all: it disappears from
  /// [WearerLink.getCompanionStatus] and `getNodes`, and queued transfers
  /// for it wait until it returns. To model a node that is *reachable* but
  /// rejects a send — the case that produces
  /// [WearerSendReport.failures] — use [failSendsTo].
  void setNodeReachable(String nodeId, bool reachable) =>
      _fakeHost.wire.setNodeReachable(nodeId, reachable);

  /// Make interactive sends to [nodeId] fail while leaving it reachable,
  /// so a fan-out reports partial delivery instead of throwing.
  ///
  /// This is the multi-watch race the real Data Layer hits: the capability
  /// query says the node is there, and the send to it fails anyway.
  void failSendsTo(
    String nodeId, {
    String code = 'sendFailed',
    String message = 'Simulated send failure.',
  }) =>
      _fakeHost.wire.sendFailures[nodeId] = (code: code, message: message);

  /// Undo [failSendsTo] for [nodeId].
  void clearSendFailure(String nodeId) =>
      _fakeHost.wire.sendFailures.remove(nodeId);

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

/// State shared by every endpoint on the network.
class _FakeWire {
  final hosts = <_FakeHost>[];

  /// Master switch: false takes the whole network down.
  bool reachable = true;

  /// Nodes individually off the air while [reachable] is still true.
  final offlineNodes = <String>{};

  /// Nodes that stay reachable but reject interactive sends.
  final sendFailures = <String, ({String code, String message})>{};

  List<_FakeHost> others(_FakeHost self) =>
      hosts.where((h) => !identical(h, self)).toList();

  bool isNodeReachable(String nodeId) =>
      reachable && !offlineNodes.contains(nodeId);

  void setReachable(bool value) {
    if (reachable == value) return;
    reachable = value;
    for (final host in hosts) {
      if (!value) host.dropStreams('link lost');
      host.pushConnectionState();
      if (value) host.flushOutbox();
    }
  }

  void setNodeReachable(String nodeId, bool value) {
    final changed = value
        ? offlineNodes.remove(nodeId)
        : offlineNodes.add(nodeId);
    if (!changed) return;
    for (final host in hosts) {
      if (!value) host.dropStreamsTo(nodeId, 'link lost');
      host.pushConnectionState();
      if (value) host.flushOutbox();
    }
  }
}

class _FakeHost extends WearerLinkHostApi {
  _FakeHost(this.wire, this.nodeId, this.platform) : linkId = nodeId;

  final _FakeWire wire;
  final String nodeId;
  final WearerFakePlatform platform;

  /// Identity this endpoint stamps on what it sends. Defaults to the node
  /// id, standing in for the package name / bundle identifier.
  String linkId;
  int protocolVersion = 0;
  bool identityIsExplicit = false;

  /// When false the endpoint sends unlabelled, standing in for a pre-2.2
  /// counterpart so the lenient path stays testable.
  bool stampIdentity = true;

  /// The currently-attached facade; null while "the app is killed".
  WearerLinkFake? link;

  bool deliveryEnabled = true;
  final pendingQueue = <WearerEventDto>[];
  /// Queued transfers awaiting a specific node's return.
  final outbox = <({String nodeId, void Function() deliver})>[];
  final syncedByMe = <String, Uint8List>{};
  final companionLaunches = <DateTime>[];
  final complicationPushes = <Uint8List>[];
  WearerBackgroundHandler? backgroundHandler;
  final openStreams = <String, String>{}; // id -> path
  final streamPeers = <String, String>{}; // id -> counterpart node id
  int _eventSeq = 0;

  static const _maxMessageBytes = 56 * 1024;

  void attach(WearerLinkFake newLink) => link = newLink;

  void detach() => link = null;

  bool get alive => link != null;

  /// Every other endpoint on the network, reachable or not.
  List<_FakeHost> get others => wire.others(this);

  /// Counterparts currently on the air.
  List<_FakeHost> get reachableOthers =>
      others.where((h) => wire.isNodeReachable(h.nodeId)).toList();

  /// The counterpart, for operations that only make sense against one.
  /// On a two-endpoint pair this is unambiguous.
  _FakeHost get other => others.first;

  /// Nodes an outbound call addresses: [nodeId] when given, else every
  /// reachable counterpart. Mirrors DataLayerBridge.targetNodes.
  List<_FakeHost> _targetHosts(String? nodeId) {
    if (nodeId != null) {
      final match = others.where(
        (h) => h.nodeId == nodeId && wire.isNodeReachable(h.nodeId),
      );
      if (match.isEmpty) {
        throw PlatformException(
          code: 'unreachable',
          message: 'Node $nodeId is not reachable/capable.',
        );
      }
      return match.toList();
    }
    final reachable = reachableOthers;
    if (reachable.isEmpty) {
      throw PlatformException(
        code: 'unreachable',
        message: 'Fake link is unreachable.',
      );
    }
    return reachable;
  }

  /// Exactly one target, as request/response and streams require.
  /// Mirrors DataLayerBridge.sendRequest, which refuses to guess.
  _FakeHost _singleTarget(String? nodeId) {
    final targets = _targetHosts(nodeId);
    if (targets.length != 1) {
      throw PlatformException(
        code: 'sendFailed',
        message: 'needs exactly one target; ${targets.length} capable nodes '
            'are reachable — pass nodeId.',
      );
    }
    return targets.single;
  }

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

  WearerEventDto _asDead(WearerEventDto dto) =>
      dto.copyWith(deliveredWhileDead: true);

  WearerEventDto _event(
    WearerEventKindDto kind,
    String path,
    Uint8List payload, {
    String? filePath,
  }) =>
      WearerEventDto(
        linkId: stampIdentity ? linkId : null,
        protocolVersion: stampIdentity ? protocolVersion : null,
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

  CompanionStatusDto _status() {
    final reachable = reachableOthers;
    return CompanionStatusDto(
      state: reachable.isEmpty
          ? ConnectionStateDto.unreachable
          : ConnectionStateDto.reachable,
      nodes: reachable.map((h) => h.nodeId).toList(),
    );
  }

  void flushOutbox() {
    final queued = List.of(outbox);
    outbox.clear();
    for (final entry in queued) {
      if (wire.isNodeReachable(entry.nodeId)) {
        entry.deliver();
      } else {
        outbox.add(entry); // still away; keep holding it
      }
    }
  }

  /// Deliver to every reachable counterpart now, holding one copy per
  /// absent node until it comes back — how DataClient items actually sync.
  void _broadcast(WearerEventDto Function(_FakeHost target) build) {
    for (final target in others) {
      if (wire.isNodeReachable(target.nodeId)) {
        target.receive(build(target));
      } else {
        outbox.add((
          nodeId: target.nodeId,
          deliver: () => target.receive(build(target)),
        ));
      }
    }
  }

  /// Tear down only the streams held with [nodeId].
  void dropStreamsTo(String nodeId, String reason) {
    for (final entry in List.of(streamPeers.entries)) {
      if (entry.value != nodeId) continue;
      streamPeers.remove(entry.key);
      openStreams.remove(entry.key);
      link?.debugFlutterApi.onStreamClosed(entry.key, reason);
    }
  }

  void dropStreams(String reason) {
    for (final id in List.of(openStreams.keys)) {
      openStreams.remove(id);
      streamPeers.remove(id);
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
  Future<LinkIdentityDto> getLinkIdentity() async => LinkIdentityDto(
        linkId: linkId,
        protocolVersion: protocolVersion,
        isExplicit: identityIsExplicit,
      );

  @override
  Future<LinkIdentityDto> configureLink(
    String? linkId,
    int? protocolVersion,
  ) async {
    if (linkId != null) {
      this.linkId = linkId;
      identityIsExplicit = true;
    }
    if (protocolVersion != null) {
      this.protocolVersion = protocolVersion;
      identityIsExplicit = true;
    }
    return getLinkIdentity();
  }

  @override
  Future<CompanionStatusDto> getCompanionStatus() async => _status();

  @override
  Future<SendReportDto> sendMessage(
    String path,
    Uint8List payload,
    String? nodeId,
  ) async {
    final targets = _targetHosts(nodeId);
    final delivered = <String>[];
    final failures = <NodeFailureDto>[];
    for (final target in targets) {
      final failure = wire.sendFailures[target.nodeId];
      if (failure != null) {
        failures.add(
          NodeFailureDto(
            nodeId: target.nodeId,
            code: failure.code,
            message: failure.message,
          ),
        );
        continue;
      }
      // A fresh event per target: ids must stay unique so receiver-side
      // dedup behaves as it does on device.
      target.receive(_event(WearerEventKindDto.message, path, payload));
      delivered.add(target.nodeId);
    }
    if (delivered.isEmpty) {
      throw PlatformException(
        code: 'sendFailed',
        message: 'sendMessage reached no node: '
            '${failures.map((f) => f.nodeId).join(', ')}',
      );
    }
    return SendReportDto(delivered: delivered, failures: failures);
  }

  @override
  Future<Uint8List> sendRequest(
    String path,
    Uint8List payload,
    String? nodeId,
  ) async {
    final counterpart = _singleTarget(nodeId);
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
    _broadcast((_) => _event(WearerEventKindDto.data, path, payload));
  }

  @override
  Future<Uint8List?> readSyncData(String path) async {
    for (final host in others) {
      final value = host.syncedByMe[path];
      if (value != null) return value;
    }
    return null;
  }

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
        for (final host in others) ...host.syncedByMe.keys,
      }.where((p) => p.startsWith(prefix)).toList();

  @override
  Future<void> transferData(String path, Uint8List payload) async {
    // Size-unlimited by contract (oversized payloads ride the blob route
    // natively); observable result is identical, so deliver directly.
    _broadcast((_) => _event(WearerEventKindDto.data, path, payload));
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
    // Each target gets its own copy on disk, as each device would.
    WearerEventDto build(_FakeHost target) {
      final dest = File(
        '${Directory.systemTemp.path}/wearer_fake_${target.nodeId}_'
        '${DateTime.now().microsecondsSinceEpoch}',
      )..writeAsBytesSync(bytes);
      return target._event(
        WearerEventKindDto.file,
        path,
        Uint8List(0),
        filePath: dest.path,
      );
    }

    if (nodeId != null) {
      final target = _targetHosts(nodeId).single;
      target.receive(build(target));
      return;
    }
    _broadcast(build);
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
    // RemoteActivityHelper fans out to every capable node.
    final targets = platform == WearerFakePlatform.iPhone
        ? others
        : _targetHosts(null);
    for (final target in targets) {
      target.companionLaunches.add(DateTime.now());
      if (route != null || argsJson != null) {
        final payload = Uint8List.fromList(
          utf8.encode(jsonEncode({'route': route, 'args': argsJson})),
        );
        target.receive(
          _event(WearerEventKindDto.data, '/__wllaunch', payload),
        );
      }
    }
  }

  @override
  Future<List<WearerNodeDto>> getNodes() async => others
      .map(
        (h) => WearerNodeDto(
          id: h.nodeId,
          displayName: 'Fake ${h.platform.name}',
          isNearby: wire.isNodeReachable(h.nodeId),
        ),
      )
      .toList();

  @override
  Future<CounterpartVitalsDto> getCounterpartVitals(String? nodeId) async {
    // Served by a request on the other side, so it needs one clear target.
    final target = _singleTarget(nodeId);
    return CounterpartVitalsDto(
      batteryPercent: 80,
      isCharging: false,
      model: 'Fake ${target.platform.name}',
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
    for (final target in others) {
      target.complicationPushes.add(payload);
    }
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
    final counterpart = _singleTarget(nodeId);
    if (!counterpart.alive || !counterpart.deliveryEnabled) {
      throw PlatformException(
        code: 'sendFailed',
        message: 'Counterpart refused the stream.',
      );
    }
    final id = 'stream-${counterpart.nodeId}-${_eventSeq++}';
    openStreams[id] = path;
    streamPeers[id] = counterpart.nodeId;
    counterpart.openStreams[id] = path;
    counterpart.streamPeers[id] = this.nodeId;
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
    final peerId = streamPeers[streamId];
    final peer = others.where((h) => h.nodeId == peerId).firstOrNull;
    peer?.link?.debugFlutterApi.onStreamData(streamId, data);
  }

  @override
  Future<void> closeStream(String streamId) async {
    if (openStreams.remove(streamId) == null) return;
    final peerId = streamPeers.remove(streamId);
    link?.debugFlutterApi.onStreamClosed(streamId, null);
    final peer = others.where((h) => h.nodeId == peerId).firstOrNull;
    if (peer != null && peer.openStreams.remove(streamId) != null) {
      peer.streamPeers.remove(streamId);
      peer.link?.debugFlutterApi.onStreamClosed(streamId, null);
    }
  }
}

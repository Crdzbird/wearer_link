import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, ByteData;
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';


import 'src/background.dart';
import 'src/cipher.dart';
import 'src/codecs.dart';
import 'src/messages.g.dart';
import 'src/models.dart';
import 'src/store.dart';
import 'src/stream.dart';
import 'src/transfer.dart';

export 'src/background.dart' show WearerBackgroundHandler;
export 'src/cipher.dart';
export 'src/codecs.dart';
export 'src/models.dart';
export 'src/store.dart' show WearerStore;
export 'src/stream.dart' show WearerStream;
export 'src/transfer.dart';

/// Entry point for phone ⇄ wearable communication.
///
/// The same API runs inside a phone app and inside a Wear OS Flutter app —
/// the Android Data Layer is symmetric. On iOS the watch side is a native
/// Swift companion (see `watchos/` in this package).
class WearerLink {
  WearerLink._(this._host) {
    _flutterApi = _WearerLinkFlutterApiImpl(this);
    WearerLinkFlutterApi.setUp(_flutterApi);
  }

  /// Test seam: inject a fake host API and skip channel registration.
  WearerLink.forTest(WearerLinkHostApi host) : _host = host;

  static WearerLink? _instance;

  /// The app-wide link to the counterpart device.
  static WearerLink get instance => _instance ??= WearerLink._(
        WearerLinkHostApi(),
      );

  final WearerLinkHostApi _host;
  // Kept so the registered FlutterApi handler isn't GC'd behind our back.
  _WearerLinkFlutterApiImpl? _flutterApi;

  /// Test seam: the native->Dart receiver this instance routes events
  /// through. Production wires it to the platform channel; fakes (see
  /// `package:wearer_link/testing.dart`) call it directly so injected
  /// events exercise the real dispatch/dedup/stream machinery.
  @visibleForTesting
  WearerLinkFlutterApi get debugFlutterApi =>
      _flutterApi ??= _WearerLinkFlutterApiImpl(this);

  final _streams = <String, WearerStream>{};
  final _incomingStreams = StreamController<WearerStream>.broadcast();
  final _messages = StreamController<WearerEvent>.broadcast();
  final _dataEvents = StreamController<WearerEvent>.broadcast();
  final _fileEvents = StreamController<WearerEvent>.broadcast();
  final _launchIntents = StreamController<WearerLaunchIntent>.broadcast();
  final _connection = StreamController<WearerCompanionStatus>.broadcast();

  bool _drained = false;

  /// Answers [sendRequest] calls from the counterpart.
  Future<Uint8List> Function(WearerEvent request)? _requestHandler;

  final _routes = <_Route>[];
  final _requestRoutes = <_Route>[];
  final _codecs = <Type, WearerCodec<Object?>>{};

  WearerStore? _store;

  WearerCipher? _cipher;

  /// Marker prefixed to encrypted payloads so mismatched endpoints fail
  /// loudly instead of emitting ciphertext. Reserved: unencrypted app
  /// payloads must not start with these bytes.
  static const _cipherMagic = [0x57, 0x4C, 0x45, 0x01]; // "WLE\x01"

  /// Install (or clear, with null) the app-supplied payload cipher. See
  /// [WearerCipher] for exactly which bytes it covers.
  void setPayloadCipher(WearerCipher? cipher) => _cipher = cipher;

  Future<Uint8List> _encryptOut(String path, Uint8List bytes) async {
    final cipher = _cipher;
    if (cipher == null || bytes.isEmpty || _cipherExempt(path)) return bytes;
    final sealed = await cipher.encrypt(path, bytes);
    return Uint8List.fromList([..._cipherMagic, ...sealed]);
  }

  /// Returns null when the payload must be dropped (cipher mismatch or
  /// failed decryption) — a diagnostic is emitted either way.
  Future<Uint8List?> _decryptIn(String path, Uint8List bytes) async {
    if (bytes.isEmpty || _cipherExempt(path)) return bytes;
    final marked = bytes.length >= _cipherMagic.length &&
        bytes[0] == _cipherMagic[0] &&
        bytes[1] == _cipherMagic[1] &&
        bytes[2] == _cipherMagic[2] &&
        bytes[3] == _cipherMagic[3];
    final cipher = _cipher;
    if (cipher == null) {
      if (!marked) return bytes;
      _diagnose(
        WearerDiagnosticSeverity.error,
        'cipher',
        'dropped encrypted payload on $path — no cipher installed here',
      );
      return null;
    }
    if (!marked) {
      _diagnose(
        WearerDiagnosticSeverity.error,
        'cipher',
        'dropped plaintext payload on $path — this endpoint requires '
            'encryption',
      );
      return null;
    }
    try {
      return await cipher.decrypt(
        path,
        Uint8List.sublistView(bytes, _cipherMagic.length),
      );
    } catch (e) {
      _diagnose(
        WearerDiagnosticSeverity.error,
        'cipher',
        'decryption failed on $path: $e',
      );
      return null;
    }
  }

  static bool _cipherExempt(String path) =>
      path == '/__wllaunch' || path == '/__wlstatus';

  /// The synced key-value store: both sides read/write the same keys,
  /// newest write wins, values persist in the OS sync layer. See
  /// [WearerStore].
  WearerStore get store {
    _scheduleDrain();
    return _store ??= WearerStore.internal(_StoreTransport(this));
  }

  /// Print every send/dispatch via [debugPrint] — field-debugging aid.
  static bool verboseLogging = false;

  final _diagnostics = StreamController<WearerDiagnostic>.broadcast();
  int _sentEvents = 0;
  int _receivedEvents = 0;
  int _replayedEvents = 0;
  int _dedupDropped = 0;

  // Session-level dedup: delivery is at-least-once, so an event can reach
  // the streams twice (e.g. live dispatch racing the startup replay). Ids
  // are unique per event; remember the recent ones and drop repeats.
  final _seenIds = <String>{};
  static const _seenIdsCap = 512;

  /// Whether this device has a wearable stack at all
  /// (Google Play services / WatchConnectivity support).
  Future<bool> get isSupported => _guard(() => _host.isSupported());

  /// What this device/pairing actually supports — check before relying on a
  /// platform-gated feature instead of catching `unsupported` errors.
  Future<WearerCapabilities> getCapabilities() => _guard(
        () async => WearerCapabilities.fromDto(await _host.getCapabilities()),
      );

  /// Pause/resume all delivery. While disabled every inbound event diverts
  /// to the persistent queue — the same lossless path as a killed app — and
  /// incoming streams are rejected. Re-enabling replays what queued up.
  Future<void> setEventDeliveryEnabled(bool enabled) async {
    await _guard(() => _host.setEventDeliveryEnabled(enabled));
    if (enabled) {
      // Whatever queued up while paused replays immediately.
      _drained = false;
      _scheduleDrain();
    }
  }

  /// Whether delivery is currently enabled (see [setEventDeliveryEnabled]).
  Future<bool> isEventDeliveryEnabled() =>
      _guard(() => _host.isEventDeliveryEnabled());

  /// Open a bidirectional byte stream to the counterpart. Requires a
  /// reachable node; see [WearerStream] for the lifecycle. On Android with
  /// several watches pass [nodeId] to pick one.
  Future<WearerStream> openStream(String path, {String? nodeId}) =>
      _guard(() async {
        final id = await _host.openStream(path, nodeId);
        // onStreamOpened(incoming: false) usually arrives first and has the
        // peer node id; fall back to registering here if it hasn't.
        return _streams.putIfAbsent(
          id,
          () => _newStream(id, path, nodeId ?? ''),
        );
      });

  /// Streams the counterpart opened toward this device.
  Stream<WearerStream> get incomingStreams => _incomingStreams.stream;

  /// Transfer a file with observable progress: the bytes ride a plugin
  /// stream on the reserved `/__wlfile` path, so the counterpart must run
  /// wearer_link >= 0.6 and be reachable for the whole transfer. For
  /// fire-and-forget delivery (including to a killed counterpart app) use
  /// [transferFile].
  Future<WearerFileTransfer> transferFileTracked(
    String path,
    String filePath, {
    String? nodeId,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw WearerLinkException(
        WearerErrorCode.sendFailed,
        'No such file: $filePath',
      );
    }
    final size = file.lengthSync();
    final stream = await openStream('/__wlfile', nodeId: nodeId);
    final transfer = WearerFileTransfer.internal(path, size);
    _sentEvents++;
    unawaited(() async {
      try {
        // Header rides the same byte stream as the file: length-prefix it,
        // because Android's native channel streams do not preserve message
        // boundaries (a read may merge the header with file bytes).
        final header =
            Uint8List.fromList(utf8.encode(jsonEncode({'p': path, 's': size})));
        final framed = Uint8List(4 + header.length)
          ..buffer.asByteData().setUint32(0, header.length)
          ..setRange(4, 4 + header.length, header);
        await stream.send(framed);
        await for (final chunk in file.openRead()) {
          await stream.send(
            chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
          );
          transfer.addSent(chunk.length);
        }
        await stream.close();
        transfer.finish();
      } catch (error) {
        _diagnose(
          WearerDiagnosticSeverity.error,
          'transfer',
          'tracked transfer of $path failed: $error',
        );
        unawaited(stream.close().catchError((_) {}));
        transfer.finish(
          error is WearerLinkException
              ? error
              : WearerLinkException(WearerErrorCode.sendFailed, '$error'),
        );
      }
    }());
    return transfer;
  }

  /// This session's traffic counters (a snapshot; poll for updates).
  WearerStats get stats => WearerStats(
        sentEvents: _sentEvents,
        receivedEvents: _receivedEvents,
        replayedEvents: _replayedEvents,
        dedupDropped: _dedupDropped,
        activeStreams: _streams.length,
      );

  /// Native delivery counters that survive app restarts — what happened
  /// while this app was dead (queued, drained, background-handled).
  /// Session-scoped counters live on [stats].
  Future<WearerPersistentStats> getPersistentStats() => _guard(() async {
        final dto = await _host.getPersistentStats();
        return WearerPersistentStats(
          receivedTotal: dto.receivedTotal,
          queuedWhileDead: dto.queuedWhileDead,
          drained: dto.drained,
          backgroundHandled: dto.backgroundHandled,
          since: DateTime.fromMillisecondsSinceEpoch(dto.sinceMillis),
        );
      });

  /// Zero the persistent counters and restart their epoch.
  Future<void> resetPersistentStats() =>
      _guard(() => _host.resetPersistentStats());

  /// Plugin-internal happenings that would otherwise die silently:
  /// abnormal stream closes, failed tracked transfers.
  Stream<WearerDiagnostic> get diagnostics => _diagnostics.stream;

  /// Round-trip latency to the counterpart, measured over the built-in
  /// status responder (no app code involved on the other side).
  Future<Duration> pingLatency({String? nodeId}) async {
    final stopwatch = Stopwatch()..start();
    await getCounterpartVitals(nodeId: nodeId);
    return stopwatch.elapsed;
  }

  /// Current pairing/reachability snapshot.
  Future<WearerCompanionStatus> getCompanionStatus() => _guard(() async =>
      WearerCompanionStatus.fromDto(await _host.getCompanionStatus()));

  /// Interactive messages from the counterpart, including ones that arrived
  /// while the app was dead (replayed on first listen, flagged with
  /// [WearerEvent.deliveredWhileDead]).
  Stream<WearerEvent> get messages {
    _scheduleDrain();
    return _messages.stream;
  }

  /// Synced/transferred data changes from the counterpart, background
  /// arrivals included (see [messages] for replay semantics).
  Stream<WearerEvent> get dataEvents {
    _scheduleDrain();
    return _dataEvents.stream;
  }

  /// Files received from the counterpart ([WearerEvent.filePath] points at
  /// the local copy), background arrivals included (see [messages] for
  /// replay semantics).
  Stream<WearerEvent> get fileEvents {
    _scheduleDrain();
    return _fileEvents.stream;
  }

  /// Pairing/reachability changes.
  Stream<WearerCompanionStatus> get connectionState => _connection.stream;

  /// Send an interactive message. Requires a reachable counterpart;
  /// throws [WearerLinkException] with [WearerErrorCode.unreachable]
  /// otherwise. For guaranteed delivery use [transferData].
  ///
  /// Android delivers to every reachable capable node unless [nodeId]
  /// narrows it to one; iOS has a single counterpart and ignores [nodeId].
  ///
  /// With [queueIfUnreachable], an unreachable counterpart downgrades the
  /// call to [transferData] on the same path instead of throwing — it
  /// arrives later as a **data event** (order relative to live messages is
  /// not guaranteed).
  Future<void> sendMessage(
    String path,
    Uint8List payload, {
    String? nodeId,
    bool queueIfUnreachable = false,
  }) async {
    _sentEvents++;
    if (verboseLogging) {
      debugPrint('wearer_link -> message $path (${payload.length}B)');
    }
    try {
      await _guard(
        () async => _host.sendMessage(
          path,
          await _encryptOut(path, payload),
          nodeId,
        ),
      );
    } on WearerLinkException catch (e) {
      if (!queueIfUnreachable || e.code != WearerErrorCode.unreachable) {
        rethrow;
      }
      await transferData(path, payload);
    }
  }

  /// Request/response round trip: resolves with the counterpart's reply.
  ///
  /// The counterpart must answer — a Flutter app via [setRequestHandler], a
  /// native watch app via `WearerLinkWatch.shared.onRequest`. Requires a
  /// reachable counterpart; [timeout] (default 10s) turns a hung round trip
  /// into [WearerErrorCode.sendFailed].
  Future<Uint8List> sendRequest(
    String path,
    Uint8List payload, {
    String? nodeId,
    Duration timeout = const Duration(seconds: 10),
  }) =>
      _guard(() async {
        final sealed = await _encryptOut(path, payload);
        final reply = await _host.sendRequest(path, sealed, nodeId).timeout(
              timeout,
              onTimeout: () => throw WearerLinkException(
                WearerErrorCode.sendFailed,
                'No reply within $timeout for $path',
              ),
            );
        final clear = await _decryptIn(path, reply);
        if (clear == null) {
          throw const WearerLinkException(
            WearerErrorCode.unsupported,
            'Reply dropped: payload cipher mismatch with the counterpart',
          );
        }
        return clear;
      });

  /// Answer [sendRequest] calls from the counterpart. The handler's returned
  /// bytes travel back as the reply; a thrown error rejects the request on
  /// the sender's side. Requests need a live handler — while the app has
  /// none, senders get an error, never a silent drop.
  void setRequestHandler(
    Future<Uint8List> Function(WearerEvent request)? handler,
  ) {
    _requestHandler = handler;
  }

  /// JSON convenience over [sendMessage].
  Future<void> sendJson(String path, Map<String, Object?> json) =>
      sendMessage(path, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  /// Sync latest state for [path]. Newest value wins; delivered to the
  /// counterpart even if it is unreachable right now (Android `DataClient`
  /// item / iOS `updateApplicationContext`).
  Future<void> syncData(String path, Uint8List payload) {
    _sentEvents++;
    return _guard(
      () async => _host.syncData(path, await _encryptOut(path, payload)),
    );
  }

  /// Latest value the counterpart synced for [path] — the current state
  /// behind [dataEvents] — or null if it never synced one.
  Future<Uint8List?> readSyncData(String path) => _guard(() async {
        final raw = await _host.readSyncData(path);
        return raw == null ? null : _decryptIn(path, raw);
      });

  /// Remove the value this device synced for [path]. The counterpart's own
  /// synced value is theirs to delete.
  Future<void> deleteSyncData(String path) =>
      _guard(() => _host.deleteSyncData(path));

  /// Queue [payload] for guaranteed background delivery — every call is
  /// delivered, in order, once the counterpart connects (Android urgent
  /// `DataClient` item / iOS `transferUserInfo`).
  Future<void> transferData(String path, Uint8List payload) {
    _sentEvents++;
    return _guard(
      () async => _host.transferData(path, await _encryptOut(path, payload)),
    );
  }

  /// Transfer the file at [filePath] to the counterpart, which receives it
  /// as a [fileEvents] event. Android: ChannelClient — requires a reachable
  /// counterpart. iOS: `WCSession.transferFile` — queued and delivered when
  /// the counterpart next connects.
  Future<void> transferFile(String path, String filePath, {String? nodeId}) {
    _sentEvents++;
    return _guard(() => _host.transferFile(path, filePath, nodeId));
  }

  /// Push fresh complication data to the watch face (iOS only).
  ///
  /// Uses `transferCurrentComplicationUserInfo`, which watchOS budgets to
  /// roughly 50 pushes per day — beyond the budget it degrades to a regular
  /// queued transfer. On Android throws [WearerErrorCode.unsupported]:
  /// sync the state with [syncData] and call [requestSurfaceUpdate] from
  /// the Wear OS app instead.
  Future<void> updateComplication(Uint8List payload) =>
      _guard(() => _host.updateComplication(payload));

  /// Ask Wear OS to re-render this app's tile or complication after its
  /// backing state changed. Call it **inside the watch app**; [component]
  /// is the fully-qualified class name of the app's `TileService` or
  /// complication data-source service. Requires the corresponding androidx
  /// dependency (`androidx.wear.tiles:tiles` /
  /// `androidx.wear.watchface:watchface-complications-data-source`) in the
  /// watch app. Throws [WearerErrorCode.unsupported] on iOS — watchOS
  /// complications reload from the native watch app.
  Future<void> requestSurfaceUpdate(String component) =>
      _guard(() => _host.requestSurfaceUpdate(component));

  /// Handle events that arrive while the app is **not running** in a
  /// headless background isolate, instead of only queueing them for the
  /// next launch.
  ///
  /// [handler] must be a **top-level or static** function — it is executed
  /// in its own isolate with no access to your app's state. Events handled
  /// there are acked out of the pending queue; if the handler throws (or
  /// the isolate dies) the event stays queued and replays on next launch,
  /// so delivery remains at-least-once either way.
  Future<void> registerBackgroundHandler(WearerBackgroundHandler handler) {
    final dispatcher = PluginUtilities.getCallbackHandle(
      wearerLinkBackgroundMain,
    );
    final user = PluginUtilities.getCallbackHandle(handler);
    if (dispatcher == null || user == null) {
      throw ArgumentError(
        'handler must be a top-level or static function '
        '(closures and instance methods cannot run in a background isolate)',
      );
    }
    return _guard(
      () => _host.registerBackgroundHandler(
        dispatcher.toRawHandle(),
        user.toRawHandle(),
      ),
    );
  }

  /// Stop background-isolate handling; dead-app events fall back to the
  /// persistent queue only.
  Future<void> clearBackgroundHandler() =>
      _guard(() => _host.clearBackgroundHandler());

  /// Route events whose path matches [pattern] to [handler] — exact
  /// (`/workout/update`) or trailing-wildcard (`/workout/*`) match. The
  /// most specific route wins per event: exact beats wildcard, longer
  /// wildcard prefixes beat shorter ones. Routed events still appear on
  /// the global [messages]/[dataEvents]/[fileEvents] streams.
  ///
  /// Returns a function that removes the route.
  void Function() on(String pattern, void Function(WearerEvent event) handler) {
    final route = _Route(pattern, handler);
    _routes.add(route);
    _scheduleDrain();
    return () => _routes.remove(route);
  }

  /// Answer [sendRequest] calls whose path matches [pattern] (same match
  /// rules as [on]). Routed handlers win over the global
  /// [setRequestHandler], which stays as the fallback.
  ///
  /// Returns a function that removes the route.
  void Function() onRequestPath(
    String pattern,
    Future<Uint8List> Function(WearerEvent request) handler,
  ) {
    final route = _Route.request(pattern, handler);
    _requestRoutes.add(route);
    return () => _requestRoutes.remove(route);
  }

  /// Register how [T] converts to/from payload bytes for the typed helpers
  /// ([sendTyped], [onTyped], [sendRequestTyped]).
  void registerCodec<T>(WearerCodec<T> codec) => _codecs[T] = codec;

  WearerCodec<T> _codec<T>() {
    final codec = _codecs[T];
    if (codec == null) {
      throw StateError(
        'No codec registered for $T — call registerCodec<$T>(...) first.',
      );
    }
    return codec as WearerCodec<T>;
  }

  /// [sendMessage] with a registered codec doing the encoding.
  Future<void> sendTyped<T>(String path, T value, {String? nodeId}) =>
      sendMessage(path, _codec<T>().encode(value), nodeId: nodeId);

  /// [on] with a registered codec doing the decoding.
  void Function() onTyped<T>(
    String pattern,
    void Function(T value, WearerEvent event) handler,
  ) {
    final codec = _codec<T>();
    return on(pattern, (event) => handler(codec.decode(event.payload), event));
  }

  /// [sendRequest] with registered codecs on both legs.
  Future<R> sendRequestTyped<T, R>(
    String path,
    T value, {
    String? nodeId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final reply = await sendRequest(
      path,
      _codec<T>().encode(value),
      nodeId: nodeId,
      timeout: timeout,
    );
    return _codec<R>().decode(reply);
  }

  /// Resolves once the counterpart is reachable — immediately when it
  /// already is. With [timeout], gives up with
  /// [WearerErrorCode.unreachable].
  Future<void> whenReachable({Duration? timeout}) async {
    // Subscribe before the initial check so a reconnect landing between
    // the two can't be missed.
    final reachable = Completer<void>();
    final subscription = connectionState.listen((s) {
      if (s.isReachable && !reachable.isCompleted) reachable.complete();
    });
    try {
      if ((await getCompanionStatus()).isReachable) return;
      if (timeout == null) {
        await reachable.future;
        return;
      }
      await reachable.future.timeout(
        timeout,
        onTimeout: () => throw const WearerLinkException(
          WearerErrorCode.unreachable,
          'Counterpart did not become reachable in time',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Launch the companion app on the counterpart device.
  ///
  /// Android/Wear OS: works both directions and brings the app to the
  /// foreground. iOS: launching the watch app requires a HealthKit workout
  /// session (throws [WearerErrorCode.unsupported] otherwise); a watch can
  /// background-wake the iPhone app simply by sending a message.
  ///
  /// [route]/[args] reach the launched app on its [launchIntents] stream
  /// (delivered as a queued transfer, so they survive the launch gap).
  Future<void> launchCompanion({String? route, Map<String, Object?>? args}) =>
      _guard(
        () => _host.launchCompanion(
          route,
          args == null ? null : jsonEncode(args),
        ),
      );

  /// Launch intents from `launchCompanion(route:, args:)` on the
  /// counterpart — the launched app subscribes here to navigate.
  Stream<WearerLaunchIntent> get launchIntents {
    _scheduleDrain();
    return _launchIntents.stream;
  }

  /// Connected counterpart nodes with their platform facts.
  Future<List<WearerNode>> getNodes() => _guard(
        () async => [
          for (final dto in await _host.getNodes()) WearerNode.fromDto(dto),
        ],
      );

  /// The counterpart device's vitals (battery, model, OS), answered by a
  /// built-in responder on the other side — no app code needed there.
  /// Requires a reachable counterpart running wearer_link >= 0.5.
  Future<WearerCounterpartVitals> getCounterpartVitals({String? nodeId}) =>
      _guard(
        () async => WearerCounterpartVitals.fromDto(
          await _host.getCounterpartVitals(nodeId),
        ),
      );

  /// Replay events persisted while the app was not running. Called
  /// automatically on first listen of [messages]/[dataEvents]; safe to call
  /// again manually (drained events are delivered at most once per launch).
  Future<void> replayPendingEvents() async {
    if (_drained) return;
    _drained = true;
    final pending = await _guard(() => _host.drainPendingEvents());
    pending.forEach(_dispatch);
  }

  void _scheduleDrain() {
    if (_drained) return;
    scheduleMicrotask(() async {
      try {
        await replayPendingEvents();
      } on WearerLinkException {
        // No host available (unit tests, detached engine): nothing to replay,
        // and an automatic drain must never surface an unhandled zone error.
      }
    });
  }

  void _diagnose(
    WearerDiagnosticSeverity severity,
    String area,
    String message,
  ) {
    final diagnostic = WearerDiagnostic(severity, area, message);
    if (verboseLogging) debugPrint('wearer_link $diagnostic');
    _diagnostics.add(diagnostic);
  }

  /// Serializes async (possibly ciphered) dispatch so event order is
  /// preserved end to end.
  Future<void> _dispatchChain = Future.value();

  void _dispatch(WearerEventDto dto) {
    _dispatchChain = _dispatchChain.then((_) => _dispatchAsync(dto));
  }

  Future<void> _dispatchAsync(WearerEventDto dto) async {
    if (dto.payload.isNotEmpty) {
      final clear = await _decryptIn(dto.path, dto.payload);
      if (clear == null) return; // dropped: cipher mismatch
      dto = WearerEventDto(
        id: dto.id,
        kind: dto.kind,
        path: dto.path,
        payload: clear,
        sourceNodeId: dto.sourceNodeId,
        timestampMillis: dto.timestampMillis,
        deliveredWhileDead: dto.deliveredWhileDead,
        filePath: dto.filePath,
      );
    }
    if (!_seenIds.add(dto.id)) {
      _dedupDropped++;
      return; // duplicate replay/live race
    }
    _receivedEvents++;
    if (dto.deliveredWhileDead) _replayedEvents++;
    if (verboseLogging) {
      debugPrint(
        'wearer_link <- ${dto.kind.name} ${dto.path} '
        '(${dto.payload.length}B${dto.deliveredWhileDead ? ', replayed' : ''})',
      );
    }
    if (_seenIds.length > _seenIdsCap) {
      _seenIds.remove(_seenIds.first); // Set keeps insertion order: drop oldest
    }
    if (dto.path == '/__wllaunch') {
      // Reserved plugin path: surface as a launch intent, not a data event.
      _launchIntents.add(_parseLaunchIntent(dto.payload));
      return;
    }
    if (dto.path.startsWith('/__wlstore/')) {
      // Reserved plugin path: a counterpart store record.
      store.onRemoteRecord(dto.path, dto.payload);
      return;
    }
    final event = WearerEvent.fromDto(dto);
    _Route.bestMatch(_routes, event.path)?.call(event);
    switch (event.kind) {
      case WearerEventKind.message:
        _messages.add(event);
      case WearerEventKind.data:
        _dataEvents.add(event);
      case WearerEventKind.file:
        _fileEvents.add(event);
    }
  }

  WearerStream _newStream(String id, String path, String peer) =>
      WearerStream.internal(
        id,
        path,
        peer,
        (streamId, bytes) async => _host.sendStreamData(
          streamId,
          await _encryptOut(path, bytes),
        ),
        (streamId) => _host.closeStream(streamId),
      );

  /// Receive one inbound tracked file: header frame, then raw chunks; a
  /// clean close completes the file and emits a file event.
  void _receiveTrackedFile(WearerStream stream) {
    String? userPath;
    IOSink? sink;
    File? target;
    var received = 0;
    // The header is length-prefixed because the byte stream may split or
    // merge writes (Android channel streams preserve order, not
    // boundaries) — buffer until it is complete.
    final pendingHeader = BytesBuilder(copy: false);
    stream.data.listen(
      (chunk) {
        if (userPath == null) {
          pendingHeader.add(chunk);
          final buffered = pendingHeader.toBytes();
          if (buffered.length < 4) return;
          final headerLength =
              ByteData.sublistView(buffered, 0, 4).getUint32(0);
          if (buffered.length < 4 + headerLength) return;
          try {
            final header = jsonDecode(
              utf8.decode(
                Uint8List.sublistView(buffered, 4, 4 + headerLength),
              ),
            ) as Map<String, Object?>;
            userPath = header['p'] as String? ?? '/';
            target = File(
              '${Directory.systemTemp.path}/wearer_link_rx_'
              '${DateTime.now().microsecondsSinceEpoch}',
            );
            sink = target!.openWrite();
          } catch (e) {
            _diagnose(
              WearerDiagnosticSeverity.error,
              'transfer',
              'malformed tracked-transfer header: $e',
            );
            unawaited(stream.close().catchError((_) {}));
            return;
          }
          // Bytes that arrived merged with the header are file data.
          final rest = buffered.length - 4 - headerLength;
          if (rest > 0) {
            sink!.add(Uint8List.sublistView(buffered, 4 + headerLength));
            received += rest;
          }
          pendingHeader.clear();
          return;
        }
        sink?.add(chunk);
        received += chunk.length;
      },
      onError: (Object _) {},
      onDone: () async {
        final path = userPath;
        final file = target;
        await sink?.close();
        if (path == null || file == null) return;
        _dispatch(
          WearerEventDto(
            id: 'tracked-${stream.id}',
            kind: WearerEventKindDto.file,
            path: path,
            payload: Uint8List(0),
            sourceNodeId: stream.peerNodeId,
            timestampMillis: DateTime.now().millisecondsSinceEpoch,
            deliveredWhileDead: false,
            filePath: file.path,
          ),
        );
      },
    );
    stream.done.catchError((Object error) {
      // Abnormal close: drop the partial file.
      sink?.close().then((_) async {
        try {
          await target?.delete();
        } catch (_) {}
      });
      _diagnose(
        WearerDiagnosticSeverity.error,
        'transfer',
        'inbound tracked transfer failed after $received bytes: $error',
      );
    });
  }

  static WearerLaunchIntent _parseLaunchIntent(Uint8List payload) {
    try {
      final decoded = jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
      final rawArgs = decoded['args'];
      return WearerLaunchIntent(
        route: decoded['route'] as String?,
        args: rawArgs is String
            ? jsonDecode(rawArgs) as Map<String, Object?>?
            : rawArgs as Map<String, Object?>?,
      );
    } catch (_) {
      return const WearerLaunchIntent();
    }
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PlatformException catch (e) {
      throw WearerLinkException(
        WearerErrorCode.values.asNameMap()[e.code] ?? WearerErrorCode.unknown,
        e.message ?? e.code,
      );
    }
  }
}

class _WearerLinkFlutterApiImpl implements WearerLinkFlutterApi {
  _WearerLinkFlutterApiImpl(this._link);

  final WearerLink _link;

  @override
  void onMessage(WearerEventDto event) => _link._dispatch(event);

  @override
  Future<Uint8List> onRequest(WearerEventDto event) async {
    var request = WearerEvent.fromDto(event);
    if (request.payload.isNotEmpty) {
      final clear = await _link._decryptIn(request.path, request.payload);
      if (clear == null) {
        throw PlatformException(
          code: 'unsupported',
          message: 'Request dropped: payload cipher mismatch.',
        );
      }
      request = WearerEvent(
        id: request.id,
        kind: request.kind,
        path: request.path,
        payload: clear,
        sourceNodeId: request.sourceNodeId,
        timestamp: request.timestamp,
        deliveredWhileDead: request.deliveredWhileDead,
      );
    }
    final route = _Route.bestMatch(_link._requestRoutes, request.path);
    final handler = route != null
        ? route.callRequest
        : _link._requestHandler ??
            (throw PlatformException(
              code: 'noHandler',
              message: 'No request handler registered '
                  '(setRequestHandler / onRequestPath).',
            ));
    return _link._encryptOut(request.path, await handler(request));
  }

  @override
  void onDataChanged(WearerEventDto event) => _link._dispatch(event);

  @override
  void onFileReceived(WearerEventDto event) => _link._dispatch(event);

  @override
  void onConnectionStateChanged(CompanionStatusDto status) =>
      _link._connection.add(WearerCompanionStatus.fromDto(status));

  @override
  void onStreamOpened(
    String streamId,
    String path,
    String sourceNodeId,
    bool incoming,
  ) {
    final stream = _link._streams.putIfAbsent(
      streamId,
      () => _link._newStream(streamId, path, sourceNodeId),
    );
    if (!incoming) return;
    if (path == '/__wlfile') {
      // Reserved plugin stream: a tracked file transfer — receive it into
      // a temp file and surface it as a file event, not a raw stream.
      _link._receiveTrackedFile(stream);
      return;
    }
    _link._incomingStreams.add(stream);
  }

  /// Per-stream decrypt chains keep chunk order under async ciphers.
  final _streamRxChains = <String, Future<void>>{};

  @override
  void onStreamData(String streamId, Uint8List data) {
    final stream = _link._streams[streamId];
    if (stream == null) return;
    _streamRxChains[streamId] =
        (_streamRxChains[streamId] ?? Future.value()).then((_) async {
      final clear = await _link._decryptIn(stream.path, data);
      if (clear != null) stream.addData(clear); // null = dropped + diagnosed
    });
  }

  @override
  void onStreamClosed(String streamId, String? error) {
    // Let queued chunks land before the stream is marked closed.
    final chain = _streamRxChains.remove(streamId) ?? Future.value();
    chain.whenComplete(() => _finishStreamClose(streamId, error));
  }

  void _finishStreamClose(String streamId, String? error) {
    if (error != null) {
      _link._diagnose(
        WearerDiagnosticSeverity.warning,
        'stream',
        'stream $streamId closed abnormally: $error',
      );
    }
    _link._streams.remove(streamId)?.markClosed(error);
  }
}


/// One registered route: exact path or trailing-`/*` prefix pattern.
class _Route {
  _Route(this.pattern, this.handler) : requestHandler = null;

  _Route.request(this.pattern, this.requestHandler) : handler = null;

  final String pattern;
  final void Function(WearerEvent event)? handler;
  final Future<Uint8List> Function(WearerEvent request)? requestHandler;

  bool get isWildcard => pattern.endsWith('/*');

  String get prefix => pattern.substring(0, pattern.length - 1); // keeps '/'

  bool matches(String path) =>
      isWildcard ? path.startsWith(prefix) : path == pattern;

  /// Most specific match: exact beats wildcard; among wildcards the longer
  /// prefix wins; ties resolve to the earliest registration.
  static _Route? bestMatch(List<_Route> routes, String path) {
    _Route? best;
    for (final route in routes) {
      if (!route.matches(path)) continue;
      if (!route.isWildcard) return route;
      if (best == null || route.prefix.length > best.prefix.length) {
        best = route;
      }
    }
    return best;
  }

  void call(WearerEvent event) {
    try {
      handler?.call(event);
    } catch (error, stack) {
      // A route handler error must not break dispatch to other listeners;
      // surface it as an unhandled async error instead of swallowing it.
      Zone.current.handleUncaughtError(error, stack);
    }
  }

  Future<Uint8List> callRequest(WearerEvent request) => requestHandler!(request);
}


/// Adapts the facade for [WearerStore] without exposing store plumbing as
/// public members of [WearerLink]; the cipher wraps store records here.
class _StoreTransport implements StoreTransport {
  _StoreTransport(this._link);

  final WearerLink _link;

  @override
  Future<void> storeSync(String path, Uint8List payload) async =>
      _link._guard(() async =>
          _link._host.syncData(path, await _link._encryptOut(path, payload)));

  @override
  Future<Uint8List?> storeReadOwn(String path) => _link._guard(() async {
        final raw = await _link._host.readOwnSyncData(path);
        return raw == null ? null : _link._decryptIn(path, raw);
      });

  @override
  Future<Uint8List?> storeReadTheirs(String path) => _link._guard(() async {
        final raw = await _link._host.readSyncData(path);
        return raw == null ? null : _link._decryptIn(path, raw);
      });

  @override
  Future<List<String>> storeListPaths(String prefix) =>
      _link._guard(() => _link._host.listSyncPaths(prefix));
}

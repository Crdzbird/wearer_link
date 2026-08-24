import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart';


import 'src/background.dart';
import 'src/codecs.dart';
import 'src/messages.g.dart';
import 'src/models.dart';
import 'src/stream.dart';

export 'src/background.dart' show WearerBackgroundHandler;
export 'src/codecs.dart';
export 'src/models.dart';
export 'src/stream.dart' show WearerStream;

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
          () => WearerStream.internal(id, path, nodeId ?? '', _host),
        );
      });

  /// Streams the counterpart opened toward this device.
  Stream<WearerStream> get incomingStreams => _incomingStreams.stream;

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
    try {
      await _guard(() => _host.sendMessage(path, payload, nodeId));
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
      _guard(
        () => _host.sendRequest(path, payload, nodeId).timeout(
              timeout,
              onTimeout: () => throw WearerLinkException(
                WearerErrorCode.sendFailed,
                'No reply within $timeout for $path',
              ),
            ),
      );

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
  Future<void> syncData(String path, Uint8List payload) =>
      _guard(() => _host.syncData(path, payload));

  /// Latest value the counterpart synced for [path] — the current state
  /// behind [dataEvents] — or null if it never synced one.
  Future<Uint8List?> readSyncData(String path) =>
      _guard(() => _host.readSyncData(path));

  /// Remove the value this device synced for [path]. The counterpart's own
  /// synced value is theirs to delete.
  Future<void> deleteSyncData(String path) =>
      _guard(() => _host.deleteSyncData(path));

  /// Queue [payload] for guaranteed background delivery — every call is
  /// delivered, in order, once the counterpart connects (Android urgent
  /// `DataClient` item / iOS `transferUserInfo`).
  Future<void> transferData(String path, Uint8List payload) =>
      _guard(() => _host.transferData(path, payload));

  /// Transfer the file at [filePath] to the counterpart, which receives it
  /// as a [fileEvents] event. Android: ChannelClient — requires a reachable
  /// counterpart. iOS: `WCSession.transferFile` — queued and delivered when
  /// the counterpart next connects.
  Future<void> transferFile(String path, String filePath, {String? nodeId}) =>
      _guard(() => _host.transferFile(path, filePath, nodeId));

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
  Future<WearerCounterpartStatus> getCounterpartStatus({String? nodeId}) =>
      _guard(
        () async => WearerCounterpartStatus.fromDto(
          await _host.getCounterpartStatus(nodeId),
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

  void _dispatch(WearerEventDto dto) {
    if (!_seenIds.add(dto.id)) return; // duplicate replay/live race
    if (_seenIds.length > _seenIdsCap) {
      _seenIds.remove(_seenIds.first); // Set keeps insertion order: drop oldest
    }
    if (dto.path == '/__wllaunch') {
      // Reserved plugin path: surface as a launch intent, not a data event.
      _launchIntents.add(_parseLaunchIntent(dto.payload));
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
  Future<Uint8List> onRequest(WearerEventDto event) {
    final request = WearerEvent.fromDto(event);
    final route = _Route.bestMatch(_link._requestRoutes, request.path);
    if (route != null) return route.callRequest(request);
    final handler = _link._requestHandler;
    if (handler == null) {
      throw PlatformException(
        code: 'noHandler',
        message: 'No request handler registered '
            '(setRequestHandler / onRequestPath).',
      );
    }
    return handler(request);
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
      () => WearerStream.internal(streamId, path, sourceNodeId, _link._host),
    );
    if (incoming) _link._incomingStreams.add(stream);
  }

  @override
  void onStreamData(String streamId, Uint8List data) =>
      _link._streams[streamId]?.addData(data);

  @override
  void onStreamClosed(String streamId, String? error) {
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

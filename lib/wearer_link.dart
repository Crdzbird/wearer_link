import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';

import 'src/background.dart';
import 'src/messages.g.dart';
import 'src/models.dart';

export 'src/background.dart' show WearerBackgroundHandler;
export 'src/models.dart';

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
  // ignore: unused_field
  _WearerLinkFlutterApiImpl? _flutterApi;

  final _messages = StreamController<WearerEvent>.broadcast();
  final _dataEvents = StreamController<WearerEvent>.broadcast();
  final _fileEvents = StreamController<WearerEvent>.broadcast();
  final _connection = StreamController<WearerCompanionStatus>.broadcast();

  bool _drained = false;

  /// Answers [sendRequest] calls from the counterpart.
  Future<Uint8List> Function(WearerEvent request)? _requestHandler;

  // Session-level dedup: delivery is at-least-once, so an event can reach
  // the streams twice (e.g. live dispatch racing the startup replay). Ids
  // are unique per event; remember the recent ones and drop repeats.
  final _seenIds = <String>{};
  static const _seenIdsCap = 512;

  /// Whether this device has a wearable stack at all
  /// (Google Play services / WatchConnectivity support).
  Future<bool> get isSupported => _guard(() => _host.isSupported());

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
  Future<void> sendMessage(String path, Uint8List payload, {String? nodeId}) =>
      _guard(() => _host.sendMessage(path, payload, nodeId));

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

  /// Launch the companion app on the counterpart device.
  ///
  /// Android/Wear OS: works both directions and brings the app to the
  /// foreground. iOS: launching the watch app requires a HealthKit workout
  /// session (throws [WearerErrorCode.unsupported] otherwise); a watch can
  /// background-wake the iPhone app simply by sending a message.
  Future<void> launchCompanion() => _guard(() => _host.launchCompanion());

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
    final event = WearerEvent.fromDto(dto);
    switch (event.kind) {
      case WearerEventKind.message:
        _messages.add(event);
      case WearerEventKind.data:
        _dataEvents.add(event);
      case WearerEventKind.file:
        _fileEvents.add(event);
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
    final handler = _link._requestHandler;
    if (handler == null) {
      throw PlatformException(
        code: 'noHandler',
        message: 'No request handler registered (setRequestHandler).',
      );
    }
    return handler(WearerEvent.fromDto(event));
  }

  @override
  void onDataChanged(WearerEventDto event) => _link._dispatch(event);

  @override
  void onFileReceived(WearerEventDto event) => _link._dispatch(event);

  @override
  void onConnectionStateChanged(CompanionStatusDto status) =>
      _link._connection.add(WearerCompanionStatus.fromDto(status));
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'src/messages.g.dart';
import 'src/models.dart';

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
  final _connection = StreamController<WearerCompanionStatus>.broadcast();

  bool _drained = false;

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

  /// Pairing/reachability changes.
  Stream<WearerCompanionStatus> get connectionState => _connection.stream;

  /// Send an interactive message. Requires a reachable counterpart;
  /// throws [WearerLinkException] with [WearerErrorCode.unreachable]
  /// otherwise. For guaranteed delivery use [transferData].
  Future<void> sendMessage(String path, Uint8List payload) =>
      _guard(() => _host.sendMessage(path, payload));

  /// JSON convenience over [sendMessage].
  Future<void> sendJson(String path, Map<String, Object?> json) =>
      sendMessage(path, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  /// Sync latest state for [path]. Newest value wins; delivered to the
  /// counterpart even if it is unreachable right now (Android `DataClient`
  /// item / iOS `updateApplicationContext`).
  Future<void> syncData(String path, Uint8List payload) =>
      _guard(() => _host.syncData(path, payload));

  /// Queue [payload] for guaranteed background delivery — every call is
  /// delivered, in order, once the counterpart connects (Android urgent
  /// `DataClient` item / iOS `transferUserInfo`).
  Future<void> transferData(String path, Uint8List payload) =>
      _guard(() => _host.transferData(path, payload));

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
    final event = WearerEvent.fromDto(dto);
    switch (event.kind) {
      case WearerEventKind.message:
        _messages.add(event);
      case WearerEventKind.data:
        _dataEvents.add(event);
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
  void onDataChanged(WearerEventDto event) => _link._dispatch(event);

  @override
  void onConnectionStateChanged(CompanionStatusDto status) =>
      _link._connection.add(WearerCompanionStatus.fromDto(status));
}

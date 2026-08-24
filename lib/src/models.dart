import 'dart:typed_data';

import 'messages.g.dart';

/// Reachability of the paired counterpart device.
enum WearerConnectionState {
  /// The wearable stack is unavailable on this device
  /// (no Google Play services / WatchConnectivity unsupported).
  unsupported,

  /// No counterpart device is paired.
  unpaired,

  /// A counterpart is paired but the companion app is not installed on it.
  appNotInstalled,

  /// Paired and installed, but not currently reachable.
  unreachable,

  /// The counterpart can receive interactive messages right now.
  reachable;

  static WearerConnectionState fromDto(ConnectionStateDto dto) =>
      switch (dto) {
        ConnectionStateDto.unsupported => unsupported,
        ConnectionStateDto.unpaired => unpaired,
        ConnectionStateDto.appNotInstalled => appNotInstalled,
        ConnectionStateDto.unreachable => unreachable,
        ConnectionStateDto.reachable => reachable,
      };
}

/// Snapshot of the relationship with the counterpart device.
class WearerCompanionStatus {
  const WearerCompanionStatus({required this.state, required this.nodes});

  factory WearerCompanionStatus.fromDto(CompanionStatusDto dto) =>
      WearerCompanionStatus(
        state: WearerConnectionState.fromDto(dto.state),
        nodes: List.unmodifiable(dto.nodes),
      );

  final WearerConnectionState state;

  /// Ids of reachable counterpart nodes. Android can report several
  /// (multiple watches); iOS reports at most one.
  final List<String> nodes;

  bool get isReachable => state == WearerConnectionState.reachable;

  @override
  String toString() => 'WearerCompanionStatus($state, nodes: $nodes)';
}

/// How an event crossed the device boundary.
enum WearerEventKind {
  /// Interactive message (`sendMessage` on the other side).
  message,

  /// Synced/transferred data (`syncData` / `transferData` on the other side).
  data,

  /// A file (`transferFile` on the other side) — see [WearerEvent.filePath].
  file,
}

/// An event received from the counterpart device.
class WearerEvent {
  const WearerEvent({
    required this.id,
    required this.kind,
    required this.path,
    required this.payload,
    required this.sourceNodeId,
    required this.timestamp,
    required this.deliveredWhileDead,
    this.filePath,
  });

  factory WearerEvent.fromDto(WearerEventDto dto) => WearerEvent(
        id: dto.id,
        kind: switch (dto.kind) {
          WearerEventKindDto.message => WearerEventKind.message,
          WearerEventKindDto.data => WearerEventKind.data,
          WearerEventKindDto.file => WearerEventKind.file,
        },
        path: dto.path,
        payload: dto.payload,
        sourceNodeId: dto.sourceNodeId,
        timestamp: DateTime.fromMillisecondsSinceEpoch(dto.timestampMillis),
        deliveredWhileDead: dto.deliveredWhileDead,
        filePath: dto.filePath,
      );

  /// Unique id, stable across background replays — use it to deduplicate
  /// (delivery is at-least-once).
  final String id;

  final WearerEventKind kind;

  /// Application-defined routing path, e.g. `/workout/update`.
  final String path;

  final Uint8List payload;

  final String sourceNodeId;

  final DateTime timestamp;

  /// True when this event arrived while the app was not running and was
  /// replayed from the plugin's persistent queue.
  final bool deliveredWhileDead;

  /// For [WearerEventKind.file] events, the absolute path of the received
  /// file. The plugin stores it in the app's cache directory — move it
  /// somewhere durable if you need it beyond the next cache purge.
  /// Null for message/data events.
  final String? filePath;

  @override
  String toString() =>
      'WearerEvent($kind $path, ${payload.length}B from $sourceNodeId'
      '${deliveredWhileDead ? ', replayed' : ''})';
}

/// Error codes surfaced by the native side.
enum WearerErrorCode {
  /// The platform forbids the operation (e.g. launching a watchOS app
  /// outside a workout context, or no wearable stack on this device).
  unsupported,

  /// No counterpart is currently reachable for an interactive message.
  unreachable,

  /// The platform accepted the call but delivery failed.
  sendFailed,

  /// Launching the companion app failed.
  launchFailed,

  /// A request reached the counterpart but no request handler was
  /// registered there.
  noHandler,

  /// Anything the native side didn't classify.
  unknown,
}

class WearerLinkException implements Exception {
  const WearerLinkException(this.code, this.message);

  final WearerErrorCode code;
  final String message;

  @override
  String toString() => 'WearerLinkException(${code.name}: $message)';
}

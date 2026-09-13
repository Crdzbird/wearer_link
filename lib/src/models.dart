import 'dart:typed_data';

import 'package:meta/meta.dart';

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
  reachable,

  /// Reachable, but every counterpart is known to declare a different link
  /// id — a different app build or protocol version. Sends are refused with
  /// [WearerErrorCode.linkMismatch] rather than crossing builds.
  incompatible;

  /// Internal: maps the wire enum.
  @internal
  static WearerConnectionState fromDto(ConnectionStateDto dto) =>
      switch (dto) {
        ConnectionStateDto.unsupported => unsupported,
        ConnectionStateDto.unpaired => unpaired,
        ConnectionStateDto.appNotInstalled => appNotInstalled,
        ConnectionStateDto.unreachable => unreachable,
        ConnectionStateDto.reachable => reachable,
        ConnectionStateDto.incompatible => incompatible,
      };
}

/// Snapshot of the relationship with the counterpart device.
class WearerCompanionStatus {
  /// Creates a snapshot (produced by the plugin; apps rarely construct it).
  const WearerCompanionStatus({required this.state, required this.nodes});

  /// Internal: maps the wire DTO.
  @internal
  factory WearerCompanionStatus.fromDto(CompanionStatusDto dto) =>
      WearerCompanionStatus(
        state: WearerConnectionState.fromDto(dto.state),
        nodes: List.unmodifiable(dto.nodes),
      );

  /// Pairing/reachability classification.
  final WearerConnectionState state;

  /// Ids of reachable counterpart nodes. Android can report several
  /// (multiple watches); iOS reports at most one.
  final List<String> nodes;

  /// Whether interactive messages can be delivered right now.
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
  /// Creates an event (produced by the plugin; apps rarely construct it).
  const WearerEvent({
    required this.id,
    required this.kind,
    required this.path,
    required this.payload,
    required this.sourceNodeId,
    required this.timestamp,
    required this.deliveredWhileDead,
    this.filePath,
    this.linkId,
    this.protocolVersion,
  });

  /// Internal: maps the wire DTO.
  @internal
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
        linkId: dto.linkId,
        protocolVersion: dto.protocolVersion,
      );

  /// Unique id, stable across background replays — use it to deduplicate
  /// (delivery is at-least-once).
  final String id;

  /// How the event crossed the boundary.
  final WearerEventKind kind;

  /// Application-defined routing path, e.g. `/workout/update`.
  final String path;

  /// Raw payload bytes (empty for [WearerEventKind.file] events).
  final Uint8List payload;

  /// Node id of the sending device.
  final String sourceNodeId;

  /// Sender-side creation time.
  final DateTime timestamp;

  /// True when this event arrived while the app was not running and was
  /// replayed from the plugin's persistent queue.
  final bool deliveredWhileDead;

  /// For [WearerEventKind.file] events, the absolute path of the received
  /// file. The plugin stores it in the app's cache directory — move it
  /// somewhere durable if you need it beyond the next cache purge.
  /// Null for message/data events.
  final String? filePath;

  /// Link id the sender stamped on this event, or null when it arrived
  /// unlabelled — a pre-2.2 counterpart, or a transport with no metadata
  /// room (Android `MessageClient` messages and requests). As of 2.2 this is
  /// carried and reported only; nothing is rejected on its account.
  final String? linkId;

  /// Protocol version the sender declared, null when unlabelled.
  final int? protocolVersion;

  /// Whether the sender identified itself at all.
  bool get isLabelled => linkId != null;

  @override
  String toString() =>
      'WearerEvent($kind $path, ${payload.length}B from $sourceNodeId'
      '${deliveredWhileDead ? ', replayed' : ''})';
}

/// One counterpart node an interactive send did not reach.
class WearerNodeFailure {
  /// Creates a failure record (produced by the plugin).
  const WearerNodeFailure({
    required this.nodeId,
    required this.code,
    required this.message,
  });

  /// Internal: maps the wire DTO.
  @internal
  factory WearerNodeFailure.fromDto(NodeFailureDto dto) => WearerNodeFailure(
        nodeId: dto.nodeId,
        code: WearerErrorCode.values.asNameMap()[dto.code] ??
            WearerErrorCode.unknown,
        message: dto.message,
      );

  /// Node that did not accept the message.
  final String nodeId;

  /// Why it failed.
  final WearerErrorCode code;

  /// Platform detail behind [code].
  final String message;

  @override
  String toString() => 'WearerNodeFailure($nodeId, ${code.name}: $message)';
}

/// Outcome of [WearerLink.sendMessage].
///
/// A pairing can have several watches. A send that reaches some and fails
/// others reports both rather than aborting on the first failure, so partial
/// delivery is visible instead of looking like total failure. The send throws
/// only when no node accepted it.
class WearerSendReport {
  /// Creates a report (produced by the plugin).
  const WearerSendReport({
    required this.delivered,
    required this.failures,
    this.queued = false,
  });

  /// Internal: maps the wire DTO.
  @internal
  factory WearerSendReport.fromDto(SendReportDto dto) => WearerSendReport(
        delivered: List.unmodifiable(dto.delivered),
        failures: List.unmodifiable(
          dto.failures.map(WearerNodeFailure.fromDto),
        ),
      );

  /// Internal: the message was downgraded to a queued transfer because the
  /// counterpart was unreachable (`queueIfUnreachable: true`).
  @internal
  const WearerSendReport.queuedTransfer()
      : delivered = const [],
        failures = const [],
        queued = true;

  /// Node ids that accepted the message. Empty only when [queued].
  final List<String> delivered;

  /// Nodes that were attempted and failed.
  final List<WearerNodeFailure> failures;

  /// True when the message was downgraded to a queued transfer and will
  /// arrive later as a data event rather than an interactive message.
  final bool queued;

  /// True when every attempted node accepted the message.
  bool get isComplete => failures.isEmpty;

  @override
  String toString() => queued
      ? 'WearerSendReport(queued)'
      : 'WearerSendReport(delivered: $delivered, failures: $failures)';
}

/// Who this side of the link claims to be.
///
/// Resolved by the native layer so it is available before any Dart runs —
/// events arrive while the app is dead, so identity cannot live only in a
/// Dart setter. Resolution order: [WearerLink.configureLink] override, then
/// `AndroidManifest.xml` meta-data / `Info.plist`, then the package name or
/// bundle identifier.
class WearerLinkIdentity {
  /// Creates an identity (produced by the plugin).
  const WearerLinkIdentity({
    required this.linkId,
    required this.protocolVersion,
    required this.isExplicit,
    this.strict = false,
  });

  /// Internal: maps the wire DTO.
  @internal
  factory WearerLinkIdentity.fromDto(LinkIdentityDto dto) =>
      WearerLinkIdentity(
        linkId: dto.linkId,
        protocolVersion: dto.protocolVersion,
        isExplicit: dto.isExplicit,
        strict: dto.strict,
      );

  /// Identifier both sides compare. Defaults to the package name (Android)
  /// or bundle identifier (iOS).
  final String linkId;

  /// Application-defined schema version; 0 when never declared.
  final int protocolVersion;

  /// True when declared explicitly rather than defaulted from the
  /// package/bundle id.
  final bool isExplicit;

  /// When true, a counterpart must positively prove a matching identity:
  /// unlabelled and not-yet-handshaked peers are refused. Default false
  /// (lenient) — only a known mismatch is refused, so pre-2.2 counterparts
  /// keep working.
  final bool strict;

  @override
  String toString() => 'WearerLinkIdentity($linkId v$protocolVersion'
      '${isExplicit ? '' : ', defaulted'}${strict ? ', strict' : ''})';
}

/// How (whether) this device can launch the companion app.
enum WearerCompanionLaunch {
  /// Opens the companion app in the foreground (Android/Wear OS).
  foreground,

  /// Only via a HealthKit workout session (iOS -> watchOS).
  workoutOnly,

  /// The OS offers no way to launch the counterpart app.
  none;

  /// Internal: maps the wire enum.
  @internal
  static WearerCompanionLaunch fromDto(CompanionLaunchDto dto) =>
      switch (dto) {
        CompanionLaunchDto.foreground => foreground,
        CompanionLaunchDto.workoutOnly => workoutOnly,
        CompanionLaunchDto.none => none,
      };
}

/// What this device/pairing actually supports. Honest OS facts — a `false`
/// here is an OS policy, not a plugin gap.
class WearerCapabilities {
  /// Creates a report (produced by the plugin; apps rarely construct it).
  const WearerCapabilities({
    required this.message,
    required this.request,
    required this.syncData,
    required this.transferData,
    required this.transferFile,
    required this.stream,
    required this.companionLaunch,
    required this.complicationPush,
    required this.surfaceUpdate,
    required this.backgroundWake,
    required this.maxMessageBytes,
  });

  /// Internal: maps the wire DTO.
  @internal
  factory WearerCapabilities.fromDto(WearerCapabilitiesDto dto) =>
      WearerCapabilities(
        message: dto.message,
        request: dto.request,
        syncData: dto.syncData,
        transferData: dto.transferData,
        transferFile: dto.transferFile,
        stream: dto.stream,
        companionLaunch: WearerCompanionLaunch.fromDto(dto.companionLaunch),
        complicationPush: dto.complicationPush,
        surfaceUpdate: dto.surfaceUpdate,
        backgroundWake: dto.backgroundWake,
        maxMessageBytes: dto.maxMessageBytes,
      );

  /// `sendMessage` support.
  final bool message;

  /// `sendRequest` support.
  final bool request;

  /// `syncData` support.
  final bool syncData;

  /// `transferData` support.
  final bool transferData;

  /// `transferFile` support.
  final bool transferFile;

  /// Bidirectional streams (Android: native ChannelClient; iOS: message
  /// framing — needs a reachable counterpart in both cases).
  final bool stream;

  /// How (whether) `launchCompanion` can work here.
  final WearerCompanionLaunch companionLaunch;

  /// `updateComplication` pushes (iOS only).
  final bool complicationPush;

  /// `requestSurfaceUpdate` (Wear OS only).
  final bool surfaceUpdate;

  /// Delivery while the app is killed.
  final bool backgroundWake;

  /// Safe upper bound for one sendMessage/sendRequest payload.
  /// `transferData` is not limited (large payloads route through a file).
  final int maxMessageBytes;

  @override
  String toString() =>
      'WearerCapabilities(stream: $stream, launch: ${companionLaunch.name}, '
      'maxMessageBytes: $maxMessageBytes)';
}

/// A connected counterpart node.
class WearerNode {
  /// Creates a node description (produced by the plugin).
  const WearerNode({
    required this.id,
    required this.displayName,
    required this.isNearby,
  });

  /// Internal: maps the wire DTO.
  @internal
  factory WearerNode.fromDto(WearerNodeDto dto) => WearerNode(
        id: dto.id,
        displayName: dto.displayName,
        isNearby: dto.isNearby,
      );

  /// Stable node id, usable as `nodeId` in targeted sends.
  final String id;

  /// Human-readable device name where the platform provides one.
  final String displayName;

  /// Android: directly connected (Bluetooth/Wi-Fi), not via cloud relay.
  /// iOS: mirrors reachability.
  final bool isNearby;

  @override
  String toString() => 'WearerNode($displayName, $id, nearby: $isNearby)';
}

/// The counterpart device's vitals (see `getCounterpartVitals`).
class WearerCounterpartVitals {
  /// Creates a vitals snapshot (produced by the plugin).
  const WearerCounterpartVitals({
    required this.batteryPercent,
    required this.isCharging,
    required this.model,
    required this.osVersion,
    this.identity,
  });

  /// Internal: maps the wire DTO.
  @internal
  factory WearerCounterpartVitals.fromDto(CounterpartVitalsDto dto) =>
      WearerCounterpartVitals(
        batteryPercent: dto.batteryPercent,
        isCharging: dto.isCharging,
        model: dto.model,
        osVersion: dto.osVersion,
        identity: dto.linkId == null
            ? null
            : WearerLinkIdentity(
                linkId: dto.linkId!,
                protocolVersion: dto.protocolVersion ?? 0,
                // A peer that answers with an id has declared one.
                isExplicit: true,
              ),
      );

  /// 0–100, or -1 when the counterpart could not read it.
  final int batteryPercent;
  /// Whether the counterpart is charging (or full, on iOS/watchOS).
  final bool isCharging;

  /// Device model, e.g. `Google Pixel Watch 2`, `Apple Watch`.
  final String model;

  /// OS name + version, e.g. `Android 14`, `watchOS 26.5`.
  final String osVersion;

  /// Who the counterpart says it is, or null when it answered without a
  /// label — a pre-2.2 peer. Reported only; nothing is rejected on it.
  final WearerLinkIdentity? identity;

  @override
  String toString() =>
      'WearerCounterpartVitals($model $osVersion, $batteryPercent%'
      '${isCharging ? ', charging' : ''}'
      '${identity == null ? '' : ', ${identity!.linkId}'})';
}

/// A companion-launch intent delivered to the launched app
/// (see `launchCompanion(route:, args:)`).
class WearerLaunchIntent {
  /// Creates a launch intent (produced by the plugin).
  const WearerLaunchIntent({this.route, this.args});

  /// The route the launcher asked this app to open, if any.
  final String? route;

  /// Structured arguments accompanying [route], if any.
  final Map<String, Object?>? args;

  @override
  String toString() => 'WearerLaunchIntent($route, $args)';
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

  /// The counterpart declares a different link id, or — in strict mode —
  /// has not proved its identity yet. See [WearerLink.getLinkIdentity].
  linkMismatch,

  /// Anything the native side didn't classify.
  unknown,
}

/// A typed failure from the plugin — [code] tells the caller whether it is
/// an OS policy ([WearerErrorCode.unsupported]), a transient link condition
/// ([WearerErrorCode.unreachable]), or a delivery failure.
class WearerLinkException implements Exception {
  /// Creates an exception with a typed [code] and human-readable [message].
  const WearerLinkException(this.code, this.message);

  /// Machine-checkable failure classification.
  final WearerErrorCode code;

  /// Human-readable detail for logs.
  final String message;

  @override
  String toString() => 'WearerLinkException(${code.name}: $message)';
}

// Pigeon contract for wearer_link.
//
// Single source of truth for the platform channel. Regenerate with:
//   dart run pigeon --input pigeons/wearer_link_api.dart
//
// CONTRACT: changing any signature here breaks the Kotlin/Swift hosts —
// regenerate all three outputs together and keep them committed.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/crdzbird/wearer_link/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.crdzbird.wearer_link'),
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'wearer_link',
  ),
)

/// Reachability of the paired wearable/phone counterpart.
enum ConnectionStateDto {
  /// Platform stack unavailable (no Play Services / WCSession unsupported).
  unsupported,

  /// No counterpart device is paired.
  unpaired,

  /// Paired, companion app not installed on the counterpart.
  appNotInstalled,

  /// Paired and installed, but not currently reachable (e.g. Bluetooth off).
  unreachable,

  /// Counterpart is reachable for interactive messages.
  reachable,
}

/// Snapshot of the companion relationship.
class CompanionStatusDto {
  CompanionStatusDto({
    required this.state,
    required this.nodes,
  });

  ConnectionStateDto state;

  /// Reachable node ids (Android may have several; iOS has at most one).
  List<String> nodes;
}

/// How an event crossed the boundary.
enum WearerEventKindDto {
  /// Interactive message.
  message,

  /// Synced or transferred data.
  data,
}

/// A message or data event crossing the device boundary.
class WearerEventDto {
  WearerEventDto({
    required this.id,
    required this.kind,
    required this.path,
    required this.payload,
    required this.sourceNodeId,
    required this.timestampMillis,
    required this.deliveredWhileDead,
  });

  /// Unique id for at-least-once dedup across background replays.
  String id;

  WearerEventKindDto kind;

  /// Application-defined routing path, e.g. '/workout/update'.
  String path;

  Uint8List payload;

  String sourceNodeId;

  int timestampMillis;

  /// True when the event was received while no Flutter engine was attached
  /// and is being replayed from the persistent queue.
  bool deliveredWhileDead;
}

/// Dart -> native.
@HostApi()
abstract class WearerLinkHostApi {
  /// Whether the wearable stack exists on this device at all.
  bool isSupported();

  @async
  CompanionStatusDto getCompanionStatus();

  /// Interactive message. Requires a reachable counterpart.
  /// On Android sends to every reachable node advertising the capability.
  @async
  void sendMessage(String path, Uint8List payload);

  /// Persistent state sync: DataClient item (Android) /
  /// updateApplicationContext (iOS). Latest value per path wins.
  @async
  void syncData(String path, Uint8List payload);

  /// Queued background transfer that survives unreachability:
  /// DataClient with urgent flag (Android) / transferUserInfo (iOS).
  @async
  void transferData(String path, Uint8List payload);

  /// Launch the companion app on the counterpart device.
  /// Android: RemoteActivityHelper (both directions, foreground).
  /// iOS phone->watch: HealthKit workout launch only; throws
  /// 'unsupported' PlatformException otherwise.
  @async
  void launchCompanion();

  /// Drain events persisted while the app was dead. Called by the Dart
  /// facade on startup; each drained event is also removed from the store.
  @async
  List<WearerEventDto> drainPendingEvents();
}

/// Native -> Dart.
@FlutterApi()
abstract class WearerLinkFlutterApi {
  void onMessage(WearerEventDto event);

  void onDataChanged(WearerEventDto event);

  void onConnectionStateChanged(CompanionStatusDto status);
}

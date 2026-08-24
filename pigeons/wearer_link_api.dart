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
    swiftOut: 'ios/wearer_link/Sources/wearer_link/Messages.g.swift',
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

  /// A file received via transferFile. `filePath` points at the local copy.
  file,
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

  /// For [WearerEventKindDto.file] events: absolute path of the received
  /// file (stored in the app's cache directory). Null for other kinds.
  String? filePath;
}

/// Dart -> native.
@HostApi()
abstract class WearerLinkHostApi {
  /// Whether the wearable stack exists on this device at all.
  bool isSupported();

  @async
  CompanionStatusDto getCompanionStatus();

  /// Interactive message. Requires a reachable counterpart.
  /// On Android sends to every reachable capable node, or only [nodeId]
  /// when given; iOS has a single counterpart and ignores [nodeId].
  @async
  void sendMessage(String path, Uint8List payload, String? nodeId);

  /// Request/response round trip: resolves with the counterpart's reply
  /// payload. Android: MessageClient.sendRequest RPC; iOS: sendMessage
  /// reply payload. The counterpart must have a request handler
  /// (setRequestHandler in Dart, onRequest in WearerLinkWatch); without one
  /// the call fails with 'noHandler'.
  @async
  Uint8List sendRequest(String path, Uint8List payload, String? nodeId);

  /// Persistent state sync: DataClient item (Android) /
  /// updateApplicationContext (iOS). Latest value per path wins.
  @async
  void syncData(String path, Uint8List payload);

  /// Latest value the COUNTERPART synced for [path] (mirror of what
  /// dataEvents delivered), or null if it never synced one.
  @async
  Uint8List? readSyncData(String path);

  /// Remove the value THIS device synced for [path] (the counterpart's own
  /// value is theirs to delete).
  @async
  void deleteSyncData(String path);

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

  /// Transfer the file at [filePath] to the counterpart (or only [nodeId]
  /// on Android). Android: ChannelClient (needs a reachable capable node).
  /// iOS: WCSession.transferFile (queued, survives unreachability).
  @async
  void transferFile(String path, String filePath, String? nodeId);

  /// Push fresh complication data to the watch face.
  /// iOS: transferCurrentComplicationUserInfo (budgeted by watchOS — ~50/day;
  /// over budget it silently degrades to a regular transfer).
  /// Android: throws 'unsupported' — use syncData + requestSurfaceUpdate
  /// inside the Wear OS app instead.
  @async
  void updateComplication(Uint8List payload);

  /// Ask the system to re-render this app's tile or complication after its
  /// backing state changed. Wear OS only (call it inside the watch app);
  /// [component] is the fully-qualified class name of the app's TileService
  /// or complication data-source service. Throws 'unsupported' on iOS.
  @async
  void requestSurfaceUpdate(String component);

  /// Store the callback handles powering the headless background isolate.
  /// [dispatcherHandle] is the plugin's entrypoint; [userHandle] the app's
  /// top-level handler. Persisted natively so events that arrive while the
  /// app is dead can start a Dart isolate and be handled immediately.
  void registerBackgroundHandler(int dispatcherHandle, int userHandle);

  /// Stop launching the background isolate for dead-app events (they fall
  /// back to the persistent queue only).
  void clearBackgroundHandler();
}

/// Native -> Dart.
@FlutterApi()
abstract class WearerLinkFlutterApi {
  void onMessage(WearerEventDto event);

  /// Request from the counterpart; the returned bytes are its reply.
  /// Completing with an error rejects the request on the sender's side.
  @async
  Uint8List onRequest(WearerEventDto event);

  void onDataChanged(WearerEventDto event);

  void onFileReceived(WearerEventDto event);

  void onConnectionStateChanged(CompanionStatusDto status);
}

/// Dart -> native, background isolate only.
@HostApi()
abstract class WearerLinkBackgroundHostApi {
  /// Handshake from the freshly-started background isolate. Returns the raw
  /// callback handle of the user's registered handler; after this returns,
  /// the native side starts delivering queued events.
  int backgroundReady();
}

/// Native -> Dart, background isolate only. The completion of
/// [onBackgroundEvent] is the delivery ack: the native side removes the
/// event from the persistent queue only after the Dart future completes.
@FlutterApi()
abstract class WearerLinkBackgroundFlutterApi {
  @async
  void onBackgroundEvent(WearerEventDto event);
}

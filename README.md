# wearer_link

Connect a Flutter phone app with its wearable companion (**Wear OS** /
**watchOS**): bidirectional messaging, synced data, **delivery while the app
is not running**, and mutual app launch where the platform allows it.

See [PLAN.md](PLAN.md) for the architecture and platform constraints, and
[ROADMAP.md](ROADMAP.md) for the feature roadmap to 1.0. Prototype status: Dart API + Android + iOS/watchOS implemented and
compiled on all three toolchains. Android verified end-to-end on real
hardware (Pixel 7 Pro + Pixel Watch 2): bidirectional messaging, sync,
transfer, and the killed-app path (events sent while the phone app was
force-stopped are replayed with `deliveredWhileDead: true`). iOS/watchOS
iOS/watchOS verified on a paired
simulator set (iPhone 17 Pro Max + Watch Series 11): reachability, messaging
and request/response RPC in both directions, applicationContext sync and
readSyncData. Simulators cannot faithfully test transferUserInfo/transferFile
delivery or the killed-app background wake — those still need a real pair.

## Quick start

```dart
final wearer = WearerLink.instance;

// Status
final status = await wearer.getCompanionStatus();     // paired? installed? reachable?
wearer.connectionState.listen((s) => print(s));       // live changes

// Receive (includes events that arrived while the app was killed — replayed
// on first listen with event.deliveredWhileDead == true)
wearer.messages.listen((e) => print('${e.path}: ${e.payload}'));
wearer.dataEvents.listen((e) => print('${e.path}: ${e.payload}'));

// Send
await wearer.sendMessage('/ping', bytes);   // interactive, needs reachable counterpart
await wearer.syncData('/state', bytes);     // latest-per-path, survives disconnects
await wearer.transferData('/log', bytes);   // queued FIFO, any size (big
                                            // payloads route through a file
                                            // — that route needs a
                                            // reachable node on Android)

// Day-one ergonomics
wearer.on('/workout/*', (e) => ...);            // path router (exact + wildcard)
wearer.registerCodec<Workout>(WearerJsonCodec(Workout.fromJson));
await wearer.sendTyped('/workout', workout);    // typed send/receive/RPC
await wearer.whenReachable(timeout: ...);       // wait for the link
final nodes = await wearer.getNodes();          // names + isNearby
final vitals = await wearer.getCounterpartStatus(); // battery/model/OS,
                                                // answered natively on the
                                                // other side
await wearer.launchCompanion(route: '/workout', args: {'id': 42});
wearer.launchIntents.listen((i) => ...);        // launched app navigates

// Request/response RPC (10s default timeout; counterpart must answer)
final reply = await wearer.sendRequest('/echo', bytes);
wearer.setRequestHandler((req) async => answerFor(req)); // answer their requests

// Read/delete synced state without waiting for an event
final latest = await wearer.readSyncData('/state'); // counterpart's latest, or null
await wearer.deleteSyncData('/state');              // removes what THIS device synced

// Multi-watch (Android): target one node; iOS ignores nodeId (single watch)
await wearer.sendMessage('/ping', bytes, nodeId: status.nodes.first);

// Bidirectional streaming (Android: ChannelClient; iOS: message framing)
final stream = await wearer.openStream('/live');
stream.data.listen(print);                      // bytes from the counterpart
await stream.send(bytes);                       // any size, chunked for you
await stream.close();
wearer.incomingStreams.listen((s) => ...);      // accept counterpart streams
// native watch: WearerLinkWatch.shared.openStream / onIncomingStream

// Capability introspection — check instead of catching 'unsupported'
final caps = await wearer.getCapabilities();
if (caps.stream) ...;                            // + companionLaunch, maxMessageBytes, …

// Pause/resume delivery (lossless: everything queues while disabled)
await wearer.setEventDeliveryEnabled(false);

// Synced key-value store: both sides read/write, newest write wins,
// values persist in the OS sync layer (Dart endpoints; the native watch
// lib gets an accessor in a later release)
await wearer.store.set('workout', bytes);
wearer.store.watch('workout').listen((v) => ...);
final current = await wearer.store.get('workout');

// Tracked file transfer with progress (both ends on wearer_link >= 0.6)
final transfer = await wearer.transferFileTracked('/photos/1', path);
transfer.progress.listen((p) => ...);           // 0.0 -> 1.0
await transfer.done;

// Diagnostics
final rtt = await wearer.pingLatency();          // built-in responder RTT
print(wearer.stats);                             // session counters
wearer.diagnostics.listen(print);                // silent failures, surfaced
WearerLink.verboseLogging = true;

// Files (received into the app cache dir; move if you need durability)
await wearer.transferFile('/photos/1', localFile.path);
wearer.fileEvents.listen((e) => print('got file: ${e.filePath}'));

// Handle events while the app is NOT running (headless Dart isolate).
// The handler must be a top-level function; it can use WearerLink APIs.
@pragma('vm:entry-point')
Future<void> onBackgroundEvent(WearerEvent event) async {
  await WearerLink.instance.sendJson('/ack', {'got': event.path});
}
// during app startup:
await wearer.registerBackgroundHandler(onBackgroundEvent);

// Watch-face surfaces
await wearer.updateComplication(bytes);          // iOS: complication push (budgeted)
await wearer.requestSurfaceUpdate('com.my.Tile'); // Wear OS: tile/complication refresh

// Launch the companion app on the other device
await wearer.launchCompanion();
```

Delivery to Dart is **at-least-once**; the facade already drops same-`id`
duplicates within a session, so cross-launch redelivery (e.g. a background
handler that died mid-work) is the only case left to deduplicate with
`event.id`.

On the native watch the same RPC surface is
`WearerLinkWatch.shared.sendRequest(path:payload:completion:)` /
`onRequest`, plus `readSyncData(path:)` / `deleteSyncData(path:)`.

## What each platform allows

| Capability | Android/Wear OS | iOS/watchOS |
|---|---|---|
| Watch auto-starts phone app | ✅ foregrounds it | ⚠️ background wake only |
| Phone auto-starts watch app | ✅ foregrounds it | ⚠️ workout apps only (HealthKit) |
| Delivery while phone app killed | ✅ | ✅ |
| Flutter on the watch | ✅ same plugin | ❌ native Swift companion lib |

## Android / Wear OS setup

Both apps (phone + watch) are ordinary Flutter apps using this plugin — the
Data Layer API is symmetric. Requirements:

1. **Same signing key and same `applicationId`** for phone and Wear apps
   (Play services pairs them by package + signature).
2. The plugin already ships the `wearer_link` capability (`wear.xml`) and the
   background `WearableListenerService` — no manifest work for receiving.
3. For `launchCompanion()`, add to **each** app's `AndroidManifest.xml`:

```xml
<!-- inside <application>: the URI this app sends to the other device -->
<meta-data
    android:name="com.crdzbird.wearer_link.launchUri"
    android:value="wearerlink://open" />

<!-- inside the target <activity>: accept that URI -->
<intent-filter>
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="wearerlink" android:host="open"/>
</intent-filter>
```

## iOS / watchOS setup

Flutter does not run on watchOS: the watch app is a native SwiftUI target
that uses the bundled `WearerLinkWatch` Swift package.

1. In Xcode: **File → New → Target → Watch App** for your iOS app.
   (`example/ios` contains a complete reference target, `RunnerWatch`,
   wired to the local package and embedded into the Runner app.)
2. **File → Add Package Dependencies → Add Local…** and select
   `<pub-cache-or-repo>/wearer_link/watchos/WearerLinkWatch`; add the library
   to the watch target.
3. In the watch app:

```swift
import WearerLinkWatch

@main
struct MyWatchApp: App {
  init() {
    WearerLinkWatch.shared.activate()
    WearerLinkWatch.shared.onEvent = { event in
      print("from phone: \(event.path)")
    }
  }
  var body: some Scene { WindowGroup { ContentView() } }
}

// Sending:
WearerLinkWatch.shared.sendMessage(path: "/ping", payload: data)  // wakes killed phone app
try WearerLinkWatch.shared.syncData(path: "/state", payload: data)
WearerLinkWatch.shared.transferData(path: "/log", payload: data)
WearerLinkWatch.shared.wakePhoneApp()
```

4. `launchCompanion()` (phone → watch) works only for workout-style apps:
   add the **HealthKit capability** + `NSHealthShareUsageDescription` /
   `NSHealthUpdateUsageDescription` to the iOS app, and start a workout
   session in the watch app when it receives the launch. Without HealthKit
   it throws `WearerErrorCode.unsupported` — an OS policy, not a plugin gap.

## Background behavior (both platforms)

Events that arrive while the app is killed are received natively (Android:
manifest-declared `WearableListenerService`; iOS: WatchConnectivity
background launch), persisted to a bounded queue (200 events), and replayed
into `messages` / `dataEvents` / `fileEvents` on the next launch, flagged
with `deliveredWhileDead: true`.

With `registerBackgroundHandler` the same events are additionally handled
**immediately** in a headless Dart isolate: the native side starts a
background Flutter engine, runs your top-level handler, and removes the
event from the queue once the handler completes. If the handler throws (or
the process dies first) the event stays queued for the next launch —
delivery is at-least-once either way, dedupable via `event.id`. The handler
runs in its own isolate (no app state); it can call `WearerLink` APIs to
respond. Keep it short — the OS may reclaim the process quickly.

## File transfers

`transferFile(path, filePath)` streams a file to the counterpart (Android:
`ChannelClient`, needs a reachable node; iOS: `WCSession.transferFile`,
queued). Received files are written to the app's cache directory and
surfaced on `fileEvents` (`event.filePath`); move them somewhere durable if
needed. On the native watch, use
`WearerLinkWatch.shared.transferFile(path:fileURL:)` and `Event.fileURL`.

## Watch-face surfaces

- **iOS → watch complication**: `updateComplication(bytes)` uses
  `transferCurrentComplicationUserInfo` (watchOS budgets ~50/day; over
  budget it degrades to a regular queued transfer). The watch app receives
  it as an event on the reserved path `/complication`.
- **Wear OS tile/complication**: sync the state with `syncData`, then call
  `requestSurfaceUpdate('<fully.qualified.ServiceClass>')` **inside the
  watch app** to make the system re-render its tile (`TileService`) or
  complication data source. Requires the matching androidx dependency in
  the watch app (`androidx.wear.tiles:tiles` or
  `androidx.wear.watchface:watchface-complications-data-source`); the
  plugin only compiles against them.
- Each call throws `WearerErrorCode.unsupported` on the platform that
  forbids it — OS policy, not a plugin gap.

## Encryption

Bring your own cipher; the plugin guarantees which bytes pass through it:

```dart
wearer.setPayloadCipher(WearerCipher(
  encrypt: (path, bytes) async => myAead.seal(bytes),
  decrypt: (path, bytes) async => myAead.open(bytes),
));
```

Covered: messages, requests (both legs), data transfers (blob route
included), store records, and every stream chunk — tracked file transfers
ride streams, so their bodies are covered. Not covered (documented, not
silent): plain `transferFile` bodies (read natively), the built-in
`/__wlstatus` probe, and launch route/args. Mismatched endpoints fail
loudly: an encrypted payload reaching a cipher-less side (or plaintext
reaching a ciphered side) is dropped with a `diagnostics` entry, and
requests fail with a typed error — ciphertext is never emitted as data.

## Streaming audio (recipe)

`WearerStream` sustains ordered audio-sized chunking (the suite pushes
1.6MB as 100×16KB frames and asserts order + integrity). A watch voice
memo:

```dart
// Watch side (Wear OS Flutter — for watchOS use WearerLinkWatch.openStream)
final stream = await wearer.openStream('/voice');
micChunks.listen(stream.send);                 // 16–32KB PCM frames
// Phone side
wearer.incomingStreams.listen((s) async {
  if (s.path != '/voice') return;
  final sink = File(outPath).openWrite();
  await s.data.forEach(sink.add);
  await sink.close();                          // arrives in order
});
```

Keep frames at or under 32KB; on iOS each frame rides an interactive
message, so the link must stay reachable for the stream's lifetime.

## Testing your app

`package:wearer_link/testing.dart` ships an in-memory two-endpoint harness
so both sides of your protocol run in plain Dart unit tests — no emulators:

```dart
import 'package:wearer_link/testing.dart';

final (phone, watch) = WearerLinkFake.pair();   // linked, reachable
watch.messages.listen(...);
await phone.sendMessage('/ping', payload);

phone.setReachable(false);        // range loss: sends fail, transfers queue
watch.simulateKill();             // killed app: events queue, background
final next = watch.relaunch();    //   handler runs; relaunch replays with
                                  //   deliveredWhileDead: true
```

Everything works on the fake: messaging, RPC, sync read/delete, files,
streams (incl. teardown on link loss), the delivery toggle, capability
matrices per simulated platform, and the pending-queue lifecycle. Injected
events run through the plugin's production dispatch code — the plugin's own
test suite runs on the same harness.

## Development

```sh
dart run pigeon --input pigeons/wearer_link_api.dart   # regenerate channel bindings
flutter test                                           # Dart unit tests
cd example && flutter run                              # demo app
```

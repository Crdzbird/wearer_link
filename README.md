# wearer_link

Connect a Flutter phone app with its wearable companion (**Wear OS** /
**watchOS**): bidirectional messaging, synced data, **delivery while the app
is not running**, and mutual app launch where the platform allows it.

See [PLAN.md](PLAN.md) for the architecture, platform constraints, and
roadmap. Prototype status: Dart API + Android + iOS/watchOS implemented and
compiled on all three toolchains. Android verified end-to-end on real
hardware (Pixel 7 Pro + Pixel Watch 2): bidirectional messaging, sync,
transfer, and the killed-app path (events sent while the phone app was
force-stopped are replayed with `deliveredWhileDead: true`). iOS/watchOS
device-pair testing pending.

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
await wearer.transferData('/log', bytes);   // queued FIFO, every item delivered

// Request/response RPC (10s default timeout; counterpart must answer)
final reply = await wearer.sendRequest('/echo', bytes);
wearer.setRequestHandler((req) async => answerFor(req)); // answer their requests

// Read/delete synced state without waiting for an event
final latest = await wearer.readSyncData('/state'); // counterpart's latest, or null
await wearer.deleteSyncData('/state');              // removes what THIS device synced

// Multi-watch (Android): target one node; iOS ignores nodeId (single watch)
await wearer.sendMessage('/ping', bytes, nodeId: status.nodes.first);

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

## Development

```sh
dart run pigeon --input pigeons/wearer_link_api.dart   # regenerate channel bindings
flutter test                                           # Dart unit tests
cd example && flutter run                              # demo app
```

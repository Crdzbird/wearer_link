# wearer_link

[![CI](https://github.com/Crdzbird/wearer_link/actions/workflows/ci.yaml/badge.svg)](https://github.com/Crdzbird/wearer_link/actions)
[![version](https://img.shields.io/github/v/tag/Crdzbird/wearer_link?label=version)](https://github.com/Crdzbird/wearer_link/tags)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platforms](https://img.shields.io/badge/platforms-Android%20%7C%20Wear%20OS%20%7C%20iOS%20%7C%20watchOS-informational)

The missing link between a Flutter phone app and its wearable companion.
One typed API for **Wear OS** and **watchOS**: messaging, request/response
RPC, a synced key-value store, bidirectional byte streams, file transfers
with progress — and **guaranteed delivery even while your app is not
running**.

```dart
final wearer = WearerLink.instance;

await wearer.sendMessage('/ping', payload);          // it's that simple
wearer.messages.listen((event) => handle(event));    // including events that
                                                     // arrived while the app
                                                     // was killed
```

> **Status:** distributed via git (not yet on pub.dev). Android/Wear OS is
> verified end-to-end on physical devices; iOS/watchOS is verified on paired
> simulators, with the simulator-untestable paths tracked in
> [ROADMAP.md](ROADMAP.md). Add it with a git dependency:
>
> ```yaml
> dependencies:
>   wearer_link:
>     git:
>       url: https://github.com/Crdzbird/wearer_link
>       ref: v1.3.0
> ```

---

## Contents

- [Why wearer_link](#why-wearer_link)
- [Platform support](#platform-support)
- [Getting started](#getting-started)
  - [Android / Wear OS](#android--wear-os)
  - [iOS / watchOS](#ios--watchos)
- [Core concepts](#core-concepts)
- [Usage](#usage)
  - [Connection & status](#connection--status)
  - [Messages & routing](#messages--routing)
  - [Request/response RPC](#requestresponse-rpc)
  - [Typed payloads](#typed-payloads)
  - [Synced data](#synced-data)
  - [Synced key-value store](#synced-key-value-store)
  - [Bidirectional streams](#bidirectional-streams)
  - [File transfers](#file-transfers)
  - [Delivery while the app is killed](#delivery-while-the-app-is-killed)
  - [Launching the companion app](#launching-the-companion-app)
  - [Watch-face surfaces](#watch-face-surfaces)
  - [Capabilities & delivery toggle](#capabilities--delivery-toggle)
  - [Encryption](#encryption)
  - [Diagnostics](#diagnostics)
- [The native watchOS API](#the-native-watchos-api)
- [Testing your app](#testing-your-app)
- [Recipes](#recipes)
- [The example app](#the-example-app)
- [Troubleshooting & FAQ](#troubleshooting--faq)
- [Versioning & wire compatibility](#versioning--wire-compatibility)
- [Contributing](#contributing)

---

## Why wearer_link

Talking to a watch means juggling two very different native stacks — Google
Play services' Data Layer on Android, WatchConnectivity on iOS — each with
its own delivery semantics, background rules, and sharp edges. `wearer_link`
wraps both behind one honest Dart API:

- 📬 **Messaging** — interactive messages, latest-state sync, queued
  transfers of any size
- 🔁 **Request/response RPC** — real reply payloads with timeouts
- 🗄️ **Synced KV store** — last-writer-wins state both sides read and write,
  persisted by the OS itself
- 🔌 **Bidirectional byte streams** — socket-like on Android, emulated on
  iOS, same API on both
- 📁 **File transfers** — fire-and-forget or tracked with a progress stream
- 💀 **Killed-app delivery** — events queue natively and replay on launch,
  or run immediately in a headless Dart isolate
- 🚀 **Mutual app launch** — with a route + arguments for deep navigation
- 🔋 **Counterpart vitals** — battery/model/OS answered natively, no app
  code needed on the other side
- 🔐 **Bring-your-own encryption** — enforced across every Dart-visible byte
- 🧪 **First-class testing** — an in-memory two-device harness; no emulators
  required

And one honest rule throughout: **where an OS forbids something, the API
reports it with a typed error — it never pretends.**

## Platform support

| Capability | Android / Wear OS | iOS / watchOS |
|---|---|---|
| Flutter on the watch | ✅ same plugin, both apps | ❌ native Swift companion lib (bundled) |
| Delivery while the phone app is killed | ✅ | ✅ |
| Headless background isolate | ✅ | ✅ (iPhone side) |
| Watch auto-starts the phone app | ✅ foregrounds it | ⚠️ background wake only |
| Phone auto-starts the watch app | ✅ foregrounds it, with route/args | ⚠️ workout (HealthKit) apps only |
| Bidirectional streams | ✅ native channels | ✅ message-framed |
| Complication push | — (use tiles) | ✅ budgeted by watchOS |
| Tile / complication refresh | ✅ | — (reload from the watch app) |

Minimum versions: Android `minSdk 24` (26 if your Wear app ships a tile),
iOS 15, watchOS 7.

## Getting started

### Android / Wear OS

The Data Layer is symmetric: your **phone app and your Wear OS app are both
ordinary Flutter apps using this plugin** — same code, both sides.

1. Give both apps the **same `applicationId` and signing key** (Play
   services pairs them by package + signature).
2. Receiving needs **zero setup** — the plugin ships its capability file and
   the background `WearableListenerService`.
3. For `launchCompanion()`, declare a launch URI in **each** app's
   `AndroidManifest.xml`:

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

### iOS / watchOS

Flutter does not run on watchOS, so the watch side is a native SwiftUI
target using the bundled **`WearerLinkWatch`** Swift package — same wire
protocol, mirrored API.

1. In Xcode: **File → New → Target → Watch App**. (The example app ships a
   complete reference target, `example/ios/RunnerWatch`.)
2. **File → Add Package Dependencies → Add Local…** →
   `<wearer_link>/watchos/WearerLinkWatch` → add it to the watch target.
3. In the watch app:

```swift
import WearerLinkWatch

@main
struct MyWatchApp: App {
  init() {
    WearerLinkWatch.shared.activate()   // as early as possible
    WearerLinkWatch.shared.onEvent = { event in
      print("from phone: \(event.path)")
    }
  }
  var body: some Scene { WindowGroup { ContentView() } }
}
```

## Core concepts

- **Paths route everything.** Every payload travels on an
  application-defined path (`/workout/update`). Paths starting with `/__wl`
  are reserved for the plugin.
- **Delivery is at-least-once.** The plugin dedups same-`id` events within a
  session; across launches, deduplicate with `event.id` if your payloads
  are not idempotent.
- **Three send semantics.** `sendMessage` is interactive (needs a reachable
  counterpart, fails fast), `syncData` is latest-state-wins (survives
  disconnects), `transferData` is a queued FIFO where every item arrives.
- **Killed apps still receive.** Events land natively, persist in a bounded
  queue (200 entries), and replay on the next launch flagged
  `deliveredWhileDead: true` — or run immediately in a background isolate.
- **Typed errors, honest API.** `WearerLinkException.code` tells you whether
  a failure is OS policy (`unsupported`), a transient link condition
  (`unreachable`), a missing responder (`noHandler`), or a send failure.

## Usage

### Connection & status

```dart
final status = await wearer.getCompanionStatus(); // paired? installed? reachable?
wearer.connectionState.listen((s) => update(s));  // live changes

await wearer.whenReachable(timeout: Duration(seconds: 30));

final nodes = await wearer.getNodes();            // names + isNearby
final vitals = await wearer.getCounterpartVitals(); // battery/model/OS —
                                                  // answered natively on the
                                                  // other side, no app code
```

### Messages & routing

```dart
await wearer.sendMessage('/ping', payload);            // interactive
await wearer.sendMessage('/cmd', payload,
    queueIfUnreachable: true);                         // degrade to a queued
                                                       // transfer instead of
                                                       // throwing

wearer.messages.listen(handleAnything);                // the global stream
wearer.on('/workout/update', handleUpdate);            // exact route
wearer.on('/workout/*', handleAny);                    // trailing wildcard —
                                                       // most specific wins

// Multi-watch (Android): target one node. iOS has a single counterpart.
await wearer.sendMessage('/ping', payload, nodeId: nodes.first.id);
```

### Request/response RPC

```dart
// Caller — resolves with the counterpart's reply (default timeout 10s):
final reply = await wearer.sendRequest('/echo', payload);

// Responder — routed handlers win, the global handler is the fallback:
wearer.onRequestPath('/echo', (req) async => transform(req.payload));
wearer.setRequestHandler((req) async => fallbackFor(req));
```

A counterpart without a handler rejects with `noHandler` — requests are
never silently queued, because the caller is waiting.

### Typed payloads

```dart
wearer.registerCodec<Workout>(WearerJsonCodec(Workout.fromJson));

await wearer.sendTyped('/workout', workout);
wearer.onTyped<Workout>('/workout', (workout, event) => render(workout));
final answer = await wearer.sendRequestTyped<Query, Answer>('/q', query);
```

### Synced data

```dart
await wearer.syncData('/state', bytes);       // newest value per path wins
wearer.dataEvents.listen(applyState);         // change notifications

final latest = await wearer.readSyncData('/state'); // counterpart's current
                                                    // value — even one synced
                                                    // before this launch
await wearer.deleteSyncData('/state');        // remove what THIS device synced

await wearer.transferData('/log', bytes);     // queued FIFO, any size — big
                                              // payloads route through a file
                                              // automatically
```

### Synced key-value store

State both sides read and write, without thinking in paths and payloads:

```dart
await wearer.store.set('workout', bytes);
wearer.store.watch('workout').listen((value) => render(value)); // both sides
final current = await wearer.store.get('workout');  // instant, cached
await wearer.store.delete('workout');               // tombstoned on both ends
final keys = await wearer.store.keys();
```

Last-writer-wins per key (sender timestamp + stable tiebreak), values
persisted by the OS sync layer itself — they survive restarts and arrive
after offline gaps. Values are capped at 48KB: the store is for state, not
payload transport. The native watch has the same store — see
[the native watchOS API](#the-native-watchos-api).

### Bidirectional streams

```dart
// Open toward the counterpart (it must be reachable and listening):
final stream = await wearer.openStream('/live');
stream.data.listen(handleBytes);        // bytes from the other side, in order
await stream.send(bytes);               // any size, chunked for you
await stream.close();

// Accept streams the counterpart opens:
wearer.incomingStreams.listen((s) { ... });
```

`WearerStream` is a **byte stream**: bytes arrive complete and in order,
but `send` boundaries may merge or split (Android's native channels do
this). If your protocol needs messages, add your own framing — length
prefixes, like the plugin's own tracked transfers. Both directions flow on
one stream: the example app's media streaming sends chunks one way and
progress acks the other way simultaneously.

### File transfers

```dart
// Fire-and-forget — queued by the OS, arrives even if the other app is killed:
await wearer.transferFile('/photos/1', file.path);

// Tracked — progress stream, needs a live link and wearer_link ≥ 0.6 on both ends:
final transfer = await wearer.transferFileTracked('/photos/1', file.path);
transfer.progress.listen((p) => bar.value = p);   // 0.0 → 1.0
await transfer.done;

// Receiving (both kinds):
wearer.fileEvents.listen((e) => use(File(e.filePath!)));
```

Received files land in the app's cache directory — move them somewhere
durable if you need them beyond the next cache purge.

### Delivery while the app is killed

Nothing to configure: events that arrive while your app is dead are
received natively, queued, and **replayed on the next launch** flagged
`deliveredWhileDead: true`.

To handle them *immediately* instead, register a background handler — a
**top-level function** that runs in a headless Dart isolate:

```dart
@pragma('vm:entry-point')
Future<void> onBackgroundEvent(WearerEvent event) async {
  // Runs with no UI, in its own isolate. WearerLink APIs work here:
  await WearerLink.instance.sendJson('/ack', {'got': event.path});
}

await wearer.registerBackgroundHandler(onBackgroundEvent);
```

The handler's completion acks the event out of the queue; if it throws or
the process dies first, the event replays on the next launch instead —
delivery stays at-least-once either way. Keep handlers short: the OS may
reclaim the process quickly.

### Launching the companion app

```dart
await wearer.launchCompanion(route: '/workout', args: {'id': 42});

// In the launched app:
wearer.launchIntents.listen((intent) => router.go(intent.route!));
```

Android foregrounds the counterpart app (both directions). iOS can only
launch the watch app through a HealthKit workout session — add the
HealthKit capability + usage descriptions, or the call throws
`unsupported`. A watch can always *background-wake* the iPhone app by just
sending to it.

### Watch-face surfaces

```dart
// iOS → watch complication (watchOS budgets ~50 pushes/day):
await wearer.updateComplication(bytes);

// Wear OS: re-render this app's tile or complication after a store/sync
// update — call it inside the watch app:
await wearer.requestSurfaceUpdate('com.my.app.MyTileService');
```

`requestSurfaceUpdate` needs the matching androidx dependency in the watch
app (`androidx.wear.tiles:tiles` or
`androidx.wear.watchface:watchface-complications-data-source`) — the plugin
only compiles against them. See the tile recipe below for a complete
store-fed tile.

### Capabilities & delivery toggle

```dart
final caps = await wearer.getCapabilities();      // check instead of
if (caps.stream) { ... }                          // catching 'unsupported':
caps.companionLaunch;                             // foreground/workoutOnly/none
caps.maxMessageBytes;                             // single-message budget

await wearer.setEventDeliveryEnabled(false);      // lossless pause: inbound
                                                  // events queue exactly like
                                                  // the killed-app path
await wearer.setEventDeliveryEnabled(true);       // backlog replays
```

### Encryption

Bring your own cipher; the plugin guarantees which bytes pass through it:

```dart
wearer.setPayloadCipher(WearerCipher(
  encrypt: (path, bytes) async => myAead.seal(bytes),
  decrypt: (path, bytes) async => myAead.open(bytes),
));
```

**Covered:** messages, both request legs, data transfers (blob route
included), store records, and every stream chunk (tracked file bodies ride
streams, so they're covered). **Not covered — documented, not silent:**
plain `transferFile` bodies (read natively), the built-in vitals probe, and
launch route/args. Mismatched endpoints fail loudly: encrypted payloads
reaching a cipher-less side (or plaintext reaching a ciphered side) are
dropped with a `diagnostics` entry, and requests fail typed — **ciphertext
is never emitted as data**.

### Diagnostics

```dart
final rtt = await wearer.pingLatency();       // RTT via the built-in responder
print(wearer.stats);                          // session counters
print(await wearer.getPersistentStats());     // native, survives restarts:
                                              // received / queued-while-dead /
                                              // drained / background-handled
wearer.diagnostics.listen(log);               // silent failures, surfaced
WearerLink.verboseLogging = true;             // tagged debugPrint of all traffic
```

## The native watchOS API

`WearerLinkWatch` mirrors the Dart surface on the watch:

```swift
let link = WearerLinkWatch.shared
link.activate()

// Events, requests, streams:
link.onEvent = { event in ... }                         // messages/data/files
link.onRequest = { event, reply in reply(answer) }      // answer phone RPCs
link.sendMessage(path: "/ping", payload: data)          // wakes a killed phone app
link.sendRequest(path: "/q", payload: data) { result in ... }
link.openStream(path: "/live") { result in ... }
link.onIncomingStream = { stream in ... }

// State:
try link.syncData(path: "/state", payload: data)
link.readSyncData(path: "/state")
try link.store.set("workout", data)                     // the same synced store
link.store.onChange = { key, value in ... }

// Files, launch, vitals:
link.transferFile(path: "/log", fileURL: url)
link.onLaunchIntent = { route, args in ... }
link.requestPhoneVitals { result in ... }
link.wakePhoneApp()
```

## Testing your app

`package:wearer_link/testing.dart` ships an in-memory two-endpoint harness:
both sides of your protocol run in plain Dart unit tests — **no emulators,
no hardware**.

```dart
import 'package:wearer_link/testing.dart';

final (phone, watch) = WearerLinkFake.pair();    // linked, reachable

watch.messages.listen(expectAsync1((e) => expect(e.path, '/ping')));
await phone.sendMessage('/ping', payload);

phone.setReachable(false);         // range loss: sends fail, transfers queue
watch.simulateKill();              // killed app: events queue, the background
final next = watch.relaunch();     //   handler runs; relaunch replays with
                                   //   deliveredWhileDead: true
```

Everything works on the fake — messaging, RPC, the store, files, streams
(including teardown on link loss), the delivery toggle, per-platform
capability matrices, persistent counters, and the whole pending-queue
lifecycle. Injected events run through the plugin's **production dispatch
code**; the plugin's own suite runs on the same harness.

## Recipes

### Sharing bytes — which primitive?

| Need | Use |
|---|---|
| Must arrive even if the other app is killed / out of range | `transferFile` / `transferData` |
| Progress bar, live link available | `transferFileTracked` |
| Shared state both sides read & write | `wearer.store` |
| Live feed, lowest latency, backchannel | `openStream` |

### Media over the link

The example app is the reference: **Pick media** opens a file picker for
any image/video/audio/file, then asks — *send*, *play here*, *stream live
to the watch*, or *both*. Live streaming pushes framed chunks one way and
progress acks the other way **on the same stream**, so the sender renders a
"watch confirmed N%" bar; the receiver plays the media on arrival
(hardware-verified: video looping on a Pixel Watch 2, mic recordings
playing through the watch speaker).

### Live viewfinder (MJPEG-style)

```dart
// Sender: camera frames → JPEG → stream; DROP frames when behind
final stream = await wearer.openStream('/viewfinder');
controller.startImageStream((frame) async {
  if (busy) return;
  busy = true;
  await stream.send(await frameToJpeg(frame, quality: 60)); // keep ≤ 32KB
  busy = false;
});

// Receiver: newest frame wins
wearer.incomingStreams.listen((s) {
  if (s.path != '/viewfinder') return;
  s.data.listen((jpeg) => setState(() => lastFrame = jpeg));
});
```

~15–20KB JPEG at 10–15fps is comfortable on a direct Bluetooth/Wi-Fi hop.
For **recorded** video, send the file and play on arrival — don't reinvent
a codec pipeline over messages.

### Voice memo from the watch

```dart
// Watch (Wear OS Flutter; watchOS: WearerLinkWatch.openStream)
final stream = await wearer.openStream('/voice');
micChunks.listen(stream.send);                  // 16–32KB frames

// Phone
wearer.incomingStreams.listen((s) async {
  if (s.path != '/voice') return;
  final sink = File(outPath).openWrite();
  await s.data.forEach(sink.add);               // arrives in order
  await sink.close();
});
```

### A Wear OS tile fed by the store

`example/android/.../DemoTileService.kt` is a complete reference: a
`TileService` reads the store's newest record straight from its Data Layer
item and re-renders when the app calls:

```dart
await wearer.store.set('demo', bytes);
await wearer.requestSurfaceUpdate('com.my.app.DemoTileService');
```

Ship `androidx.wear.tiles:tiles` in the watch app and set `minSdk 26`.
Hardware-verified: Dart call → re-rendered tile in about a second.

## The example app

`example/` is a full tour — run it on a phone + watch pair (both Flutter on
Android; on iOS pair the phone app with the bundled `RunnerWatch` target):

- media picking, sending, and **live streaming with remote-progress acks**
- mic recording that plays on the other device
- RPC, store, streams, tracked transfers with progress bars
- the store-fed Wear OS tile, launch intents, vitals & RTT chips
- a watch-adaptive layout for round screens

```sh
cd example && flutter run
```

## Troubleshooting & FAQ

**Nothing arrives on Android.**
Both apps must share the same `applicationId` *and* signing key, and be
installed on devices paired via the Wear OS companion app. Check
`getCompanionStatus()` — `appNotInstalled` means the capability of the
counterpart app isn't visible yet (install/update it).

**`sendRequest` times out but messages work.**
Update wearer_link on both ends (< 0.8.1 lacked the RPC manifest action) —
and remember the responder needs a live handler; requests are never queued.

**My stream chunks arrive glued together.**
That's the byte-stream contract: order is guaranteed, write boundaries are
not (Android merges them). Frame your messages (length prefixes).

**Tracked transfer fails with `sendFailed` immediately.**
The counterpart app isn't running or is on < 0.6 — tracked transfers ride
live streams. Use `transferFile` for killed-app delivery.

**`requestSurfaceUpdate` throws `unsupported`.**
The watch app must itself depend on `androidx.wear.tiles:tiles` (or the
complications artifact) — the plugin only compiles against them. Tiles also
require `minSdk 26`.

**iOS simulator: transfers never arrive.**
Known simulator limitation: `transferUserInfo`/`transferFile` (and the
killed-app wake) don't work between paired simulators. Live messaging, RPC,
streams and `applicationContext` sync do.

**Do I need to deduplicate events?**
Within a session, no — the plugin drops duplicate ids. Across launches,
dedupe with `event.id` if redelivery would hurt (delivery is
at-least-once by design).

**Battery cost?**
The plugin adds no polling; everything is OS-push-driven. `sendMessage`
and streams keep the radio active while used; `syncData`/`transferData`
let the OS batch.

## Versioning & wire compatibility

- **Semver** — breaking Dart API changes only in majors.
- **Wire compatibility is additive** — envelope keys and reserved `/__wl*`
  paths are never repurposed; newer features degrade cleanly against older
  counterparts (typed error or queued no-op — never a hang, never garbage).
- **Reserved namespace** — application paths must not start with `/__wl`.

## Contributing

```sh
dart run pigeon --input pigeons/wearer_link_api.dart  # regenerate bindings
flutter test                                          # 54 Dart tests
cd example/android && ./gradlew :wearer_link:testDebugUnitTest
cd example && flutter run                             # the demo app
```

CI compiles all three native stacks (Kotlin, iOS, watchOS) and runs both
test suites on every push. Architecture notes live in [PLAN.md](PLAN.md);
the road past 1.0 in [ROADMAP.md](ROADMAP.md).

Licensed under [MIT](LICENSE).

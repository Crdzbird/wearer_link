# wearer_link — Working Prototype Plan

> M0–M5 below have shipped. The post-0.4.0 feature roadmap (M6–M8, road
> to 1.0) lives in [ROADMAP.md](ROADMAP.md).

A Flutter plugin that connects a phone app (Android / iOS) with its wearable
companion (Wear OS / watchOS): bidirectional messaging, shared/synced data,
delivery while the phone app is **not running**, and mutual app launch where
each platform allows it.

---

## 1. Platform realities (what the OSes actually permit)

The plugin is a thin, honest facade over two very different native stacks.
Every API we expose maps to a real platform primitive; where a platform
forbids something, the Dart API reports it instead of pretending.

### Android ⇄ Wear OS — Google Play Services **Wearable Data Layer**

| Need | Primitive |
|---|---|
| Interactive message (RPC-ish) | `MessageClient.sendMessage(nodeId, path, bytes)` |
| Persistent synced data (survives disconnects, delivered eventually) | `DataClient` + `PutDataMapRequest` |
| Discover the counterpart | `NodeClient` + `CapabilityClient` (capability advertised in `res/values/wear.xml`) |
| **Delivery while app is dead** | `WearableListenerService` declared in the manifest — the system **starts the app's process** to deliver messages/data items |
| Launch the other device's app | `androidx.wear.remote.interactions` → `RemoteActivityHelper.startRemoteActivity(intent)` — works **both directions** (phone→watch and watch→phone) |

Key property: the Data Layer API is **symmetric** — the identical plugin code
runs inside a phone Flutter app *and* inside a Wear OS Flutter app. One plugin,
both sides.

### iOS ⇄ watchOS — **WatchConnectivity** (`WCSession`)

| Need | Primitive |
|---|---|
| Interactive message (counterpart reachable) | `session.sendMessage(_:replyHandler:)` |
| Latest-state sync (only newest matters) | `session.updateApplicationContext(_:)` |
| Queued background transfer (FIFO, every item delivered) | `session.transferUserInfo(_:)` |
| **Delivery while app is dead** | watch → phone `sendMessage`/`transferUserInfo` **wakes the iPhone app in the background**; delegate callbacks fire during that background launch |
| Launch the watch app from the phone | Only via `HKHealthStore.startWatchApp(with: HKWorkoutConfiguration)` — **workout apps only** |
| Launch the phone app from the watch | `sendMessage` from the watch background-launches the iPhone app (background execution, not foregrounded UI — iOS never allows a watch to bring another app on screen) |

Key constraint: **Flutter does not run on watchOS.** The watch side ships as a
small native Swift library (`WearerLinkWatch`) + a documented wire protocol,
which the developer drops into their SwiftUI watch app.

### Honest limitation table (encoded in the API as typed errors, not surprises)

| Capability | Android/Wear OS | iOS/watchOS |
|---|---|---|
| Watch auto-starts phone app | ✅ `RemoteActivityHelper` (foreground) | ⚠️ background wake only (`sendMessage`) |
| Phone auto-starts watch app | ✅ `RemoteActivityHelper` | ⚠️ workout apps only (`startWatchApp`) |
| Data delivered while phone app killed | ✅ `WearableListenerService` starts process | ✅ background launch via WatchConnectivity |
| Flutter on the watch itself | ✅ (Wear OS Flutter app, same plugin) | ❌ native Swift companion lib |

## 2. Architecture

```
wearer_link/
  pigeons/wearer_link_api.dart      ← single source of truth for the channel contract
  lib/
    wearer_link.dart                ← public facade (singleton, streams, futures)
    src/messages.g.dart             ← Pigeon-generated Dart
    src/model/                      ← WearerMessage, WearerDataEvent, ConnectionState, errors
  android/src/main/kotlin/…
    WearerLinkPlugin.kt             ← FlutterPlugin + Pigeon host API impl
    DataLayerBridge.kt              ← MessageClient/DataClient/Capability listeners
    WearerLinkListenerService.kt    ← manifest-declared WearableListenerService (background)
    PendingEventStore.kt            ← persisted queue for events that arrive while no engine is attached
  ios/wearer_link/Sources/wearer_link/
    WearerLinkPlugin.swift          ← FlutterPlugin + Pigeon host API impl
    WatchSessionBridge.swift        ← WCSessionDelegate (activated at app launch → background wake works)
    PendingEventStore.swift         ← persisted queue (UserDefaults/file) for background-received events
  watchos/WearerLinkWatch/          ← Swift sources for the native watchOS companion app
  example/                          ← phone-side demo app
```

- **Channel layer: Pigeon** (type-safe generated Kotlin/Swift/Dart; no
  hand-written channel strings). `HostApi` for Dart→native calls,
  `FlutterApi` for native→Dart events.
- **Background story (the hard part):** events that arrive while no Flutter
  engine exists are (a) persisted to a bounded on-device queue, and (b)
  replayed into the Dart stream as soon as the app next attaches. Phase 2 can
  add a headless background isolate (workmanager-style callback dispatcher);
  the prototype guarantees **no event loss** instead.
- **Wire protocol:** every payload travels as `path: String` +
  `payload: bytes` (+ auto phone/watch envelope on iOS so paths multiplex over
  WatchConnectivity's dictionary API). JSON helpers on top; raw bytes stay
  possible.

## 3. Public Dart API (prototype surface)

```dart
final wearer = WearerLink.instance;

await wearer.isSupported;                         // Play Services / WCSession availability
await wearer.getCompanionStatus();                // paired? appInstalled? reachable?
wearer.connectionState;                           // Stream<WearerConnectionState>

await wearer.sendMessage('/ping', bytes);         // interactive, needs reachable node
wearer.messages;                                  // Stream<WearerMessage> (incl. replayed background ones)

await wearer.syncData('workout', jsonBytes);      // DataClient item / applicationContext
wearer.dataEvents;                                // Stream<WearerDataEvent>

await wearer.launchCompanion();                   // RemoteActivityHelper / startWatchApp; throws
                                                  // WearerUnsupportedException where the OS forbids it
```

## 4. Milestones

1. **M0 — Plan + scaffold** (this document; `flutter create --template=plugin`).
2. **M1 — Contract**: Pigeon schema, generated bindings, Dart facade + models, unit tests. ✅ prototype
3. **M2 — Android**: DataLayerBridge, background `WearableListenerService` + persisted queue, `RemoteActivityHelper` launch. ✅ prototype (most complex step #1)
4. **M3 — iOS**: WCSession bridge with launch-time activation, background wake + persisted queue, workout-gated watch launch, `WearerLinkWatch` Swift companion sources. ✅ prototype (most complex step #2)
5. **M4 — Example + docs**: demo phone app, wiring guide (manifest entries, capabilities file, Xcode watch target steps).
6. **M5 — Post-prototype**: headless Dart background isolate, file/channel transfers, watchOS complication push (`transferCurrentComplicationUserInfo`), Wear OS tiles. ✅ implemented (isolate + files device-verified on Pixel 7 Pro + Pixel Watch 2); remaining: integration test harness on emulator pairs.

## 5. Risks / decisions taken

- **No cross-vendor magic:** Wear OS ⇄ iPhone and Apple Watch ⇄ Android pairs
  expose only what those pairings actually support (nothing) — API reports
  `unsupported`, never fakes it.
- **Play Services required** on Android (true for every Wear OS pairing).
- **Background execution ≠ foreground UI on iOS**: we document that a watch
  message wakes the iPhone app silently; visible auto-open exists only on
  Android. This is an OS policy, not a plugin gap.
- **Prototype guarantees at-least-once delivery to Dart** via the persisted
  pending queue; exactly-once dedup (event ids) is in the models from day one
  so Phase 2 doesn't break the contract.

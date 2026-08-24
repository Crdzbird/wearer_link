## 0.1.0

Working prototype.

* Pigeon-typed platform channel (Dart / Kotlin / Swift).
* Dart facade: `messages`, `dataEvents`, `connectionState` streams;
  `sendMessage`, `syncData`, `transferData`, `launchCompanion`;
  automatic replay of events received while the app was not running
  (at-least-once, dedup via `WearerEvent.id`).
* Android / Wear OS: Data Layer bridge (Message/Data/Capability clients),
  manifest-declared `WearableListenerService` as the single receive path
  (live dispatch to Dart or persisted bounded queue), shipped `wearer_link`
  capability resource, `RemoteActivityHelper`-based mutual app launch.
* iOS: singleton `WCSession` bridge safe for watch-triggered background
  launches, persisted pending queue, per-path `applicationContext` merge,
  reply-acknowledged interactive sends, HealthKit workout-session watch
  launch (typed `unsupported` error elsewhere — OS policy).
* watchOS: `WearerLinkWatch` Swift package for native watch apps
  (activate/send/sync/transfer/wake, startup event buffering).

## 0.6.0

M7: product surfaces.

* `wearer.store` — synced reactive KV store: last-writer-wins (timestamp +
  writer tiebreak), tombstoned deletes, values persisted by the OS sync
  layer itself (survive restarts, arrive after offline gaps). Dart
  endpoints; values capped at 48KB (store state, not payloads). Live
  set/get/keys verified on the simulator pair.
* `transferFileTracked` — file transfer with a 0..1 progress stream and
  `done` future, carried over a plugin stream on `/__wlfile` (both ends
  need >= 0.6 and a live link; `transferFile` remains the fire-and-forget
  path). 150KB round-trips byte-identical on the test harness.
* Diagnostics: `stats` (session counters incl. replayed/dedup-dropped),
  `diagnostics` stream for silent failures, `pingLatency()` over the
  built-in status responder, `WearerLink.verboseLogging`.
* New host APIs backing the store: `readOwnSyncData`, `listSyncPaths`.

## 0.5.0

M6: developer-experience core.

* `getNodes()` (id, display name, isNearby) and `getCounterpartStatus()`
  — battery/model/OS served by a built-in native responder on all three
  sides (sim-pair verified; no app code needed on the counterpart).
* `launchCompanion(route:, args:)` — the launched app receives them on the
  new `launchIntents` stream (queued transfer, survives the launch gap;
  Android also embeds them in the launch URI). watchOS: `onLaunchIntent`.
* Path router: `on('/workout/*', handler)` / `onRequestPath` — exact and
  trailing-wildcard routes, most-specific match wins, request routes take
  precedence over the global handler.
* Typed codecs: `registerCodec` + `sendTyped` / `onTyped` /
  `sendRequestTyped`, with `WearerJsonCodec` built in.
* Reachability helpers: `whenReachable({timeout})` and
  `sendMessage(..., queueIfUnreachable: true)` (downgrades to a queued
  transfer instead of throwing).
* `package:wearer_link/testing.dart`: `WearerLinkFake.pair()` — in-memory
  two-endpoint harness reproducing the full delivery contract
  (reachability, kill/relaunch replay, background handler + ack, streams,
  delivery toggle, per-platform capabilities). The plugin's own suite runs
  12 tests on it.

## 0.4.0

* Bidirectional streaming: `openStream` / `incomingStreams` /
  `WearerStream` (Android: real ChannelClient socket streams; iOS/watchOS:
  chunked frames over interactive messages). Verified live on the simulator
  pair: open -> chunks echoed in order -> orderly close.
* `transferData` is size-unlimited: payloads over the platform message cap
  transparently travel as a file and still arrive as a plain data event
  (Android verified route; iOS sender verified — simulator pairs cannot
  deliver transferFile, a known simulator gap).
* `getCapabilities()`: typed, honest feature report (message/request/sync/
  transfer/file/stream, companionLaunch, complicationPush, surfaceUpdate,
  backgroundWake, maxMessageBytes).
* `setEventDeliveryEnabled(bool)`: lossless pause — inbound events divert
  to the persistent queue (same path as a killed app), incoming streams
  and requests are refused; re-enabling replays the backlog. Persisted.

## 0.3.0

* Example gained a `RunnerWatch` watchOS target (SwiftUI + WearerLinkWatch).
  iOS/watchOS verified on paired simulators: messaging + RPC both
  directions, applicationContext sync, readSyncData.

* `sendRequest` / `setRequestHandler`: request-response RPC with reply
  payloads (Android `MessageClient.sendRequest`; iOS `sendMessage` reply
  dictionaries; watchOS `sendRequest`/`onRequest`). Dart-side timeout
  (default 10s) maps to `sendFailed`; a counterpart without a handler
  rejects with `noHandler` instead of queueing — the sender is waiting.
* `readSyncData` / `deleteSyncData`: query the counterpart's latest synced
  value (device-verified: read a value synced in a previous session);
  delete this device's own synced value.
* Optional `nodeId` on `sendMessage` / `sendRequest` / `transferFile` for
  multi-watch targeting on Android (iOS has a single counterpart).
* Session-level dedup: the facade drops duplicate event ids (bounded LRU),
  so at-least-once redelivery within a session no longer double-fires
  streams.

## 0.2.0

M5: background isolate, file transfers, watch-face surfaces.

* `registerBackgroundHandler`: events that arrive while the app is dead are
  handled immediately in a headless Dart isolate (workmanager-style
  callback handles; ack removes the event from the pending queue, a failed
  handler leaves it queued — at-least-once preserved). Device-verified:
  dead phone app handled a watch ping in the isolate and messaged back.
* `transferFile` + `fileEvents`: Android ChannelClient / iOS
  `WCSession.transferFile`; received files land in the app cache dir; new
  `WearerEventKind.file` with `filePath`. Manifest gained the
  `CHANNEL_EVENT` action. Device-verified phone→watch.
* `updateComplication` (iOS `transferCurrentComplicationUserInfo`; typed
  `unsupported` on Android) and `requestSurfaceUpdate` (Wear OS tile /
  complication refresh via compileOnly androidx requesters; typed
  `unsupported` on iOS).
* watchOS lib: `transferFile(path:fileURL:)`, `Event.fileURL` for received
  files.

## 0.1.1

* Android verified on real hardware (Pixel 7 Pro + Pixel Watch 2):
  capability discovery both directions, ping/sync/transfer both directions,
  and the background path — app force-stopped, watch sends, system restarts
  the process for `WearerLinkListenerService`, events replay on next launch
  with `deliveredWhileDead: true`.

* First native compiles verified on a real toolchain (previously authored
  offline): Kotlin plugin + unit tests (AGP 8.11.1, Kotlin 2.2.20,
  Gradle 8.14.3), iOS `flutter build ios`, watchOS package
  (`xcodebuild -destination generic/platform=watchOS`).
* Android deps pinned to current stable and compile-verified:
  play-services-wearable 20.0.1, wear-remote-interactions 1.2.0
  (`RemoteActivityHelper(Context, Executor)` confirmed), coroutines 1.11.0.
  Both `// VERIFY:` markers resolved.
* iOS: added missing `import Flutter` in `PendingEventStore.swift`.
* Example iOS project migrated to UIScene lifecycle (Flutter 3.47 tooling).

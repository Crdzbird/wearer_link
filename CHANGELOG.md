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

## 0.3.0

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

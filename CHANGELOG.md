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

## 1.1.0

* **watchOS-native store accessor**: `WearerLinkWatch.shared.store` —
  get/set/delete/keys/onChange over the same records as the Dart store
  (LWW + tombstones, 48KB cap). Verified both directions on the simulator
  pair: Dart set -> native onChange/get; native set -> Dart get (across a
  simulator reboot).
* **Persistent delivery counters**: `getPersistentStats()` /
  `resetPersistentStats()` — native, cross-restart counts of
  received/queued-while-dead/drained/background-handled with an epoch.
  Hardware-verified on the Pixel pair: a dead-app ping produced
  queuedDead:1 + bgHandled:1 + drained:0 with the epoch surviving
  force-stop; iOS counters survived two process restarts and a simulator
  reboot.
* Example: startup console probe (store value + persistent stats) for
  headless verification.

## 1.0.0

First stable release. The API is now under semver: breaking Dart API
changes only in majors, wire compatibility additive across minors (see
"Versioning & wire compatibility" in the README).

Everything below is cumulative through the 0.x line — highlights:

* **Core link**: messaging, latest-state sync, queued transfers, file
  transfers, mutual app launch — phone ⇄ Wear OS (symmetric Flutter) and
  iPhone ⇄ watchOS (native `WearerLinkWatch` Swift package).
* **Delivery contract**: at-least-once with session dedup; events that
  arrive while the app is killed are received natively, queued, and
  replayed flagged `deliveredWhileDead` — or handled immediately in a
  headless background isolate.
* **RPC** with reply payloads, **bidirectional byte streams**,
  size-unlimited transfers, tracked transfers with progress, a **synced
  KV store** (LWW + tombstones, persisted by the OS sync layer), launch
  intents, counterpart vitals, capabilities introspection, lossless
  delivery toggle, app-supplied **payload encryption**, diagnostics.
* **Tooling**: `WearerLinkFake` in-memory pair harness, path router,
  typed codecs, reachability helpers.
* **Verification**: Android matrix fully green on real hardware
  (Pixel 7 Pro + Pixel Watch 2), incl. a store-fed Wear OS tile
  re-rendering on request; iOS verified on paired simulators, physical
  Apple hardware rows formally waived. 52 Dart + 4 Kotlin tests; CI
  compiles all three native stacks.

Not published to pub.dev; distribution is via git until further notice.

## 0.8.2

* Wear OS tile surface-update verified on hardware: the example gained
  `DemoTileService` (renders the synced store's newest record, read
  natively from the Data Layer item) — a Dart `store.set` +
  `requestSurfaceUpdate` re-rendered it in ~1s on the Pixel Watch 2.
  Example minSdk raised to 26 (androidx.wear.tiles requirement).
* README: tile-fed-by-store recipe + "Versioning & wire compatibility"
  policy. Roadmap: iOS physical rows formally waived pending hardware.

## 0.8.1

Hardware verification sweep on the real Pixel 7 Pro + Pixel Watch 2 pair —
two hardware-only bugs found and fixed:

* **Fix**: the manifest listener was missing the
  `com.google.android.gms.wearable.REQUEST_RECEIVED` action, so
  `sendRequest` (and the built-in vitals responder) never received RPCs on
  real Android hardware — every request timed out. Simulators masked this
  (iOS RPC rides the plugin's own envelope).
* **Fix**: tracked file transfers now length-prefix their header frame.
  Android's native channel streams do not preserve write boundaries
  (observed merged chunks on hardware), so the "first chunk = header"
  assumption was unsafe. `WearerStream` docs now state the byte-stream
  contract explicitly.
* Vitals model string no longer duplicates the manufacturer.
* Matrix results: RPC + vitals (real battery/charging), 153KB blob intact,
  streams ordered, 2MB tracked transfer md5-identical, store LWW converged
  under real latency, launch-with-intent foregrounded the watch app with
  route/args.

## 0.8.0

* Example app: "Share photo" (image_picker -> tracked transfer -> progress
  bar -> receiver thumbnail) and "Stream file" (2MB with live % and MB/s —
  2.31 MB/s measured on the simulator pair). README gained recipes: photo
  capture & share, MJPEG-style live viewfinder over streams, file-sharing
  primitive decision table, large-file streaming with throughput.

API review pass (pre-1.0 breaking renames, no deprecation shims since the
package is unpublished):

* `getCounterpartStatus()` -> `getCounterpartVitals()` and
  `WearerCounterpartStatus` -> `WearerCounterpartVitals` — the old name
  collided with `getCompanionStatus` (pairing state) while meaning
  something different. watchOS: `requestPhoneStatus` ->
  `requestPhoneVitals`. Wire path (`/__wlstatus`) unchanged.
* Store plumbing (`storeSync` etc.) no longer leaks as public members of
  `WearerLink` (moved to a private transport adapter).
* Internal plumbing members (`WearerStream.addData`/`markClosed`,
  `.internal` constructors, `fromDto` mappers) annotated `@internal`.
* `public_member_api_docs` enforced permanently; every public symbol is
  documented.

## 0.7.0

M8: trust & media.

* `setPayloadCipher(WearerCipher)` — app-supplied encryption enforced
  across messages, requests (both legs), data/blob transfers, store
  records, and all stream chunks (tracked files included). A 4-byte wire
  marker makes mismatched endpoints drop payloads with diagnostics and
  fail requests typed — ciphertext is never emitted as app data.
  Dispatch and per-stream decrypt chains keep ordering under async
  ciphers. Exclusions documented: plain transferFile bodies, /__wlstatus,
  launch args.
* Audio streaming guarantee: suite sustains 100×16KB ordered chunks over
  one stream; README voice-memo recipe. (No new API — measurements did
  not justify a profile knob.)
* `WearerStream` now takes injected transport hooks (internal refactor).

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

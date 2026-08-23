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

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

## 0.1.1

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

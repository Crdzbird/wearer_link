# wearer_link — Feature Roadmap (post-0.4.0)

Where [PLAN.md](PLAN.md) covered the prototype (M0–M5, all shipped), this
document plans the road to 1.0: developer experience, product-shaped
features, and the trust/media layer. Grouped into three milestones sized to
ship independently, each cut so the library stays honest (typed errors for
OS policy, at-least-once delivery, symmetric API) and verifiable (unit
tests + at least one live pair check per feature).

---

## Ground rules (apply to every milestone)

- **Reserved namespace**: every internal path the plugin invents lives
  under `/__wl*` (`/__wlblob` already does). User paths never collide with
  plugin machinery, and the reserved space is documented.
- **Wire compatibility**: additive envelope changes only. Any feature that
  needs both sides upgraded (store, encryption) must degrade cleanly when
  the counterpart runs an older version — a typed error or a no-op, never
  a hang or a crash.
- **Test-first native**: nothing merges without Dart unit tests, all three
  native stacks compiling in CI, and a live check on the simulator pair;
  hardware-only behaviors (background wake, transferFile delivery) get an
  entry in the hardware verification matrix instead.
- **Docs move with code**: README + dartdoc in the same commit.

---

## M6 — Developer experience core (v0.5.0)

The milestone that makes the library pleasant on day one. All items are
small-to-medium and independent; ship together as 0.5.0.

### 6.1 In-memory test harness — `WearerLinkFake` ✅ shipped

The single biggest adoption lever: app developers can unit test both sides
of their protocol with zero hardware.

```dart
final (phone, watch) = WearerLinkFake.pair();     // two linked instances
watch.messages.listen(...);                        // receives phone sends
await phone.sendMessage('/ping', bytes);
fakeLink.setReachable(false);                      // simulate range loss
fakeLink.simulateColdStart();                      // queue -> replay path
```

- Pure Dart (`lib/testing.dart` export, no platform code). Implements the
  same `WearerLink` surface backed by an in-memory link object.
- Simulates: reachability flips, pending-queue/replay (`deliveredWhileDead`),
  request round trips, streams, file transfers (temp files), capability
  matrices per simulated platform, delivery toggle.
- Verification: the plugin's own test suite partially migrates onto it —
  the harness is trustworthy because we use it ourselves.
- Effort: M.

### 6.2 Path router ✅ shipped

```dart
wearer.on('/workout/update', (event) { ... });     // exact
wearer.on('/workout/*', (event) { ... });          // prefix wildcard
wearer.onRequestPath('/echo', (req) async => ...); // per-path request handler
```

- Sugar over the existing streams — global `messages`/`dataEvents` remain.
- Routing rules: most-specific match wins; unmatched events still reach the
  global streams; `*` only valid as a trailing segment.
- Request routing composes with `setRequestHandler` (router registered
  handlers take precedence; global handler is the fallback).
- Effort: S. Pure Dart.

### 6.3 Typed codecs ✅ shipped

```dart
wearer.registerCodec<WorkoutState>(JsonCodec(WorkoutState.fromJson));
await wearer.sendTyped('/workout', WorkoutState(...));
wearer.onTyped<WorkoutState>('/workout', (state, event) { ... });
final reply = await wearer.sendRequestTyped<Query, Answer>('/q', query);
```

- Pure Dart layer over payload bytes; JSON codec built in, codec interface
  open for proto/msgpack.
- Effort: S.

### 6.4 Reachability helpers ✅ shipped

```dart
await wearer.whenReachable(timeout: Duration(seconds: 30));
await wearer.sendMessage('/cmd', bytes, queueIfUnreachable: true);
```

- `whenReachable`: resolves immediately if reachable, otherwise waits on
  `connectionState` with a timeout → `WearerErrorCode.unreachable`.
- `queueIfUnreachable`: on `unreachable`, falls back to `transferData` on
  the same path (documented: arrives as a data event, order not guaranteed
  relative to live messages).
- Effort: S. Pure Dart.

### 6.5 Rich node info ✅ shipped

```dart
final nodes = await wearer.getNodes();
// WearerNode(id, displayName, isNearby)  — Android: NodeClient facts;
// iOS: the single watch (name from WCSession where available).
```

- Replaces bare id strings in app code; `isNearby` feeds "watch nearby" UI.
- Pigeon: `getNodes() -> List<WearerNodeDto>`.
- Effort: S.

### 6.6 Launch with intent ✅ shipped

```dart
await wearer.launchCompanion(route: '/workout', args: {'id': 42});
```

- Android: appended to the launch URI as query params
  (`wearerlink://open?route=...&args=...`); receiving activity reads them,
  and the plugin also emits them as a data event on `/__wllaunch` so pure
  Flutter apps need no intent-filter parsing.
- iOS: workout-launch cannot carry data (OS policy) — route/args delivered
  via a queued `transferData` on `/__wllaunch` immediately after launch.
- Watch lib: `onLaunchIntent` callback.
- Effort: S–M.

### 6.7 Counterpart status ✅ shipped

```dart
final status = await wearer.getCounterpartStatus();
// battery %, isCharging, model, osVersion
```

- Built on `sendRequest` to a **built-in well-known handler** (`/__wlstatus`)
  that all three sides implement natively — works even before the app
  registers anything.
- Graceful degrade: older counterpart → typed `noHandler` error.
- Effort: S–M (battery APIs on three platforms).

**Exit criteria 0.5.0**: harness powering ≥5 of the plugin's own tests;
router/codec/reachability unit-tested; nodes + launch-intent +
counterpart-status verified on the simulator pair; CI green; CHANGELOG.

---

## M7 — Product surfaces (v0.6.0)

The features that make companion apps product-shaped.

### 7.1 Synced KV store ✅ shipped (watchOS-native accessor landed in 1.1.0)

```dart
final store = wearer.store;                  // WearerStore
await store.set('workout', bytes);           // or setTyped with codecs
store.watch('workout').listen(...);          // reactive, both directions
final value = await store.get('workout');    // local cache, instant
await store.delete('workout');
store.keys;                                  // snapshot
```

- Semantics: last-writer-wins per key (timestamp + node-id tiebreak),
  persisted locally on both sides, replayed through the existing pending
  queue so cold starts see the full picture.
- Impl: one reserved sync path per key (`/__wlstore/<key>`) over the
  existing syncData machinery + a local persisted map; tombstones for
  deletes with a bounded GC.
- The design doc section must cover: conflict rules, tombstone TTL, max
  key/value budget (values above the message cap ride the blob route).
- Effort: M–L. The headline of 0.6.0.

### 7.2 File transfer progress ✅ shipped (pure Dart over plugin streams)

```dart
final transfer = await wearer.transferFileTracked('/photos/1', path);
transfer.progress.listen((p) => ...);        // 0.0 → 1.0
await transfer.done;
```

- iOS: native (`WCSessionFileTransfer.progress` KVO).
- Android: reimplement the send leg over a plugin stream (we own both
  ends now): sender chunks the file over a `/__wlfile` stream with byte
  counts → receiver writes + acks; keeps ChannelClient `sendFile` as the
  fallback for untracked transfers.
- Effort: M.

### 7.3 Diagnostics & link quality ✅ shipped (persistent native counters landed in 1.1.0)

```dart
wearer.diagnostics;                          // Stream<WearerDiagnostic>
final rtt = await wearer.pingLatency();      // built-in /__wlping probe
final stats = await wearer.getStats();       // queued, replayed, dropped, sent
WearerLink.verboseLogging = true;            // tagged native + Dart logs
```

- Counters live natively (they must survive Dart restarts); one Pigeon
  `getStats()` + an event stream for errors that today die silently
  (background ack failures, stream teardown reasons).
- Effort: M.

**Exit criteria 0.6.0**: store surviving cold-start + conflict unit tests
on the fake harness plus a live sim-pair session; tracked transfer showing
monotonic progress on Android hardware; diagnostics counters asserted in
tests; CI green.

---

## M8 — Trust & media (v0.7.0)

### 8.1 App-layer encryption hook ✅ shipped

```dart
wearer.setPayloadCipher(WearerCipher(
  encrypt: (path, bytes) async => ...,
  decrypt: (path, bytes) async => ...,
));
```

- Plugin never invents crypto: the app supplies the cipher (and its key
  exchange); we guarantee every payload crosses the wire through it —
  messages, requests, data, store, stream frames, file bodies.
- Envelope gains a flag so an encrypted payload meeting a cipher-less
  counterpart fails typed (`WearerErrorCode.unsupported` + reason), never
  emits garbage.
- Effort: S–M (the discipline is auditing every path, not the code).

### 8.2 Audio / sensor stream helpers ✅ shipped (recipe + ordering guarantee; no profile knob — measurements did not justify one)

```dart
final mic = await wearer.openStream('/voice', profile: WearerStreamProfile.audio);
```

- Thin, honest helpers over `WearerStream`: recommended chunk sizes,
  backpressure guidance, a worked voice-memo example in the watch demo
  apps (watch mic → phone file) for both platforms.
- Mostly example + docs; one `profile` knob if measurements justify it.
- Effort: M (dominated by the demo + tuning on hardware).

### 8.3 Hardware verification matrix (continuous, gates 1.0)

The simulator-untestable behaviors, tracked as a table in this file:

| Behavior | Android (Pixel pair) | iOS (physical pair) |
|---|---|---|
| Killed-app background wake + replay | ✅ verified 0.1 | ⬜ |
| Background isolate handling | ✅ verified 0.2 | ⬜ |
| transferFile delivery | ✅ verified 0.2 | ⬜ |
| Blob (oversized transferData) delivery | ✅ 0.8.1 (153KB intact) | ⬜ |
| Streams on hardware | ✅ 0.8.1 (ordered; write boundaries may merge — documented) | ⬜ |
| RPC happy path on hardware | ✅ 0.8.1 (after REQUEST_RECEIVED fix) | ⬜ (sim-verified) |
| Launch-with-intent foreground open | ✅ 0.8.1 (foreground + route/args) | n/a (workout-only) |
| Complication push budget behavior | n/a | ⬜ |
| Counterpart vitals on hardware | ✅ 0.8.1 (real battery/charging) | ⬜ (sim-verified) |
| Tile/complication surface update | ✅ 0.8.2 (DemoTileService re-rendered in ~1s showing fresh store state) | n/a |
| Store conflict under real latency | ✅ 0.8.1 (LWW converged to later writer) | ⬜ |
| Tracked transfer progress on hardware | ✅ 0.8.1 (2MB md5-identical, framed header) | n/a (native watch) |

---

**iOS physical column: waived** (2026-08-24, user decision) — pending real
iPhone + Apple Watch hardware. The iOS implementations are sim-verified
where the simulator permits; rows marked ⬜ in the iOS column are release
waivers, not unknown-unknowns.

## 1.0 criteria — ✅ met; 1.0.0 cut 2026-08-24 (unpublished, git-only)

- M6–M8 shipped; hardware matrix has no ⬜ in at least one full platform
  column per row (or a documented waiver).
- ~~API review pass: naming consistency sweep, `@Deprecated` shims removed,
  dartdoc coverage on every public symbol.~~ ✅ done in 0.8.0.
- pub.dev publish — **on the user's explicit go only** — + example app
  polished as the reference implementation.
- ~~Versioning promise documented~~ ✅ see "Versioning & wire
  compatibility" in README.

## M9 — Link identity: knowing who is on the other end (v2.2.0)

**The constraint that shapes this milestone.** Both OSes already scope
traffic to one app pair, so a plugin-level identifier cannot grant
cross-app reach and is not needed to prevent cross-app leakage:

- **Android/Wear OS** — the Data Layer delivers only between apps sharing a
  package name *and* signing certificate (the `applicationId` + signing-key
  requirement in the README is exactly this).
- **iOS/watchOS** — `WCSession.default` connects an iOS app to its own
  embedded watch app; there is no API to address another vendor's app.

So M9 is **not** a router. It is a guard and a handshake, covering the
failures OS scoping does *not*:

1. **Same identifier, different build** — debug/staging/prod, TestFlight vs
   App Store. Same `applicationId`/bundle id, mismatched expectations, and
   today they talk to each other happily.
2. **Protocol drift** — phone v3 ⇄ watch v1: same paths, incompatible
   payload schemas. Currently surfaces as a corrupt decode inside app code
   instead of a typed error at the boundary.
3. **Diagnosability** — a mismatched counterpart is invisible until its
   payloads misbehave.

### 9.0 Verify the platform fact (gates the rest)

Two builds with differing package names on a paired phone/watch; confirm
zero cross-delivery on messages, data items and capability discovery.

- If confirmed (expected): the design below stands as written.
- If cross-package delivery is possible at all, M9 grows a real routing
  layer and must be re-planned before any code lands.
- Effort: S (a device experiment, ~30 min). **Nothing else starts first.**

### 9.1 Carry the identity ✅ shipped (2.2.0)

A **link id** (developer-chosen, defaults to the package/bundle id) plus an
optional **protocol version**.

Declared natively, not only in Dart. INVARIANT: events arrive while the app
is dead, so the receive path must resolve identity *before any Dart engine
exists* — a Dart-only setter cannot be the source of truth.

```xml
<!-- AndroidManifest.xml -->
<meta-data android:name="com.crdzbird.wearer_link.linkId"
           android:value="com.acme.fitness" />
<meta-data android:name="com.crdzbird.wearer_link.protocolVersion"
           android:value="3" />
```

```dart
// Optional override; persists natively so later cold starts see it.
await wearer.configureLink(id: 'com.acme.fitness', protocolVersion: 3);
```

- **iOS/watchOS**: two envelope keys (`a` = link id, `v` = version) —
  everything already rides the dictionary envelope.
- **Android**: fold the id into the path namespace (`/wl/<idHash>/m/…`) so a
  foreign payload cannot even parse as ours, and scope capability discovery
  per link id. `// VERIFY:` `wear.xml` is a *static* resource, so a
  per-app capability string needs either the consuming app declaring its
  own or a runtime registration (`CapabilityClient.addLocalCapability`) —
  confirm against the pinned play-services release before committing.
- Carried and exposed read-only; no behaviour change yet.
- Effort: M.

### 9.2 Enforce, and say so (next — runs after 9.3, which it keys off)

- A non-matching event is dropped at the native boundary, counted in
  `getPersistentStats`, and never delivered silently.
- New `WearerErrorCode.linkMismatch` on sends; new
  `WearerConnectionState.incompatible` so status reports it.
- Effort: S–M.

### 9.3 Handshake for free ✅ shipped (2.3.0)

The built-in `/__wlstatus` responder already answers counterpart vitals
without app code. Extend its reply with link id + protocol version, so
`getNodes()` carries the counterpart's identity and an app can check
compatibility before sending a byte.

- Effort: S.

### 9.4 Compatibility, testing, docs

- **v2 peers send no identity.** Default **lenient** (accept, count, warn);
  `strictLinkIdentity: true` opts into rejection. A v3 phone will meet v2
  watches in the field, and silently breaking them is worse than the
  problem being solved.
- `WearerLinkFake.network()` takes a per-endpoint link id + version so
  mismatch is unit-testable with no hardware.
- README section + migration note.
- Effort: M.

**Risks:** wire compatibility with v2 peers; the static `wear.xml`
constraint; capability-name length limits when hashing ids; and the main
trap — building a router for something the OS forbids.

## Explicitly out of scope (and why)

- **Notification bridging** — both OSes bridge notifications natively;
  a comms plugin re-implementing it would fight the platform. Docs recipe
  instead.
- **Health/sensor data collection** — belongs to Health Connect /
  HealthKit / Wear Health Services; this plugin moves bytes. A companion
  package could pair them later.
- **Cross-vendor pairs** (Wear OS ⇄ iPhone beyond OS support) — unchanged
  from PLAN.md: we report what the OS allows, never fake it.

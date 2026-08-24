import Flutter
import Foundation
import HealthKit
import UIKit
import WatchConnectivity

/// Envelope keys shared with the watchOS companion library.
/// CONTRACT: mirrored in watchos/WearerLinkWatch/WearerLinkWatch.swift.
enum Envelope {
  static let path = "p"
  static let payload = "d"
  static let kind = "k"
  static let id = "id"
  static let timestamp = "ts"

  static let kindMessage = 0
  static let kindData = 1
  static let kindFile = 2
  static let kindRequest = 3
  static let kindStream = 4

  /// Built-in counterpart-vitals responder (request path).
  static let statusPath = "/__wlstatus"

  /// Reserved data path carrying launchCompanion route/args.
  static let launchPath = "/__wllaunch"

  /// Oversized transferData payloads travel as files whose path carries
  /// this marker; the receiver restores them into plain data events.
  /// CONTRACT: mirrored on Android/watchOS.
  static let blobMarker = "/__wlblob"

  /// Payloads above this route through the blob file path.
  static let maxMessageBytes = 56 * 1024

  /// Reply-dictionary keys for request round trips.
  static let replyPayload = "d"
  static let replyError = "err"
}

/// Singleton owner of the WCSession, deliberately independent of any plugin
/// instance: when the watch wakes this app in the background, the session
/// must activate and buffer events before (or without) a Flutter engine.
///
/// Live delivery: the plugin installs `liveDispatcher` while an engine is
/// attached; otherwise events go to PendingEventStore (at-least-once, same
/// contract as Android).
final class WatchSessionBridge: NSObject {
  static let shared = WatchSessionBridge()

  /// Reserved launch-intent path, exposed for the plugin's launch flow.
  static let launchPathForPlugin = Envelope.launchPath

  /// Set on the main thread by the plugin; called on the main thread.
  var liveDispatcher: ((WearerEventDto) -> Void)?

  /// Pushed on reachability/pairing changes while a plugin is bound.
  var statusListener: ((CompanionStatusDto) -> Void)?

  /// Answers request round trips while a plugin is bound. Main thread;
  /// the completion may fire on any thread.
  var requestHandler: ((WearerEventDto, @escaping (Result<Data, Error>) -> Void) -> Void)?

  private override init() {
    super.init()
  }

  var isSupported: Bool { WCSession.isSupported() }

  func activate() {
    guard WCSession.isSupported() else { return }
    // Needed for the built-in /__wlstatus vitals responder.
    UIDevice.current.isBatteryMonitoringEnabled = true
    let session = WCSession.default
    session.delegate = self
    if session.activationState != .activated {
      session.activate()
    }
  }

  func companionStatus() -> CompanionStatusDto {
    guard WCSession.isSupported() else {
      return CompanionStatusDto(state: .unsupported, nodes: [])
    }
    let session = WCSession.default
    guard session.isPaired else {
      return CompanionStatusDto(state: .unpaired, nodes: [])
    }
    guard session.isWatchAppInstalled else {
      return CompanionStatusDto(state: .appNotInstalled, nodes: [])
    }
    guard session.isReachable else {
      return CompanionStatusDto(state: .unreachable, nodes: [])
    }
    return CompanionStatusDto(state: .reachable, nodes: ["watch"])
  }

  // MARK: - Outbound

  func sendMessage(path: String, payload: Data, completion: @escaping (Error?) -> Void) {
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable else {
      completion(PigeonError(
        code: "unreachable",
        message: "Watch is not reachable for interactive messages.",
        details: nil))
      return
    }
    // Reply-handler round trip: exactly one completion, and success means
    // the counterpart actually received the message.
    session.sendMessage(
      envelope(path: path, payload: payload, kind: Envelope.kindMessage),
      replyHandler: { _ in
        DispatchQueue.main.async { completion(nil) }
      },
      errorHandler: { error in
        DispatchQueue.main.async {
          completion(PigeonError(code: "sendFailed", message: "\(error)", details: nil))
        }
      })
  }

  /// Request/response round trip: the reply dictionary carries the
  /// counterpart handler's payload (or its rejection).
  func sendRequest(path: String, payload: Data, completion: @escaping (Result<Data, Error>) -> Void) {
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable else {
      completion(.failure(PigeonError(
        code: "unreachable",
        message: "Watch is not reachable for interactive requests.",
        details: nil)))
      return
    }
    session.sendMessage(
      envelope(path: path, payload: payload, kind: Envelope.kindRequest),
      replyHandler: { reply in
        DispatchQueue.main.async {
          if let err = reply[Envelope.replyError] as? String {
            let code = err == "noHandler" ? "noHandler" : "sendFailed"
            completion(.failure(PigeonError(
              code: code, message: "Counterpart rejected request: \(err)", details: nil)))
          } else if let data = reply[Envelope.replyPayload] as? Data {
            completion(.success(data))
          } else {
            completion(.failure(PigeonError(
              code: "sendFailed", message: "Malformed reply.", details: nil)))
          }
        }
      },
      errorHandler: { error in
        DispatchQueue.main.async {
          completion(.failure(PigeonError(code: "sendFailed", message: "\(error)", details: nil)))
        }
      })
  }

  /// Latest value the counterpart synced for [path].
  func readSyncData(path: String) -> Data? {
    let received = WCSession.default.receivedApplicationContext
    guard let dictionary = received[path] as? [String: Any] else { return nil }
    return dictionary[Envelope.payload] as? Data
  }

  /// Latest value this device synced for [path].
  func readOwnSyncData(path: String) -> Data? {
    guard let dictionary = WCSession.default.applicationContext[path]
      as? [String: Any] else { return nil }
    return dictionary[Envelope.payload] as? Data
  }

  /// Every stored sync path under [prefix], own and received combined.
  func listSyncPaths(prefix: String) -> [String] {
    let session = WCSession.default
    var paths = [String]()
    for key in session.applicationContext.keys where key.hasPrefix(prefix) {
      paths.append(key)
    }
    for key in session.receivedApplicationContext.keys
    where key.hasPrefix(prefix) && !paths.contains(key) {
      paths.append(key)
    }
    return paths
  }

  /// Remove the value this device synced for [path].
  func deleteSyncData(path: String) throws {
    let session = WCSession.default
    var context = session.applicationContext
    if context.removeValue(forKey: path) != nil {
      try session.updateApplicationContext(context)
    }
  }

  func syncData(path: String, payload: Data) throws {
    let session = WCSession.default
    // applicationContext is replaced wholesale; merge so each user path
    // keeps its own latest value.
    var context = session.applicationContext
    context[path] = envelope(path: path, payload: payload, kind: Envelope.kindData)
    try session.updateApplicationContext(context)
  }

  func transferData(path: String, payload: Data) throws {
    if payload.count > Envelope.maxMessageBytes {
      // Too big for a userInfo transfer: travel as a file, arrive as a
      // plain data event on the other side.
      let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("wearer_blob_\(UUID().uuidString)")
      try payload.write(to: temp)
      defer { try? FileManager.default.removeItem(at: temp) }
      try transferFile(path: Envelope.blobMarker + path, filePath: temp.path)
      return
    }
    WCSession.default.transferUserInfo(
      envelope(path: path, payload: payload, kind: Envelope.kindData))
  }

  func getNodes() -> [WearerNodeDto] {
    let session = WCSession.default
    guard WCSession.isSupported(), session.isPaired else { return [] }
    return [
      WearerNodeDto(
        id: "watch",
        displayName: "Apple Watch",
        isNearby: session.isReachable)
    ]
  }

  /// Ask the watch's built-in /__wlstatus responder for its vitals.
  func getCounterpartVitals(completion: @escaping (Result<CounterpartVitalsDto, Error>) -> Void) {
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable else {
      completion(.failure(PigeonError(
        code: "unreachable", message: "Watch is not reachable.", details: nil)))
      return
    }
    session.sendMessage(
      envelope(path: Envelope.statusPath, payload: Data(), kind: Envelope.kindRequest),
      replyHandler: { reply in
        DispatchQueue.main.async {
          guard
            let data = reply[Envelope.replyPayload] as? Data,
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
          else {
            let reason = reply[Envelope.replyError] as? String ?? "malformed reply"
            completion(.failure(PigeonError(
              code: "noHandler",
              message: "Counterpart status probe failed "
                + "(older WearerLinkWatch on the watch?): \(reason)",
              details: nil)))
            return
          }
          completion(.success(CounterpartVitalsDto(
            batteryPercent: Int64(json["battery"] as? Int ?? -1),
            isCharging: json["charging"] as? Bool ?? false,
            model: json["model"] as? String ?? "unknown",
            osVersion: json["os"] as? String ?? "unknown")))
        }
      },
      errorHandler: { error in
        DispatchQueue.main.async {
          completion(.failure(PigeonError(code: "sendFailed", message: "\(error)", details: nil)))
        }
      })
  }

  /// This device's vitals, serving inbound /__wlstatus probes.
  func localStatusJson() -> Data {
    let device = UIDevice.current
    let level = device.batteryLevel
    let charging = device.batteryState == .charging || device.batteryState == .full
    let payload: [String: Any] = [
      "battery": level < 0 ? -1 : Int(level * 100),
      "charging": charging,
      "model": device.model,
      "os": "iOS \(device.systemVersion)",
    ]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
  }

  var deliveryEnabled: Bool {
    UserDefaults.standard.object(forKey: "wearer_link_delivery_enabled") as? Bool ?? true
  }

  func setDeliveryEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: "wearer_link_delivery_enabled")
    if !enabled { StreamRegistry.shared.closeAll() }
  }

  func capabilities() -> WearerCapabilitiesDto {
    let supported = WCSession.isSupported()
    return WearerCapabilitiesDto(
      message: supported,
      request: supported,
      syncData: supported,
      transferData: supported,
      transferFile: supported,
      stream: supported,
      companionLaunch: supported && HKHealthStore.isHealthDataAvailable()
        ? .workoutOnly : .none,
      complicationPush: supported,
      surfaceUpdate: false,  // Wear OS-only primitive
      backgroundWake: supported,
      maxMessageBytes: Int64(Envelope.maxMessageBytes))
  }

  func transferFile(path: String, filePath: String) throws {
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw PigeonError(
        code: "sendFailed", message: "No such file: \(filePath)", details: nil)
    }
    // Metadata carries the envelope (minus payload — the file IS the payload).
    var metadata = envelope(path: path, payload: Data(), kind: Envelope.kindFile)
    metadata.removeValue(forKey: Envelope.payload)
    WCSession.default.transferFile(URL(fileURLWithPath: filePath), metadata: metadata)
  }

  /// Push fresh complication data. watchOS budgets these transfers
  /// (`remainingComplicationUserInfoTransfers`); past the budget the system
  /// delivers them as regular userInfo transfers instead.
  func updateComplication(payload: Data) {
    WCSession.default.transferCurrentComplicationUserInfo(
      envelope(path: "/complication", payload: payload, kind: Envelope.kindData))
  }

  private func envelope(path: String, payload: Data, kind: Int) -> [String: Any] {
    [
      Envelope.path: path,
      Envelope.payload: payload,
      Envelope.kind: kind,
      Envelope.id: UUID().uuidString,
      Envelope.timestamp: Int64(Date().timeIntervalSince1970 * 1000),
    ]
  }

  // MARK: - Inbound

  private func handleInbound(_ dictionary: [String: Any], filePath: String? = nil) {
    guard let path = dictionary[Envelope.path] as? String else { return }
    let payload = dictionary[Envelope.payload] as? Data
    if payload == nil && filePath == nil { return }
    let kindRaw = dictionary[Envelope.kind] as? Int ?? Envelope.kindMessage
    let event = StoredEvent(
      id: dictionary[Envelope.id] as? String ?? UUID().uuidString,
      kindRaw: kindRaw,
      path: path,
      payload: payload ?? Data(),
      sourceNodeId: "watch",
      timestampMillis: dictionary[Envelope.timestamp] as? Int64
        ?? Int64(Date().timeIntervalSince1970 * 1000),
      filePath: filePath
    )
    DispatchQueue.main.async {
      StatsStore.shared.increment(StatsStore.keyReceived)
      if !self.deliveryEnabled {
        // Delivery paused: divert to the queue, wake nothing.
        StatsStore.shared.increment(StatsStore.keyQueued)
        PendingEventStore.shared.append(event)
        return
      }
      if let dispatcher = self.liveDispatcher {
        dispatcher(event.toDto(deliveredWhileDead: false))
      } else {
        // Persist first (crash-safe), then hand to the headless isolate if
        // one is registered; its ack removes the queued copy.
        StatsStore.shared.increment(StatsStore.keyQueued)
        PendingEventStore.shared.append(event)
        if BackgroundDispatcher.shared.isRegistered {
          BackgroundDispatcher.shared.deliver(event.toDto(deliveredWhileDead: true))
        }
      }
    }
  }

  private func pushStatus() {
    DispatchQueue.main.async {
      self.statusListener?(self.companionStatus())
    }
  }
}

// MARK: - WCSessionDelegate

extension WatchSessionBridge: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    pushStatus()
  }

  func sessionDidBecomeInactive(_ session: WCSession) {
    pushStatus()
  }

  func sessionDidDeactivate(_ session: WCSession) {
    // The user switched to a different watch: re-activate for the new one.
    session.activate()
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    pushStatus()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    pushStatus()
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    if (message[Envelope.kind] as? Int) == Envelope.kindStream {
      DispatchQueue.main.async { StreamRegistry.shared.handleFrame(message) }
      return
    }
    handleInbound(message)
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    switch message[Envelope.kind] as? Int {
    case Envelope.kindRequest:
      if (message[Envelope.path] as? String) == Envelope.statusPath {
        // Built-in vitals responder: device facts, no app involvement,
        // and deliberately outside the delivery gate.
        replyHandler([Envelope.replyPayload: localStatusJson()])
        return
      }
      guard deliveryEnabled else {
        replyHandler([StreamRegistry.Frame.err: "deliveryDisabled"])
        return
      }
      handleRequest(message, replyHandler: replyHandler)
    case Envelope.kindStream:
      let enabled = deliveryEnabled
      DispatchQueue.main.async {
        StreamRegistry.shared.handleOpen(
          message, deliveryEnabled: enabled, replyHandler: replyHandler)
      }
    default:
      handleInbound(message)
      replyHandler([:])
    }
  }

  /// Requests need a live Dart handler right now — the sender is waiting —
  /// so with no engine/handler bound they are rejected, never queued.
  private func handleRequest(
    _ message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard
      let path = message[Envelope.path] as? String,
      let payload = message[Envelope.payload] as? Data
    else {
      replyHandler([Envelope.replyError: "malformed"])
      return
    }
    let event = WearerEventDto(
      id: message[Envelope.id] as? String ?? UUID().uuidString,
      kind: .message,
      path: path,
      payload: FlutterStandardTypedData(bytes: payload),
      sourceNodeId: "watch",
      timestampMillis: message[Envelope.timestamp] as? Int64
        ?? Int64(Date().timeIntervalSince1970 * 1000),
      deliveredWhileDead: false)
    DispatchQueue.main.async {
      guard let handler = self.requestHandler else {
        replyHandler([Envelope.replyError: "noHandler"])
        return
      }
      handler(event) { result in
        switch result {
        case .success(let data):
          replyHandler([Envelope.replyPayload: data])
        case .failure(let error):
          replyHandler([Envelope.replyError: "\(error)"])
        }
      }
    }
  }

  func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    // One envelope per synced user path.
    for value in applicationContext.values {
      if let dictionary = value as? [String: Any] {
        handleInbound(dictionary)
      }
    }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    handleInbound(userInfo)
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    // The system deletes file.fileURL when this delegate returns — copy it
    // out synchronously before dispatching.
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("wearer_link", isDirectory: true)
    let metadata = file.metadata ?? [:]
    let id = metadata[Envelope.id] as? String ?? UUID().uuidString
    let dest = dir.appendingPathComponent(id)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.copyItem(at: file.fileURL, to: dest)
    } catch {
      return // nothing to deliver if the copy failed
    }
    if let path = metadata[Envelope.path] as? String,
      path.hasPrefix(Envelope.blobMarker) {
      // Oversized transferData that traveled as a file: back into bytes.
      guard let payload = try? Data(contentsOf: dest) else { return }
      try? FileManager.default.removeItem(at: dest)
      var restored = metadata
      restored[Envelope.path] = String(path.dropFirst(Envelope.blobMarker.count))
      restored[Envelope.payload] = payload
      restored[Envelope.kind] = Envelope.kindData
      handleInbound(restored)
      return
    }
    handleInbound(metadata, filePath: dest.path)
  }
}

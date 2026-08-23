import Foundation
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

  /// Set on the main thread by the plugin; called on the main thread.
  var liveDispatcher: ((WearerEventDto) -> Void)?

  /// Pushed on reachability/pairing changes while a plugin is bound.
  var statusListener: ((CompanionStatusDto) -> Void)?

  private override init() {
    super.init()
  }

  var isSupported: Bool { WCSession.isSupported() }

  func activate() {
    guard WCSession.isSupported() else { return }
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

  func syncData(path: String, payload: Data) throws {
    let session = WCSession.default
    // applicationContext is replaced wholesale; merge so each user path
    // keeps its own latest value.
    var context = session.applicationContext
    context[path] = envelope(path: path, payload: payload, kind: Envelope.kindData)
    try session.updateApplicationContext(context)
  }

  func transferData(path: String, payload: Data) {
    WCSession.default.transferUserInfo(
      envelope(path: path, payload: payload, kind: Envelope.kindData))
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

  private func handleInbound(_ dictionary: [String: Any]) {
    guard
      let path = dictionary[Envelope.path] as? String,
      let payload = dictionary[Envelope.payload] as? Data
    else { return }
    let kindRaw = dictionary[Envelope.kind] as? Int ?? Envelope.kindMessage
    let event = StoredEvent(
      id: dictionary[Envelope.id] as? String ?? UUID().uuidString,
      kindRaw: kindRaw,
      path: path,
      payload: payload,
      sourceNodeId: "watch",
      timestampMillis: dictionary[Envelope.timestamp] as? Int64
        ?? Int64(Date().timeIntervalSince1970 * 1000)
    )
    DispatchQueue.main.async {
      if let dispatcher = self.liveDispatcher {
        dispatcher(event.toDto(deliveredWhileDead: false))
      } else {
        PendingEventStore.shared.append(event)
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
    handleInbound(message)
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    handleInbound(message)
    replyHandler([:])
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
}

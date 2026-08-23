import Foundation
import WatchConnectivity

/// Watch-side counterpart of the wearer_link Flutter plugin.
///
/// Flutter does not run on watchOS, so the watch app is native Swift and
/// talks to the phone through this small library, which speaks the same
/// wire envelope as the plugin's iOS side.
///
/// Usage (SwiftUI):
/// ```swift
/// @main struct MyWatchApp: App {
///   init() {
///     WearerLinkWatch.shared.activate()
///     WearerLinkWatch.shared.onEvent = { event in print(event.path) }
///   }
///   var body: some Scene { WindowGroup { ContentView() } }
/// }
/// ```
public final class WearerLinkWatch: NSObject {

  public static let shared = WearerLinkWatch()

  /// An event received from the phone. Delivered on the main queue.
  public struct Event {
    public let id: String
    public let path: String
    public let payload: Data
    public let isDataEvent: Bool
    public let timestamp: Date
  }

  public enum WearerError: Error {
    case notActivated
    case phoneUnreachable
    case sendFailed(Error)
  }

  /// Called on the main queue for every message/data event from the phone.
  public var onEvent: ((Event) -> Void)?

  /// Called on the main queue when reachability to the phone changes.
  public var onReachabilityChange: ((Bool) -> Void)?

  // Events received before `onEvent` was assigned are buffered so nothing
  // is lost during app startup. Bounded to keep memory flat.
  private var buffered: [Event] = []
  private let bufferLimit = 200

  private override init() {
    super.init()
  }

  public var isReachable: Bool {
    WCSession.isSupported() && WCSession.default.isReachable
  }

  /// Activate the session. Call as early as possible (App.init) so
  /// background deliveries reach the app.
  public func activate() {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    if session.activationState != .activated {
      session.activate()
    }
  }

  // MARK: - Outbound

  /// Interactive message. If the phone app is killed, iOS launches it in
  /// the background to receive this — the sanctioned "wake the phone app"
  /// mechanism on this platform.
  public func sendMessage(
    path: String,
    payload: Data,
    completion: ((WearerError?) -> Void)? = nil
  ) {
    let session = WCSession.default
    guard session.activationState == .activated else {
      completion?(.notActivated)
      return
    }
    guard session.isReachable else {
      completion?(.phoneUnreachable)
      return
    }
    // Reply-handler round trip: exactly one completion, and success means
    // the phone actually received the message.
    session.sendMessage(
      envelope(path: path, payload: payload, kind: Envelope.kindMessage),
      replyHandler: { _ in
        DispatchQueue.main.async { completion?(nil) }
      },
      errorHandler: { error in
        DispatchQueue.main.async { completion?(.sendFailed(error)) }
      })
  }

  /// Latest-state sync; newest value per path wins. Delivered even when
  /// the phone is currently unreachable.
  public func syncData(path: String, payload: Data) throws {
    let session = WCSession.default
    var context = session.applicationContext
    context[path] = envelope(path: path, payload: payload, kind: Envelope.kindData)
    try session.updateApplicationContext(context)
  }

  /// Queued FIFO transfer; every call is delivered once the phone connects,
  /// launching the phone app in the background if needed.
  public func transferData(path: String, payload: Data) {
    WCSession.default.transferUserInfo(
      envelope(path: path, payload: payload, kind: Envelope.kindData))
  }

  /// Wake the phone app in the background (delivered as a data event on the
  /// reserved path "/wearer_link/wake"). iOS never lets a watch app bring
  /// the phone app on screen; this is the closest sanctioned behavior.
  public func wakePhoneApp() {
    transferData(path: "/wearer_link/wake", payload: Data())
  }

  // MARK: - Internals

  private func envelope(path: String, payload: Data, kind: Int) -> [String: Any] {
    [
      Envelope.path: path,
      Envelope.payload: payload,
      Envelope.kind: kind,
      Envelope.id: UUID().uuidString,
      Envelope.timestamp: Int64(Date().timeIntervalSince1970 * 1000),
    ]
  }

  private func handleInbound(_ dictionary: [String: Any]) {
    guard
      let path = dictionary[Envelope.path] as? String,
      let payload = dictionary[Envelope.payload] as? Data
    else { return }
    let millis = dictionary[Envelope.timestamp] as? Int64
      ?? Int64(Date().timeIntervalSince1970 * 1000)
    let event = Event(
      id: dictionary[Envelope.id] as? String ?? UUID().uuidString,
      path: path,
      payload: payload,
      isDataEvent: (dictionary[Envelope.kind] as? Int ?? 0) == Envelope.kindData,
      timestamp: Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    )
    DispatchQueue.main.async {
      if let handler = self.onEvent {
        // Flush anything buffered before the handler existed, in order.
        let backlog = self.buffered
        self.buffered.removeAll()
        backlog.forEach(handler)
        handler(event)
      } else {
        self.buffered.append(event)
        if self.buffered.count > self.bufferLimit {
          self.buffered.removeFirst(self.buffered.count - self.bufferLimit)
        }
      }
    }
  }

  /// Envelope keys shared with the plugin's iOS side.
  /// CONTRACT: mirrored in ios/Classes/WatchSessionBridge.swift.
  private enum Envelope {
    static let path = "p"
    static let payload = "d"
    static let kind = "k"
    static let id = "id"
    static let timestamp = "ts"
    static let kindMessage = 0
    static let kindData = 1
  }
}

// MARK: - WCSessionDelegate

extension WearerLinkWatch: WCSessionDelegate {

  public func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    DispatchQueue.main.async {
      self.onReachabilityChange?(session.isReachable)
    }
  }

  public func sessionReachabilityDidChange(_ session: WCSession) {
    DispatchQueue.main.async {
      self.onReachabilityChange?(session.isReachable)
    }
  }

  public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    handleInbound(message)
  }

  public func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    handleInbound(message)
    replyHandler([:])
  }

  public func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    for value in applicationContext.values {
      if let dictionary = value as? [String: Any] {
        handleInbound(dictionary)
      }
    }
  }

  public func session(
    _ session: WCSession,
    didReceiveUserInfo userInfo: [String: Any] = [:]
  ) {
    handleInbound(userInfo)
  }
}

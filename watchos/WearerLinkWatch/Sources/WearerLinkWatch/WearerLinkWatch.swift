// The library is watchOS-only; toolchains that also compile the package for
// the iOS side of a paired build get an empty module instead of a class that
// cannot satisfy iOS's stricter WCSessionDelegate requirements.
#if os(watchOS)

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

    /// For file transfers: local URL of the received file (in Caches — move
    /// it somewhere durable if needed). Nil for message/data events.
    public let fileURL: URL?
  }

  public enum WearerError: Error {
    case notActivated
    case phoneUnreachable
    case sendFailed(Error)
  }

  /// Called on the main queue for every message/data event from the phone.
  public var onEvent: ((Event) -> Void)?

  /// Answers `sendRequest` round trips from the phone. Called on the main
  /// queue; invoke `reply` exactly once with the response payload. While
  /// unset, phone requests fail with a noHandler error (never queued — the
  /// sender is waiting).
  public var onRequest: ((Event, @escaping (Data) -> Void) -> Void)?

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

  /// Request/response round trip: completes with the payload the phone's
  /// request handler returned.
  public func sendRequest(
    path: String,
    payload: Data,
    completion: @escaping (Result<Data, WearerError>) -> Void
  ) {
    let session = WCSession.default
    guard session.activationState == .activated else {
      completion(.failure(.notActivated))
      return
    }
    guard session.isReachable else {
      completion(.failure(.phoneUnreachable))
      return
    }
    session.sendMessage(
      envelope(path: path, payload: payload, kind: Envelope.kindRequest),
      replyHandler: { reply in
        DispatchQueue.main.async {
          if let data = reply[Envelope.replyPayload] as? Data {
            completion(.success(data))
          } else {
            let reason = reply[Envelope.replyError] as? String ?? "malformed reply"
            completion(.failure(.sendFailed(NSError(
              domain: "wearer_link", code: 1,
              userInfo: [NSLocalizedDescriptionKey: reason]))))
          }
        }
      },
      errorHandler: { error in
        DispatchQueue.main.async { completion(.failure(.sendFailed(error))) }
      })
  }

  /// Latest value the phone synced for [path], or nil.
  public func readSyncData(path: String) -> Data? {
    guard let dictionary = WCSession.default.receivedApplicationContext[path]
      as? [String: Any] else { return nil }
    return dictionary[Envelope.payload] as? Data
  }

  /// Remove the value this watch synced for [path].
  public func deleteSyncData(path: String) throws {
    let session = WCSession.default
    var context = session.applicationContext
    if context.removeValue(forKey: path) != nil {
      try session.updateApplicationContext(context)
    }
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

  /// Transfer a file to the phone (queued; delivered even if the phone app
  /// is killed — it is background-launched, and the plugin surfaces the file
  /// on the Dart `fileEvents` stream).
  public func transferFile(path: String, fileURL: URL) {
    var metadata = envelope(path: path, payload: Data(), kind: Envelope.kindFile)
    metadata.removeValue(forKey: Envelope.payload)
    WCSession.default.transferFile(fileURL, metadata: metadata)
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

  private func handleInbound(_ dictionary: [String: Any], fileURL: URL? = nil) {
    guard let path = dictionary[Envelope.path] as? String else { return }
    let payload = dictionary[Envelope.payload] as? Data
    if payload == nil && fileURL == nil { return }
    let millis = dictionary[Envelope.timestamp] as? Int64
      ?? Int64(Date().timeIntervalSince1970 * 1000)
    let event = Event(
      id: dictionary[Envelope.id] as? String ?? UUID().uuidString,
      path: path,
      payload: payload ?? Data(),
      isDataEvent: (dictionary[Envelope.kind] as? Int ?? 0) == Envelope.kindData,
      timestamp: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
      fileURL: fileURL
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
    static let kindFile = 2
    static let kindRequest = 3

    static let replyPayload = "d"
    static let replyError = "err"
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
    if (message[Envelope.kind] as? Int) == Envelope.kindRequest {
      guard
        let path = message[Envelope.path] as? String,
        let payload = message[Envelope.payload] as? Data
      else {
        replyHandler([Envelope.replyError: "malformed"])
        return
      }
      let millis = message[Envelope.timestamp] as? Int64
        ?? Int64(Date().timeIntervalSince1970 * 1000)
      let event = Event(
        id: message[Envelope.id] as? String ?? UUID().uuidString,
        path: path,
        payload: payload,
        isDataEvent: false,
        timestamp: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
        fileURL: nil
      )
      DispatchQueue.main.async {
        guard let handler = self.onRequest else {
          replyHandler([Envelope.replyError: "noHandler"])
          return
        }
        handler(event) { data in
          replyHandler([Envelope.replyPayload: data])
        }
      }
      return
    }
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

  public func session(_ session: WCSession, didReceive file: WCSessionFile) {
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
    handleInbound(metadata, fileURL: dest)
  }
}

#endif  // os(watchOS)

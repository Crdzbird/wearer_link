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
/// A live bidirectional byte stream to the phone, framed over interactive
/// messages (needs the phone reachable for its whole lifetime).
public final class WatchStream {
  public let id: String
  public let path: String

  /// Bytes from the phone, on the main queue.
  public var onData: ((Data) -> Void)?

  /// Stream ended; nil reason means an orderly close. Main queue.
  public var onClose: ((String?) -> Void)?

  init(id: String, path: String) {
    self.id = id
    self.path = path
  }

  /// Send bytes (chunked internally). Errors tear the stream down.
  public func send(_ data: Data) {
    WearerLinkWatch.shared.streamSend(id: id, data: data)
  }

  public func close() {
    WearerLinkWatch.shared.streamClose(id: id, notifyPeer: true, error: nil)
  }
}

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

  /// Streams the phone opened toward the watch. While unset, opens are
  /// refused. Main queue.
  public var onIncomingStream: ((WatchStream) -> Void)?

  // Open streams by id. Main-queue confined.
  private var streams: [String: WatchStream] = [:]

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
    if payload.count > Envelope.maxMessageBytes {
      // Too big for one transfer: travel as a file, arrive as a data event.
      let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("wearer_blob_\(UUID().uuidString)")
      guard (try? payload.write(to: temp)) != nil else { return }
      transferFile(path: Envelope.blobMarker + path, fileURL: temp)
      return
    }
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

  /// Open a bidirectional stream to the phone. The phone must be reachable
  /// and have a listener on `WearerLink.instance.incomingStreams`.
  public func openStream(
    path: String,
    completion: @escaping (Result<WatchStream, WearerError>) -> Void
  ) {
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable else {
      completion(.failure(.phoneUnreachable))
      return
    }
    let id = UUID().uuidString
    session.sendMessage(
      Frame.open(id: id, path: path),
      replyHandler: { reply in
        DispatchQueue.main.async {
          if reply[Frame.ok] != nil {
            let stream = WatchStream(id: id, path: path)
            self.streams[id] = stream
            completion(.success(stream))
          } else {
            let reason = reply[Frame.err] as? String ?? "rejected"
            completion(.failure(.sendFailed(NSError(
              domain: "wearer_link", code: 2,
              userInfo: [NSLocalizedDescriptionKey: reason]))))
          }
        }
      },
      errorHandler: { error in
        DispatchQueue.main.async { completion(.failure(.sendFailed(error))) }
      })
  }

  fileprivate func streamSend(id: String, data: Data) {
    guard streams[id] != nil else { return }
    var offset = 0
    while offset < data.count {
      let end = min(offset + Frame.chunkBytes, data.count)
      let chunk = data.subdata(in: offset..<end)
      WCSession.default.sendMessage(
        Frame.data(id: id, chunk: chunk),
        replyHandler: nil,
        errorHandler: { [weak self] error in
          DispatchQueue.main.async {
            self?.streamClose(id: id, notifyPeer: false, error: "\(error)")
          }
        })
      offset = end
    }
  }

  fileprivate func streamClose(id: String, notifyPeer: Bool, error: String?) {
    guard let stream = streams.removeValue(forKey: id) else { return }
    if notifyPeer && WCSession.default.isReachable {
      WCSession.default.sendMessage(
        Frame.close(id: id), replyHandler: nil, errorHandler: { _ in })
    }
    stream.onClose?(error)
  }

  private func handleStreamOpen(
    _ message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard
      let id = message[Frame.sid] as? String,
      let path = message[Frame.path] as? String
    else {
      replyHandler([Frame.err: "malformed"])
      return
    }
    DispatchQueue.main.async {
      guard let accept = self.onIncomingStream else {
        replyHandler([Frame.err: "noListener"])
        return
      }
      let stream = WatchStream(id: id, path: path)
      self.streams[id] = stream
      replyHandler([Frame.ok: 1])
      accept(stream)
    }
  }

  private func handleStreamFrame(_ message: [String: Any]) {
    guard
      let id = message[Frame.sid] as? String,
      let op = message[Frame.op] as? String
    else { return }
    DispatchQueue.main.async {
      switch op {
      case Frame.opData:
        if let chunk = message[Frame.chunk] as? Data {
          self.streams[id]?.onData?(chunk)
        }
      case Frame.opClose:
        self.streamClose(id: id, notifyPeer: false, error: nil)
      default:
        break
      }
    }
  }

  /// Stream frame wire format. CONTRACT: mirrored in the plugin's iOS side.
  private enum Frame {
    static let chunkBytes = 56 * 1024
    static let op = "op"
    static let sid = "sid"
    static let path = "p"
    static let chunk = "d"
    static let ok = "ok"
    static let err = "err"
    static let opOpen = "o"
    static let opData = "d"
    static let opClose = "c"

    static func base(op operation: String, id: String) -> [String: Any] {
      ["k": Envelope.kindStream, sid: id, op: operation]
    }

    static func open(id: String, path streamPath: String) -> [String: Any] {
      var frame = base(op: opOpen, id: id)
      frame[path] = streamPath
      return frame
    }

    static func data(id: String, chunk bytes: Data) -> [String: Any] {
      var frame = base(op: opData, id: id)
      frame[chunk] = bytes
      return frame
    }

    static func close(id: String) -> [String: Any] {
      base(op: opClose, id: id)
    }
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
    static let kindStream = 4

    static let replyPayload = "d"
    static let replyError = "err"

    /// Oversized transferData marker. CONTRACT: mirrored on iOS/Android.
    static let blobMarker = "/__wlblob"
    static let maxMessageBytes = 56 * 1024
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
    if (message[Envelope.kind] as? Int) == Envelope.kindStream {
      handleStreamFrame(message)
      return
    }
    handleInbound(message)
  }

  public func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    if (message[Envelope.kind] as? Int) == Envelope.kindStream {
      handleStreamOpen(message, replyHandler: replyHandler)
      return
    }
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
    handleInbound(metadata, fileURL: dest)
  }
}

#endif  // os(watchOS)

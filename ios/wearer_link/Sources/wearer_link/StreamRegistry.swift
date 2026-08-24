import Foundation
import WatchConnectivity

/// Bidirectional streams emulated over interactive messages (WCSession has
/// no socket primitive). Frames: kind=stream + op open/data/close + stream
/// id. Frame delivery relies on sendMessage FIFO ordering; any transport
/// error tears the stream down. Streams need a live listener — with none
/// bound (or delivery disabled) inbound opens are refused.
final class StreamRegistry {
  static let shared = StreamRegistry()

  /// Chunk bound for one data frame (WCSession message budget ~64KB).
  static let chunkBytes = 56 * 1024

  /// Stream lifecycle listener, bound by the plugin. Main thread.
  var onOpened: ((String, String, String, Bool) -> Void)?
  var onData: ((String, Data) -> Void)?
  var onClosed: ((String, String?) -> Void)?

  /// Paths of currently open streams by id. Main-thread confined.
  private var open: [String: String] = [:]

  private init() {}

  var hasListener: Bool { onOpened != nil }

  // MARK: - Outbound

  func openStream(path: String, completion: @escaping (Result<String, Error>) -> Void) {
    let session = WCSession.default
    guard session.activationState == .activated, session.isReachable else {
      completion(.failure(PigeonError(
        code: "unreachable",
        message: "Counterpart is not reachable for streams.", details: nil)))
      return
    }
    let id = UUID().uuidString
    session.sendMessage(
      Frame.open(id: id, path: path),
      replyHandler: { reply in
        DispatchQueue.main.async {
          if reply[Frame.ok] != nil {
            self.open[id] = path
            self.onOpened?(id, path, "watch", false)
            completion(.success(id))
          } else {
            let reason = reply[Frame.err] as? String ?? "rejected"
            completion(.failure(PigeonError(
              code: "sendFailed",
              message: "Counterpart refused the stream: \(reason)", details: nil)))
          }
        }
      },
      errorHandler: { error in
        DispatchQueue.main.async {
          completion(.failure(PigeonError(
            code: "sendFailed", message: "\(error)", details: nil)))
        }
      })
  }

  func send(id: String, data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
    guard open[id] != nil else {
      completion(.failure(PigeonError(
        code: "sendFailed", message: "Stream \(id) is not open.", details: nil)))
      return
    }
    var offset = 0
    while offset < data.count {
      let end = min(offset + Self.chunkBytes, data.count)
      let chunk = data.subdata(in: offset..<end)
      WCSession.default.sendMessage(
        Frame.data(id: id, chunk: chunk),
        replyHandler: nil,
        errorHandler: { [weak self] error in
          DispatchQueue.main.async { self?.tearDown(id: id, error: "\(error)") }
        })
      offset = end
    }
    completion(.success(()))
  }

  func close(id: String) {
    guard open.removeValue(forKey: id) != nil else { return }
    if WCSession.default.isReachable {
      WCSession.default.sendMessage(
        Frame.close(id: id), replyHandler: nil, errorHandler: { _ in })
    }
    onClosed?(id, nil)
  }

  func closeAll() {
    for id in Array(open.keys) { close(id: id) }
  }

  // MARK: - Inbound (from the session delegate; called on main)

  func handleOpen(
    _ message: [String: Any],
    deliveryEnabled: Bool,
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard
      let id = message[Frame.sid] as? String,
      let path = message[Frame.path] as? String
    else {
      replyHandler([Frame.err: "malformed"])
      return
    }
    guard hasListener, deliveryEnabled else {
      replyHandler([Frame.err: deliveryEnabled ? "noListener" : "deliveryDisabled"])
      return
    }
    open[id] = path
    onOpened?(id, path, "watch", true)
    replyHandler([Frame.ok: 1])
  }

  func handleFrame(_ message: [String: Any]) {
    guard
      let id = message[Frame.sid] as? String,
      let op = message[Frame.op] as? String
    else { return }
    switch op {
    case Frame.opData:
      guard open[id] != nil, let chunk = message[Frame.chunk] as? Data else { return }
      onData?(id, chunk)
    case Frame.opClose:
      if open.removeValue(forKey: id) != nil {
        onClosed?(id, nil)
      }
    default:
      break
    }
  }

  private func tearDown(id: String, error: String) {
    guard open.removeValue(forKey: id) != nil else { return }
    onClosed?(id, error)
  }

  /// Stream frame wire format.
  /// CONTRACT: mirrored in watchos/WearerLinkWatch.
  enum Frame {
    static let kindStream = 4
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
      ["k": kindStream, sid: id, op: operation]
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
}

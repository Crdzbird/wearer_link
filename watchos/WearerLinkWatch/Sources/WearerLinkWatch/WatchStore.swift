#if os(watchOS)

import Foundation
import WatchConnectivity

/// Native accessor for the wearer_link synced key-value store — the same
/// keys the Flutter side reads and writes through `WearerLink.store`.
///
/// Semantics mirror the Dart store: last-writer-wins by sender timestamp
/// (stable per-endpoint tiebreak), tombstoned deletes, values persisted by
/// WatchConnectivity's application context (survive restarts and offline
/// gaps). Values are capped at 48KB — store state, not payloads.
///
/// Obtain via `WearerLinkWatch.shared.store`.
public final class WatchStore {

  static let pathPrefix = "/__wlstore/"
  static let maxValueBytes = 48 * 1024

  /// Fired on the main queue when the phone's write for a key is accepted
  /// (nil value = deleted).
  public var onChange: ((String, Data?) -> Void)?

  private let writerId: String
  private var cache: [String: Record] = [:]
  private var cachedKeys = Set<String>()
  private let sync: (String, Data) throws -> Void

  init(sync: @escaping (String, Data) throws -> Void) {
    self.sync = sync
    let key = "wearer_link_store_writer"
    if let existing = UserDefaults.standard.string(forKey: key) {
      writerId = existing
    } else {
      let fresh = UUID().uuidString
      UserDefaults.standard.set(fresh, forKey: key)
      writerId = fresh
    }
  }

  /// Write [value] for [key]; the phone's watchers see it too.
  public func set(_ key: String, _ value: Data) throws {
    try checkKey(key)
    guard value.count <= Self.maxValueBytes else {
      throw NSError(
        domain: "wearer_link", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Store values are capped at \(Self.maxValueBytes) bytes"
        ])
    }
    let record = Record(
      timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
      writerId: writerId, deleted: false, value: value)
    try sync(Self.pathPrefix + key, record.encode())
    apply(key, record)
  }

  /// Delete [key] on both sides (propagates as a tombstone).
  public func delete(_ key: String) throws {
    try checkKey(key)
    let record = Record(
      timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
      writerId: writerId, deleted: true, value: nil)
    try sync(Self.pathPrefix + key, record.encode())
    apply(key, record)
  }

  /// Current value for [key], or nil when absent/deleted.
  public func get(_ key: String) -> Data? {
    guard let record = resolve(key), !record.deleted else { return nil }
    return record.value
  }

  /// Keys currently present (tombstoned keys excluded).
  public func keys() -> [String] {
    let session = WCSession.default
    var paths = Set(session.applicationContext.keys)
      .union(session.receivedApplicationContext.keys)
      .filter { $0.hasPrefix(Self.pathPrefix) }
      .map { String($0.dropFirst(Self.pathPrefix.count)) }
    paths.removeAll { get($0) == nil }
    return paths
  }

  /// Internal: an inbound phone record (routed by WearerLinkWatch).
  func applyRemote(path: String, payload: Data) {
    let key = String(path.dropFirst(Self.pathPrefix.count))
    guard let record = Record.decode(payload) else { return }
    apply(key, record)
  }

  // MARK: - internals

  private func apply(_ key: String, _ record: Record) {
    if let current = cache[key], !record.wins(over: current) { return }
    cache[key] = record
    cachedKeys.insert(key)
    DispatchQueue.main.async {
      self.onChange?(key, record.deleted ? nil : record.value)
    }
  }

  private func resolve(_ key: String) -> Record? {
    if cachedKeys.contains(key) { return cache[key] }
    let session = WCSession.default
    let path = Self.pathPrefix + key
    let own = Record.decode(payload(of: session.applicationContext[path]))
    let theirs = Record.decode(payload(of: session.receivedApplicationContext[path]))
    let winner: Record?
    switch (own, theirs) {
    case (nil, let t): winner = t
    case (let o, nil): winner = o
    case (let o?, let t?): winner = t.wins(over: o) ? t : o
    }
    if let winner { apply(key, winner) }
    cachedKeys.insert(key)
    return cache[key]
  }

  /// Store records travel inside the normal sync envelope; "d" holds them.
  private func payload(of envelope: Any?) -> Data? {
    (envelope as? [String: Any])?["d"] as? Data
  }

  private func checkKey(_ key: String) throws {
    guard !key.isEmpty, !key.contains("/") else {
      throw NSError(
        domain: "wearer_link", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Store keys must be non-empty, without '/'"])
    }
  }

  /// One store record on the wire: JSON {t, n, d, v(base64)}.
  /// CONTRACT: mirrored by the Dart store and the Android tile recipe.
  struct Record {
    let timestampMillis: Int64
    let writerId: String
    let deleted: Bool
    let value: Data?

    func wins(over other: Record) -> Bool {
      timestampMillis > other.timestampMillis
        || (timestampMillis == other.timestampMillis && writerId > other.writerId)
    }

    func encode() -> Data {
      var json: [String: Any] = ["t": timestampMillis, "n": writerId, "d": deleted]
      if let value { json["v"] = value.base64EncodedString() }
      return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    static func decode(_ payload: Data?) -> Record? {
      guard
        let payload,
        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
        let timestamp = json["t"] as? Int64 ?? (json["t"] as? Int).map(Int64.init)
      else { return nil }
      let encoded = json["v"] as? String
      return Record(
        timestampMillis: timestamp,
        writerId: json["n"] as? String ?? "",
        deleted: json["d"] as? Bool ?? false,
        value: encoded.flatMap { Data(base64Encoded: $0) })
    }
  }
}

#endif  // os(watchOS)

import Flutter
import Foundation

/// Cross-restart delivery counters backing getPersistentStats.
final class StatsStore {
  static let shared = StatsStore()

  static let keyReceived = "wearer_link_stats_received"
  static let keyQueued = "wearer_link_stats_queued"
  static let keyDrained = "wearer_link_stats_drained"
  static let keyBackground = "wearer_link_stats_background"
  private static let keySince = "wearer_link_stats_since"

  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "com.crdzbird.wearer_link.stats")

  func increment(_ key: String, by amount: Int = 1) {
    queue.sync {
      ensureEpoch()
      defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }
  }

  func snapshot() -> PersistentStatsDto {
    queue.sync {
      ensureEpoch()
      return PersistentStatsDto(
        receivedTotal: Int64(defaults.integer(forKey: Self.keyReceived)),
        queuedWhileDead: Int64(defaults.integer(forKey: Self.keyQueued)),
        drained: Int64(defaults.integer(forKey: Self.keyDrained)),
        backgroundHandled: Int64(defaults.integer(forKey: Self.keyBackground)),
        sinceMillis: Int64(
          defaults.object(forKey: Self.keySince) as? Double
            ?? Date().timeIntervalSince1970 * 1000))
    }
  }

  func reset() {
    queue.sync {
      for key in [Self.keyReceived, Self.keyQueued, Self.keyDrained, Self.keyBackground] {
        defaults.removeObject(forKey: key)
      }
      defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Self.keySince)
    }
  }

  private func ensureEpoch() {
    if defaults.object(forKey: Self.keySince) == nil {
      defaults.set(Date().timeIntervalSince1970 * 1000, forKey: Self.keySince)
    }
  }
}

/// Bounded persistent FIFO for events that arrive while no Flutter engine is
/// attached (background launch triggered by the watch). Mirrors the Android
/// PendingEventStore semantics: replayed and cleared on next app launch.
final class PendingEventStore {
  static let shared = PendingEventStore()

  private let defaults = UserDefaults.standard
  private let key = "wearer_link_pending_queue"
  private let maxEvents = 200
  private let queue = DispatchQueue(label: "com.crdzbird.wearer_link.pending")

  func append(_ event: StoredEvent) {
    queue.sync {
      var events = readAll()
      events.append(event)
      if events.count > maxEvents {
        events.removeFirst(events.count - maxEvents)
      }
      write(events)
    }
  }

  /// Drop one event by id — called after a background isolate acked it.
  func remove(id: String) {
    queue.sync {
      let events = readAll()
      let kept = events.filter { $0.id != id }
      if kept.count != events.count { write(kept) }
    }
  }

  func drain() -> [StoredEvent] {
    queue.sync {
      let events = readAll()
      defaults.removeObject(forKey: key)
      return events
    }
  }

  private func readAll() -> [StoredEvent] {
    guard let data = defaults.data(forKey: key) else { return [] }
    // A corrupt queue must never brick startup; drop it.
    return (try? JSONDecoder().decode([StoredEvent].self, from: data)) ?? []
  }

  private func write(_ events: [StoredEvent]) {
    if let data = try? JSONEncoder().encode(events) {
      defaults.set(data, forKey: key)
    }
  }
}

/// Codable twin of WearerEventDto (the Pigeon struct isn't Codable).
struct StoredEvent: Codable {
  let id: String
  let kindRaw: Int
  let path: String
  let payload: Data
  let sourceNodeId: String
  let timestampMillis: Int64
  var filePath: String? = nil

  func toDto(deliveredWhileDead: Bool) -> WearerEventDto {
    WearerEventDto(
      id: id,
      kind: WearerEventKindDto(rawValue: kindRaw) ?? .message,
      path: path,
      payload: FlutterStandardTypedData(bytes: payload),
      sourceNodeId: sourceNodeId,
      timestampMillis: timestampMillis,
      deliveredWhileDead: deliveredWhileDead,
      filePath: filePath
    )
  }
}

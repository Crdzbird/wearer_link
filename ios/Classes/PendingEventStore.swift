import Foundation

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

  func toDto(deliveredWhileDead: Bool) -> WearerEventDto {
    WearerEventDto(
      id: id,
      kind: WearerEventKindDto(rawValue: kindRaw) ?? .message,
      path: path,
      payload: FlutterStandardTypedData(bytes: payload),
      sourceNodeId: sourceNodeId,
      timestampMillis: timestampMillis,
      deliveredWhileDead: deliveredWhileDead
    )
  }
}

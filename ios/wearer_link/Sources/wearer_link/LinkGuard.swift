import Foundation

/// Decides whether traffic belongs to this app's link (M9.2).
///
/// The failures this guards are the ones bundle scoping does not catch: the
/// same identifier on a different build (TestFlight talking to App Store)
/// and protocol drift between app versions.
///
/// INVARIANT: every decision is made from persisted state only, so the same
/// verdict is reached during a background launch with no Flutter engine.
///
/// CONTRACT: mirrors android/.../LinkGuard.kt — keep the policy identical.
enum LinkGuard {

  private static let keyStrict = "wearer_link.guard.strict"
  private static let prefixLinkId = "wearer_link.guard.peer.lid."
  private static let prefixVersion = "wearer_link.guard.peer.pv."

  /// A counterpart's declared identity, as last observed.
  struct Known {
    let linkId: String
    let protocolVersion: Int64
  }

  static var isStrict: Bool {
    UserDefaults.standard.bool(forKey: keyStrict)
  }

  static func setStrict(_ strict: Bool) {
    UserDefaults.standard.set(strict, forKey: keyStrict)
  }

  /// Records what a counterpart declared, from a handshake reply or a
  /// labelled event. Persisted so a background launch can still check it.
  static func remember(nodeId: String, linkId: String, protocolVersion: Int64) {
    guard !nodeId.isEmpty else { return }
    let defaults = UserDefaults.standard
    defaults.set(linkId, forKey: prefixLinkId + nodeId)
    defaults.set(NSNumber(value: protocolVersion), forKey: prefixVersion + nodeId)
  }

  static func known(nodeId: String) -> Known? {
    guard !nodeId.isEmpty,
          let linkId = UserDefaults.standard.string(forKey: prefixLinkId + nodeId)
    else { return nil }
    let version = (UserDefaults.standard.object(forKey: prefixVersion + nodeId)
      as? NSNumber)?.int64Value ?? 0
    return Known(linkId: linkId, protocolVersion: version)
  }

  /// Whether an inbound event may be delivered.
  ///
  /// Lenient (default): refuse only what is positively known to be foreign —
  /// an unlabelled or not-yet-seen peer is accepted, because a pre-2.2
  /// counterpart cannot label itself and breaking it silently would be worse
  /// than the problem being solved.
  /// Strict: require a positive match; unverified traffic is refused.
  static func accepts(_ event: WearerEventDto) -> Bool {
    let ours = LinkIdentity.resolve().linkId
    // A per-event label wins; otherwise fall back to what the handshake
    // taught us about this node.
    let theirs = event.linkId ?? known(nodeId: event.sourceNodeId)?.linkId
    guard let theirs else { return !isStrict }
    return theirs == ours
  }

  /// Applies `accepts`, learning from a labelled event on the way through.
  /// Returns false when the caller should drop the event; the rejection is
  /// counted so getPersistentStats can show it.
  static func admit(_ event: WearerEventDto) -> Bool {
    guard accepts(event) else {
      StatsStore.shared.increment(StatsStore.keyRejected)
      return false
    }
    if let linkId = event.linkId {
      remember(
        nodeId: event.sourceNodeId,
        linkId: linkId,
        protocolVersion: event.protocolVersion ?? 0)
    }
    return true
  }

  /// Guards an outbound interactive send, throwing rather than letting a
  /// payload cross into a foreign app build.
  static func requireCompatible(nodeId: String) throws {
    let ours = LinkIdentity.resolve().linkId
    guard let peer = known(nodeId: nodeId) else {
      if !isStrict { return } // never handshaked; lenient lets it try
      throw PigeonError(
        code: "linkMismatch",
        message: "Strict link identity: the watch has not proved its identity "
          + "yet — call getCounterpartIdentity() first.",
        details: nil)
    }
    if peer.linkId != ours {
      throw PigeonError(
        code: "linkMismatch",
        message: "Counterpart declares link id '\(peer.linkId)', "
          + "this app is '\(ours)'.",
        details: nil)
    }
  }

  /// True when the node is known and declares a different link id.
  static func isKnownMismatch(nodeId: String) -> Bool {
    guard let peer = known(nodeId: nodeId) else { return false }
    return peer.linkId != LinkIdentity.resolve().linkId
  }
}

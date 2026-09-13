import Foundation

/// Resolves who this side of the link claims to be.
///
/// INVARIANT: must work with no Flutter engine attached. WatchConnectivity
/// background-launches the app to deliver events, so identity resolves from
/// Info.plist and UserDefaults — never from a Dart-held value.
///
/// Precedence: configureLink override (persisted) > Info.plist > bundle id.
enum LinkIdentity {

  static let plistLinkId = "WearerLinkId"
  static let plistProtocolVersion = "WearerLinkProtocolVersion"

  private static let defaultsLinkId = "wearer_link.identity.linkId"
  private static let defaultsProtocolVersion = "wearer_link.identity.protocolVersion"

  /// Protocol version reported when the app never declared one.
  static let undeclaredVersion: Int64 = 0

  static func resolve() -> LinkIdentityDto {
    let defaults = UserDefaults.standard

    let overrideId = defaults.string(forKey: defaultsLinkId)
    let plistId = Bundle.main.object(forInfoDictionaryKey: plistLinkId) as? String
    let linkId = overrideId
      ?? plistId
      ?? Bundle.main.bundleIdentifier
      ?? "unknown"

    let overrideVersion = defaults.object(forKey: defaultsProtocolVersion) as? NSNumber
    let plistVersion = plistProtocolVersionValue()
    let version = overrideVersion?.int64Value ?? plistVersion ?? undeclaredVersion

    let isExplicit = overrideId != nil
      || plistId != nil
      || overrideVersion != nil
      || plistVersion != nil

    return LinkIdentityDto(
      linkId: linkId,
      protocolVersion: version,
      isExplicit: isExplicit)
  }

  /// Persists an override so later cold starts resolve the same values.
  @discardableResult
  static func configure(linkId: String?, protocolVersion: Int64?) -> LinkIdentityDto {
    let defaults = UserDefaults.standard
    if let linkId {
      defaults.set(linkId, forKey: defaultsLinkId)
    }
    if let protocolVersion {
      defaults.set(NSNumber(value: protocolVersion), forKey: defaultsProtocolVersion)
    }
    return resolve()
  }

  /// An <integer> in Info.plist arrives as NSNumber, a <string> as String —
  /// accept both rather than silently defaulting a declared version to 0.
  private static func plistProtocolVersionValue() -> Int64? {
    switch Bundle.main.object(forInfoDictionaryKey: plistProtocolVersion) {
    case let number as NSNumber: return number.int64Value
    case let text as String: return Int64(text)
    default: return nil
    }
  }
}

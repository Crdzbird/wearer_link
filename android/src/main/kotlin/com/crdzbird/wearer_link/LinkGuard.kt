package com.crdzbird.wearer_link

import android.content.Context

/**
 * Decides whether traffic belongs to this app's link (M9.2).
 *
 * The failures this guards are the ones package/bundle scoping does not
 * catch: the same identifier on a different build (debug talking to prod)
 * and protocol drift between app versions.
 *
 * INVARIANT: every decision is made from persisted state only, so the same
 * verdict is reached while the app is dead and the listener service is the
 * only thing running.
 */
object LinkGuard {

  private const val PREFS = "wearer_link_guard"
  private const val KEY_STRICT = "strict"
  private const val PREFIX_LINK_ID = "peer_lid_"
  private const val PREFIX_VERSION = "peer_pv_"

  /** A counterpart's declared identity, as last observed. */
  data class Known(val linkId: String, val protocolVersion: Long)

  fun isStrict(context: Context): Boolean =
    prefs(context).getBoolean(KEY_STRICT, false)

  fun setStrict(context: Context, strict: Boolean) {
    prefs(context).edit().putBoolean(KEY_STRICT, strict).apply()
  }

  /**
   * Records what a counterpart declared, from a handshake reply or a
   * labelled event. Persisted so the dead-app path can still check it.
   */
  fun remember(context: Context, nodeId: String, linkId: String, protocolVersion: Long) {
    if (nodeId.isEmpty()) return
    prefs(context).edit()
      .putString(PREFIX_LINK_ID + nodeId, linkId)
      .putLong(PREFIX_VERSION + nodeId, protocolVersion)
      .apply()
  }

  fun known(context: Context, nodeId: String): Known? {
    if (nodeId.isEmpty()) return null
    val p = prefs(context)
    val linkId = p.getString(PREFIX_LINK_ID + nodeId, null) ?: return null
    return Known(linkId, p.getLong(PREFIX_VERSION + nodeId, 0L))
  }

  /**
   * Whether an inbound event may be delivered.
   *
   * Lenient (default): refuse only what is positively known to be foreign —
   * an unlabelled or not-yet-seen peer is accepted, because a pre-2.2
   * counterpart cannot label itself and breaking it silently would be worse
   * than the problem being solved.
   * Strict: require a positive match; unverified traffic is refused.
   */
  fun accepts(context: Context, event: WearerEventDto): Boolean {
    val ours = LinkIdentity.resolve(context).linkId
    // A per-event label wins; otherwise fall back to what the handshake
    // taught us about this node, which is the only signal available on
    // transports with no metadata room (Android messages/requests/files).
    val theirs = event.linkId ?: known(context, event.sourceNodeId)?.linkId
    if (theirs == null) return !isStrict(context)
    return theirs == ours
  }

  /**
   * Applies [accepts], learning from a labelled event on the way through.
   * Returns false when the caller should drop the event; the rejection is
   * counted so getPersistentStats can show it.
   */
  fun admit(context: Context, event: WearerEventDto): Boolean {
    val accepted = accepts(context, event)
    if (accepted) {
      val linkId = event.linkId
      if (linkId != null) {
        remember(context, event.sourceNodeId, linkId, event.protocolVersion ?: 0L)
      }
      return true
    }
    StatsStore.increment(context, StatsStore.KEY_REJECTED)
    return false
  }

  /**
   * Guards an outbound interactive send to [nodeId], throwing rather than
   * letting a payload cross into a foreign app build.
   */
  fun requireCompatible(context: Context, nodeId: String) {
    val ours = LinkIdentity.resolve(context).linkId
    val peer = known(context, nodeId)
    if (peer == null) {
      if (!isStrict(context)) return // never handshaked; lenient lets it try
      throw FlutterError(
        "linkMismatch",
        "Strict link identity: $nodeId has not proved its identity yet — " +
          "call getCounterpartIdentity() first.",
        null,
      )
    }
    if (peer.linkId != ours) {
      throw FlutterError(
        "linkMismatch",
        "Counterpart $nodeId declares link id '${peer.linkId}', this app is '$ours'.",
        null,
      )
    }
  }

  /** True when [nodeId] is known and declares a different link id. */
  fun isKnownMismatch(context: Context, nodeId: String): Boolean {
    val peer = known(context, nodeId) ?: return false
    return peer.linkId != LinkIdentity.resolve(context).linkId
  }

  private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

package com.crdzbird.wearer_link

import android.content.Context
import android.content.pm.PackageManager

/**
 * Resolves who this side of the link claims to be.
 *
 * INVARIANT: must work with no Flutter engine attached. Events arrive while
 * the app is dead, so the receive path resolves identity from the manifest
 * and SharedPreferences — never from a Dart-held value.
 *
 * Precedence: configureLink override (persisted) > manifest meta-data >
 * package name.
 */
object LinkIdentity {

  const val METADATA_LINK_ID = "com.crdzbird.wearer_link.linkId"
  const val METADATA_PROTOCOL_VERSION = "com.crdzbird.wearer_link.protocolVersion"

  private const val PREFS = "wearer_link_identity"
  private const val KEY_LINK_ID = "link_id"
  private const val KEY_PROTOCOL_VERSION = "protocol_version"

  /** Protocol version reported when the app never declared one. */
  const val UNDECLARED_VERSION = 0L

  fun resolve(context: Context): LinkIdentityDto {
    val prefs = prefs(context)
    val metaData = metaData(context)

    val overrideId = prefs.getString(KEY_LINK_ID, null)
    val manifestId = metaData?.getString(METADATA_LINK_ID)
    val linkId = overrideId ?: manifestId ?: context.packageName

    val overrideVersion =
      if (prefs.contains(KEY_PROTOCOL_VERSION)) {
        prefs.getLong(KEY_PROTOCOL_VERSION, UNDECLARED_VERSION)
      } else {
        null
      }
    val protocolVersion =
      overrideVersion ?: manifestVersion(metaData) ?: UNDECLARED_VERSION

    val isExplicit = overrideId != null ||
      manifestId != null ||
      overrideVersion != null ||
      manifestVersion(metaData) != null

    return LinkIdentityDto(linkId, protocolVersion, isExplicit)
  }

  /** Persists an override so later cold starts resolve the same values. */
  fun configure(
    context: Context,
    linkId: String?,
    protocolVersion: Long?,
  ): LinkIdentityDto {
    prefs(context).edit().apply {
      if (linkId != null) putString(KEY_LINK_ID, linkId)
      if (protocolVersion != null) putLong(KEY_PROTOCOL_VERSION, protocolVersion)
      apply()
    }
    return resolve(context)
  }

  private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun metaData(context: Context) = try {
    context.applicationContext.packageManager.getApplicationInfo(
      context.packageName,
      PackageManager.GET_META_DATA,
    ).metaData
  } catch (_: PackageManager.NameNotFoundException) {
    null
  }

  /**
   * android:value="3" is stored as an Integer, but a value written as a
   * string resource or with a leading zero arrives as a String — accept both
   * rather than silently defaulting a declared version to 0.
   */
  private fun manifestVersion(metaData: android.os.Bundle?): Long? {
    if (metaData == null || !metaData.containsKey(METADATA_PROTOCOL_VERSION)) {
      return null
    }
    return when (val raw = metaData.get(METADATA_PROTOCOL_VERSION)) {
      is Int -> raw.toLong()
      is Long -> raw
      is String -> raw.toLongOrNull()
      else -> null
    }
  }
}

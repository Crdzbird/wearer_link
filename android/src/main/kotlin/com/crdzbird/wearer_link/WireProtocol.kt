package com.crdzbird.wearer_link

/**
 * On-the-wire namespacing over the Data Layer so wearer_link traffic never
 * collides with other plugins/apps sharing the same node network.
 *
 * CONTRACT: mirrored by the iOS/watchOS sides ("kind"/"path" envelope keys).
 */
object WireProtocol {
  /** Capability advertised by every app embedding this plugin (wear.xml). */
  const val CAPABILITY = "wearer_link"

  /** Root prefix for every message and data item owned by the plugin. */
  const val PREFIX = "/wl"

  /** Interactive messages: MessageClient path = "/wl/m<userPath>". */
  const val MESSAGE_PREFIX = "$PREFIX/m"

  /** Latest-state sync items: DataItem path = "/wl/s<userPath>". */
  const val SYNC_PREFIX = "$PREFIX/s"

  /** Queued transfers: DataItem path = "/wl/q<userPath>/<uuid>". */
  const val QUEUE_PREFIX = "$PREFIX/q"

  /** File transfers: ChannelClient path = "/wl/f<userPath>/<uuid>". */
  const val FILE_PREFIX = "$PREFIX/f"

  /** Request/response RPC: MessageClient path = "/wl/r<userPath>". */
  const val REQUEST_PREFIX = "$PREFIX/r"

  /** Bidirectional streams: ChannelClient path = "/wl/c<userPath>/<uuid>". */
  const val STREAM_PREFIX = "$PREFIX/c"

  /**
   * transferData payloads too large for a DataItem travel as a file whose
   * user path carries this marker; the receiver turns them back into a
   * plain data event. CONTRACT: mirrored on iOS/watchOS.
   */
  const val BLOB_MARKER = "/__wlblob"

  /** Payloads above this route through the blob file path (DataItem cap ~100KB). */
  const val MAX_DATA_ITEM_BYTES = 90 * 1024

  /** Safe single-message payload bound reported by getCapabilities. */
  const val MAX_MESSAGE_BYTES = 90 * 1024

  const val KEY_PAYLOAD = "payload"
  const val KEY_ID = "id"
  const val KEY_TIMESTAMP = "ts"

  /** Built-in counterpart-vitals responder (request path). */
  const val STATUS_PATH = "/__wlstatus"

  /** Reserved data path carrying launchCompanion route/args. */
  const val LAUNCH_PATH = "/__wllaunch"

  /** Manifest meta-data key holding the deep-link URI used by launchCompanion. */
  const val LAUNCH_URI_METADATA = "com.crdzbird.wearer_link.launchUri"

  fun messagePath(userPath: String) = MESSAGE_PREFIX + userPath

  fun userPathOfMessage(wirePath: String) = wirePath.removePrefix(MESSAGE_PREFIX)

  fun syncPath(userPath: String) = SYNC_PREFIX + userPath

  fun userPathOfSync(wirePath: String) = wirePath.removePrefix(SYNC_PREFIX)

  fun queuePath(userPath: String, id: String) = "$QUEUE_PREFIX$userPath/$id"

  /** "/wl/q/foo/bar/<uuid>" -> "/foo/bar". */
  fun userPathOfQueue(wirePath: String) =
    wirePath.removePrefix(QUEUE_PREFIX).substringBeforeLast('/')

  fun requestPath(userPath: String) = REQUEST_PREFIX + userPath

  fun userPathOfRequest(wirePath: String) = wirePath.removePrefix(REQUEST_PREFIX)

  fun filePath(userPath: String, id: String) = "$FILE_PREFIX$userPath/$id"

  /** "/wl/f/foo/bar/<uuid>" -> "/foo/bar". */
  fun userPathOfFile(wirePath: String) =
    wirePath.removePrefix(FILE_PREFIX).substringBeforeLast('/')

  /** "/wl/f/foo/bar/<uuid>" -> "<uuid>". */
  fun idOfFile(wirePath: String) = wirePath.substringAfterLast('/')

  fun streamPath(userPath: String, id: String) = "$STREAM_PREFIX$userPath/$id"

  /** "/wl/c/foo/<uuid>" -> "/foo". */
  fun userPathOfStream(wirePath: String) =
    wirePath.removePrefix(STREAM_PREFIX).substringBeforeLast('/')

  /** "/wl/c/foo/<uuid>" -> "<uuid>". */
  fun idOfStream(wirePath: String) = wirePath.substringAfterLast('/')
}

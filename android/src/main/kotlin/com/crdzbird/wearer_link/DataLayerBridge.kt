package com.crdzbird.wearer_link

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.wear.remote.interactions.RemoteActivityHelper
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Node
import java.io.File
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import java.util.UUID
import java.util.concurrent.Executor
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.tasks.await

/**
 * All outbound Data Layer traffic + companion status. Inbound traffic is
 * owned exclusively by [WearerLinkListenerService] (single receive path, no
 * double delivery).
 */
class DataLayerBridge(private val context: Context) {

  private val channelClient by lazy { Wearable.getChannelClient(context) }
  private val messageClient by lazy { Wearable.getMessageClient(context) }
  private val dataClient by lazy { Wearable.getDataClient(context) }
  private val nodeClient by lazy { Wearable.getNodeClient(context) }
  private val capabilityClient by lazy { Wearable.getCapabilityClient(context) }

  fun isSupported(): Boolean =
    GoogleApiAvailability.getInstance()
      .isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS

  suspend fun companionStatus(): CompanionStatusDto {
    if (!isSupported()) {
      return CompanionStatusDto(ConnectionStateDto.UNSUPPORTED, emptyList())
    }
    val connected = try {
      nodeClient.connectedNodes.await()
    } catch (e: ApiException) {
      // On phones with no Wear pairing configured, Play services reports the
      // Wearable API itself as unavailable (API_NOT_CONNECTED, connection
      // result API_UNAVAILABLE). That is "no companion", not an error.
      if (e.statusCode == CommonStatusCodes.API_NOT_CONNECTED) {
        return CompanionStatusDto(ConnectionStateDto.UNSUPPORTED, emptyList())
      }
      throw e
    }
    if (connected.isEmpty()) {
      // The Data Layer cannot distinguish "nothing paired" from "paired but
      // out of range" without a reachable node; report unreachable.
      return CompanionStatusDto(ConnectionStateDto.UNREACHABLE, emptyList())
    }
    val capable = capableNodes()
    return if (capable.isEmpty()) {
      CompanionStatusDto(
        ConnectionStateDto.APP_NOT_INSTALLED,
        connected.map { it.id },
      )
    } else {
      CompanionStatusDto(ConnectionStateDto.REACHABLE, capable.map { it.id })
    }
  }

  suspend fun sendMessage(userPath: String, payload: ByteArray, nodeId: String?) {
    val nodes = targetNodes(nodeId)
    val wirePath = WireProtocol.messagePath(userPath)
    for (node in nodes) {
      try {
        messageClient.sendMessage(node.id, wirePath, payload).await()
      } catch (e: Exception) {
        throw FlutterError("sendFailed", "sendMessage to ${node.id} failed: $e", null)
      }
    }
  }

  /**
   * Request/response RPC over MessageClient.sendRequest. Targets one node:
   * [nodeId] when given, otherwise the sole capable node (several capable
   * nodes without a nodeId is ambiguous for a round trip — typed error).
   */
  suspend fun sendRequest(userPath: String, payload: ByteArray, nodeId: String?): ByteArray {
    val nodes = targetNodes(nodeId)
    val node = nodes.singleOrNull()
      ?: throw FlutterError(
        "sendFailed",
        "sendRequest needs exactly one target; ${nodes.size} capable nodes " +
          "are reachable — pass nodeId.",
        null,
      )
    return try {
      messageClient.sendRequest(node.id, WireProtocol.requestPath(userPath), payload).await()
    } catch (e: Exception) {
      // The receiver rejecting (no handler / handler threw) surfaces here
      // as a failed Task; the wire does not carry the reason across.
      throw FlutterError("sendFailed", "sendRequest to ${node.id} failed: $e", null)
    }
  }

  /** Latest value the counterpart synced for [userPath], newest wins. */
  suspend fun readSyncData(userPath: String): ByteArray? {
    val localId = try {
      nodeClient.localNode.await().id
    } catch (e: Exception) {
      throw FlutterError("unknown", "localNode failed: $e", null)
    }
    val wirePath = WireProtocol.syncPath(userPath)
    val buffer = try {
      dataClient.getDataItems(
        Uri.Builder().scheme("wear").path(wirePath).build(),
        com.google.android.gms.wearable.DataClient.FILTER_LITERAL,
      ).await()
    } catch (e: Exception) {
      throw FlutterError("unknown", "getDataItems($wirePath) failed: $e", null)
    }
    try {
      var newest: ByteArray? = null
      var newestTs = Long.MIN_VALUE
      for (item in buffer) {
        if (item.uri.host == localId) continue // our own synced value
        val map = com.google.android.gms.wearable.DataMapItem.fromDataItem(item.freeze()).dataMap
        val ts = map.getLong(WireProtocol.KEY_TIMESTAMP, 0L)
        if (ts >= newestTs) {
          newestTs = ts
          newest = map.getByteArray(WireProtocol.KEY_PAYLOAD)
        }
      }
      return newest
    } finally {
      buffer.release()
    }
  }

  /** Latest value THIS device synced for [userPath]. */
  suspend fun readOwnSyncData(userPath: String): ByteArray? {
    val localId = try {
      nodeClient.localNode.await().id
    } catch (e: Exception) {
      throw FlutterError("unknown", "localNode failed: $e", null)
    }
    val wirePath = WireProtocol.syncPath(userPath)
    val buffer = try {
      dataClient.getDataItems(
        Uri.Builder().scheme("wear").path(wirePath).build(),
        com.google.android.gms.wearable.DataClient.FILTER_LITERAL,
      ).await()
    } catch (e: Exception) {
      throw FlutterError("unknown", "getDataItems($wirePath) failed: $e", null)
    }
    try {
      for (item in buffer) {
        if (item.uri.host != localId) continue
        val map = com.google.android.gms.wearable.DataMapItem.fromDataItem(item.freeze()).dataMap
        return map.getByteArray(WireProtocol.KEY_PAYLOAD)
      }
      return null
    } finally {
      buffer.release()
    }
  }

  /** Every stored sync path under [prefix], own and received combined. */
  suspend fun listSyncPaths(prefix: String): List<String> {
    val wirePrefix = WireProtocol.syncPath(prefix)
    val buffer = try {
      dataClient.getDataItems(
        Uri.Builder().scheme("wear").path(wirePrefix).build(),
        com.google.android.gms.wearable.DataClient.FILTER_PREFIX,
      ).await()
    } catch (e: Exception) {
      throw FlutterError("unknown", "getDataItems($wirePrefix) failed: $e", null)
    }
    try {
      val paths = LinkedHashSet<String>()
      for (item in buffer) {
        item.uri.path?.let { paths.add(WireProtocol.userPathOfSync(it)) }
      }
      return paths.toList()
    } finally {
      buffer.release()
    }
  }

  /** Delete the value THIS device synced for [userPath]. */
  suspend fun deleteSyncData(userPath: String) {
    val localId = try {
      nodeClient.localNode.await().id
    } catch (e: Exception) {
      throw FlutterError("unknown", "localNode failed: $e", null)
    }
    val uri = Uri.Builder()
      .scheme("wear")
      .authority(localId)
      .path(WireProtocol.syncPath(userPath))
      .build()
    try {
      dataClient.deleteDataItems(uri).await()
    } catch (e: Exception) {
      throw FlutterError("unknown", "deleteDataItems($uri) failed: $e", null)
    }
  }

  /** One node for point-to-point links: [nodeId] or the sole capable node. */
  suspend fun singleTargetNode(nodeId: String?): String {
    val nodes = targetNodes(nodeId)
    return nodes.singleOrNull()?.id
      ?: throw FlutterError(
        "sendFailed",
        "Need exactly one target; ${nodes.size} capable nodes are reachable " +
          "— pass nodeId.",
        null,
      )
  }

  private suspend fun targetNodes(nodeId: String?): Set<Node> {
    val nodes = capableNodes()
    if (nodes.isEmpty()) {
      throw FlutterError(
        "unreachable",
        "No reachable node advertises the '${WireProtocol.CAPABILITY}' capability.",
        null,
      )
    }
    if (nodeId == null) return nodes
    val match = nodes.filter { it.id == nodeId }.toSet()
    if (match.isEmpty()) {
      throw FlutterError("unreachable", "Node $nodeId is not reachable/capable.", null)
    }
    return match
  }

  suspend fun syncData(userPath: String, payload: ByteArray) {
    putDataItem(WireProtocol.syncPath(userPath), payload, id = null, urgent = false)
  }

  suspend fun transferData(userPath: String, payload: ByteArray) {
    if (payload.size > WireProtocol.MAX_DATA_ITEM_BYTES) {
      // Too big for a DataItem: travel as a file, arrive as a data event.
      // Trade-off (documented): this route needs a reachable node.
      val blob = File.createTempFile("wearer_blob", null, context.cacheDir)
      try {
        blob.writeBytes(payload)
        transferFile(WireProtocol.BLOB_MARKER + userPath, blob.absolutePath, nodeId = null)
      } finally {
        blob.delete()
      }
      return
    }
    val id = UUID.randomUUID().toString()
    putDataItem(WireProtocol.queuePath(userPath, id), payload, id = id, urgent = true)
  }

  fun capabilities(): WearerCapabilitiesDto {
    val supported = isSupported()
    return WearerCapabilitiesDto(
      message = supported,
      request = supported,
      syncData = supported,
      transferData = supported,
      transferFile = supported,
      stream = supported,
      companionLaunch =
        if (supported) CompanionLaunchDto.FOREGROUND else CompanionLaunchDto.NONE,
      complicationPush = false, // watchOS-only primitive
      surfaceUpdate = true, // tiles/complications on Wear OS
      backgroundWake = supported,
      maxMessageBytes = WireProtocol.MAX_MESSAGE_BYTES.toLong(),
    )
  }

  private suspend fun putDataItem(
    wirePath: String,
    payload: ByteArray,
    id: String?,
    urgent: Boolean,
  ) {
    try {
      val request = PutDataMapRequest.create(wirePath).apply {
        dataMap.putByteArray(WireProtocol.KEY_PAYLOAD, payload)
        dataMap.putLong(WireProtocol.KEY_TIMESTAMP, System.currentTimeMillis())
        id?.let { dataMap.putString(WireProtocol.KEY_ID, it) }
      }
      val put = request.asPutDataRequest()
      if (urgent) put.setUrgent()
      dataClient.putDataItem(put).await()
    } catch (e: Exception) {
      throw FlutterError("sendFailed", "putDataItem($wirePath) failed: $e", null)
    }
  }

  /**
   * Stream the file to every capable counterpart node over a dedicated
   * ChannelClient channel; the receiver's WearerLinkListenerService writes
   * it into its cache dir and emits a file event.
   */
  suspend fun transferFile(userPath: String, filePath: String, nodeId: String?) {
    val file = File(filePath)
    if (!file.isFile) {
      throw FlutterError("sendFailed", "No such file: $filePath", null)
    }
    val nodes = targetNodes(nodeId)
    for (node in nodes) {
      val wirePath = WireProtocol.filePath(userPath, UUID.randomUUID().toString())
      val channel = try {
        channelClient.openChannel(node.id, wirePath).await()
      } catch (e: Exception) {
        throw FlutterError("sendFailed", "openChannel to ${node.id} failed: $e", null)
      }
      try {
        channelClient.sendFile(channel, Uri.fromFile(file)).await()
      } catch (e: Exception) {
        channelClient.close(channel)
        throw FlutterError("sendFailed", "sendFile to ${node.id} failed: $e", null)
      }
    }
  }

  /**
   * Re-render a tile or complication surface of the app this plugin runs in
   * (meaningful inside a Wear OS app). The androidx requesters are
   * compileOnly dependencies: only apps that ship those surfaces have them,
   * so their absence is reported as a typed 'unsupported' error.
   */
  fun requestSurfaceUpdate(component: String) {
    val cls = try {
      Class.forName(component)
    } catch (e: ClassNotFoundException) {
      throw FlutterError("unknown", "Class not found in this app: $component", null)
    }
    val isTile = try {
      androidx.wear.tiles.TileService::class.java.isAssignableFrom(cls)
    } catch (_: NoClassDefFoundError) {
      false // tiles library absent — fall through to complications
    }
    try {
      if (isTile) {
        @Suppress("UNCHECKED_CAST")
        androidx.wear.tiles.TileService.getUpdater(context)
          .requestUpdate(cls as Class<out androidx.wear.tiles.TileService>)
      } else {
        androidx.wear.watchface.complications.datasource
          .ComplicationDataSourceUpdateRequester
          .create(context, ComponentName(context, cls.name))
          .requestUpdateAll()
      }
    } catch (_: NoClassDefFoundError) {
      throw FlutterError(
        "unsupported",
        "requestSurfaceUpdate needs androidx.wear.tiles:tiles (tiles) or " +
          "androidx.wear.watchface:watchface-complications-data-source " +
          "(complications) on the Wear OS app's classpath.",
        null,
      )
    }
  }

  /**
   * Launch the companion app on every capable counterpart node via
   * RemoteActivityHelper. The counterpart app must declare a BROWSABLE
   * VIEW intent-filter for the URI configured in this app's manifest:
   *
   *   <meta-data
   *     android:name="com.crdzbird.wearer_link.launchUri"
   *     android:value="wearerlink://open" />
   */
  suspend fun getNodes(): List<WearerNodeDto> {
    val connected = try {
      nodeClient.connectedNodes.await()
    } catch (e: Exception) {
      throw FlutterError("unknown", "connectedNodes failed: $e", null)
    }
    return connected.map {
      WearerNodeDto(id = it.id, displayName = it.displayName, isNearby = it.isNearby)
    }
  }

  /** Ask the counterpart's built-in /__wlstatus responder for its vitals. */
  suspend fun getCounterpartStatus(nodeId: String?): CounterpartStatusDto {
    val node = singleTargetNode(nodeId)
    val reply = try {
      messageClient
        .sendRequest(node, WireProtocol.requestPath(WireProtocol.STATUS_PATH), ByteArray(0))
        .await()
    } catch (e: Exception) {
      throw FlutterError(
        "noHandler",
        "Counterpart status probe failed (older wearer_link on the other side?): $e",
        null,
      )
    }
    return try {
      val json = org.json.JSONObject(String(reply, Charsets.UTF_8))
      CounterpartStatusDto(
        batteryPercent = json.optLong("battery", -1L),
        isCharging = json.optBoolean("charging", false),
        model = json.optString("model", "unknown"),
        osVersion = json.optString("os", "unknown"),
      )
    } catch (e: Exception) {
      throw FlutterError("unknown", "Malformed status reply: $e", null)
    }
  }

  suspend fun launchCompanion(mainExecutor: Executor, route: String?, argsJson: String?) {
    val uri = launchUriFromManifest()
      ?: throw FlutterError(
        "launchFailed",
        "Missing <meta-data android:name=\"${WireProtocol.LAUNCH_URI_METADATA}\"> " +
          "in AndroidManifest.xml.",
        null,
      )
    val nodes = capableNodes()
    if (nodes.isEmpty()) {
      throw FlutterError("unreachable", "No reachable companion node.", null)
    }
    val launchUri = Uri.parse(uri).buildUpon().apply {
      route?.let { appendQueryParameter("route", it) }
      argsJson?.let { appendQueryParameter("args", it) }
    }.build()
    val intent = Intent(Intent.ACTION_VIEW)
      .addCategory(Intent.CATEGORY_BROWSABLE)
      .setData(launchUri)
    val helper = RemoteActivityHelper(context, mainExecutor)
    for (node in nodes) {
      try {
        helper.startRemoteActivity(intent, node.id).await()
      } catch (e: Exception) {
        throw FlutterError("launchFailed", "startRemoteActivity(${node.id}) failed: $e", null)
      }
    }
    if (route != null || argsJson != null) {
      // Queued delivery survives the launch gap; the launched app reads it
      // from its launchIntents stream.
      val payload = org.json.JSONObject().apply {
        put("route", route ?: org.json.JSONObject.NULL)
        put("args", argsJson ?: org.json.JSONObject.NULL)
      }
      transferData(WireProtocol.LAUNCH_PATH, payload.toString().toByteArray(Charsets.UTF_8))
    }
  }

  fun addCapabilityListener(listener: CapabilityClient.OnCapabilityChangedListener) {
    capabilityClient.addListener(listener, WireProtocol.CAPABILITY)
  }

  fun removeCapabilityListener(listener: CapabilityClient.OnCapabilityChangedListener) {
    capabilityClient.removeListener(listener)
  }

  private suspend fun capableNodes(): Set<Node> =
    capabilityClient
      .getCapability(WireProtocol.CAPABILITY, CapabilityClient.FILTER_REACHABLE)
      .await()
      .nodes

  private fun launchUriFromManifest(): String? = try {
    val info = context.packageManager.getApplicationInfo(
      context.packageName,
      PackageManager.GET_META_DATA,
    )
    info.metaData?.getString(WireProtocol.LAUNCH_URI_METADATA)
  } catch (_: PackageManager.NameNotFoundException) {
    null
  }
}

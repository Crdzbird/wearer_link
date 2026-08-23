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

  suspend fun sendMessage(userPath: String, payload: ByteArray) {
    val nodes = capableNodes()
    if (nodes.isEmpty()) {
      throw FlutterError(
        "unreachable",
        "No reachable node advertises the '${WireProtocol.CAPABILITY}' capability.",
        null,
      )
    }
    val wirePath = WireProtocol.messagePath(userPath)
    for (node in nodes) {
      try {
        messageClient.sendMessage(node.id, wirePath, payload).await()
      } catch (e: Exception) {
        throw FlutterError("sendFailed", "sendMessage to ${node.id} failed: $e", null)
      }
    }
  }

  suspend fun syncData(userPath: String, payload: ByteArray) {
    putDataItem(WireProtocol.syncPath(userPath), payload, id = null, urgent = false)
  }

  suspend fun transferData(userPath: String, payload: ByteArray) {
    val id = UUID.randomUUID().toString()
    putDataItem(WireProtocol.queuePath(userPath, id), payload, id = id, urgent = true)
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
  suspend fun transferFile(userPath: String, filePath: String) {
    val file = File(filePath)
    if (!file.isFile) {
      throw FlutterError("sendFailed", "No such file: $filePath", null)
    }
    val nodes = capableNodes()
    if (nodes.isEmpty()) {
      throw FlutterError(
        "unreachable",
        "No reachable node advertises the '${WireProtocol.CAPABILITY}' capability.",
        null,
      )
    }
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
  suspend fun launchCompanion(mainExecutor: Executor) {
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
    val intent = Intent(Intent.ACTION_VIEW)
      .addCategory(Intent.CATEGORY_BROWSABLE)
      .setData(Uri.parse(uri))
    val helper = RemoteActivityHelper(context, mainExecutor)
    for (node in nodes) {
      try {
        helper.startRemoteActivity(intent, node.id).await()
      } catch (e: Exception) {
        throw FlutterError("launchFailed", "startRemoteActivity(${node.id}) failed: $e", null)
      }
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

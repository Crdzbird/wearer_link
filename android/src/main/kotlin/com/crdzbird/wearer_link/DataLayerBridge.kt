package com.crdzbird.wearer_link

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.wear.remote.interactions.RemoteActivityHelper
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Node
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
    val connected = nodeClient.connectedNodes.await()
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
    // VERIFY: RemoteActivityHelper(Context, Executor) constructor against the
    // pinned androidx.wear:wear-remote-interactions release.
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

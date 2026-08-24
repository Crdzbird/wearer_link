package com.crdzbird.wearer_link

import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.TaskCompletionSource
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * The single receive path for all wearer_link traffic, alive or dead:
 * declared in the manifest, so the system starts this app's process to
 * deliver events even when the app was killed. With a Flutter engine
 * attached it forwards to Dart on the main thread; otherwise it persists
 * to [PendingEventStore] for replay on next launch.
 */
class WearerLinkListenerService : WearableListenerService() {

  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onMessageReceived(event: MessageEvent) {
    if (!event.path.startsWith(WireProtocol.MESSAGE_PREFIX)) return
    dispatch(
      WearerEventDto(
        id = UUID.randomUUID().toString(),
        kind = WearerEventKindDto.MESSAGE,
        path = WireProtocol.userPathOfMessage(event.path),
        payload = event.data,
        sourceNodeId = event.sourceNodeId,
        timestampMillis = System.currentTimeMillis(),
        deliveredWhileDead = WearerLinkPlugin.liveDispatcher == null,
      ),
    )
  }

  override fun onDataChanged(events: DataEventBuffer) {
    // DataClient events also fire on the node that wrote the item —
    // drop self-originated ones or every sender would echo itself.
    val localNodeId = localNodeId() ?: return
    for (event in events) {
      if (event.type != DataEvent.TYPE_CHANGED) continue
      val item = event.dataItem
      val wirePath = item.uri.path ?: continue
      if (item.uri.host == localNodeId) continue

      val isSync = wirePath.startsWith(WireProtocol.SYNC_PREFIX)
      val isQueue = wirePath.startsWith(WireProtocol.QUEUE_PREFIX)
      if (!isSync && !isQueue) continue

      val map = DataMapItem.fromDataItem(item.freeze()).dataMap
      val payload = map.getByteArray(WireProtocol.KEY_PAYLOAD) ?: continue
      dispatch(
        WearerEventDto(
          id = map.getString(WireProtocol.KEY_ID) ?: UUID.randomUUID().toString(),
          kind = WearerEventKindDto.DATA,
          path = if (isSync) {
            WireProtocol.userPathOfSync(wirePath)
          } else {
            WireProtocol.userPathOfQueue(wirePath)
          },
          payload = payload,
          sourceNodeId = item.uri.host ?: "",
          timestampMillis = map.getLong(WireProtocol.KEY_TIMESTAMP, System.currentTimeMillis()),
          deliveredWhileDead = WearerLinkPlugin.liveDispatcher == null,
        ),
      )
      if (isQueue) {
        // Queue items are one-shot deliveries, not shared state: remove the
        // item so the shared map doesn't grow without bound.
        Wearable.getDataClient(this).deleteDataItems(item.uri)
      }
    }
  }

  /**
   * Request/response RPC. Requests need a live Dart handler right now —
   * unlike fire-and-forget events they cannot be queued (the sender is
   * waiting) — so with no engine attached the request is rejected.
   */
  override fun onRequest(nodeId: String, path: String, request: ByteArray): Task<ByteArray>? {
    if (!path.startsWith(WireProtocol.REQUEST_PREFIX)) return null
    if (!DeliveryGate.isEnabled(this)) {
      return Tasks.forException(
        IllegalStateException("wearer_link: delivery is disabled on this device"),
      )
    }
    val handler = WearerLinkPlugin.liveRequestHandler
      ?: return Tasks.forException(
        IllegalStateException("wearer_link: app has no live request handler"),
      )
    val source = TaskCompletionSource<ByteArray>()
    val dto = WearerEventDto(
      id = UUID.randomUUID().toString(),
      kind = WearerEventKindDto.MESSAGE,
      path = WireProtocol.userPathOfRequest(path),
      payload = request,
      sourceNodeId = nodeId,
      timestampMillis = System.currentTimeMillis(),
      deliveredWhileDead = false,
    )
    mainHandler.post {
      val live = WearerLinkPlugin.liveRequestHandler
      if (live == null) {
        source.setException(IllegalStateException("wearer_link: engine detached"))
      } else {
        live(dto) { result ->
          result.fold(
            onSuccess = { source.setResult(it) },
            onFailure = { source.setException(Exception(it)) },
          )
        }
      }
    }
    return source.task
  }

  // -- File transfers (ChannelClient) ---------------------------------------

  override fun onChannelOpened(channel: ChannelClient.Channel) {
    val wirePath = channel.path
    if (wirePath.startsWith(WireProtocol.STREAM_PREFIX)) {
      StreamRegistry.accept(this, channel)
      return
    }
    if (!wirePath.startsWith(WireProtocol.FILE_PREFIX)) return
    // Destination is derived from the wire path alone so onInputClosed can
    // find it even if the service was recycled in between.
    Wearable.getChannelClient(this)
      .receiveFile(channel, Uri.fromFile(fileFor(wirePath)), false)
  }

  override fun onInputClosed(
    channel: ChannelClient.Channel,
    closeReason: Int,
    appSpecificErrorCode: Int,
  ) {
    val wirePath = channel.path
    if (!wirePath.startsWith(WireProtocol.FILE_PREFIX)) return
    val file = fileFor(wirePath)
    if (closeReason != ChannelClient.ChannelCallback.CLOSE_REASON_NORMAL || !file.exists()) {
      file.delete() // partial transfer — the sender sees the failure
      return
    }
    val userPath = WireProtocol.userPathOfFile(wirePath)
    if (userPath.startsWith(WireProtocol.BLOB_MARKER)) {
      // Oversized transferData that traveled as a file: back into bytes.
      val payload = try {
        file.readBytes()
      } finally {
        file.delete()
      }
      dispatch(
        WearerEventDto(
          id = WireProtocol.idOfFile(wirePath),
          kind = WearerEventKindDto.DATA,
          path = userPath.removePrefix(WireProtocol.BLOB_MARKER),
          payload = payload,
          sourceNodeId = channel.nodeId,
          timestampMillis = System.currentTimeMillis(),
          deliveredWhileDead = WearerLinkPlugin.liveDispatcher == null,
        ),
      )
      return
    }
    dispatch(
      WearerEventDto(
        id = WireProtocol.idOfFile(wirePath),
        kind = WearerEventKindDto.FILE,
        path = userPath,
        payload = ByteArray(0),
        sourceNodeId = channel.nodeId,
        timestampMillis = System.currentTimeMillis(),
        deliveredWhileDead = WearerLinkPlugin.liveDispatcher == null,
        filePath = file.absolutePath,
      ),
    )
  }

  private fun fileFor(wirePath: String): File {
    val dir = File(cacheDir, "wearer_link")
    dir.mkdirs()
    return File(dir, WireProtocol.idOfFile(wirePath))
  }

  private fun dispatch(dto: WearerEventDto) {
    if (!DeliveryGate.isEnabled(this)) {
      // Delivery paused: divert everything to the queue, wake nothing.
      PendingEventStore(this).append(dto.copy(deliveredWhileDead = true))
      return
    }
    val live = WearerLinkPlugin.liveDispatcher
    if (live != null) {
      mainHandler.post {
        // Re-read: the engine may have detached between check and post.
        val stillLive = WearerLinkPlugin.liveDispatcher
        if (stillLive != null) stillLive(dto) else PendingEventStore(this).append(dto)
      }
    } else {
      // Persist first (crash-safe), then hand to the headless isolate if the
      // app registered one; the isolate's ack removes the queued copy.
      PendingEventStore(this).append(dto)
      if (BackgroundDispatcher.isRegistered(this)) {
        BackgroundDispatcher.deliver(this, dto)
      }
    }
  }

  private fun localNodeId(): String? = try {
    // Service callbacks run off the main thread; a short block is safe here.
    Tasks.await(Wearable.getNodeClient(this).localNode, 5, TimeUnit.SECONDS).id
  } catch (_: Exception) {
    null
  }
}

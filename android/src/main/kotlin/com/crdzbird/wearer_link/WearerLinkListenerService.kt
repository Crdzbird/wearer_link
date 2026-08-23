package com.crdzbird.wearer_link

import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
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

  private fun dispatch(dto: WearerEventDto) {
    val live = WearerLinkPlugin.liveDispatcher
    if (live != null) {
      mainHandler.post {
        // Re-read: the engine may have detached between check and post.
        val stillLive = WearerLinkPlugin.liveDispatcher
        if (stillLive != null) stillLive(dto) else PendingEventStore(this).append(dto)
      }
    } else {
      PendingEventStore(this).append(dto)
    }
  }

  private fun localNodeId(): String? = try {
    // Service callbacks run off the main thread; a short block is safe here.
    Tasks.await(Wearable.getNodeClient(this).localNode, 5, TimeUnit.SECONDS).id
  } catch (_: Exception) {
    null
  }
}

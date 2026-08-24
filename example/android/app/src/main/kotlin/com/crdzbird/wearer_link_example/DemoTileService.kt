package com.crdzbird.wearer_link_example

import android.util.Base64
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import org.json.JSONObject

/**
 * Demo Wear OS tile fed by the wearer_link synced store: it renders the
 * store's `demo` key (written by either device) plus its own render time,
 * and re-renders whenever the app calls
 * `WearerLink.instance.requestSurfaceUpdate('...DemoTileService')`.
 *
 * Reading the store natively: store records live in ordinary Data Layer
 * items at `/wl/s/__wlstore/<key>` as JSON `{t, n, d, v(base64)}` — pick
 * the newest record across nodes, base64-decode `v`.
 */
class DemoTileService : TileService() {

  override fun onTileRequest(
    requestParams: RequestBuilders.TileRequest
  ): ListenableFuture<TileBuilders.Tile> {
    val future = SettableFuture.create<TileBuilders.Tile>()
    val rendered = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
    readStoreDemoValue { value ->
      future.set(
        TileBuilders.Tile.Builder()
          .setResourcesVersion(RESOURCES_VERSION)
          .setTileTimeline(
            TimelineBuilders.Timeline.Builder()
              .addTimelineEntry(
                TimelineBuilders.TimelineEntry.Builder()
                  .setLayout(
                    LayoutElementBuilders.Layout.Builder()
                      .setRoot(layout(rendered, value))
                      .build()
                  )
                  .build()
              )
              .build()
          )
          .build()
      )
    }
    return future
  }

  override fun onTileResourcesRequest(
    requestParams: RequestBuilders.ResourcesRequest
  ): ListenableFuture<ResourceBuilders.Resources> =
    Futures.immediateFuture(
      ResourceBuilders.Resources.Builder().setVersion(RESOURCES_VERSION).build()
    )

  private fun layout(
    rendered: String,
    storeValue: String,
  ): LayoutElementBuilders.LayoutElement =
    LayoutElementBuilders.Column.Builder()
      .addContent(text("wearer_link tile", 16f))
      .addContent(text("rendered $rendered", 13f))
      .addContent(text(storeValue, 12f))
      .build()

  private fun text(value: String, size: Float): LayoutElementBuilders.Text =
    LayoutElementBuilders.Text.Builder()
      .setText(value)
      .setFontStyle(
        LayoutElementBuilders.FontStyle.Builder()
          .setSize(androidx.wear.protolayout.DimensionBuilders.sp(size))
          .setColor(argb(0xFFFFFFFF.toInt()))
          .build()
      )
      .build()

  /** Newest `demo` store record across both devices, or a placeholder. */
  private fun readStoreDemoValue(callback: (String) -> Unit) {
    Wearable.getDataClient(this)
      .getDataItems(
        android.net.Uri.Builder().scheme("wear").path(STORE_DEMO_PATH).build(),
        DataClient.FILTER_LITERAL,
      )
      .addOnSuccessListener { buffer ->
        var newestTs = Long.MIN_VALUE
        var newest: String? = null
        try {
          for (item in buffer) {
            val payload =
              DataMapItem.fromDataItem(item.freeze()).dataMap.getByteArray("payload")
                ?: continue
            val record = JSONObject(String(payload, Charsets.UTF_8))
            if (record.optBoolean("d", false)) continue
            val ts = record.optLong("t", 0)
            if (ts > newestTs) {
              newestTs = ts
              newest =
                String(Base64.decode(record.optString("v"), Base64.DEFAULT), Charsets.UTF_8)
            }
          }
        } catch (_: Exception) {
          // fall through to placeholder
        } finally {
          buffer.release()
        }
        callback(newest ?: "store: (empty)")
      }
      .addOnFailureListener { callback("store: unavailable") }
  }

  private companion object {
    const val RESOURCES_VERSION = "1"
    const val STORE_DEMO_PATH = "/wl/s/__wlstore/demo"
  }
}

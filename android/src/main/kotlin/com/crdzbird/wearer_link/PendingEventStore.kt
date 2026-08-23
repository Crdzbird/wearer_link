package com.crdzbird.wearer_link

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * Bounded persistent FIFO for events that arrive while no Flutter engine is
 * attached (app killed / not yet started). Replayed and cleared by
 * [WearerLinkHostApi.drainPendingEvents] on the next app launch.
 *
 * SharedPreferences-backed: payloads on this transport are small (Data Layer
 * items are capped at ~100KB), and the queue is bounded, so a prefs blob is
 * simpler and atomic enough for the prototype.
 */
class PendingEventStore(context: Context) {

  private val prefs =
    context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

  @Synchronized
  fun append(event: WearerEventDto) {
    val events = readAll()
    events.add(event)
    while (events.size > MAX_EVENTS) events.removeAt(0)
    write(events)
  }

  /** Drop one event by id — called after a background isolate acked it. */
  @Synchronized
  fun remove(id: String) {
    val events = readAll()
    if (events.removeAll { it.id == id }) write(events)
  }

  @Synchronized
  fun drain(): List<WearerEventDto> {
    val events = readAll()
    prefs.edit().remove(KEY_QUEUE).apply()
    return events
  }

  private fun readAll(): MutableList<WearerEventDto> {
    val raw = prefs.getString(KEY_QUEUE, null) ?: return mutableListOf()
    return try {
      val array = JSONArray(raw)
      MutableList(array.length()) { fromJson(array.getJSONObject(it)) }
    } catch (_: Exception) {
      // A corrupt queue must never brick startup; drop it.
      mutableListOf()
    }
  }

  private fun write(events: List<WearerEventDto>) {
    val array = JSONArray()
    events.forEach { array.put(toJson(it)) }
    prefs.edit().putString(KEY_QUEUE, array.toString()).apply()
  }

  private fun toJson(e: WearerEventDto) = JSONObject().apply {
    put("id", e.id)
    put("kind", e.kind.raw)
    put("path", e.path)
    put("payload", Base64.encodeToString(e.payload, Base64.NO_WRAP))
    put("node", e.sourceNodeId)
    put("ts", e.timestampMillis)
    e.filePath?.let { put("file", it) }
  }

  private fun fromJson(o: JSONObject) = WearerEventDto(
    id = o.getString("id"),
    kind = WearerEventKindDto.ofRaw(o.getInt("kind")) ?: WearerEventKindDto.MESSAGE,
    path = o.getString("path"),
    payload = Base64.decode(o.getString("payload"), Base64.NO_WRAP),
    sourceNodeId = o.getString("node"),
    timestampMillis = o.getLong("ts"),
    deliveredWhileDead = true,
    filePath = if (o.has("file")) o.getString("file") else null,
  )

  private companion object {
    const val PREFS_NAME = "wearer_link_pending"
    const val KEY_QUEUE = "queue"
    const val MAX_EVENTS = 200
  }
}

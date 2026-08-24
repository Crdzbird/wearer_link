package com.crdzbird.wearer_link

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.Wearable
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.tasks.await

/**
 * Process-wide owner of live bidirectional streams (ChannelClient channels
 * with real input/output streams). Streams only exist while a Flutter
 * engine is attached — the plugin installs [listener]; with none installed
 * (or delivery disabled) incoming stream channels are closed immediately.
 */
internal object StreamRegistry {

  /** Surfaces stream lifecycle to Dart. Set by the plugin; main thread. */
  interface Listener {
    fun onOpened(id: String, path: String, nodeId: String, incoming: Boolean)
    fun onData(id: String, data: ByteArray)
    fun onClosed(id: String, error: String?)
  }

  @Volatile
  var listener: Listener? = null

  private val mainHandler = Handler(Looper.getMainLooper())

  private class Entry(
    val channel: ChannelClient.Channel,
    val output: OutputStream,
  )

  private val entries = ConcurrentHashMap<String, Entry>()

  suspend fun open(context: Context, userPath: String, node: String): String {
    val id = UUID.randomUUID().toString()
    val client = Wearable.getChannelClient(context)
    val channel = try {
      client.openChannel(node, WireProtocol.streamPath(userPath, id)).await()
    } catch (e: Exception) {
      throw FlutterError("sendFailed", "openChannel($userPath) failed: $e", null)
    }
    try {
      val output = client.getOutputStream(channel).await()
      val input = client.getInputStream(channel).await()
      register(context, id, userPath, node, channel, output, input, incoming = false)
    } catch (e: Exception) {
      client.close(channel)
      throw FlutterError("sendFailed", "stream setup($userPath) failed: $e", null)
    }
    return id
  }

  /** Called from the listener service for inbound STREAM_PREFIX channels. */
  fun accept(context: Context, channel: ChannelClient.Channel) {
    val active = listener
    if (active == null || !DeliveryGate.isEnabled(context)) {
      // No engine to hand the stream to (or delivery paused): refuse.
      Wearable.getChannelClient(context).close(channel)
      return
    }
    val id = WireProtocol.idOfStream(channel.path)
    val userPath = WireProtocol.userPathOfStream(channel.path)
    // Blocking Tasks are fine here: service callbacks run off the main thread.
    val client = Wearable.getChannelClient(context)
    try {
      val output = Tasks.await(client.getOutputStream(channel), 10, TimeUnit.SECONDS)
      val input = Tasks.await(client.getInputStream(channel), 10, TimeUnit.SECONDS)
      register(context, id, userPath, channel.nodeId, channel, output, input, incoming = true)
    } catch (e: Exception) {
      client.close(channel)
    }
  }

  fun send(id: String, data: ByteArray) {
    val entry = entries[id]
      ?: throw FlutterError("sendFailed", "Stream $id is not open.", null)
    try {
      entry.output.write(data)
      entry.output.flush()
    } catch (e: Exception) {
      throw FlutterError("sendFailed", "stream write failed: $e", null)
    }
  }

  fun close(context: Context, id: String) {
    val entry = entries.remove(id) ?: return
    runCatching { entry.output.close() }
    Wearable.getChannelClient(context).close(entry.channel)
    notifyClosed(id, null)
  }

  fun closeAll(context: Context) {
    for (id in entries.keys.toList()) close(context, id)
  }

  // -- internals ------------------------------------------------------------

  private fun register(
    context: Context,
    id: String,
    userPath: String,
    nodeId: String,
    channel: ChannelClient.Channel,
    output: OutputStream,
    input: InputStream,
    incoming: Boolean,
  ) {
    entries[id] = Entry(channel, output)
    mainHandler.post { listener?.onOpened(id, userPath, nodeId, incoming) }
    Thread({ pump(context, id, input) }, "wearer_link-stream-$id").start()
  }

  private fun pump(context: Context, id: String, input: InputStream) {
    val buffer = ByteArray(32 * 1024)
    try {
      while (true) {
        val read = input.read(buffer)
        if (read < 0) break
        if (read == 0) continue
        val chunk = buffer.copyOf(read)
        mainHandler.post { listener?.onData(id, chunk) }
      }
      finish(context, id, null)
    } catch (e: Exception) {
      finish(context, id, "$e")
    } finally {
      runCatching { input.close() }
    }
  }

  private fun finish(context: Context, id: String, error: String?) {
    val entry = entries.remove(id) ?: return // already closed locally
    runCatching { entry.output.close() }
    Wearable.getChannelClient(context).close(entry.channel)
    notifyClosed(id, error)
  }

  private fun notifyClosed(id: String, error: String?) {
    mainHandler.post { listener?.onClosed(id, error) }
  }
}

/** Cross-restart delivery counters backing getPersistentStats. */
internal object StatsStore {
  private const val PREFS = "wearer_link_stats"

  private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  @Synchronized
  fun increment(context: Context, key: String, by: Int = 1) {
    val p = prefs(context)
    ensureEpoch(context)
    p.edit().putLong(key, p.getLong(key, 0L) + by).apply()
  }

  @Synchronized
  fun snapshot(context: Context): PersistentStatsDto {
    ensureEpoch(context)
    val p = prefs(context)
    return PersistentStatsDto(
      receivedTotal = p.getLong(KEY_RECEIVED, 0L),
      queuedWhileDead = p.getLong(KEY_QUEUED, 0L),
      drained = p.getLong(KEY_DRAINED, 0L),
      backgroundHandled = p.getLong(KEY_BACKGROUND, 0L),
      sinceMillis = p.getLong(KEY_SINCE, System.currentTimeMillis()),
    )
  }

  @Synchronized
  fun reset(context: Context) {
    prefs(context).edit()
      .clear()
      .putLong(KEY_SINCE, System.currentTimeMillis())
      .apply()
  }

  private fun ensureEpoch(context: Context) {
    val p = prefs(context)
    if (!p.contains(KEY_SINCE)) {
      p.edit().putLong(KEY_SINCE, System.currentTimeMillis()).apply()
    }
  }

  const val KEY_RECEIVED = "received"
  const val KEY_QUEUED = "queued"
  const val KEY_DRAINED = "drained"
  const val KEY_BACKGROUND = "background"
  private const val KEY_SINCE = "since"
}

/**
 * Persisted delivery switch: while disabled every inbound event diverts to
 * the pending queue (nothing lost, nothing delivered) and incoming streams
 * are refused.
 */
internal object DeliveryGate {
  private const val PREFS = "wearer_link_delivery"
  private const val KEY = "enabled"

  fun isEnabled(context: Context): Boolean =
    context.applicationContext
      .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .getBoolean(KEY, true)

  fun setEnabled(context: Context, enabled: Boolean) {
    context.applicationContext
      .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .edit()
      .putBoolean(KEY, enabled)
      .apply()
  }
}

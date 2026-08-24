package com.crdzbird.wearer_link

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.wearable.CapabilityClient
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.Executor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Phone/Wear OS entry point. Symmetric: runs on both devices. */
class WearerLinkPlugin : FlutterPlugin, WearerLinkHostApi {

  private lateinit var context: Context
  private var bridge: DataLayerBridge? = null
  private var flutterApi: WearerLinkFlutterApi? = null
  private var store: PendingEventStore? = null
  private var scope: CoroutineScope? = null

  private val mainHandler = Handler(Looper.getMainLooper())
  private val mainExecutor = Executor { r -> mainHandler.post(r) }

  private val capabilityListener =
    CapabilityClient.OnCapabilityChangedListener { pushConnectionState() }

  /** True when this instance owns the process-wide [liveDispatcher] slot. */
  private var claimedLiveDispatch = false

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    bridge = DataLayerBridge(context)
    store = PendingEventStore(context)
    scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    WearerLinkHostApi.setUp(binding.binaryMessenger, this)
    if (BackgroundDispatcher.creatingBackgroundEngine) {
      // Attached to the plugin's own headless engine (FlutterEngine
      // auto-registers plugins). It must NOT claim live event dispatch —
      // events reach it through WearerLinkBackgroundFlutterApi — but the
      // HostApi above stays so the background handler can send/sync back.
      return
    }
    flutterApi = WearerLinkFlutterApi(binding.binaryMessenger)
    if (bridge?.isSupported() == true) {
      bridge?.addCapabilityListener(capabilityListener)
    }
    liveDispatcher = ::dispatchToDart
    liveRequestHandler = ::requestToDart
    StreamRegistry.listener = streamListener
    claimedLiveDispatch = true
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    if (claimedLiveDispatch) {
      liveDispatcher = null
      liveRequestHandler = null
      StreamRegistry.listener = null
      StreamRegistry.closeAll(context)
      claimedLiveDispatch = false
    }
    WearerLinkHostApi.setUp(binding.binaryMessenger, null)
    bridge?.removeCapabilityListener(capabilityListener)
    scope?.cancel()
    scope = null
    flutterApi = null
    bridge = null
    // store stays usable by the background service; it holds only an app context.
    store = null
  }

  // -- WearerLinkHostApi ----------------------------------------------------

  override fun isSupported(): Boolean = bridge?.isSupported() ?: false

  override fun getCompanionStatus(callback: (Result<CompanionStatusDto>) -> Unit) {
    launchWith(callback) { it.companionStatus() }
  }

  override fun sendMessage(
    path: String,
    payload: ByteArray,
    nodeId: String?,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.sendMessage(path, payload, nodeId) }
  }

  override fun sendRequest(
    path: String,
    payload: ByteArray,
    nodeId: String?,
    callback: (Result<ByteArray>) -> Unit,
  ) {
    launchWith(callback) { it.sendRequest(path, payload, nodeId) }
  }

  override fun readSyncData(
    path: String,
    callback: (Result<ByteArray?>) -> Unit,
  ) {
    launchWith(callback) { it.readSyncData(path) }
  }

  override fun deleteSyncData(
    path: String,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.deleteSyncData(path) }
  }

  override fun readOwnSyncData(
    path: String,
    callback: (Result<ByteArray?>) -> Unit,
  ) {
    launchWith(callback) { it.readOwnSyncData(path) }
  }

  override fun listSyncPaths(
    prefix: String,
    callback: (Result<List<String>>) -> Unit,
  ) {
    launchWith(callback) { it.listSyncPaths(prefix) }
  }

  override fun syncData(
    path: String,
    payload: ByteArray,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.syncData(path, payload) }
  }

  override fun transferData(
    path: String,
    payload: ByteArray,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.transferData(path, payload) }
  }

  override fun launchCompanion(
    route: String?,
    argsJson: String?,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.launchCompanion(mainExecutor, route, argsJson) }
  }

  override fun getNodes(callback: (Result<List<WearerNodeDto>>) -> Unit) {
    launchWith(callback) { it.getNodes() }
  }

  override fun getCounterpartVitals(
    nodeId: String?,
    callback: (Result<CounterpartVitalsDto>) -> Unit,
  ) {
    launchWith(callback) { it.getCounterpartVitals(nodeId) }
  }

  override fun transferFile(
    path: String,
    filePath: String,
    nodeId: String?,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.transferFile(path, filePath, nodeId) }
  }

  override fun updateComplication(
    payload: ByteArray,
    callback: (Result<Unit>) -> Unit,
  ) {
    // watchOS-only primitive; the honest Android answer is a typed error.
    callback(
      Result.failure(
        FlutterError(
          "unsupported",
          "Android has no phone->watch complication push. Sync the state " +
            "with syncData and call requestSurfaceUpdate inside the " +
            "Wear OS app instead.",
          null,
        ),
      ),
    )
  }

  override fun requestSurfaceUpdate(
    component: String,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.requestSurfaceUpdate(component) }
  }

  override fun registerBackgroundHandler(dispatcherHandle: Long, userHandle: Long) {
    BackgroundDispatcher.register(context, dispatcherHandle, userHandle)
  }

  override fun clearBackgroundHandler() {
    BackgroundDispatcher.clear(context)
  }

  override fun getCapabilities(): WearerCapabilitiesDto =
    bridge?.capabilities()
      ?: throw FlutterError("unknown", "Plugin detached.", null)

  override fun setEventDeliveryEnabled(enabled: Boolean) {
    DeliveryGate.setEnabled(context, enabled)
    if (!enabled) StreamRegistry.closeAll(context)
  }

  override fun isEventDeliveryEnabled(): Boolean = DeliveryGate.isEnabled(context)

  override fun openStream(
    path: String,
    nodeId: String?,
    callback: (Result<String>) -> Unit,
  ) {
    launchWith(callback) { activeBridge ->
      if (!DeliveryGate.isEnabled(context)) {
        throw FlutterError("unsupported", "Event delivery is disabled.", null)
      }
      val node = activeBridge.singleTargetNode(nodeId)
      StreamRegistry.open(context, path, node)
    }
  }

  override fun sendStreamData(
    streamId: String,
    data: ByteArray,
    callback: (Result<Unit>) -> Unit,
  ) {
    val activeScope = scope
      ?: return callback(Result.failure(FlutterError("unknown", "Plugin detached.", null)))
    activeScope.launch(Dispatchers.IO) {
      val result = try {
        StreamRegistry.send(streamId, data)
        Result.success(Unit)
      } catch (e: FlutterError) {
        Result.failure(e)
      } catch (e: Exception) {
        Result.failure<Unit>(FlutterError("sendFailed", "$e", null))
      }
      mainHandler.post { callback(result) }
    }
  }

  override fun closeStream(streamId: String, callback: (Result<Unit>) -> Unit) {
    StreamRegistry.close(context, streamId)
    callback(Result.success(Unit))
  }

  override fun drainPendingEvents(callback: (Result<List<WearerEventDto>>) -> Unit) {
    val activeStore = store
      ?: return callback(Result.failure(FlutterError("unknown", "Plugin detached.", null)))
    val activeScope = scope ?: return
    activeScope.launch(Dispatchers.IO) {
      val events = activeStore.drain()
      if (events.isNotEmpty()) {
        StatsStore.increment(context, StatsStore.KEY_DRAINED, events.size)
      }
      mainHandler.post { callback(Result.success(events)) }
    }
  }

  override fun getPersistentStats(callback: (Result<PersistentStatsDto>) -> Unit) {
    callback(Result.success(StatsStore.snapshot(context)))
  }

  override fun resetPersistentStats(callback: (Result<Unit>) -> Unit) {
    StatsStore.reset(context)
    callback(Result.success(Unit))
  }

  // -- internals ------------------------------------------------------------

  private fun <T> launchWith(
    callback: (Result<T>) -> Unit,
    block: suspend (DataLayerBridge) -> T,
  ) {
    val activeBridge = bridge
      ?: return callback(Result.failure(FlutterError("unknown", "Plugin detached.", null)))
    val activeScope = scope ?: return
    activeScope.launch {
      try {
        callback(Result.success(block(activeBridge)))
      } catch (e: FlutterError) {
        callback(Result.failure(e))
      } catch (e: Exception) {
        callback(Result.failure(FlutterError("unknown", e.toString(), null)))
      }
    }
  }

  private fun pushConnectionState() {
    val api = flutterApi ?: return
    val activeBridge = bridge ?: return
    scope?.launch {
      val status = try {
        activeBridge.companionStatus()
      } catch (_: Exception) {
        return@launch
      }
      api.onConnectionStateChanged(status) { /* best-effort push */ }
    }
  }

  /**
   * Live delivery from [WearerLinkListenerService]. Runs on the main thread.
   * If the Dart side has no handler yet (engine up, WearerLink not touched),
   * the Pigeon callback reports failure and the event falls back to the
   * persistent queue — delivery stays at-least-once.
   */
  private fun dispatchToDart(dto: WearerEventDto) {
    val api = flutterApi ?: run { store?.append(dto); return }
    val onResult: (Result<Unit>) -> Unit = { result ->
      if (result.isFailure) {
        store?.append(dto.copy(deliveredWhileDead = true))
          ?: PendingEventStore(context).append(dto.copy(deliveredWhileDead = true))
      }
    }
    when (dto.kind) {
      WearerEventKindDto.MESSAGE -> api.onMessage(dto, onResult)
      WearerEventKindDto.DATA -> api.onDataChanged(dto, onResult)
      WearerEventKindDto.FILE -> api.onFileReceived(dto, onResult)
    }
  }

  private val streamListener = object : StreamRegistry.Listener {
    override fun onOpened(id: String, path: String, nodeId: String, incoming: Boolean) {
      flutterApi?.onStreamOpened(id, path, nodeId, incoming) { }
    }

    override fun onData(id: String, data: ByteArray) {
      flutterApi?.onStreamData(id, data) { }
    }

    override fun onClosed(id: String, error: String?) {
      flutterApi?.onStreamClosed(id, error) { }
    }
  }

  /** Routes an inbound RPC to the Dart request handler. Main thread. */
  private fun requestToDart(dto: WearerEventDto, completion: (Result<ByteArray>) -> Unit) {
    val api = flutterApi
      ?: return completion(Result.failure(IllegalStateException("engine detached")))
    api.onRequest(dto) { result ->
      completion(result)
    }
  }

  companion object {
    /**
     * Set while a Flutter engine is attached; the background listener
     * service prefers it over persisting. Volatile: written on main,
     * read from the service's binder thread.
     */
    @Volatile
    internal var liveDispatcher: ((WearerEventDto) -> Unit)? = null

    /**
     * Answers MessageClient.sendRequest RPCs while an engine is attached.
     * Called on the main thread; completion may fire on any thread.
     */
    @Volatile
    internal var liveRequestHandler:
      ((WearerEventDto, (Result<ByteArray>) -> Unit) -> Unit)? = null
  }
}

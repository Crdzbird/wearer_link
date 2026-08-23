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
    claimedLiveDispatch = true
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    if (claimedLiveDispatch) {
      liveDispatcher = null
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
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.sendMessage(path, payload) }
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

  override fun launchCompanion(callback: (Result<Unit>) -> Unit) {
    launchWith(callback) { it.launchCompanion(mainExecutor) }
  }

  override fun transferFile(
    path: String,
    filePath: String,
    callback: (Result<Unit>) -> Unit,
  ) {
    launchWith(callback) { it.transferFile(path, filePath) }
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

  override fun drainPendingEvents(callback: (Result<List<WearerEventDto>>) -> Unit) {
    val activeStore = store
      ?: return callback(Result.failure(FlutterError("unknown", "Plugin detached.", null)))
    val activeScope = scope ?: return
    activeScope.launch(Dispatchers.IO) {
      val events = activeStore.drain()
      mainHandler.post { callback(Result.success(events)) }
    }
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

  companion object {
    /**
     * Set while a Flutter engine is attached; the background listener
     * service prefers it over persisting. Volatile: written on main,
     * read from the service's binder thread.
     */
    @Volatile
    internal var liveDispatcher: ((WearerEventDto) -> Unit)? = null
  }
}

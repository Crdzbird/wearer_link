package com.crdzbird.wearer_link

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.view.FlutterCallbackInformation

/**
 * Headless Dart delivery for events that arrive while no UI engine exists.
 *
 * Flow: [WearerLinkListenerService] persists the event (crash-safe), then
 * hands it here. A background [FlutterEngine] is started (once per process)
 * on the plugin's dispatcher entrypoint; after the isolate's
 * `backgroundReady` handshake each event is pushed over
 * [WearerLinkBackgroundFlutterApi] and removed from the persistent queue
 * only when the Dart handler's future completes — an unhandled handler
 * error leaves it queued for the next foreground launch (at-least-once).
 */
internal object BackgroundDispatcher : WearerLinkBackgroundHostApi {

  private const val PREFS = "wearer_link_background"
  private const val KEY_DISPATCHER = "dispatcher_handle"
  private const val KEY_USER = "user_handle"

  private val mainHandler = Handler(Looper.getMainLooper())

  // All mutable state below is confined to the main thread.
  /**
   * True while the headless engine is being constructed. FlutterEngine
   * auto-registers all plugins (including WearerLinkPlugin) during
   * construction; this flag stops that instance from claiming the live
   * dispatcher slot meant for UI engines. Main-thread confined.
   */
  var creatingBackgroundEngine = false
    private set

  private var engine: FlutterEngine? = null
  private var api: WearerLinkBackgroundFlutterApi? = null
  private var ready = false
  private val awaitingReady = ArrayDeque<WearerEventDto>()
  private var appContext: Context? = null

  fun register(context: Context, dispatcherHandle: Long, userHandle: Long) {
    prefs(context).edit()
      .putLong(KEY_DISPATCHER, dispatcherHandle)
      .putLong(KEY_USER, userHandle)
      .apply()
  }

  fun clear(context: Context) {
    prefs(context).edit().clear().apply()
  }

  fun isRegistered(context: Context): Boolean =
    prefs(context).getLong(KEY_DISPATCHER, 0L) != 0L

  /**
   * Deliver [dto] to the background isolate, starting it if needed.
   * The event must already be persisted; it is removed on ack.
   */
  fun deliver(context: Context, dto: WearerEventDto) {
    val app = context.applicationContext
    mainHandler.post {
      appContext = app
      if (ready) {
        push(app, dto)
      } else {
        awaitingReady.add(dto)
        startEngineIfNeeded(app)
      }
    }
  }

  // -- WearerLinkBackgroundHostApi (called from the background isolate) -----

  override fun backgroundReady(): Long {
    val context = appContext
      ?: throw FlutterError("unknown", "Background engine without context.", null)
    ready = true
    // Flush on the NEXT main-loop turn: platform messages are delivered in
    // order, so events pushed inside this handler would reach the isolate
    // before the backgroundReady reply it needs to resolve the user handler.
    mainHandler.post {
      while (awaitingReady.isNotEmpty()) {
        push(context, awaitingReady.removeFirst())
      }
    }
    return prefs(context).getLong(KEY_USER, 0L)
  }

  // -- internals ------------------------------------------------------------

  private fun startEngineIfNeeded(context: Context) {
    if (engine != null) return
    val handle = prefs(context).getLong(KEY_DISPATCHER, 0L)
    if (handle == 0L) return
    // The loader must be fully initialized BEFORE the callback lookup:
    // lookupCallbackInformation is a native call into libflutter.so.
    val loader = FlutterInjector.instance().flutterLoader()
    if (!loader.initialized()) {
      loader.startInitialization(context)
    }
    loader.ensureInitializationComplete(context, null)
    val callback = FlutterCallbackInformation.lookupCallbackInformation(handle)
      ?: return // stale handle from a previous app version; queue keeps the events
    creatingBackgroundEngine = true
    val backgroundEngine = try {
      FlutterEngine(context)
    } finally {
      creatingBackgroundEngine = false
    }
    WearerLinkBackgroundHostApi.setUp(
      backgroundEngine.dartExecutor.binaryMessenger,
      this,
    )
    api = WearerLinkBackgroundFlutterApi(backgroundEngine.dartExecutor.binaryMessenger)
    backgroundEngine.dartExecutor.executeDartCallback(
      DartExecutor.DartCallback(context.assets, loader.findAppBundlePath(), callback),
    )
    engine = backgroundEngine
  }

  private fun push(context: Context, dto: WearerEventDto) {
    val activeApi = api ?: return
    activeApi.onBackgroundEvent(dto) { result ->
      if (result.isSuccess) {
        PendingEventStore(context).remove(dto.id)
      }
      // Failure: the handler threw or the isolate died — the event stays in
      // the persistent queue and replays on the next foreground launch.
    }
  }

  private fun prefs(context: Context) =
    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

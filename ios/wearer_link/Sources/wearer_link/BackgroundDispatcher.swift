import Flutter
import Foundation

/// Headless Dart delivery for events that arrive while no UI engine exists
/// (watch-triggered background launch). Mirrors the Android
/// BackgroundDispatcher: events are persisted first, pushed into a headless
/// FlutterEngine running the plugin's dispatcher entrypoint, and removed
/// from the queue only when the Dart handler's future completes.
final class BackgroundDispatcher: NSObject {
  static let shared = BackgroundDispatcher()

  private static let keyDispatcher = "wearer_link_bg_dispatcher_handle"
  private static let keyUser = "wearer_link_bg_user_handle"

  private let defaults = UserDefaults.standard

  // Main-thread confined.
  private var engine: FlutterEngine?
  private var api: WearerLinkBackgroundFlutterApi?
  private var hostApi: WearerLinkPlugin?
  private var ready = false
  private var awaitingReady: [WearerEventDto] = []

  private override init() { super.init() }

  func register(dispatcherHandle: Int64, userHandle: Int64) {
    defaults.set(dispatcherHandle, forKey: Self.keyDispatcher)
    defaults.set(userHandle, forKey: Self.keyUser)
  }

  func clear() {
    defaults.removeObject(forKey: Self.keyDispatcher)
    defaults.removeObject(forKey: Self.keyUser)
  }

  var isRegistered: Bool {
    (defaults.object(forKey: Self.keyDispatcher) as? Int64 ?? 0) != 0
  }

  /// Deliver an already-persisted event to the background isolate,
  /// starting the headless engine if needed. Call on the main thread.
  func deliver(_ event: WearerEventDto) {
    if ready {
      push(event)
    } else {
      awaitingReady.append(event)
      startEngineIfNeeded()
    }
  }

  // MARK: - internals

  private func startEngineIfNeeded() {
    guard engine == nil else { return }
    let handle = defaults.object(forKey: Self.keyDispatcher) as? Int64 ?? 0
    guard handle != 0,
      let info = FlutterCallbackCache.lookupCallbackInformation(handle)
    else { return } // stale handle; the persistent queue keeps the events
    let backgroundEngine = FlutterEngine(
      name: "wearer_link_background", project: nil, allowHeadlessExecution: true)
    guard backgroundEngine.run(
      withEntrypoint: info.callbackName, libraryURI: info.callbackLibraryPath)
    else { return }
    WearerLinkBackgroundHostApiSetup.setUp(
      binaryMessenger: backgroundEngine.binaryMessenger, api: self)
    // Expose the regular host API too, so the background handler can
    // send/sync back to the watch. Only the API — live event dispatch stays
    // with the UI engine; this isolate is fed via the background channel.
    let host = WearerLinkPlugin()
    WearerLinkHostApiSetup.setUp(
      binaryMessenger: backgroundEngine.binaryMessenger, api: host)
    hostApi = host
    api = WearerLinkBackgroundFlutterApi(
      binaryMessenger: backgroundEngine.binaryMessenger)
    engine = backgroundEngine
  }

  private func push(_ event: WearerEventDto) {
    api?.onBackgroundEvent(event: event) { result in
      if case .success = result {
        PendingEventStore.shared.remove(id: event.id)
        StatsStore.shared.increment(StatsStore.keyBackground)
      }
      // Failure: handler threw — the event stays queued for the next launch.
    }
  }
}

// MARK: - WearerLinkBackgroundHostApi

extension BackgroundDispatcher: WearerLinkBackgroundHostApi {
  func backgroundReady() throws -> Int64 {
    ready = true
    // Flush on the NEXT main-loop turn: events pushed inside this handler
    // would reach the isolate before the backgroundReady reply it needs to
    // resolve the user handler (platform messages are delivered in order).
    DispatchQueue.main.async {
      let queued = self.awaitingReady
      self.awaitingReady = []
      queued.forEach(self.push)
    }
    return defaults.object(forKey: Self.keyUser) as? Int64 ?? 0
  }
}

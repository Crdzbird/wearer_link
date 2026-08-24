import Flutter
import HealthKit
import UIKit

/// iPhone-side entry point. The WCSession itself lives in
/// WatchSessionBridge (a singleton) so background launches triggered by the
/// watch can activate it without a Flutter engine.
public class WearerLinkPlugin: NSObject, FlutterPlugin {

  private var flutterApi: WearerLinkFlutterApi?
  private let bridge = WatchSessionBridge.shared

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = WearerLinkPlugin()
    instance.flutterApi = WearerLinkFlutterApi(binaryMessenger: registrar.messenger())
    WearerLinkHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    instance.bindBridge()
    instance.bridge.activate()
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    bridge.liveDispatcher = nil
    bridge.statusListener = nil
    bridge.requestHandler = nil
    StreamRegistry.shared.onOpened = nil
    StreamRegistry.shared.onData = nil
    StreamRegistry.shared.onClosed = nil
    StreamRegistry.shared.closeAll()
    WearerLinkHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    flutterApi = nil
  }

  private func bindBridge() {
    bridge.liveDispatcher = { [weak self] event in
      guard let api = self?.flutterApi else {
        PendingEventStore.shared.append(StoredEvent(
          id: event.id,
          kindRaw: event.kind.rawValue,
          path: event.path,
          payload: event.payload.data,
          sourceNodeId: event.sourceNodeId,
          timestampMillis: event.timestampMillis,
          filePath: event.filePath))
        return
      }
      let persistOnFailure: (Result<Void, PigeonError>) -> Void = { result in
        if case .failure = result {
          // Dart handler not registered yet: keep at-least-once delivery.
          PendingEventStore.shared.append(StoredEvent(
            id: event.id,
            kindRaw: event.kind.rawValue,
            path: event.path,
            payload: event.payload.data,
            sourceNodeId: event.sourceNodeId,
            timestampMillis: event.timestampMillis,
            filePath: event.filePath))
        }
      }
      switch event.kind {
      case .message:
        api.onMessage(event: event, completion: persistOnFailure)
      case .data:
        api.onDataChanged(event: event, completion: persistOnFailure)
      case .file:
        api.onFileReceived(event: event, completion: persistOnFailure)
      }
    }
    bridge.statusListener = { [weak self] status in
      self?.flutterApi?.onConnectionStateChanged(status: status) { _ in }
    }
    StreamRegistry.shared.onOpened = { [weak self] id, path, node, incoming in
      self?.flutterApi?.onStreamOpened(
        streamId: id, path: path, sourceNodeId: node, incoming: incoming) { _ in }
    }
    StreamRegistry.shared.onData = { [weak self] id, data in
      self?.flutterApi?.onStreamData(
        streamId: id, data: FlutterStandardTypedData(bytes: data)) { _ in }
    }
    StreamRegistry.shared.onClosed = { [weak self] id, error in
      self?.flutterApi?.onStreamClosed(streamId: id, error: error) { _ in }
    }
    bridge.requestHandler = { [weak self] event, completion in
      guard let api = self?.flutterApi else {
        completion(.failure(PigeonError(
          code: "noHandler", message: "Engine detached.", details: nil)))
        return
      }
      api.onRequest(event: event) { result in
        completion(result.map { $0.data }.mapError { $0 as Error })
      }
    }
  }
}

// MARK: - WearerLinkHostApi

extension WearerLinkPlugin: WearerLinkHostApi {

  func isSupported() throws -> Bool {
    bridge.isSupported
  }

  func getCompanionStatus(completion: @escaping (Result<CompanionStatusDto, Error>) -> Void) {
    completion(.success(bridge.companionStatus()))
  }

  func sendMessage(
    path: String,
    payload: FlutterStandardTypedData,
    nodeId: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // nodeId is Android-only fan-out control; iOS has a single counterpart.
    bridge.sendMessage(path: path, payload: payload.data) { error in
      if let error { completion(.failure(error)) } else { completion(.success(())) }
    }
  }

  func sendRequest(
    path: String,
    payload: FlutterStandardTypedData,
    nodeId: String?,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    bridge.sendRequest(path: path, payload: payload.data) { result in
      completion(result.map { FlutterStandardTypedData(bytes: $0) })
    }
  }

  func readSyncData(
    path: String,
    completion: @escaping (Result<FlutterStandardTypedData?, Error>) -> Void
  ) {
    completion(.success(bridge.readSyncData(path: path).map {
      FlutterStandardTypedData(bytes: $0)
    }))
  }

  func deleteSyncData(
    path: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try bridge.deleteSyncData(path: path)
      completion(.success(()))
    } catch {
      completion(.failure(PigeonError(code: "unknown", message: "\(error)", details: nil)))
    }
  }

  func syncData(
    path: String,
    payload: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try bridge.syncData(path: path, payload: payload.data)
      completion(.success(()))
    } catch {
      completion(.failure(
        PigeonError(code: "sendFailed", message: "\(error)", details: nil)))
    }
  }

  func transferData(
    path: String,
    payload: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try bridge.transferData(path: path, payload: payload.data)
      completion(.success(()))
    } catch {
      completion(.failure(PigeonError(code: "sendFailed", message: "\(error)", details: nil)))
    }
  }

  func getCapabilities() throws -> WearerCapabilitiesDto {
    bridge.capabilities()
  }

  func setEventDeliveryEnabled(enabled: Bool) throws {
    bridge.setDeliveryEnabled(enabled)
  }

  func isEventDeliveryEnabled() throws -> Bool {
    bridge.deliveryEnabled
  }

  func openStream(
    path: String,
    nodeId: String?,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard bridge.deliveryEnabled else {
      completion(.failure(PigeonError(
        code: "unsupported", message: "Event delivery is disabled.", details: nil)))
      return
    }
    StreamRegistry.shared.openStream(path: path, completion: completion)
  }

  func sendStreamData(
    streamId: String,
    data: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    StreamRegistry.shared.send(id: streamId, data: data.data, completion: completion)
  }

  func closeStream(
    streamId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    StreamRegistry.shared.close(id: streamId)
    completion(.success(()))
  }

  func transferFile(
    path: String,
    filePath: String,
    nodeId: String?,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try bridge.transferFile(path: path, filePath: filePath)
      completion(.success(()))
    } catch {
      completion(.failure(error))
    }
  }

  func updateComplication(
    payload: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    bridge.updateComplication(payload: payload.data)
    completion(.success(()))
  }

  func requestSurfaceUpdate(
    component: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // watchOS complications reload from the native watch app (ClockKit /
    // WidgetKit); the phone cannot request it. OS policy, typed error.
    completion(.failure(PigeonError(
      code: "unsupported",
      message: "requestSurfaceUpdate is Wear OS-only; on watchOS reload "
        + "complications from the watch app after it receives your data.",
      details: nil)))
  }

  func registerBackgroundHandler(dispatcherHandle: Int64, userHandle: Int64) throws {
    BackgroundDispatcher.shared.register(
      dispatcherHandle: dispatcherHandle, userHandle: userHandle)
  }

  func clearBackgroundHandler() throws {
    BackgroundDispatcher.shared.clear()
  }

  /// iOS can only launch the watch app for a HealthKit workout session —
  /// an OS policy, surfaced as a typed error everywhere else.
  func launchCompanion(completion: @escaping (Result<Void, Error>) -> Void) {
    guard HKHealthStore.isHealthDataAvailable() else {
      completion(.failure(PigeonError(
        code: "unsupported",
        message: "iOS only allows launching the watch app via a HealthKit "
          + "workout session, and HealthKit is unavailable on this device.",
        details: nil)))
      return
    }
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = .other
    HKHealthStore().startWatchApp(with: configuration) { success, error in
      DispatchQueue.main.async {
        if success {
          completion(.success(()))
        } else {
          completion(.failure(PigeonError(
            code: "launchFailed",
            message: "startWatchApp failed: \(error.map(String.init(describing:)) ?? "unknown")",
            details: nil)))
        }
      }
    }
  }

  func drainPendingEvents(completion: @escaping (Result<[WearerEventDto], Error>) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      let events = PendingEventStore.shared.drain()
        .map { $0.toDto(deliveredWhileDead: true) }
      DispatchQueue.main.async {
        completion(.success(events))
      }
    }
  }
}

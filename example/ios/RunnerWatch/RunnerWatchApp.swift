import SwiftUI
import WearerLinkWatch

@main
struct RunnerWatchApp: App {
  init() {
    WearerLinkWatch.shared.activate()
  }
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @State private var log: [String] = []
  @State private var reachable = false
  @State private var counter = 0

  var body: some View {
    List {
      Text(reachable ? "phone: reachable" : "phone: unreachable")
        .font(.caption2)
        .foregroundStyle(reachable ? .green : .secondary)
      Button("Ping") {
        WearerLinkWatch.shared.sendMessage(
          path: "/ping",
          payload: Data("watch ping".utf8)
        ) { error in
          append(error == nil ? "ping ok" : "ping failed: \(error!)")
        }
      }
      Button("Request") {
        WearerLinkWatch.shared.sendRequest(
          path: "/echo",
          payload: Data("hello from watch".utf8)
        ) { result in
          switch result {
          case .success(let data):
            append("reply: \(String(decoding: data, as: UTF8.self))")
          case .failure(let error):
            append("request failed: \(error)")
          }
        }
      }
      Button("Sync counter") {
        counter += 1
        try? WearerLinkWatch.shared.syncData(
          path: "/counter",
          payload: Data("{\"value\":\(counter)}".utf8)
        )
        append("synced \(counter)")
      }
      ForEach(log.indices, id: \.self) { i in
        Text(log[i]).font(.caption2)
      }
    }
    .onAppear {
      WearerLinkWatch.shared.onReachabilityChange = { value in
        reachable = value
      }
      reachable = WearerLinkWatch.shared.isReachable
      WearerLinkWatch.shared.onEvent = { event in
        append("\(event.isDataEvent ? "data" : "msg") \(event.path): "
          + String(decoding: event.payload, as: UTF8.self))
      }
      // Echo phone-initiated streams back, uppercased.
      WearerLinkWatch.shared.onIncomingStream = { stream in
        append("stream in \(stream.path)")
        stream.onData = { chunk in
          let text = String(decoding: chunk, as: UTF8.self)
          append("stream← \(text)")
          stream.send(Data(text.uppercased().utf8))
        }
        stream.onClose = { error in
          append("stream closed\(error.map { ": \($0)" } ?? "")")
        }
      }
      // Answer phone sendRequest round trips: echo, uppercased.
      WearerLinkWatch.shared.onRequest = { event, reply in
        append("request \(event.path)")
        reply(Data(String(decoding: event.payload, as: UTF8.self)
          .uppercased().utf8))
      }
    }
  }

  private func append(_ line: String) {
    log.insert(line, at: 0)
    if log.count > 30 { log.removeLast() }
  }
}

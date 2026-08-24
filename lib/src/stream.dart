import 'dart:async';
import 'dart:typed_data';

/// A live bidirectional byte stream to the counterpart device.
///
/// Android carries it over a native ChannelClient channel (socket-like);
/// iOS/watchOS frame it over interactive messages. Either way it needs a
/// reachable counterpart for its whole lifetime — when the link drops the
/// stream closes with an error.
class WearerStream {
  WearerStream.internal(
    this.id,
    this.path,
    this.peerNodeId,
    this._send,
    this._close,
  ) {
    // An abnormal close must not crash apps that never await [done].
    _done.future.ignore();
  }

  /// Plugin-assigned stream id (stable for the stream's lifetime).
  final String id;

  /// The application path this stream was opened on.
  final String path;

  /// Node id of the other end.
  final String peerNodeId;

  final Future<void> Function(String id, Uint8List bytes) _send;
  final Future<void> Function(String id) _close;

  final _incoming = StreamController<Uint8List>();
  final _done = Completer<void>();
  bool _closed = false;

  /// Bytes from the counterpart, in order. Closes when the stream ends.
  Stream<Uint8List> get data => _incoming.stream;

  /// Completes when the stream is fully closed; with an error when it was
  /// torn down abnormally (peer vanished, transport failure).
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  /// Send bytes to the counterpart. Chunked internally where the transport
  /// requires it; the future completes when the transport accepted them.
  Future<void> send(Uint8List bytes) {
    if (_closed) {
      throw StateError('WearerStream($path) is closed');
    }
    return _send(id, bytes);
  }

  /// Close both directions. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    await _close(id);
    // onStreamClosed finishes the bookkeeping; nothing else to do here.
  }

  /// Called by the facade when the native side reports data.
  void addData(Uint8List bytes) {
    if (!_closed) _incoming.add(bytes);
  }

  /// Called by the facade when the native side reports closure.
  void markClosed(String? error) {
    if (_closed) return;
    _closed = true;
    if (error != null && !_incoming.hasListener) {
      // Nobody will see the stream error; surface it via [done] only.
    }
    if (error != null) {
      _incoming.addError(StateError('WearerStream($path): $error'));
    }
    _incoming.close();
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(StateError('WearerStream($path): $error'));
    }
  }
}

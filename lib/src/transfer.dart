import 'dart:async';

import 'package:meta/meta.dart';

/// A file transfer with observable progress (see
/// `WearerLink.transferFileTracked`).
class WearerFileTransfer {
  /// Internal: created by the facade.
  @internal
  WearerFileTransfer.internal(this.path, this.totalBytes) {
    _done.future.ignore(); // callers may watch only [progress]
  }

  /// The application path the file was sent on.
  final String path;

  /// Size of the file being transferred.
  final int totalBytes;

  final _progress = StreamController<double>.broadcast();
  final _done = Completer<void>();
  int _sentBytes = 0;

  /// Fraction sent so far, 0.0 → 1.0. "Sent" means the transport accepted
  /// the bytes; the receiver finishes writing at stream close.
  Stream<double> get progress => _progress.stream;

  /// Fraction sent so far (same value the stream last emitted).
  double get fraction => totalBytes == 0 ? 1.0 : _sentBytes / totalBytes;

  /// Completes when the whole file was handed to the transport and the
  /// stream closed cleanly; errors when the link failed mid-transfer.
  Future<void> get done => _done.future;

  /// Internal: record [count] more accepted bytes.
  @internal
  void addSent(int count) {
    _sentBytes += count;
    if (!_progress.isClosed) _progress.add(fraction);
  }

  /// Internal: finish (null = success).
  @internal
  void finish([Object? error]) {
    if (_done.isCompleted) return;
    if (error == null) {
      if (!_progress.isClosed) _progress.add(1.0);
      _done.complete();
    } else {
      _done.completeError(error);
    }
    _progress.close();
  }
}

/// A snapshot of this session's traffic counters (see `WearerLink.stats`).
class WearerStats {
  /// Creates a snapshot (produced by the plugin).
  const WearerStats({
    required this.sentEvents,
    required this.receivedEvents,
    required this.replayedEvents,
    required this.dedupDropped,
    required this.activeStreams,
  });

  /// Messages/data/files handed to the transport this session.
  final int sentEvents;

  /// Events dispatched to this app this session (replays included).
  final int receivedEvents;

  /// Received events that had been queued while the app was dead/paused.
  final int replayedEvents;

  /// Duplicate event ids dropped by the session dedup.
  final int dedupDropped;

  /// Currently open bidirectional streams.
  final int activeStreams;

  @override
  String toString() =>
      'WearerStats(sent: $sentEvents, received: $receivedEvents, '
      'replayed: $replayedEvents, dedupDropped: $dedupDropped, '
      'streams: $activeStreams)';
}

/// Severity of a [WearerDiagnostic].
enum WearerDiagnosticSeverity {
  /// Informational; no action needed.
  info,

  /// Unexpected but recovered (e.g. an abnormal stream close).
  warning,

  /// Something was lost or rejected (e.g. a cipher-mismatch drop).
  error,
}

/// An observable plugin-internal event that would otherwise die silently
/// (see `WearerLink.diagnostics`).
class WearerDiagnostic {
  /// Creates a diagnostic stamped with the current time.
  WearerDiagnostic(this.severity, this.area, this.message)
      : timestamp = DateTime.now();

  /// How bad it is.
  final WearerDiagnosticSeverity severity;

  /// Subsystem tag, e.g. `stream`, `request`, `replay`, `launch`.
  final String area;

  /// Human-readable description.
  final String message;

  /// When it happened.
  final DateTime timestamp;

  @override
  String toString() =>
      '[${severity.name}] $area: $message (${timestamp.toIso8601String()})';
}

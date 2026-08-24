import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'messages.g.dart';

/// A reactive key-value store synced between phone and watch.
///
/// Both sides read and write the same keys; the newest write wins
/// (last-writer-wins by sender timestamp, with a stable per-endpoint
/// tiebreak — sender clocks are trusted, the standard trade-off for this
/// kind of store). Values persist in the OS sync layer itself (Android
/// DataItems / iOS applicationContext), so they survive app restarts and
/// arrive even when written while the other side was unreachable.
///
/// Deletes propagate as tombstones so both sides converge; a tombstone
/// occupies one small record per deleted key until the key is written
/// again.
///
/// Values above the single-message budget are rejected with an
/// [ArgumentError] — the store is for state, not payload transport; use
/// `transferData`/`transferFile` for bulk bytes.
class WearerStore {
  /// Internal: obtain via `WearerLink.store`.
  WearerStore.internal(this._host);

  static const _prefix = '/__wlstore/';
  static const _maxValueBytes = 48 * 1024;

  final WearerLinkHostApi _host;
  final String _writerId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  final _watchers = <String, StreamController<Uint8List?>>{};

  /// Local last-known record per key, merged from own writes and inbound
  /// counterpart records. Backed by the OS sync layer for cold reads.
  final _cache = <String, _StoreRecord>{};
  final _cachedKeys = <String>{};

  /// Write [value] for [key]; the counterpart's watchers see it too.
  Future<void> set(String key, Uint8List value) async {
    _checkKey(key);
    if (value.length > _maxValueBytes) {
      throw ArgumentError(
        'Store values are capped at $_maxValueBytes bytes '
        '(got ${value.length}); use transferData/transferFile for bulk '
        'bytes and store a reference instead.',
      );
    }
    final record = _StoreRecord(
      timestampMillis: DateTime.now().millisecondsSinceEpoch,
      writerId: _writerId,
      deleted: false,
      value: value,
    );
    await _host.syncData(_prefix + key, record.encode());
    _apply(key, record);
  }

  /// Delete [key] on both sides (propagates as a tombstone).
  Future<void> delete(String key) async {
    _checkKey(key);
    final record = _StoreRecord(
      timestampMillis: DateTime.now().millisecondsSinceEpoch,
      writerId: _writerId,
      deleted: true,
      value: null,
    );
    await _host.syncData(_prefix + key, record.encode());
    _apply(key, record);
  }

  /// Current value for [key], or null when absent/deleted. Cold reads pull
  /// from the OS sync layer; later reads are served from the merged cache.
  Future<Uint8List?> get(String key) async {
    _checkKey(key);
    final record = await _resolve(key);
    return record == null || record.deleted ? null : record.value;
  }

  /// Live values for [key]: emits on every accepted write/delete from
  /// either side (null for deletes). Listen, then [get] for the current
  /// value.
  Stream<Uint8List?> watch(String key) {
    _checkKey(key);
    return _watcher(key).stream;
  }

  /// Keys currently present (tombstoned keys excluded).
  Future<Set<String>> keys() async {
    final paths = await _host.listSyncPaths(_prefix);
    final result = <String>{};
    for (final path in paths) {
      final key = path.substring(_prefix.length);
      final record = await _resolve(key);
      if (record != null && !record.deleted) result.add(key);
    }
    return result;
  }

  /// Internal: an inbound counterpart record (facade routes reserved-path
  /// data events here).
  void onRemoteRecord(String path, Uint8List payload) {
    final key = path.substring(_prefix.length);
    final record = _StoreRecord.decode(payload);
    if (record == null) return;
    _apply(key, record);
  }

  // -- internals ------------------------------------------------------------

  /// Merge [record] into the cache; emit to watchers only if it wins.
  void _apply(String key, _StoreRecord record) {
    final current = _cache[key];
    if (current != null && !record.wins(current)) return;
    _cache[key] = record;
    _cachedKeys.add(key);
    _watchers[key]?.add(record.deleted ? null : record.value);
  }

  Future<_StoreRecord?> _resolve(String key) async {
    if (_cachedKeys.contains(key)) return _cache[key];
    // Cold read: merge both sides' persisted records once.
    final own = _StoreRecord.decode(await _host.readOwnSyncData(_prefix + key));
    final theirs = _StoreRecord.decode(await _host.readSyncData(_prefix + key));
    final winner = switch ((own, theirs)) {
      (null, final t) => t,
      (final o, null) => o,
      (final o!, final t!) => t.wins(o) ? t : o,
    };
    // A racing _apply may have cached a fresher record meanwhile — merge,
    // don't overwrite.
    if (winner != null) _apply(key, winner);
    _cachedKeys.add(key);
    return _cache[key];
  }

  StreamController<Uint8List?> _watcher(String key) =>
      _watchers.putIfAbsent(key, StreamController<Uint8List?>.broadcast);

  void _checkKey(String key) {
    if (key.isEmpty || key.contains('/')) {
      throw ArgumentError.value(key, 'key', 'must be non-empty, without "/"');
    }
  }
}

/// One store record on the wire: JSON {t, n, d, v(base64)}.
class _StoreRecord {
  _StoreRecord({
    required this.timestampMillis,
    required this.writerId,
    required this.deleted,
    required this.value,
  });

  final int timestampMillis;
  final String writerId;
  final bool deleted;
  final Uint8List? value;

  /// Last-writer-wins with a stable tiebreak; ties (same clock, same
  /// writer id ordering) keep the incumbent.
  bool wins(_StoreRecord other) =>
      timestampMillis > other.timestampMillis ||
      (timestampMillis == other.timestampMillis &&
          writerId.compareTo(other.writerId) > 0);

  Uint8List encode() => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            't': timestampMillis,
            'n': writerId,
            'd': deleted,
            if (value != null) 'v': base64Encode(value!),
          }),
        ),
      );

  static _StoreRecord? decode(Uint8List? payload) {
    if (payload == null) return null;
    try {
      final json = jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
      final encoded = json['v'] as String?;
      return _StoreRecord(
        timestampMillis: json['t'] as int,
        writerId: json['n'] as String? ?? '',
        deleted: json['d'] as bool? ?? false,
        value: encoded == null ? null : base64Decode(encoded),
      );
    } catch (_) {
      return null; // corrupt/foreign record: ignore rather than crash
    }
  }
}

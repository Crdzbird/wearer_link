import 'dart:convert';
import 'dart:typed_data';

/// Converts typed values to/from the raw payload bytes that cross the
/// device boundary. Register per type with `WearerLink.registerCodec`.
abstract class WearerCodec<T> {
  /// Value -> payload bytes.
  Uint8List encode(T value);

  /// Payload bytes -> value.
  T decode(Uint8List bytes);
}

/// JSON-over-UTF-8 codec.
///
/// [fromJson] builds the value from a decoded JSON map. Encoding uses
/// [toJson] when given, otherwise the value's own `toJson()` method (the
/// json_serializable convention).
class WearerJsonCodec<T> implements WearerCodec<T> {
  /// Creates the codec; see [fromJson]/[toJson].
  const WearerJsonCodec(this.fromJson, {this.toJson});

  /// Builds a value from a decoded JSON map.
  final T Function(Map<String, Object?> json) fromJson;

  /// Optional explicit serializer; defaults to the value's own `toJson()`.
  final Object? Function(T value)? toJson;

  @override
  Uint8List encode(T value) {
    final json = toJson != null ? toJson!(value) : (value as dynamic).toJson();
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  @override
  T decode(Uint8List bytes) =>
      fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, Object?>);
}

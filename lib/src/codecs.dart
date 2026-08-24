import 'dart:convert';
import 'dart:typed_data';

/// Converts typed values to/from the raw payload bytes that cross the
/// device boundary. Register per type with `WearerLink.registerCodec`.
abstract class WearerCodec<T> {
  Uint8List encode(T value);

  T decode(Uint8List bytes);
}

/// JSON-over-UTF-8 codec.
///
/// [fromJson] builds the value from a decoded JSON map. Encoding uses
/// [toJson] when given, otherwise the value's own `toJson()` method (the
/// json_serializable convention).
class WearerJsonCodec<T> implements WearerCodec<T> {
  const WearerJsonCodec(this.fromJson, {this.toJson});

  final T Function(Map<String, Object?> json) fromJson;
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

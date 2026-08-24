import 'dart:typed_data';

/// App-supplied payload encryption (see `WearerLink.setPayloadCipher`).
///
/// The plugin never invents cryptography: the app owns the algorithm and
/// the key exchange; the plugin guarantees which bytes pass through it.
/// Covered: messages, requests (both legs), data transfers (blob route
/// included), store records, and every stream chunk (tracked file
/// transfers ride streams, so their bodies are covered too).
///
/// NOT covered — documented, not silent: plain `transferFile` bodies (read
/// natively, Dart never sees the bytes), the built-in `/__wlstatus` vitals
/// probe, and `launchCompanion` route/args (on Android they also travel in
/// the launch URI).
///
/// Encrypted payloads carry a 4-byte marker so a cipher-less counterpart
/// drops them with a diagnostic instead of emitting ciphertext, and a
/// ciphered endpoint drops unmarked plaintext the same way.
class WearerCipher {
  const WearerCipher({required this.encrypt, required this.decrypt});

  /// Encrypt [bytes] leaving this device on [path].
  final Future<Uint8List> Function(String path, Uint8List bytes) encrypt;

  /// Decrypt [bytes] arriving on [path]. Throwing rejects the payload
  /// (dropped with a diagnostic; requests fail typed on the sender side).
  final Future<Uint8List> Function(String path, Uint8List bytes) decrypt;
}

import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'messages.g.dart';
import 'models.dart';

/// Signature of the app's background handler: a **top-level or static**
/// function that receives events while the app has no UI running.
///
/// Runs in a dedicated headless isolate — no access to the UI isolate's
/// state, and only this plugin's channels are registered. Keep it fast; the
/// OS may reclaim the process shortly after delivery.
typedef WearerBackgroundHandler = Future<void> Function(WearerEvent event);

/// Entrypoint executed by the native side inside the headless background
/// engine. Not for direct use.
@pragma('vm:entry-point')
Future<void> wearerLinkBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final host = WearerLinkBackgroundHostApi();
  final dispatcher = _BackgroundDispatcher();
  WearerLinkBackgroundFlutterApi.setUp(dispatcher);
  // Handshake: fetch the user handler; native starts delivering events only
  // after this returns, so the late assignment below cannot be raced.
  final rawHandle = await host.backgroundReady();
  final callback = PluginUtilities.getCallbackFromHandle(
    CallbackHandle.fromRawHandle(rawHandle),
  );
  dispatcher.handler = callback is WearerBackgroundHandler ? callback : null;
}

class _BackgroundDispatcher implements WearerLinkBackgroundFlutterApi {
  WearerBackgroundHandler? handler;

  @override
  Future<void> onBackgroundEvent(WearerEventDto event) async {
    final active = handler;
    if (active == null) {
      // Handler no longer resolvable (e.g. renamed between app versions).
      // Completing normally would ack — and drop — the event; throwing keeps
      // it in the native queue for the next foreground launch.
      throw StateError(
        'wearer_link: registered background handler could not be resolved. '
        'Re-register with WearerLink.registerBackgroundHandler.',
      );
    }
    await active(WearerEvent.fromDto(event));
  }
}

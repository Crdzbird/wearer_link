import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';
import 'package:wearer_link/wearer_link.dart';

/// Runs in a headless isolate when an event arrives while the app is dead.
/// Sends a visible ack back to the counterpart as proof of life.
@pragma('vm:entry-point')
Future<void> demoBackgroundHandler(WearerEvent event) async {
  // ignore: avoid_print
  print('wearer_link demo: background event ${event.kind.name} ${event.path}');
  await WearerLink.instance.sendJson('/bg-ack', {
    'handled': event.path,
    'kind': event.kind.name,
  });
}

void main() => runApp(const WearerLinkDemo());

/// Demo app: every wearer_link capability, with real media rendered —
/// received photos display, audio plays, video plays.
class WearerLinkDemo extends StatelessWidget {
  const WearerLinkDemo({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'wearer_link demo',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _link = WearerLink.instance;
  final _log = <String>[];
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _recorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();

  WearerCompanionStatus? _status;
  int _counter = 0;
  Timer? _startupProbe;

  // Visual results.
  int? _syncedCounter;
  Duration? _rtt;
  WearerCounterpartVitals? _vitals;
  double? _transferProgress;
  String? _transferLabel;

  // Received media.
  String? _receivedImagePath;
  String? _receivedAudioPath;
  bool _audioPlaying = false;
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        _link.messages.listen(
          (e) => _append(
            'msg ${e.path}: ${_decode(e.payload)}'
            '${e.deliveredWhileDead ? ' (replayed)' : ''}',
          ),
        ),
      )
      ..add(
        _link.dataEvents.listen((e) {
          _append(
            'data ${e.path}: ${_decode(e.payload)}'
            '${e.deliveredWhileDead ? ' (replayed)' : ''}',
          );
          if (e.path == '/counter') {
            final value =
                (jsonDecode(utf8.decode(e.payload))
                    as Map<String, Object?>)['value'];
            if (value is int) setState(() => _syncedCounter = value);
          }
        }),
      )
      ..add(_link.fileEvents.listen(_onFile))
      ..add(_link.connectionState.listen((s) => setState(() => _status = s)))
      ..add(
        _link.launchIntents.listen(
          (intent) => _append('launch intent: ${intent.route} ${intent.args}'),
        ),
      )
      ..add(
        _audioPlayer.onPlayerComplete.listen(
          (_) => setState(() => _audioPlaying = false),
        ),
      );
    // Echo every incoming stream back, uppercased.
    _subscriptions.add(
      _link.incomingStreams.listen((stream) {
        _append('stream in ${stream.path}');
        stream.data.listen(
          (chunk) {
            _append('stream← ${_decode(chunk)}');
            stream.send(
              Uint8List.fromList(utf8.encode(_decode(chunk).toUpperCase())),
            );
          },
          onError: (Object e) => _append('stream error: $e'),
          onDone: () => _append('stream in done'),
        );
      }),
    );
    // Answer sendRequest round trips from the counterpart: echo, uppercased.
    _link.setRequestHandler((request) async {
      _append('request ${request.path}: ${_decode(request.payload)}');
      return Uint8List.fromList(
        utf8.encode(_decode(request.payload).toUpperCase()),
      );
    });
    _refreshStatus();
    _link
        .registerBackgroundHandler(demoBackgroundHandler)
        .catchError((Object e) => _append('bg register failed: $e'));
    // Headless verification aid: log link state to the console on startup.
    _startupProbe = Timer(const Duration(seconds: 3), () async {
      try {
        final value = await _link.store.get('demo');
        debugPrint(
          'wearer_demo startup store.get(demo) = '
          '${value == null ? 'null' : _decode(value)}',
        );
        debugPrint('wearer_demo startup ${await _link.getPersistentStats()}');
      } catch (e) {
        debugPrint('wearer_demo startup probe failed: $e');
      }
    });
  }

  @override
  void dispose() {
    _startupProbe?.cancel();
    _video?.dispose();
    _audioPlayer.dispose();
    _recorder.dispose();
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  // -- receiving media ------------------------------------------------------

  Future<void> _onFile(WearerEvent e) async {
    _append(
      'file ${e.path}: ${e.filePath}'
      '${e.deliveredWhileDead ? ' (replayed)' : ''}',
    );
    final path = e.filePath;
    if (path == null) return;
    switch (e.path) {
      case '/photo':
        setState(() => _receivedImagePath = path);
      case '/audio':
        setState(() => _receivedAudioPath = path);
        await _playAudio(path); // hear it as it lands
      case '/video':
        final controller = VideoPlayerController.file(File(path));
        await controller.initialize();
        await controller.setLooping(true);
        await controller.play();
        setState(() {
          _video?.dispose();
          _video = controller;
        });
    }
  }

  Future<void> _playAudio(String path) async {
    await _audioPlayer.stop();
    await _audioPlayer.play(DeviceFileSource(path));
    setState(() => _audioPlaying = true);
  }

  // -- helpers --------------------------------------------------------------

  String _decode(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      return text.length > 60
          ? '${text.substring(0, 60)}… (${bytes.length}B)'
          : text;
    } on FormatException {
      return '${bytes.length} bytes';
    }
  }

  void _append(String line) {
    setState(() => _log.insert(0, '${TimeOfDay.now().format(context)}  $line'));
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await _link.getCompanionStatus();
      setState(() => _status = status);
    } on WearerLinkException catch (e) {
      _append('status error: $e');
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    try {
      await action();
      _append('$label ok');
    } on WearerLinkException catch (e) {
      _append('$label failed: ${e.code.name} — ${e.message}');
    } catch (e) {
      _append('$label failed: $e');
    }
  }

  /// Send [filePath] with live progress + throughput in the media panel.
  Future<void> _trackedSend(String path, String filePath, String label) async {
    final started = DateTime.now();
    final transfer = await _link.transferFileTracked(path, filePath);
    setState(() {
      _transferProgress = 0;
      _transferLabel = label;
    });
    transfer.progress.listen((p) => setState(() => _transferProgress = p));
    try {
      await transfer.done;
      final seconds =
          DateTime.now().difference(started).inMilliseconds / 1000.0;
      final mbps = seconds == 0
          ? 0
          : transfer.totalBytes / (1024 * 1024) / seconds;
      _append(
        '$label sent: ${transfer.totalBytes}B in '
        '${seconds.toStringAsFixed(2)}s (${mbps.toStringAsFixed(2)} MB/s)',
      );
    } finally {
      setState(() {
        _transferProgress = null;
        _transferLabel = null;
      });
    }
  }

  // -- media senders --------------------------------------------------------

  Future<void> _sharePhoto() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) {
      _append('photo: nothing picked');
      return;
    }
    await _trackedSend('/photo', picked.path, 'photo');
  }

  Future<void> _recordAndSendAudio() async {
    if (!await _recorder.hasPermission()) {
      _append('audio: microphone permission denied');
      return;
    }
    final path =
        '${Directory.systemTemp.path}/wearer_clip_'
        '${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(), path: path);
    _append('audio: recording 5s…');
    await Future<void>.delayed(const Duration(seconds: 5));
    final recorded = await _recorder.stop();
    if (recorded == null) {
      _append('audio: recording failed');
      return;
    }
    await _trackedSend('/audio', recorded, 'audio clip');
  }

  Future<void> _sendVideo() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) {
      _append('video: nothing picked');
      return;
    }
    await _trackedSend('/video', picked.path, 'video');
  }

  // -- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final status = _status;
    // Watch mode: round Wear OS screens get compact controls, fitted media
    // and bezel-safe padding instead of the phone layout squeezed down.
    final isWatch = MediaQuery.sizeOf(context).shortestSide < 300;
    final theme = Theme.of(context);
    final body = Theme(
      data: isWatch
          ? theme.copyWith(
              visualDensity: VisualDensity.compact,
              filledButtonTheme: FilledButtonThemeData(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              outlinedButtonTheme: OutlinedButtonThemeData(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            )
          : theme,
      child: SafeArea(
        child: ListView(
          padding: isWatch
              ? const EdgeInsets.fromLTRB(20, 28, 20, 40)
              : EdgeInsets.zero,
          children: [
            ListTile(
              dense: isWatch,
              contentPadding: isWatch ? EdgeInsets.zero : null,
              leading: isWatch
                  ? null
                  : Icon(
                      status?.isReachable ?? false
                          ? Icons.watch
                          : Icons.watch_off,
                      color: status?.isReachable ?? false
                          ? Colors.green
                          : Colors.grey,
                    ),
              title: Text(
                isWatch
                    ? (status?.state.name ?? '…')
                    : 'Companion: ${status?.state.name ?? '…'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isWatch
                    ? TextStyle(
                        fontSize: 13,
                        color: status?.isReachable ?? false
                            ? Colors.green
                            : Colors.grey,
                      )
                    : null,
              ),
              subtitle: isWatch
                  ? null
                  : Text('nodes: ${status?.nodes.join(', ') ?? '-'}'),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshStatus,
              ),
            ),
            // Live result chips instead of log-only text.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  if (_syncedCounter != null)
                    _chip(isWatch, Icons.sync, 'counter $_syncedCounter'),
                  if (_rtt != null)
                    _chip(isWatch, Icons.speed, '${_rtt!.inMilliseconds}ms'),
                  if (_vitals != null)
                    _chip(
                      isWatch,
                      _vitals!.isCharging
                          ? Icons.battery_charging_full
                          : Icons.battery_std,
                      isWatch
                          ? '${_vitals!.batteryPercent}%'
                          : '${_vitals!.model} ${_vitals!.batteryPercent}%',
                    ),
                ],
              ),
            ),
            OverflowBar(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _run('photo', _sharePhoto),
                  child: const Text('Share photo'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('audio', _recordAndSendAudio),
                  child: const Text('Record 5s audio'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('video', _sendVideo),
                  child: const Text('Send video'),
                ),
                FilledButton(
                  onPressed: () => _run(
                    'ping',
                    () => _link.sendJson('/ping', {'at': '${DateTime.now()}'}),
                  ),
                  child: const Text('Ping'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('sync', () {
                    _counter++;
                    setState(() => _syncedCounter = _counter);
                    return _link.syncData(
                      '/counter',
                      utf8.encode(jsonEncode({'value': _counter})),
                    );
                  }),
                  child: const Text('Sync counter'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run(
                    'transfer',
                    () => _link.transferData(
                      '/note',
                      utf8.encode('queued at ${DateTime.now()}'),
                    ),
                  ),
                  child: const Text('Transfer'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('request', () async {
                    final reply = await _link.sendRequest(
                      '/echo',
                      Uint8List.fromList(utf8.encode('hello rpc')),
                    );
                    _append('reply: ${_decode(reply)}');
                  }),
                  child: const Text('Request'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('read', () async {
                    final value = await _link.readSyncData('/counter');
                    _append(
                      'sync /counter = '
                      '${value == null ? 'null' : _decode(value)}',
                    );
                  }),
                  child: const Text('Read sync'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('store', () async {
                    await _link.store.set(
                      'demo',
                      Uint8List.fromList(
                        utf8.encode('saved ${DateTime.now()}'),
                      ),
                    );
                    _append(
                      'store demo = '
                      '${_decode((await _link.store.get('demo'))!)}',
                    );
                  }),
                  child: const Text('Store'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('storeget', () async {
                    final value = await _link.store.get('demo');
                    _append(
                      'store demo = '
                      '${value == null ? 'null' : _decode(value)}',
                    );
                  }),
                  child: const Text('Store get'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('status', () async {
                    final nodes = await _link.getNodes();
                    _append('nodes: $nodes');
                    final vitals = await _link.getCounterpartVitals();
                    final rtt = await _link.pingLatency();
                    setState(() {
                      _vitals = vitals;
                      _rtt = rtt;
                    });
                    _append('persistent: ${await _link.getPersistentStats()}');
                  }),
                  child: const Text('Status'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('stream', () async {
                    final stream = await _link.openStream('/live');
                    _append('stream open ${stream.id.substring(0, 8)}');
                    stream.data.listen(
                      (chunk) => _append('stream← ${_decode(chunk)}'),
                      onError: (Object e) => _append('stream error: $e'),
                      onDone: () => _append('stream done'),
                    );
                    for (var i = 1; i <= 3; i++) {
                      await stream.send(
                        Uint8List.fromList(utf8.encode('chunk $i')),
                      );
                    }
                    await Future<void>.delayed(const Duration(seconds: 3));
                    await stream.close();
                  }),
                  child: const Text('Stream'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('big', () async {
                    final payload = Uint8List.fromList(
                      List.generate(150 * 1024, (i) => 0x61 + (i % 26)),
                    );
                    await _link.transferData('/big', payload);
                    _append('big sent ${payload.length}B');
                  }),
                  child: const Text('Big transfer'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('file', () async {
                    final file = File(
                      '${Directory.systemTemp.path}/wearer_demo.txt',
                    );
                    await file.writeAsString(
                      'file payload written at ${DateTime.now()}',
                    );
                    return _link.transferFile('/demo-file', file.path);
                  }),
                  child: const Text('Send file'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('tile', () async {
                    await _link.store.set(
                      'demo',
                      Uint8List.fromList(utf8.encode('tile ${DateTime.now()}')),
                    );
                    await _link.requestSurfaceUpdate(
                      'com.crdzbird.wearer_link_example.DemoTileService',
                    );
                    _append('tile refresh requested');
                  }),
                  child: const Text('Tile refresh'),
                ),
                OutlinedButton(
                  onPressed: () => _run(
                    'launch',
                    () => _link.launchCompanion(
                      route: '/workout',
                      args: {'id': 42},
                    ),
                  ),
                  child: const Text('Launch companion'),
                ),
              ],
            ),
            if (_transferProgress != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'sending $_transferLabel '
                      '${(_transferProgress! * 100).toStringAsFixed(0)}%',
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: _transferProgress),
                  ],
                ),
              ),
            // ---- received media, rendered for real ----
            if (_receivedImagePath != null)
              Card(
                margin: const EdgeInsets.all(8),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Image.file(
                      File(_receivedImagePath!),
                      height: isWatch ? 90 : 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                    _mediaCaption(isWatch, Icons.image, 'received photo'),
                  ],
                ),
              ),
            if (_receivedAudioPath != null)
              Card(
                margin: const EdgeInsets.all(8),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isWatch ? 8 : 16,
                    vertical: isWatch ? 2 : 8,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          _audioPlaying
                              ? Icons.stop_circle
                              : Icons.play_circle_fill,
                          size: isWatch ? 28 : 36,
                        ),
                        onPressed: () async {
                          if (_audioPlaying) {
                            await _audioPlayer.stop();
                            setState(() => _audioPlaying = false);
                          } else {
                            await _playAudio(_receivedAudioPath!);
                          }
                        },
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _audioPlaying ? 'audio: playing…' : 'audio clip',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: isWatch ? 12 : 15),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_video != null && _video!.value.isInitialized)
              Card(
                margin: const EdgeInsets.all(8),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SizedBox(
                      height: isWatch ? 100 : null,
                      width: double.infinity,
                      child: isWatch
                          ? FittedBox(
                              fit: BoxFit.cover,
                              clipBehavior: Clip.hardEdge,
                              child: SizedBox(
                                width: _video!.value.size.width,
                                height: _video!.value.size.height,
                                child: VideoPlayer(_video!),
                              ),
                            )
                          : AspectRatio(
                              aspectRatio: _video!.value.aspectRatio,
                              child: VideoPlayer(_video!),
                            ),
                    ),
                    _mediaCaption(
                      isWatch,
                      Icons.videocam,
                      isWatch ? 'video' : 'received video (looping)',
                      trailing: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: isWatch ? 20 : 24,
                        icon: Icon(
                          _video!.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        onPressed: () => setState(() {
                          _video!.value.isPlaying
                              ? _video!.pause()
                              : _video!.play();
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(),
            for (final line in _log)
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: isWatch ? 4 : 16,
                  vertical: 2,
                ),
                child: Text(
                  line,
                  style: TextStyle(fontSize: isWatch ? 10 : 13),
                ),
              ),
          ],
        ),
      ),
    );
    return Scaffold(
      appBar: isWatch ? null : AppBar(title: const Text('wearer_link demo')),
      body: body,
    );
  }

  Widget _chip(bool isWatch, IconData icon, String label) => Chip(
    visualDensity: VisualDensity.compact,
    avatar: Icon(icon, size: isWatch ? 12 : 16),
    labelPadding: isWatch ? const EdgeInsets.symmetric(horizontal: 2) : null,
    label: Text(label, style: TextStyle(fontSize: isWatch ? 10 : 13)),
  );

  Widget _mediaCaption(
    bool isWatch,
    IconData icon,
    String label, {
    Widget? trailing,
  }) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: isWatch ? 8 : 16,
      vertical: isWatch ? 2 : 6,
    ),
    child: Row(
      children: [
        Icon(icon, size: isWatch ? 14 : 20),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: isWatch ? 11 : 14),
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );
}

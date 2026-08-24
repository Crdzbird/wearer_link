import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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

  WearerCompanionStatus? _status;
  int _counter = 0;

  // Live transfer feedback for the photo/stream demos.
  double? _transferProgress;
  String? _transferLabel;
  String? _receivedImagePath;

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
        _link.dataEvents.listen(
          (e) => _append(
            'data ${e.path}: ${_decode(e.payload)}'
            '${e.deliveredWhileDead ? ' (replayed)' : ''}',
          ),
        ),
      )
      ..add(
        _link.fileEvents.listen((e) {
          _append(
            'file ${e.path}: ${e.filePath}'
            '${e.deliveredWhileDead ? ' (replayed)' : ''}',
          );
          if (e.path == '/photo' && e.filePath != null) {
            setState(() => _receivedImagePath = e.filePath);
          }
        }),
      )
      ..add(_link.connectionState.listen((s) => setState(() => _status = s)))
      ..add(
        _link.launchIntents.listen(
          (intent) => _append('launch intent: ${intent.route} ${intent.args}'),
        ),
      );
    _refreshStatus();
    _link
        .registerBackgroundHandler(demoBackgroundHandler)
        .catchError((Object e) => _append('bg register failed: $e'));
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
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

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
    }
  }

  /// Send [filePath] with live progress + throughput in the app bar area.
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

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('wearer_link demo')),
      // One scrollable list so the demo also fits small/round Wear OS screens.
      body: SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: Icon(
                status?.isReachable ?? false ? Icons.watch : Icons.watch_off,
                color: status?.isReachable ?? false
                    ? Colors.green
                    : Colors.grey,
              ),
              title: Text('Companion: ${status?.state.name ?? '…'}'),
              subtitle: Text('nodes: ${status?.nodes.join(', ') ?? '-'}'),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshStatus,
              ),
            ),
            OverflowBar(
              spacing: 8,
              children: [
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
                  onPressed: () => _run('photo', () async {
                    final picked = await ImagePicker().pickImage(
                      source: ImageSource.gallery,
                    );
                    if (picked == null) {
                      _append('photo: nothing picked');
                      return;
                    }
                    await _trackedSend('/photo', picked.path, 'photo');
                  }),
                  child: const Text('Share photo'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('streamfile', () async {
                    // ~2MB generated file: demonstrates streaming any large
                    // file with live progress + throughput.
                    final file = File(
                      '${Directory.systemTemp.path}/wearer_2mb.bin',
                    );
                    if (!file.existsSync()) {
                      file.writeAsBytesSync(
                        List.generate(2 * 1024 * 1024, (i) => i % 256),
                      );
                    }
                    await _trackedSend('/bigfile', file.path, '2MB file');
                  }),
                  child: const Text('Stream file'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('store', () async {
                    await _link.store.set(
                      'demo',
                      Uint8List.fromList(
                        utf8.encode('saved ${DateTime.now()}'),
                      ),
                    );
                    final value = await _link.store.get('demo');
                    _append('store demo = ${_decode(value!)}');
                    _append('store keys = ${await _link.store.keys()}');
                    final rtt = await _link.pingLatency();
                    _append('rtt = ${rtt.inMilliseconds}ms');
                  }),
                  child: const Text('Store'),
                ),
                FilledButton.tonal(
                  onPressed: () => _run('status', () async {
                    final nodes = await _link.getNodes();
                    _append('nodes: $nodes');
                    final status = await _link.getCounterpartVitals();
                    _append('counterpart: $status');
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
                    // Leave time for the echoes, then close tidily.
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
                  onPressed: () => _run('storeget', () async {
                    final value = await _link.store.get('demo');
                    _append(
                      'store demo = '
                      '${value == null ? 'null' : _decode(value)}',
                    );
                  }),
                  child: const Text('Store get'),
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
            if (_receivedImagePath != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_receivedImagePath!),
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            const Divider(),
            for (final line in _log)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 2,
                ),
                child: Text(line, style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }
}

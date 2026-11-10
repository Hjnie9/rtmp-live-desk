import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'stream_server.dart';
import 'stream_settings.dart';

class DesktopStreamServer implements StreamServer {
  DesktopStreamServer({this.attachWindowsJob});

  final Future<void> Function(int pid)? attachWindowsJob;
  final _logs = StreamController<String>.broadcast();
  final _http = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(milliseconds: 800);
  Process? _process;
  Directory? _session;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  bool _running = false;
  int _apiPort = 0;
  int _previewPort = 0;
  String _secret = '';

  @override
  bool get supported => Platform.isWindows || Platform.isLinux;

  @override
  bool get running => _running;

  @override
  Stream<String> get logs => _logs.stream;

  Directory get _data {
    final env = Platform.environment;
    if (Platform.isWindows) {
      return Directory(
        p.join(
          env['LOCALAPPDATA'] ?? Directory.systemTemp.path,
          'RtmpLiveDesk',
        ),
      );
    }
    return Directory(
      p.join(
        env['XDG_CONFIG_HOME'] ??
            p.join(env['HOME'] ?? Directory.systemTemp.path, '.config'),
        'rtmp-live-desk',
      ),
    );
  }

  @override
  Future<StreamSettings> loadSettings() async {
    if (!supported) return const StreamSettings();
    try {
      final file = File(p.join(_data.path, 'settings.json'));
      return StreamSettings.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } on FileSystemException {
      return const StreamSettings();
    } on FormatException {
      return const StreamSettings();
    } on TypeError {
      return const StreamSettings();
    }
  }

  @override
  Future<void> saveSettings(StreamSettings settings) async {
    await _data.create(recursive: true);
    final destination = p.join(_data.path, 'settings.json');
    final file = File('$destination.new');
    try {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()),
        flush: true,
      );
      await file.rename(destination);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<List<ListenAddress>> addresses() async {
    final result = <ListenAddress>[ListenAddress.any];
    if (!supported) return result;
    final seen = <String>{};
    final interfaces = await NetworkInterface.list(
      includeLoopback: true,
      includeLinkLocal: true,
    );
    for (final adapter in interfaces) {
      for (final address in adapter.addresses) {
        var value = address.address;
        if (address.type == InternetAddressType.IPv6 &&
            address.isLinkLocal &&
            !value.contains('%')) {
          value += '%${adapter.index}';
        }
        if (seen.add(value)) {
          result.add(
            ListenAddress(
              value,
              address.isLoopback ? '$value · 本机回环' : '$value · ${adapter.name}',
            ),
          );
        }
      }
    }
    return result;
  }

  @override
  String preferredAddress(List<ListenAddress> addresses) {
    final ipv4 = addresses.where(
      (item) =>
          item.address.contains('.') &&
          !item.address.startsWith('127.') &&
          !item.address.startsWith('169.254.'),
    );
    final standardLan = ipv4.where(
      (item) =>
          item.address.startsWith('192.168.') || item.address.startsWith('10.'),
    );
    if (standardLan.isNotEmpty) return standardLan.first.address;
    return ipv4.isNotEmpty ? ipv4.first.address : '127.0.0.1';
  }

  @override
  Future<void> start(StreamSettings settings) async {
    if (!supported) throw UnsupportedError('当前平台需要 RTMP 服务适配层。');
    settings.validate(await addresses());
    await stop();
    final executable = p.join(
      p.dirname(Platform.resolvedExecutable),
      'server',
      Platform.isWindows ? 'mediamtx.exe' : 'mediamtx',
    );
    if (!await File(executable).exists()) {
      throw const FileSystemException('安装目录缺少 MediaMTX 服务核心。');
    }
    _apiPort = await _reservePort({settings.port});
    _previewPort = await _reservePort({settings.port, _apiPort});
    final random = Random.secure();
    _secret = base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
    await _data.create(recursive: true);
    final session = await _data.createTemp('runtime-');
    _session = session;
    try {
      final config = File(p.join(session.path, 'mediamtx.yml'));
      await config.writeAsString(_configuration(settings), flush: true);
      final environment = Map<String, String>.from(Platform.environment)
        ..removeWhere((key, _) => key.toUpperCase().startsWith('MTX_'));
      final process = await Process.start(
        executable,
        [config.path],
        workingDirectory: session.path,
        includeParentEnvironment: false,
        environment: environment,
      );
      _process = process;
      final ready = Completer<void>();
      final pending = {'RTMP', 'RTSP', 'API'};
      String? errorLine;
      int? exitCode;

      void onLine(String line) {
        if (_logs.isClosed) return;
        _logs.add(line);
        if (line.contains(' ERR ')) errorLine = line;
        final matched = RegExp(
          r'\[(RTMP|RTSP|API)\] started with listeners? on ',
        ).firstMatch(line);
        if (matched != null) pending.remove(matched.group(1));
        if (pending.isEmpty && !ready.isCompleted) ready.complete();
      }

      _stdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine);
      _stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine);
      unawaited(
        process.exitCode.then((code) {
          exitCode = code;
          if (identical(_process, process)) _running = false;
          if (!ready.isCompleted)
            ready.completeError(
              StateError(errorLine ?? 'MediaMTX 已退出（$code）。'),
            );
        }),
      );
      final prepare = Future.wait<void>([
        ready.future,
        if (Platform.isWindows && attachWindowsJob != null)
          attachWindowsJob!(process.pid),
      ], eagerError: true);
      await prepare.timeout(
        const Duration(seconds: 9),
        onTimeout: () {
          throw TimeoutException(errorLine ?? '等待 RTMP 和预览端口启动超时。');
        },
      );
      if (exitCode != null)
        throw StateError(errorLine ?? 'MediaMTX 已退出（$exitCode）。');
      _running = true;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final process = _process;
    _process = null;
    _running = false;
    try {
      if (process != null) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 4));
      }
    } finally {
      await _clearSession();
    }
  }

  Future<void> _clearSession() async {
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = _stderr = null;
    final session = _session;
    _session = null;
    if (session != null) {
      final config = File(p.join(session.path, 'mediamtx.yml'));
      try {
        if (await config.exists()) await config.delete();
        if (await session.exists()) await session.delete();
      } on FileSystemException {
        // Runtime files belong to this application instance.
      }
    }
  }

  @override
  Future<PublisherStatus?> publisher(StreamSettings settings) async {
    if (!running) return const PublisherStatus(online: false);
    try {
      final url = Uri.http('127.0.0.1:$_apiPort', '/v3/paths/list');
      final request = await _http
          .getUrl(url)
          .timeout(const Duration(seconds: 1));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('local-panel:$_secret'))}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 1),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 1));
      if (response.statusCode != HttpStatus.ok) return null;
      final data = jsonDecode(text) as Map<String, dynamic>;
      for (final path in (data['items'] as List? ?? const [])) {
        if (path is! Map ||
            path['name'] != settings.streamPath ||
            path['online'] != true)
          continue;
        final tracks = (path['tracks'] as List? ?? const [])
            .whereType<String>()
            .toList();
        final videoOnly =
            tracks.length == 1 &&
            const {
              'h264',
              'h265',
              'av1',
              'vp8',
              'vp9',
              'mjpeg',
            }.contains(tracks.first.toLowerCase());
        return PublisherStatus(online: true, videoOnly: videoOnly);
      }
      return const PublisherStatus(online: false);
    } on Exception {
      return null;
    }
  }

  @override
  Uri previewUri(StreamSettings settings) => Uri(
    scheme: 'rtsp',
    host: '127.0.0.1',
    port: _previewPort,
    pathSegments: settings.pathSegments,
  );

  @override
  Future<void> close() async {
    try {
      await stop();
    } finally {
      _http.close(force: true);
      await _logs.close();
    }
  }

  Future<int> _reservePort(Set<int> excluded) async {
    for (var i = 0; i < 8; i++) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      if (!excluded.contains(port)) return port;
    }
    throw const SocketException('无法分配本机预览端口。');
  }

  String _configuration(StreamSettings settings) =>
      '''
logLevel: info
logDestinations: [stdout]
authMethod: internal
authInternalUsers:
  - user: any
    permissions:
      - action: publish
        path: ${settings.streamPath}
      - action: read
        path: ${settings.streamPath}
  - user: local-panel
    pass: "$_secret"
    ips: [127.0.0.1]
    permissions:
      - action: api
api: true
apiAddress: 127.0.0.1:$_apiPort
rtmp: true
rtmpAddress: "${settings.binding}"
rtsp: true
rtspAddress: 127.0.0.1:$_previewPort
rtspTransports: [tcp]
hls: false
webrtc: false
srt: false
moq: false
paths:
  ${settings.streamPath}:
    source: publisher
    overridePublisher: false
''';
}

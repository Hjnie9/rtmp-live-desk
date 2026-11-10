import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'live_preview.dart';
import 'stream_server.dart';
import 'stream_settings.dart';

class DeskController extends ChangeNotifier {
  DeskController(this.server, this.preview);

  final StreamServer server;
  final LivePreview preview;
  final _log = ListQueue<String>();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  StreamSettings settings = const StreamSettings();
  List<ListenAddress> addresses = const [ListenAddress.any];
  bool initialized = false;
  bool busy = false;
  bool online = false;
  bool showingVideo = false;
  bool _videoOnly = false;
  bool _closing = false;
  bool _previewOpened = false;
  String? message;
  String? error;
  int _revision = 0;
  Timer? _timer;
  Future<void>? _poll;
  Future<void>? _operation;
  DateTime _retryAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get running => server.running;
  List<String> get logs => List.unmodifiable(_log);
  String get publishAddress =>
      settings.publishServer(server.preferredAddress(addresses));

  Future<void> initialize() async {
    _subscriptions.add(server.logs.listen(_append));
    _subscriptions.add(
      preview.player.stream.playing.listen((playing) {
        if (_closing || showingVideo == playing) return;
        showingVideo = playing;
        _notify();
      }),
    );
    _subscriptions.add(
      preview.player.stream.error.listen((message) {
        if (_closing || !online) return;
        _previewOpened = false;
        _retryAt = DateTime.now().add(const Duration(seconds: 2));
        _append('播放器 $message');
      }),
    );
    try {
      settings = await server.loadSettings();
      await reloadAddresses();
      await preview.initialize();
      _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (busy || _closing || _poll != null) return;
        final future = _check();
        _poll = future;
        unawaited(future.whenComplete(() => _poll = null));
      });
    } catch (problem) {
      error = _message(problem);
    } finally {
      initialized = true;
      _notify();
    }
  }

  Future<void> reloadAddresses() async {
    final items = await server.addresses();
    addresses = [
      ...items,
      if (!items.any((item) => item.address == settings.address))
        ListenAddress(settings.address, '${settings.address} · 当前不可用'),
    ];
    _notify();
  }

  Future<void> apply(
    StreamSettings next, {
    bool start = false,
    bool restart = false,
  }) => _perform(() async {
    final available = await server.addresses();
    next.validate(available);
    final wasRunning = running;
    final prior = settings;
    if (wasRunning && !restart && prior.sameAs(next)) {
      message = '已使用当前设置。';
      return;
    }
    if (wasRunning) await _stop();
    try {
      if (wasRunning || start) await server.start(next);
      await server.saveSettings(next);
      settings = next;
      addresses = available;
      message = running ? '服务已启动，等待推流。' : '设置已保存。';
    } catch (_) {
      if (running) await _stop();
      if (wasRunning) await server.start(prior);
      rethrow;
    }
  });

  Future<void> stop() => _perform(() async {
    await _stop();
    message = '服务已停止。';
  });

  Future<void> goLive() => _perform(() async {
    if (!online || !running) return;
    await preview.stop();
    await _connect();
  });

  Future<void> toggleMute() async {
    await preview.setMuted(!preview.muted);
    _notify();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_closing || busy) return;
    busy = true;
    _revision++;
    error = message = null;
    _notify();
    final work = () async {
      await _poll;
      await action();
    }();
    _operation = work;
    try {
      await work;
    } catch (problem) {
      error = _message(problem);
    } finally {
      _operation = null;
      busy = false;
      _notify();
    }
  }

  Future<void> _stop() async {
    online = showingVideo = _previewOpened = false;
    await preview.stop();
    await server.stop();
  }

  Future<void> _check() async {
    final revision = _revision;
    try {
      final status = await server.publisher(settings);
      if (_closing || busy || revision != _revision || status == null) return;
      if (!status.online) {
        if (online || _previewOpened) {
          online = _previewOpened = showingVideo = false;
          await preview.stop();
          _notify();
        }
        return;
      }
      if (!online) {
        online = true;
        _retryAt = DateTime.fromMillisecondsSinceEpoch(0);
        _notify();
      }
      _videoOnly = status.videoOnly;
      if (!_previewOpened && DateTime.now().isAfter(_retryAt)) await _connect();
    } on Exception catch (problem) {
      _previewOpened = false;
      _retryAt = DateTime.now().add(const Duration(seconds: 2));
      _append('预览暂时不可用。 ${_message(problem)}');
    }
  }

  Future<void> _connect() async {
    _previewOpened = true;
    try {
      await preview.open(server.previewUri(settings), videoOnly: _videoOnly);
    } catch (_) {
      _previewOpened = false;
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    try {
      await _operation;
    } catch (_) {
      // The outstanding action already reports its own error.
    }
    await _poll;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await preview.close();
    } finally {
      await server.close();
    }
  }

  void _append(String line) {
    if (_closing) return;
    _log.add(line);
    if (_log.length > 120) _log.removeFirst();
    _notify();
  }

  void _notify() {
    if (!_closing) notifyListeners();
  }

  String _message(Object problem) => switch (problem) {
    FormatException(:final message) => message,
    TimeoutException(:final message) => message ?? '操作超时。',
    StateError(:final message) => message,
    _ => problem.toString(),
  };
}

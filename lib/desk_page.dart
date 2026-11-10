import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'desk_controller.dart';
import 'desk_theme.dart';
import 'stream_settings.dart';

class DeskPage extends StatefulWidget {
  const DeskPage({super.key, required this.controller});
  final DeskController controller;

  @override
  State<DeskPage> createState() => _DeskPageState();
}

class _DeskPageState extends State<DeskPage> with WindowListener {
  final _port = TextEditingController(text: '1935');
  final _key = TextEditingController();
  final _videoKey = GlobalKey();
  String _address = '';
  bool _showLogs = false;
  bool _fullscreen = false;
  bool _closing = false;
  bool _switchingScreen = false;
  DeskController get _desk => widget.controller;

  @override
  void initState() {
    super.initState();
    if (desktop) windowManager.addListener(this);
    unawaited(
      _desk.initialize().then((_) {
        if (!mounted) return;
        setState(() {
          _address = _desk.settings.address;
          _port.text = _desk.settings.port.toString();
          _key.text = _desk.settings.key;
        });
      }),
    );
  }

  @override
  void dispose() {
    if (desktop) windowManager.removeListener(this);
    _port.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await _desk.close();
    } finally {
      await windowManager.destroy();
    }
  }

  Future<void> _toggleFullscreen() async {
    if (_switchingScreen) return;
    _switchingScreen = true;
    final next = !_fullscreen;
    try {
      if (desktop) {
        await windowManager.setFullScreen(next);
      } else {
        await SystemChrome.setEnabledSystemUIMode(
          next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      }
      if (mounted) setState(() => _fullscreen = next);
    } finally {
      _switchingScreen = false;
    }
  }

  Future<void> _apply({bool start = false, bool restart = false}) async {
    final port = int.tryParse(_port.text.trim());
    if (port == null) {
      _snack('请输入有效的 RTMP 端口。');
      return;
    }
    await _desk.apply(
      StreamSettings(address: _address, port: port, key: _key.text.trim()),
      start: start,
      restart: restart,
    );
  }

  Future<void> _copy(String value) async {
    if (value.isEmpty) {
      _snack('当前串流密钥留空。');
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _snack('已复制');
  }

  void _snack(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            unawaited(_toggleFullscreen()),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen) unawaited(_toggleFullscreen());
        },
      },
      child: Focus(
        autofocus: true,
        child: AnimatedBuilder(
          animation: _desk,
          builder: (context, _) {
            if (_fullscreen) {
              return Scaffold(
                backgroundColor: deskVideo,
                body: SafeArea(
                  child: Stack(
                    children: [
                      Positioned.fill(child: _video()),
                      Positioned(
                        right: 18,
                        bottom: 18,
                        child: _overlayButton(
                          Icons.fullscreen_exit_rounded,
                          '退出全屏（Esc）',
                          _toggleFullscreen,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            return Scaffold(
              backgroundColor: deskCanvas,
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final wide = bounds.maxWidth >= 920;
                    return Padding(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 28 : 16,
                        16,
                        wide ? 28 : 16,
                        20,
                      ),
                      child: Column(
                        children: [
                          _header(wide),
                          const SizedBox(height: 18),
                          Expanded(
                            child: wide
                                ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(child: _monitor()),
                                      const SizedBox(width: 20),
                                      SizedBox(
                                        width: 315,
                                        child: _settingsCard(),
                                      ),
                                    ],
                                  )
                                : ListView(
                                    children: [
                                      _monitor(compact: true),
                                      const SizedBox(height: 16),
                                      _settingsCard(scroll: false),
                                    ],
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header(bool wide) {
    return Row(
      children: [
        Image.asset(
          'assets/desk.png',
          width: 39,
          height: 39,
          semanticLabel: 'RTMP Live Desk',
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'RTMP Live Desk',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                  color: deskInk,
                ),
              ),
              if (wide)
                const Text(
                  '直播控制台',
                  style: TextStyle(color: deskMuted, fontSize: 12),
                ),
            ],
          ),
        ),
        if (wide) _status(),
        if (wide) const SizedBox(width: 12),
        TextButton.icon(
          onPressed: () => setState(() => _showLogs = !_showLogs),
          icon: Icon(
            _showLogs
                ? Icons.visibility_off_outlined
                : Icons.receipt_long_outlined,
            size: 19,
          ),
          label: Text(_showLogs ? '隐藏日志' : '日志'),
        ),
      ],
    );
  }

  Widget _status() {
    final active = _desk.online && _desk.showingVideo;
    final value = _desk.busy
        ? '正在应用'
        : !_desk.running
        ? '服务已停止'
        : !_desk.online
        ? '等待推流'
        : active
        ? '正在直播'
        : '正在连接';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? const Color(0xffe5f2ea) : Colors.white,
        border: Border.all(color: deskLine),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: active ? deskAccent : deskMuted),
            const SizedBox(width: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: active ? deskAccent : deskMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _monitor({bool compact = false}) {
    final stage = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: _video(),
    );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '实时预览',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              if (compact) _status(),
            ],
          ),
          const SizedBox(height: 12),
          if (compact)
            AspectRatio(aspectRatio: 16 / 9, child: stage)
          else
            Expanded(child: stage),
          const SizedBox(height: 7),
          Row(
            children: [
              TextButton.icon(
                onPressed: _desk.online && !_desk.busy ? _desk.goLive : null,
                icon: const Icon(Icons.adjust_rounded, size: 18),
                label: const Text('回到直播'),
              ),
              const Spacer(),
              IconButton(
                tooltip: _desk.preview.muted ? '打开声音' : '静音',
                onPressed: _desk.initialized ? _desk.toggleMute : null,
                icon: Icon(
                  _desk.preview.muted
                      ? Icons.volume_off_outlined
                      : Icons.volume_up_outlined,
                ),
              ),
              IconButton(
                tooltip: '全屏（F11）',
                onPressed: _toggleFullscreen,
                icon: const Icon(Icons.fullscreen_rounded),
              ),
            ],
          ),
          if (_showLogs) ...[
            const Divider(height: 10),
            const SizedBox(height: 4),
            _logs(),
          ],
        ],
      ),
    );
  }

  Widget _video() {
    return GestureDetector(
      onDoubleTap: _toggleFullscreen,
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: deskVideo,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(
              key: _videoKey,
              controller: _desk.preview.video,
              fit: BoxFit.contain,
              fill: deskVideo,
              controls: NoVideoControls,
            ),
            if (!_desk.showingVideo)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 37,
                      color: Color(0xff92a69b),
                    ),
                    const SizedBox(height: 11),
                    Text(
                      _desk.online
                          ? '正在接入实时画面'
                          : _desk.running
                          ? '等待推流'
                          : '等待启动服务',
                      style: const TextStyle(
                        color: Color(0xffdae5dd),
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _settingsCard({bool scroll = true}) {
    final enabled = _desk.initialized && !_desk.busy && _desk.server.supported;
    final addressExists = _desk.addresses.any(
      (item) => item.address == _address,
    );
    final fields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '推流设置',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '刷新网卡地址',
              iconSize: 18,
              onPressed: enabled
                  ? () async {
                      try {
                        await _desk.reloadAddresses();
                      } catch (_) {
                        if (mounted) _snack('无法读取网卡地址。');
                      }
                    }
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: ValueKey(
            '${addressExists ? _address : ''}:${_desk.addresses.length}',
          ),
          initialValue: addressExists ? _address : '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: '监听地址'),
          items: _desk.addresses
              .map(
                (item) => DropdownMenuItem(
                  value: item.address,
                  child: Text(item.label, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: enabled
              ? (value) => setState(() => _address = value ?? '')
              : null,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              width: 95,
              child: TextField(
                enabled: enabled,
                controller: _port,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                decoration: const InputDecoration(labelText: '端口'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                enabled: enabled,
                controller: _key,
                inputFormatters: [LengthLimitingTextInputFormatter(64)],
                decoration: const InputDecoration(
                  labelText: '串流密钥',
                  hintText: '可留空',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 7,
          children: [
            FilledButton(
              onPressed: enabled && !_desk.running
                  ? () => _apply(start: true)
                  : null,
              child: const Text('启动'),
            ),
            OutlinedButton(
              onPressed: enabled && _desk.running ? _desk.stop : null,
              child: const Text('停止'),
            ),
            OutlinedButton(
              onPressed: enabled && _desk.running
                  ? () => _apply(restart: true)
                  : null,
              child: const Text('重启'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: enabled ? _apply : null,
            child: const Text('保存并应用'),
          ),
        ),
        const Divider(height: 20),
        const Text(
          'OBS 推流参数',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 9),
        _copyValue('服务器', _desk.publishAddress),
        const SizedBox(height: 9),
        _copyValue('串流密钥', _desk.settings.key),
        if (!_desk.server.supported ||
            _desk.error != null ||
            _desk.message != null) ...[
          const SizedBox(height: 12),
          Text(
            !_desk.server.supported
                ? '当前平台需要接入 RTMP 服务适配层。'
                : _desk.error ?? _desk.message ?? '',
            style: TextStyle(
              fontSize: 12,
              color: _desk.error == null
                  ? deskMuted
                  : Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
    return _card(child: scroll ? SingleChildScrollView(child: fields) : fields);
  }

  Widget _copyValue(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: deskMuted, fontSize: 12)),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value.isEmpty ? '留空' : value,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: '复制$label',
              onPressed: () => _copy(value),
              icon: const Icon(Icons.content_copy_outlined, size: 17),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ],
    );
  }

  Widget _logs() {
    final lines = _desk.logs.reversed.toList();
    return SizedBox(
      height: 123,
      child: ColoredBox(
        color: const Color(0xfff6f7f5),
        child: lines.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: Text('等待服务日志', style: TextStyle(color: deskMuted)),
              )
            : SelectionArea(
                child: ListView.builder(
                  padding: const EdgeInsets.all(9),
                  itemCount: lines.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      lines[index],
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _overlayButton(IconData icon, String tooltip, VoidCallback action) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xdd26362e),
          borderRadius: BorderRadius.circular(30),
        ),
        child: IconButton(
          color: Colors.white,
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: action,
        ),
      );

  Widget _card({required Widget child}) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: deskLine),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

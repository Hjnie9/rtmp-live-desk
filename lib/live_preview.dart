import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class LivePreview {
  LivePreview()
    : player = Player(
        configuration: const PlayerConfiguration(title: 'RTMP Live Desk'),
      ) {
    video = VideoController(player);
  }

  final Player player;
  late final VideoController video;
  bool muted = true;

  Future<void> initialize() async {
    final engine = player.platform;
    if (engine is NativePlayer) {
      for (final option in const {
        'cache': 'no',
        'cache-pause': 'no',
        'demuxer-readahead-secs': '0',
        'demuxer-lavf-probe-info': 'no',
        'demuxer-lavf-o': 'rtsp_transport=tcp,fflags=nobuffer,max_delay=0',
        'vd-lavc-threads': '1',
        'video-latency-hacks': 'yes',
        'framedrop': 'vo',
        'audio-buffer': '0.06',
      }.entries) {
        await engine.setProperty('options/${option.key}', option.value);
      }
    }
    await player.setVolume(0);
  }

  Future<void> open(Uri uri, {required bool videoOnly}) async {
    final engine = player.platform;
    if (engine is NativePlayer) {
      await engine.setProperty('options/untimed', videoOnly ? 'yes' : 'no');
    }
    await player.open(Media(uri.toString()), play: true);
  }

  Future<void> setMuted(bool value) async {
    await player.setVolume(value ? 0 : 100);
    muted = value;
  }

  Future<void> stop() => player.stop();
  Future<void> close() => player.dispose();
}

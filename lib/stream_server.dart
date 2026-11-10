import 'stream_settings.dart';

abstract interface class StreamServer {
  bool get supported;
  bool get running;
  Stream<String> get logs;

  Future<StreamSettings> loadSettings();
  Future<void> saveSettings(StreamSettings settings);
  Future<List<ListenAddress>> addresses();
  String preferredAddress(List<ListenAddress> addresses);
  Future<void> start(StreamSettings settings);
  Future<void> stop();
  Future<PublisherStatus?> publisher(StreamSettings settings);
  Uri previewUri(StreamSettings settings);
  Future<void> close();
}

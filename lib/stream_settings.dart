class StreamSettings {
  const StreamSettings({this.address = '', this.port = 1935, this.key = ''});

  final String address;
  final int port;
  final String key;

  List<String> get pathSegments => ['live', if (key.isNotEmpty) key];
  String get streamPath => pathSegments.join('/');
  String get binding => '${_host(address, url: false)}:$port';

  String publishServer(String defaultAddress) =>
      'rtmp://${_host(address.isEmpty ? defaultAddress : address, url: true)}:$port/live';

  void validate(List<ListenAddress> options) {
    if (port < 1 || port > 65535) {
      throw const FormatException('RTMP 端口应为 1 到 65535。');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{0,64}$').hasMatch(key)) {
      throw const FormatException('串流密钥最多 64 位，可使用字母、数字、下划线和连字符。');
    }
    if (address.isNotEmpty &&
        !options.any((option) => option.address == address)) {
      throw const FormatException('请选择当前可用的监听地址。');
    }
  }

  bool sameAs(StreamSettings other) =>
      address == other.address && port == other.port && key == other.key;

  factory StreamSettings.fromJson(Map<String, dynamic> json) {
    final port = json['Port'];
    return StreamSettings(
      address: json['ListenAddress'] is String
          ? json['ListenAddress'] as String
          : '',
      port: port is int && port >= 1 && port <= 65535 ? port : 1935,
      key: json['StreamKey'] is String ? json['StreamKey'] as String : '',
    );
  }

  Map<String, Object> toJson() => {
    'ListenAddress': address,
    'Port': port,
    'StreamKey': key,
  };

  static String _host(String address, {required bool url}) {
    if (!address.contains(':')) return address;
    return '[${url ? address.replaceAll('%', '%25') : address}]';
  }
}

class ListenAddress {
  const ListenAddress(this.address, this.label);

  static const any = ListenAddress('', '所有地址（IPv4 / IPv6）');
  final String address;
  final String label;
}

class PublisherStatus {
  const PublisherStatus({required this.online, this.videoOnly = false});

  final bool online;
  final bool videoOnly;
}

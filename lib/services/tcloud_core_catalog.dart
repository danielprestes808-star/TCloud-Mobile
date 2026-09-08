import 'dart:convert';
import 'dart:io';

import '../models/tcloud_file.dart';
import 'tcloud_device_auth.dart';

class TCloudCoreCatalogEntry {
  const TCloudCoreCatalogEntry({
    required this.coreFileId,
    required this.messageId,
    required this.topicId,
    required this.peerId,
    required this.name,
    required this.size,
  });

  final String coreFileId;
  final int messageId;
  final int topicId;
  final int peerId;
  final String name;
  final int size;

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  factory TCloudCoreCatalogEntry.fromMap(Map<String, dynamic> map) {
    String stringOf(List<String> keys) {
      for (final key in keys) {
        final value = map[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
      return '';
    }

    int intOf(List<String> keys) {
      for (final key in keys) {
        if (map.containsKey(key)) return _asInt(map[key]);
      }
      return 0;
    }

    return TCloudCoreCatalogEntry(
      coreFileId: stringOf([
        'coreFileId',
        'core_file_id',
        'canonicalId',
        'canonical_id',
        'id',
      ]),
      messageId: intOf([
        'telegramMessageId',
        'telegram_message_id',
        'messageId',
        'message_id',
      ]),
      topicId: intOf([
        'telegramTopicId',
        'telegram_topic_id',
        'topicId',
        'topic_id',
      ]),
      peerId: intOf([
        'telegramPeerId',
        'telegram_peer_id',
        'peerId',
        'peer_id',
      ]),
      name: stringOf(['name', 'fileName', 'file_name']).toLowerCase(),
      size: intOf(['sizeBytes', 'size_bytes', 'size']),
    );
  }

  bool get valid => coreFileId.isNotEmpty && messageId > 0;
}

class TCloudCoreCatalog {
  TCloudCoreCatalog._();

  static final TCloudCoreCatalog instance = TCloudCoreCatalog._();

  static const _coreUrl = String.fromEnvironment(
    'TCLOUD_CORE_URL',
    defaultValue: 'https://tcloud-core.onrender.com',
  );

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 2;

  DateTime? _loadedAt;
  List<TCloudCoreCatalogEntry> _entries = const [];
  Future<void>? _refreshing;
  Map<String, List<TCloudCoreCatalogEntry>> _byTransport = const {};
  Map<String, List<TCloudCoreCatalogEntry>> _byTopicMessageName = const {};
  Map<String, List<TCloudCoreCatalogEntry>> _byMessageName = const {};

  String get coreBaseUrl => _coreUrl.replaceAll(RegExp(r'/+$'), '');

  bool get configuredForRemoteDevice =>
      !coreBaseUrl.contains('127.0.0.1') && !coreBaseUrl.contains('localhost');

  Future<void> refresh({bool force = false}) {
    if (!force &&
        _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < const Duration(seconds: 20)) {
      return Future<void>.value();
    }

    final current = _refreshing;
    if (current != null) return current;

    final future = _refresh();
    _refreshing = future;
    return future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
  }

  Future<void> _refresh() async {
    final request = await _client.getUrl(
      Uri.parse('$coreBaseUrl/api/v1/files'),
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    await TCloudDeviceAuth.instance.authorize(request);

    final response = await request.close().timeout(const Duration(seconds: 8));

    final body = await utf8.decoder.bind(response).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Core catalog HTTP ${response.statusCode}');
    }

    final dynamic decoded = jsonDecode(body);

    final List<dynamic> rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map && decoded['items'] is List) {
      rows = decoded['items'] as List<dynamic>;
    } else if (decoded is Map && decoded['files'] is List) {
      rows = decoded['files'] as List<dynamic>;
    } else {
      rows = const [];
    }

    _entries = rows
        .whereType<Map>()
        .map(
          (row) => TCloudCoreCatalogEntry.fromMap(row.cast<String, dynamic>()),
        )
        .where((entry) => entry.valid)
        .toList(growable: false);

    final byTransport = <String, List<TCloudCoreCatalogEntry>>{};
    final byTopicMessageName = <String, List<TCloudCoreCatalogEntry>>{};
    final byMessageName = <String, List<TCloudCoreCatalogEntry>>{};

    for (final entry in _entries) {
      byTransport
          .putIfAbsent(
            '${entry.peerId}:${entry.topicId}:${entry.messageId}',
            () => <TCloudCoreCatalogEntry>[],
          )
          .add(entry);
      byTopicMessageName
          .putIfAbsent(
            '${entry.topicId}:${entry.messageId}:${entry.name}',
            () => <TCloudCoreCatalogEntry>[],
          )
          .add(entry);
      byMessageName
          .putIfAbsent(
            '${entry.messageId}:${entry.name}',
            () => <TCloudCoreCatalogEntry>[],
          )
          .add(entry);
    }

    _byTransport = byTransport;
    _byTopicMessageName = byTopicMessageName;
    _byMessageName = byMessageName;

    _loadedAt = DateTime.now();
  }

  List<TCloudCoreCatalogEntry> _matchingSize(
    Iterable<TCloudCoreCatalogEntry> entries,
    int size,
  ) => entries
      .where((entry) => size <= 0 || entry.size <= 0 || entry.size == size)
      .toList(growable: false);

  Future<TCloudFile> enrich(TCloudFile file) async {
    final currentCore = file.coreFileId?.trim() ?? '';
    if (currentCore.isNotEmpty) return file;

    try {
      await refresh();
    } catch (_) {
      return file;
    }

    if (_entries.isEmpty || file.messageId <= 0) {
      return file;
    }

    final name = file.name.trim().toLowerCase();

    // 1) Exact transport identity when the mobile chat ID already matches
    // the canonical Telegram peer ID.
    final exactTransport =
        _byTransport['${file.chatId}:${file.messageThreadId}:${file.messageId}'] ??
        const <TCloudCoreCatalogEntry>[];

    if (exactTransport.length == 1) {
      return file.copyWith(coreFileId: exactTransport.single.coreFileId);
    }

    // 2) Topic + message + name + size. This handles clients whose local chat
    // representation differs from the Core peer representation.
    final topicMessageNameSize = _matchingSize(
      _byTopicMessageName['${file.messageThreadId}:${file.messageId}:$name'] ??
          const <TCloudCoreCatalogEntry>[],
      file.size,
    );

    if (topicMessageNameSize.length == 1) {
      return file.copyWith(coreFileId: topicMessageNameSize.single.coreFileId);
    }

    // 3) Final safe fallback: message + name + size must still be globally
    // unique in the current Core catalog.
    final messageNameSize = _matchingSize(
      _byMessageName['${file.messageId}:$name'] ??
          const <TCloudCoreCatalogEntry>[],
      file.size,
    );

    if (messageNameSize.length == 1) {
      return file.copyWith(coreFileId: messageNameSize.single.coreFileId);
    }

    // Ambiguous or absent match: preserve TDLib identity unchanged.
    return file;
  }

  void close() {
    _client.close(force: true);
  }
}

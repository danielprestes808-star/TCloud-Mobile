import 'dart:convert';
import 'dart:io';
import 'tcloud_device_auth.dart';

class TCloudCanonicalOps {
  TCloudCanonicalOps({String? coreBaseUrl, HttpClient? client})
    : coreBaseUrl = (coreBaseUrl == null || coreBaseUrl.trim().isEmpty)
          ? const String.fromEnvironment(
              'TCLOUD_CORE_URL',
              defaultValue: 'https://tcloud-core.onrender.com',
            ).replaceAll(RegExp(r'/+$'), '')
          : coreBaseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      _client = client ?? HttpClient();

  final String coreBaseUrl;
  final HttpClient _client;

  String _id(String value) {
    final id = value.trim();
    if (id.isEmpty) {
      throw StateError('coreFileId canônico é obrigatório.');
    }
    return id;
  }

  Uri mediaUri(String coreFileId) => Uri.parse(
    '$coreBaseUrl/api/v1/media/${Uri.encodeComponent(_id(coreFileId))}',
  );

  Uri fileUri(String coreFileId) => Uri.parse(
    '$coreBaseUrl/api/v1/files/${Uri.encodeComponent(_id(coreFileId))}',
  );

  Future<Map<String, dynamic>> _decode(HttpClientResponse response) async {
    final body = await utf8.decoder.bind(response).join();

    dynamic decoded;
    if (body.trim().isEmpty) {
      decoded = <String, dynamic>{};
    } else {
      decoded = jsonDecode(body);
    }

    final payload = decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{'value': decoded};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          payload['error']?.toString() ?? 'Core HTTP ${response.statusCode}';
      throw StateError(message);
    }

    return payload;
  }

  Future<Map<String, dynamic>> getFile(String coreFileId) async {
    final request = await _client.getUrl(fileUri(coreFileId));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    await TCloudDeviceAuth.instance.authorize(request);
    final response = await request.close();
    return _decode(response);
  }

  Future<Map<String, dynamic>> mutate(
    String operation,
    String coreFileId, {
    Map<String, dynamic> extra = const {},
  }) async {
    const allowed = {'rename', 'move', 'trash', 'restore', 'delete'};
    if (!allowed.contains(operation)) {
      throw ArgumentError.value(operation, 'operation', 'Operação inválida');
    }

    final uri = Uri.parse('$coreBaseUrl/api/v1/files/$operation');
    final request = await _client.postUrl(uri);

    request.headers.contentType = ContentType.json;
    await TCloudDeviceAuth.instance.authorize(request);
    request.write(jsonEncode({'id': _id(coreFileId), ...extra}));

    final response = await request.close();
    return _decode(response);
  }

  Future<Map<String, dynamic>> rename(String id, String name) =>
      mutate('rename', id, extra: {'name': name});

  Future<Map<String, dynamic>> move(String id, String parentId) =>
      mutate('move', id, extra: {'parentId': parentId});

  Future<Map<String, dynamic>> trash(String id) => mutate('trash', id);

  Future<Map<String, dynamic>> restore(String id) => mutate('restore', id);

  Future<Map<String, dynamic>> delete(String id) => mutate('delete', id);

  void close() {
    _client.close(force: true);
  }
}

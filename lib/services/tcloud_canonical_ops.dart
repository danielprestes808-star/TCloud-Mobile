import 'dart:convert';
import 'dart:io';
import 'tcloud_device_auth.dart';

class TCloudCanonicalOps {
  TCloudCanonicalOps({
    String? coreBaseUrl,
    HttpClient? client,
    this.authorizeRequests = true,
  }) : coreBaseUrl = (coreBaseUrl == null || coreBaseUrl.trim().isEmpty)
           ? const String.fromEnvironment(
               'TCLOUD_CORE_URL',
               defaultValue: 'https://tcloud-core.onrender.com',
             ).replaceAll(RegExp(r'/+$'), '')
           : coreBaseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? HttpClient();

  final String coreBaseUrl;
  final HttpClient _client;
  final bool authorizeRequests;

  Future<void> _authorize(HttpClientRequest request) async {
    if (authorizeRequests) {
      await TCloudDeviceAuth.instance.authorize(request);
    }
  }

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
    await _authorize(request);
    final response = await request.close();
    return _decode(response);
  }

  /// Baixa a midia usando a identidade global do Core. O endpoint limita cada
  /// resposta a uma janela de bytes, portanto arquivos grandes precisam ser
  /// retomados com Range ate que o tamanho total seja alcançado.
  Future<String> downloadMedia(
    String coreFileId,
    String targetPath, {
    int expectedSize = 0,
  }) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final partial = File('$targetPath.part');
    var offset = await partial.exists() ? await partial.length() : 0;
    var total = expectedSize > 0 ? expectedSize : 0;
    final sink = partial.openWrite(mode: FileMode.append);

    try {
      while (total == 0 || offset < total) {
        final request = await _client.getUrl(mediaUri(coreFileId));
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        await _authorize(request);

        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          final body = await utf8.decoder.bind(response).join();
          throw HttpException(
            body.trim().isEmpty
                ? 'Core media HTTP ${response.statusCode}'
                : body,
          );
        }

        final range = response.headers.value(HttpHeaders.contentRangeHeader);
        final match = range == null
            ? null
            : RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$').firstMatch(range);
        if (match != null) {
          final responseStart = int.parse(match.group(1)!);
          if (responseStart != offset) {
            throw StateError('O Core retornou uma faixa de midia inesperada.');
          }
          total = int.parse(match.group(3)!);
        } else {
          final length = response.contentLength;
          if (length >= 0 && total == 0) total = offset + length;
        }

        var received = 0;
        await for (final bytes in response) {
          sink.add(bytes);
          received += bytes.length;
        }
        await sink.flush();
        if (received == 0) {
          throw StateError('O Core nao retornou bytes da midia.');
        }
        offset += received;

        // Uma resposta 200 sem Content-Range representa o arquivo completo.
        if (response.statusCode == HttpStatus.ok && range == null) {
          total = offset;
        }
      }
    } catch (_) {
      await sink.close();
      rethrow;
    }
    await sink.close();

    if (total > 0 && offset != total) {
      throw StateError('Download incompleto: $offset de $total bytes.');
    }
    if (await target.exists()) await target.delete();
    await partial.rename(targetPath);
    return targetPath;
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
    await _authorize(request);
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

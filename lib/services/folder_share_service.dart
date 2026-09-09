import 'dart:convert';
import 'dart:io';

import '../models/tcloud_folder.dart';
import 'tcloud_device_auth.dart';

class FolderShareService {
  FolderShareService._();
  static final instance = FolderShareService._();

  Future<String> create(TCloudFolder folder) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('${TCloudDeviceAuth.coreBaseUrl}/api/v1/shares'),
      );
      request.headers.contentType = ContentType.json;
      await TCloudDeviceAuth.instance.authorize(request);
      request.write(
        jsonEncode({
          'folderPeerId': folder.chatId,
          'folderTopicId': folder.forumTopicId == 0
              ? folder.messageThreadId
              : folder.forumTopicId,
          'expiresInHours': 168,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await utf8.decoder.bind(response).join();
      final data = body.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(body) as Map).cast<String, dynamic>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(data['message']?.toString() ?? 'Falha ao criar link.');
      }
      final path = data['path']?.toString() ?? '';
      if (path.isEmpty) throw StateError('O Core nao retornou o link.');
      return path;
    } finally {
      client.close(force: true);
    }
  }
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/tcloud_file.dart';
import 'package:mobile/models/tcloud_folder.dart';
import 'package:mobile/services/app_update_service.dart';
import 'package:mobile/services/tcloud_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('TCloudUpdateInfo', () {
    test('aceita um manifesto HTTPS completo', () {
      final update = TCloudUpdateInfo.fromJson(<String, dynamic>{
        'version': '1.0.55',
        'versionCode': 67,
        'apkUrl': 'https://example.com/TCloud-Mobile-1.0.55.apk',
        'sha256': List<String>.filled(64, 'a').join(),
        'notes': 'Melhorias de estabilidade.',
        'mandatory': false,
      });

      expect(update.version, '1.0.55');
      expect(update.versionCode, 67);
      expect(update.mandatory, isFalse);
    });

    test('recusa download sem HTTPS', () {
      expect(
        () => TCloudUpdateInfo.fromJson(<String, dynamic>{
          'version': '1.0.55',
          'versionCode': 67,
          'apkUrl': 'http://example.com/app.apk',
          'sha256': List<String>.filled(64, 'b').join(),
        }),
        throwsFormatException,
      );
    });

    test('recusa hash incompleto', () {
      expect(
        () => TCloudUpdateInfo.fromJson(<String, dynamic>{
          'version': '1.0.55',
          'versionCode': 67,
          'apkUrl': 'https://example.com/app.apk',
          'sha256': 'invalido',
        }),
        throwsFormatException,
      );
    });
  });

  group('TCloudFile', () {
    test('preserva identidade canonica e campos no cache', () {
      const original = TCloudFile(
        coreFileId: 'core-123',
        messageId: 45,
        chatId: -1001,
        messageThreadId: 12,
        fileId: 99,
        name: 'foto.jpg',
        size: 2048,
        kind: 'imagem',
        createdAt: 123456,
        mimeType: 'image/jpeg',
        remoteId: 'remote-reference',
        remoteUniqueId: 'telegram-unique-123',
      );

      final restored = TCloudFile.fromJson(original.toJson());

      expect(restored.globalIdentity, 'core:core-123');
      expect(restored.stableIdentity, original.stableIdentity);
      expect(restored.fileId, 99);
      expect(restored.contentIdentity, 'telegram-file:telegram-unique-123');
      expect(restored.isMedia, isTrue);
    });

    test('usa identidade Telegram quando nao ha ID canonico', () {
      const file = TCloudFile(
        messageId: 45,
        chatId: -1001,
        messageThreadId: 12,
        fileId: 99,
        name: 'arquivo.pdf',
        size: 1024,
        kind: 'documento',
      );

      expect(file.globalIdentity, 'telegram:-1001:12:45');
      expect(file.isMedia, isFalse);
    });
  });

  group('TCloudFolder', () {
    test('identidade nao muda quando chega uma mensagem nova', () {
      const before = TCloudFolder(
        chatId: -1001,
        title: 'Viagens',
        forumTopicId: 20,
        messageThreadId: 20,
        historyMessageId: 100,
      );
      const after = TCloudFolder(
        chatId: -1001,
        title: 'Viagens',
        forumTopicId: 20,
        messageThreadId: 20,
        historyMessageId: 999,
      );

      expect(after.cacheKey, before.cacheKey);
    });

    test('pastas com o mesmo nome continuam fisicamente distintas', () {
      const first = TCloudFolder(
        chatId: -1001,
        title: 'Fotos',
        forumTopicId: 20,
        messageThreadId: 20,
      );
      const second = TCloudFolder(
        chatId: -1001,
        title: 'Fotos',
        forumTopicId: 21,
        messageThreadId: 21,
      );

      expect(first.cacheKey, isNot(second.cacheKey));
    });

    test('repositorio exibe um nome e preserva todas as origens', () async {
      const first = TCloudFolder(
        chatId: -1001,
        title: 'Fotos',
        forumTitle: 'TCloud 1',
        forumTopicId: 20,
        messageThreadId: 20,
      );
      const second = TCloudFolder(
        chatId: -1002,
        title: '  fotos  ',
        forumTitle: 'TCloud 2',
        forumTopicId: 21,
        messageThreadId: 21,
      );
      const documents = TCloudFolder(
        chatId: -1001,
        title: 'Documentos',
        forumTopicId: 22,
        messageThreadId: 22,
      );
      const firstFile = TCloudFile(
        messageId: 101,
        chatId: -1001,
        messageThreadId: 20,
        fileId: 501,
        name: 'primeira.jpg',
        size: 100,
        kind: 'imagem',
      );
      const secondFile = TCloudFile(
        messageId: 102,
        chatId: -1002,
        messageThreadId: 21,
        fileId: 502,
        name: 'segunda.jpg',
        size: 100,
        kind: 'imagem',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tcloud_folder_cache_v6_physical_topics': jsonEncode(<Object>[
          first.toJson(),
          second.toJson(),
          documents.toJson(),
        ]),
        'tcloud_file_page_v10_physical_topics_${first.cacheKey}': jsonEncode(
          <String, Object>{
            'files': <Object>[firstFile.toJson()],
            'nextFromMessageId': 101,
            'hasMore': false,
          },
        ),
        'tcloud_file_page_v10_physical_topics_${second.cacheKey}': jsonEncode(
          <String, Object>{
            'files': <Object>[secondFile.toJson()],
            'nextFromMessageId': 102,
            'hasMore': false,
          },
        ),
      });

      final visible = await TCloudRepository.instance.loadCachedFolders();
      final photos = visible.singleWhere(
        (folder) => folder.title.trim().toLowerCase() == 'fotos',
      );

      expect(visible, hasLength(2));
      expect(TCloudRepository.instance.sourceCountForFolder(photos), 2);
      expect(
        TCloudRepository.instance
            .sourcesForFolder(photos)
            .map((folder) => folder.cacheKey)
            .toSet(),
        <String>{first.cacheKey, second.cacheKey},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('tcloud_folder_cache_v8_numbered_duplicates'),
        isNotEmpty,
      );
      final cachedFiles = await TCloudRepository.instance.loadCachedFilePage(
        photos,
      );
      expect(cachedFiles.files, isEmpty);
      expect(
        prefs.getString(
          'tcloud_file_page_v10_physical_topics_${first.cacheKey}',
        ),
        isNull,
      );
    });

    test('unifica os sufixos numericos criados pelo Telegram', () async {
      const base = TCloudFolder(
        chatId: -2001,
        title: 'animeaddictsofficial',
        forumTopicId: 31,
      );
      const numbered1 = TCloudFolder(
        chatId: -2002,
        title: 'animeaddictsofficial (1)',
        forumTopicId: 32,
      );
      const numbered2 = TCloudFolder(
        chatId: -2003,
        title: ' animeaddictsofficial  (2) ',
        forumTopicId: 33,
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tcloud_folder_cache_v7_unified_sources': jsonEncode(<Object>[
          numbered1.toJson(),
          numbered2.toJson(),
          base.toJson(),
        ]),
      });

      final visible = await TCloudRepository.instance.loadCachedFolders();

      expect(visible, hasLength(1));
      expect(visible.single.title, 'animeaddictsofficial');
      expect(TCloudRepository.instance.sourceCountForFolder(visible.single), 3);
    });
  });
}

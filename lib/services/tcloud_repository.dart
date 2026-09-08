import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/tcloud_file.dart';
import '../models/tcloud_file_page.dart';
import '../models/tcloud_folder.dart';
import '../telegram/tdlib_service.dart';
import 'tcloud_canonical_ops.dart';
import 'tcloud_core_catalog.dart';

class _ResolvedMediaCacheEntry {
  const _ResolvedMediaCacheEntry(this.loadedAt, this.file);

  final DateTime loadedAt;
  final TCloudFile file;
}

class TCloudRepository {
  Future<String> validateDownloadedFilePath(
    TCloudFile file,
    String path,
  ) async {
    final normalized = path.trim();

    if (normalized.isEmpty) {
      throw StateError('TDLib retornou caminho local vazio.');
    }

    if (!await File(normalized).exists()) {
      throw StateError('Arquivo baixado nao existe no dispositivo.');
    }

    final resolved = await resolveCurrentMedia(file);
    final current = await _td.execute('GetFile', <String, dynamic>{
      'fileId': resolved.fileId,
    });

    if (current['_type']?.toString() == 'Error') {
      throw StateError('TDLib nao confirmou o arquivo baixado.');
    }

    final local = _asMap(current['local']);
    final completed = local['isDownloadingCompleted'] == true;
    final currentPath = local['path']?.toString().trim() ?? '';

    if (!completed) {
      throw StateError('Download do video ainda nao foi concluido.');
    }

    if (currentPath.isEmpty) {
      throw StateError('TDLib nao informou o caminho do arquivo.');
    }

    if (currentPath != normalized) {
      throw StateError('Arquivo local nao corresponde ao fileId atual.');
    }

    return normalized;
  }

  TCloudRepository._();

  static final instance = TCloudRepository._();

  final TdlibService _td = TdlibService.instance;
  final TCloudCanonicalOps _canonicalOps = TCloudCanonicalOps();
  final Map<String, _ResolvedMediaCacheEntry> _resolvedMediaCache =
      <String, _ResolvedMediaCacheEntry>{};
  final Map<String, Future<TCloudFile>> _resolvedMediaInFlight =
      <String, Future<TCloudFile>>{};

  static const _offlineKey = 'tcloud_offline_files_v2';
  static const _folderCacheKey = 'tcloud_folder_cache_v8_numbered_duplicates';
  static const _legacyUnifiedFolderCacheKey =
      'tcloud_folder_cache_v7_unified_sources';
  static const _legacyPhysicalFolderCacheKey =
      'tcloud_folder_cache_v6_physical_topics';
  // TCLOUD_MEDIA_IDENTITY_CACHE_V2
  // TCLOUD_ORPHAN_CACHE_CLEANUP_1035
  static const _legacyPageCachePrefix = 'tcloud_file_page_v2_canonical_';
  static const _legacyLivePageCachePrefix =
      'tcloud_file_page_v8_global_logical_canonical_';
  static const _legacyMergedPageCachePrefix =
      'tcloud_file_page_v9_global_logical_canonical_';
  static const _legacyPhysicalPageCachePrefix =
      'tcloud_file_page_v10_physical_topics_';
  static const _legacyUnifiedPageCachePrefix =
      'tcloud_file_page_v11_unified_name_';
  static const _pageCachePrefix = 'tcloud_file_page_v12_numbered_duplicates_';
  Future<void> _purgeLegacyPageCache(SharedPreferences prefs) async {
    final legacyKeys = prefs
        .getKeys()
        .where(
          (key) =>
              key.startsWith(_legacyPageCachePrefix) ||
              key.startsWith(_legacyLivePageCachePrefix) ||
              key.startsWith(_legacyMergedPageCachePrefix) ||
              key.startsWith(_legacyPhysicalPageCachePrefix) ||
              key.startsWith(_legacyUnifiedPageCachePrefix),
        )
        .toList(growable: false);

    for (final key in legacyKeys) {
      await prefs.remove(key);
    }
  }

  // TCLOUD_FOLDER_CONTENT_RECOVERY_1038
  // TCLOUD_GHOST_MESSAGE_VERIFIED_1040
  bool _isLiveFileUsable(TCloudFile file) {
    // O item acabou de vir do historico remoto. Uma falha transitória em
    // GetMessage/GetFile não pode esconder uma mensagem que o próprio TDLib
    // acabou de confirmar. A validação detalhada acontece ao abrir/baixar.
    return file.chatId != 0 && file.messageId != 0 && file.fileId > 0;
  }

  List<TCloudFolder> _deduplicatePhysicalFolders(
    Iterable<TCloudFolder> source,
  ) {
    final physical = <String, TCloudFolder>{};

    for (final candidate in source) {
      if (candidate.chatId == 0) continue;
      physical[candidate.cacheKey] = candidate;
    }

    return physical.values.toList();
  }

  final Map<String, List<TCloudFolder>> _folderSources =
      <String, List<TCloudFolder>>{};

  String _folderDisplayName(String value) {
    var normalized = value
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u2007', ' ')
        .replaceAll('\u202F', ' ')
        .replaceAll('\u3000', ' ')
        .replaceAll(RegExp(r'[\u200B-\u200D\u2060\uFEFF]'), '')
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .trim();
    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ');
    // O Telegram acrescenta (1), (2), ... quando recria um topico com o
    // mesmo nome. Para o TCloud essas partes sao uma unica pasta logica.
    while (RegExp(r'\s*\([1-9]\d*\)$').hasMatch(normalized)) {
      normalized = normalized.replaceFirst(RegExp(r'\s*\([1-9]\d*\)$'), '');
    }
    return normalized.trim();
  }

  String _folderGroupName(String value) {
    final normalized = _folderDisplayName(value).toLowerCase();
    return normalized;
  }

  String _folderGroupKey(TCloudFolder folder) {
    final name = _folderGroupName(folder.title);
    return name.isEmpty ? folder.cacheKey : name;
  }

  String _folderPageCacheKey(TCloudFolder folder) {
    final bytes = utf8.encode(_folderGroupKey(folder));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _replaceFolderSources(Iterable<TCloudFolder> source) {
    _folderSources.clear();
    for (final folder in _deduplicatePhysicalFolders(source)) {
      _folderSources
          .putIfAbsent(_folderGroupKey(folder), () => <TCloudFolder>[])
          .add(folder);
    }
    for (final sources in _folderSources.values) {
      sources.sort((a, b) => a.cacheKey.compareTo(b.cacheKey));
    }
  }

  List<TCloudFolder> _logicalFolders(Iterable<TCloudFolder> source) {
    final grouped = <String, TCloudFolder>{};
    final physical = _deduplicatePhysicalFolders(source)
      ..sort((a, b) => a.cacheKey.compareTo(b.cacheKey));
    for (final folder in physical) {
      final key = _folderGroupKey(folder);
      final current = grouped[key];
      if (current == null ||
          _folderDisplayName(folder.title) == folder.title.trim()) {
        grouped[key] = folder;
      }
    }
    final result =
        grouped.values
            .map(
              (folder) => TCloudFolder(
                chatId: folder.chatId,
                title: _folderDisplayName(folder.title),
                forumTitle: folder.forumTitle,
                forumTopicId: folder.forumTopicId,
                messageThreadId: folder.messageThreadId,
                historyMessageId: folder.historyMessageId,
                isGeneral: folder.isGeneral,
              ),
            )
            .toList()
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
    return result;
  }

  List<TCloudFolder> _sourcesForLogicalFolder(TCloudFolder folder) {
    final sources = _folderSources[_folderGroupKey(folder)];
    if (sources == null || sources.isEmpty) return <TCloudFolder>[folder];
    return List<TCloudFolder>.unmodifiable(sources);
  }

  List<TCloudFolder> sourcesForFolder(TCloudFolder folder) =>
      _sourcesForLogicalFolder(folder);

  int sourceCountForFolder(TCloudFolder folder) =>
      _sourcesForLogicalFolder(folder).length;

  Future<List<TCloudFolder>> loadCachedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final currentRaw = prefs.getString(_folderCacheKey);
    final raw =
        currentRaw ??
        prefs.getString(_legacyUnifiedFolderCacheKey) ??
        prefs.getString(_legacyPhysicalFolderCacheKey);

    if (raw == null || raw.isEmpty) {
      return <TCloudFolder>[];
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is! List) {
        return <TCloudFolder>[];
      }

      final cached = decoded
          .whereType<Map>()
          .map(
            (item) => TCloudFolder.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          )
          .where((folder) => folder.chatId != 0)
          .toList();

      final physical = _deduplicatePhysicalFolders(cached);
      _replaceFolderSources(physical);
      if (currentRaw == null && physical.isNotEmpty) {
        await _saveFolderCache(physical);
      }
      return _logicalFolders(physical);
    } catch (_) {
      return <TCloudFolder>[];
    }
  }

  Future<void> _saveFolderCache(List<TCloudFolder> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _folderCacheKey,
      jsonEncode(folders.map((item) => item.toJson()).toList()),
    );
  }

  Future<List<Map<String, dynamic>>> _loadAllForumTopics(int chatId) async {
    final topics = <Map<String, dynamic>>[];
    var offsetDate = 0;
    var offsetMessageId = 0;
    var offsetForumTopicId = 0;

    for (var page = 0; page < 50; page++) {
      final result = await _td.execute('GetForumTopics', <String, dynamic>{
        'chatId': chatId,
        'query': '',
        'offsetDate': offsetDate,
        'offsetMessageId': offsetMessageId,
        'offsetForumTopicId': offsetForumTopicId,
        'limit': 100,
      });
      if (result['_type']?.toString() == 'Error') {
        if (topics.isEmpty) {
          throw StateError(
            result['message']?.toString() ?? 'Falha ao carregar pastas.',
          );
        }
        break;
      }

      final pageTopics = _maps(result['topics']);
      if (pageTopics.isEmpty) break;
      topics.addAll(pageTopics);

      final last = pageTopics.last;
      final info = _asMap(last['info']);
      final lastMessage = _asMap(last['lastMessage']);
      final nextDate = _toInt(lastMessage['date']);
      final nextMessageId = _toInt(lastMessage['id']);
      final nextTopicId = _toInt(info['forumTopicId']) != 0
          ? _toInt(info['forumTopicId'])
          : _toInt(info['messageThreadId']);

      if (pageTopics.length < 100 ||
          (nextDate == offsetDate &&
              nextMessageId == offsetMessageId &&
              nextTopicId == offsetForumTopicId)) {
        break;
      }
      offsetDate = nextDate;
      offsetMessageId = nextMessageId;
      offsetForumTopicId = nextTopicId;
    }

    return topics;
  }

  Future<List<TCloudFolder>> discoverFolders() async {
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        final response = await _td.execute('LoadChats', <String, dynamic>{
          'limit': 100,
        });

        final type = response['_type']?.toString() ?? '';

        if (type == 'Ok') continue;
        if (type == 'Error' && _toInt(response['code']) == 404) break;
      } catch (_) {
        break;
      }
    }

    Map<String, dynamic> result;

    try {
      result = await _td.execute('GetChats', <String, dynamic>{'limit': 5000});
    } catch (_) {
      result = await _td.execute('GetChats', <String, dynamic>{'limit': 1000});
    }

    final chatIds = _intList(result['chatIds']);
    final folders = <TCloudFolder>[];

    for (final chatId in chatIds) {
      try {
        final chat = await _td.execute('GetChat', <String, dynamic>{
          'chatId': chatId,
        });

        final forumTitle = chat['title']?.toString().trim() ?? '';
        if (forumTitle.isEmpty) continue;

        final chatType = _asMap(chat['type']);

        if (chatType['_type']?.toString() != 'ChatTypeSupergroup') {
          continue;
        }

        final supergroupId = _toInt(chatType['supergroupId']);
        if (supergroupId == 0) continue;

        final supergroup = await _td.execute('GetSupergroup', <String, dynamic>{
          'supergroupId': supergroupId,
        });

        if (supergroup['_type']?.toString() == 'Error') continue;
        if (supergroup['isForum'] != true) continue;

        final status = _asMap(supergroup['status']);

        if (status['_type']?.toString() != 'ChatMemberStatusCreator') {
          continue;
        }

        final topics = await _loadAllForumTopics(chatId);

        for (final topic in topics) {
          final info = _asMap(topic['info']);
          final lastMessage = _asMap(topic['lastMessage']);

          final name = info['name']?.toString().trim() ?? '';
          if (name.isEmpty) continue;

          final isGeneral = info['isGeneral'] == true;

          // The special General topic is omitted when it has no real
          // message. This avoids showing an empty placeholder folder.
          if (isGeneral && lastMessage.isEmpty) {
            continue;
          }

          var messageThreadId = _toInt(info['messageThreadId']);
          if (messageThreadId == 0) {
            messageThreadId = _toInt(lastMessage['messageThreadId']);
          }

          final forumTopicId = _toInt(info['forumTopicId']) != 0
              ? _toInt(info['forumTopicId'])
              : _toInt(info['messageThreadId']);
          final historyMessageId = _toInt(lastMessage['id']);

          if (forumTopicId == 0) {
            continue;
          }
          // TCLOUD_LOGICAL_FOLDER_DEDUP_1038
          final candidate = TCloudFolder(
            chatId: chatId,
            title: name,
            forumTitle: forumTitle,
            forumTopicId: forumTopicId,
            messageThreadId: messageThreadId,
            historyMessageId: historyMessageId,
            isGeneral: isGeneral,
          );

          folders.add(candidate);
        }
      } catch (_) {
        // One chat must never block the complete TCloud library.
      }
    }

    final unique = <String, TCloudFolder>{};

    for (final folder in folders) {
      unique[folder.cacheKey] = folder;
    }

    final physicalFolders = unique.values.toList();
    _replaceFolderSources(physicalFolders);
    await _saveFolderCache(physicalFolders);

    return _logicalFolders(physicalFolders);
  }

  Future<void> renameFolder(TCloudFolder folder, String newName) async {
    final name = newName.trim();

    if (folder.forumTopicId == 0) {
      throw StateError('Pasta sem identificador de topico.');
    }

    if (name.isEmpty || name.length > 128) {
      throw StateError('Use um nome entre 1 e 128 caracteres.');
    }

    final result = await _td.execute('EditForumTopic', <String, dynamic>{
      'chatId': folder.chatId,
      'forumTopicId': folder.forumTopicId,
      'name': name,
      'editIconCustomEmoji': false,
      'iconCustomEmojiId': 0,
    });

    if (result['_type']?.toString() == 'Error') {
      throw StateError(
        result['message']?.toString() ?? 'Falha ao renomear pasta.',
      );
    }
  }

  Future<void> deleteFolder(TCloudFolder folder) async {
    if (folder.isGeneral) {
      throw StateError('A pasta Geral do Telegram nao pode ser excluida.');
    }

    if (folder.forumTopicId == 0) {
      throw StateError('Pasta sem identificador de topico.');
    }

    final result = await _td.execute('DeleteForumTopic', <String, dynamic>{
      'chatId': folder.chatId,
      'forumTopicId': folder.forumTopicId,
    });

    if (result['_type']?.toString() == 'Error') {
      throw StateError(
        result['message']?.toString() ?? 'Falha ao excluir pasta.',
      );
    }
  }

  Future<void> createFolder({required int chatId, required String name}) async {
    final cleanName = name.trim();

    if (cleanName.isEmpty || cleanName.length > 128) {
      throw StateError('Use um nome entre 1 e 128 caracteres.');
    }

    final result = await _td.execute('CreateForumTopic', <String, dynamic>{
      'chatId': chatId,
      'name': cleanName,
      'isNameImplicit': false,
      'icon': <String, dynamic>{
        '_type': 'ForumTopicIcon',
        'color': 7322096,
        'customEmojiId': 0,
      },
    });

    if (result['_type']?.toString() == 'Error') {
      throw StateError(
        result['message']?.toString() ?? 'Falha ao criar pasta.',
      );
    }
  }

  Future<TCloudFilePage> loadCachedFilePage(TCloudFolder folder) async {
    final prefs = await SharedPreferences.getInstance();

    // Remove somente paginas da geracao antiga. Nenhum dado remoto,
    // offline fixado, Telegram ou Core e apagado.
    await _purgeLegacyPageCache(prefs);

    final raw = prefs.getString(
      '$_pageCachePrefix${_folderPageCacheKey(folder)}',
    );

    if (raw != null && raw.isNotEmpty) {
      return _decodeCachedFilePage(raw) ?? _emptyCachedFilePage;
    }

    // Leitura defensiva: os caches antigos sao removidos acima porque nao
    // guardavam a identidade remota necessaria para eliminar duplicatas.
    final files = <String, TCloudFile>{};
    final cursors = <String, int>{};
    var hasMore = false;
    var firstCursor = 0;

    for (final source in _sourcesForLogicalFolder(folder)) {
      final legacyRaw = prefs.getString(
        '$_legacyPhysicalPageCachePrefix${source.cacheKey}',
      );
      if (legacyRaw == null || legacyRaw.isEmpty) continue;
      final page = _decodeCachedFilePage(legacyRaw);
      if (page == null) continue;

      for (final file in page.files) {
        files[file.contentIdentity] = file;
      }
      if (firstCursor == 0) firstCursor = page.nextFromMessageId;
      cursors[source.cacheKey] = page.hasMore ? page.nextFromMessageId : -1;
      hasMore = hasMore || page.hasMore;
    }

    if (files.isEmpty) return _emptyCachedFilePage;

    final migratedFiles = files.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final migrated = TCloudFilePage(
      files: migratedFiles,
      nextFromMessageId: firstCursor,
      nextFromMessageIds: cursors,
      hasMore: hasMore,
      fromCache: true,
    );
    await _saveFirstPageCache(folder, migrated);
    return migrated;
  }

  static const _emptyCachedFilePage = TCloudFilePage(
    files: <TCloudFile>[],
    nextFromMessageId: 0,
    hasMore: false,
    fromCache: true,
  );

  TCloudFilePage? _decodeCachedFilePage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException();

      final map = decoded.map((k, v) => MapEntry(k.toString(), v));
      final rawFiles = map['files'];

      final parsedFiles = rawFiles is List
          ? rawFiles
                .whereType<Map>()
                .map(
                  (item) =>
                      TCloudFile.fromJson(
                        item.map((k, v) => MapEntry(k.toString(), v)),
                      ).copyWith(
                        localPath: '',
                        downloaded: false,
                        thumbnailLocalPath: '',
                      ),
                )
                .toList()
          : <TCloudFile>[];
      final filesByContent = <String, TCloudFile>{};
      for (final file in parsedFiles) {
        final current = filesByContent[file.contentIdentity];
        if (current == null || _preferMediaCandidate(file, current)) {
          filesByContent[file.contentIdentity] = file;
        }
      }

      return TCloudFilePage(
        files: filesByContent.values.toList(),
        nextFromMessageId: _toInt(map['nextFromMessageId']),
        hasMore: map['hasMore'] == true,
        nextFromMessageIds: _intMap(map['nextFromMessageIds']),
        fromCache: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveFirstPageCache(
    TCloudFolder folder,
    TCloudFilePage page,
  ) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      '$_pageCachePrefix${_folderPageCacheKey(folder)}',
      jsonEncode(<String, dynamic>{
        'files': page.files.map((item) => item.toJson()).toList(),
        'nextFromMessageId': page.nextFromMessageId,
        'nextFromMessageIds': page.nextFromMessageIds,
        'hasMore': page.hasMore,
      }),
    );
  }

  // TCLOUD_FOLDER_CONTENT_PAGE_CACHE_1038: page cache rebuilt after live-message recovery.\n  // TCLOUD_SYNC_INTEGRITY_61: GetForumTopicHistory preserved; stale album cache invalidated.
  // TCLOUD_LOGICAL_FOLDER_TOPICS_1038
  Future<List<int>> _logicalFolderTopicIds(TCloudFolder folder) async {
    if (folder.forumTopicId == 0) {
      return const <int>[];
    }
    return <int>[folder.forumTopicId];
  }

  // TCLOUD_FORUM_HISTORY_COMPAT_1047
  // Algumas versoes/bridges TDLib expoem o identificador do topico como
  // forumTopicId; outras usam messageThreadId. A leitura tenta ambas sem
  // alterar/deletar nada remoto.
  Future<Map<String, dynamic>> _getForumTopicHistoryCompat({
    required int chatId,
    required int topicId,
    required int fromMessageId,
    required int limit,
  }) async {
    Map<String, dynamic>? firstResponse;

    try {
      final response = await _td
          .execute('GetForumTopicHistory', <String, dynamic>{
            'chatId': chatId,
            'forumTopicId': topicId,
            'fromMessageId': fromMessageId,
            'offset': 0,
            'limit': limit,
          });

      firstResponse = response;

      final messages = _maps(response['messages']);
      if (response['_type']?.toString() != 'Error' && messages.isNotEmpty) {
        return response;
      }
    } catch (_) {}

    try {
      final response = await _td
          .execute('GetForumTopicHistory', <String, dynamic>{
            'chatId': chatId,
            'messageThreadId': topicId,
            'fromMessageId': fromMessageId,
            'offset': 0,
            'limit': limit,
          });

      final messages = _maps(response['messages']);
      if (response['_type']?.toString() != 'Error' && messages.isNotEmpty) {
        return response;
      }

      if (firstResponse == null ||
          firstResponse['_type']?.toString() == 'Error') {
        return response;
      }
    } catch (_) {}

    return firstResponse ??
        <String, dynamic>{
          '_type': 'Messages',
          'messages': <Map<String, dynamic>>[],
        };
  }

  // TCLOUD_GLOBAL_FOLDER_CONTENT_1043
  Future<TCloudFilePage> loadFilePage(
    TCloudFolder folder, {
    int fromMessageId = 0,
    Map<String, int> fromMessageIds = const <String, int>{},
    int limit = 100,
  }) async {
    final safeLimit = limit.clamp(1, 100);
    final sources = _sourcesForLogicalFolder(folder);

    final filesByIdentity = <String, TCloudFile>{};
    var nextFromMessageId = 0;
    var hasMore = false;
    final nextFromMessageIds = <String, int>{};
    var attemptedSources = 0;
    var successfulSources = 0;
    Object? lastSourceError;

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      final sourceCursor = fromMessageIds[source.cacheKey];

      // -1 marks an origin that was completely paged. Without this marker,
      // completed origins would restart at their first page on every load.
      if (sourceCursor == -1) {
        continue;
      }

      attemptedSources++;

      try {
        final page = await _loadFilePageSingleOrigin(
          source,
          fromMessageId:
              sourceCursor ?? (sources.length == 1 ? fromMessageId : 0),
          limit: safeLimit,
        );
        successfulSources++;

        if (index == 0) {
          nextFromMessageId = page.nextFromMessageId;
        }
        if (page.hasMore && page.nextFromMessageId != 0) {
          nextFromMessageIds[source.cacheKey] = page.nextFromMessageId;
          hasMore = true;
        } else {
          nextFromMessageIds[source.cacheKey] = -1;
        }

        for (final file in page.files) {
          final existing = filesByIdentity[file.contentIdentity];
          if (existing == null || _preferMediaCandidate(file, existing)) {
            filesByIdentity[file.contentIdentity] = file;
          }
        }
      } catch (error) {
        lastSourceError = error;
        // Uma origem com falha nao bloqueia as outras.
      }
    }

    if (attemptedSources > 0 && successfulSources == 0) {
      throw StateError(
        'Nao foi possivel atualizar esta pasta. ${lastSourceError ?? ''}',
      );
    }

    final files = filesByIdentity.values.toList()
      ..sort((a, b) {
        final byDate = b.createdAt.compareTo(a.createdAt);
        if (byDate != 0) return byDate;

        final byChat = b.chatId.compareTo(a.chatId);
        if (byChat != 0) return byChat;

        return b.messageId.compareTo(a.messageId);
      });

    final result = TCloudFilePage(
      files: files,
      nextFromMessageId: nextFromMessageId,
      hasMore: hasMore,
      nextFromMessageIds: nextFromMessageIds,
    );

    if (fromMessageId == 0 && fromMessageIds.isEmpty) {
      await _saveFirstPageCache(folder, result);
    }

    return result;
  }

  Future<TCloudFilePage> _loadFilePageSingleOrigin(
    TCloudFolder folder, {
    int fromMessageId = 0,
    int limit = 100,
  }) async {
    final safeLimit = limit.clamp(1, 100);

    // TCLOUD_LOGICAL_FOLDER_CONTENT_1038
    Map<String, dynamic> result;

    if (folder.forumTopicId != 0) {
      final topicIds = await _logicalFolderTopicIds(folder);
      final mergedMessages = <Map<String, dynamic>>[];
      final seenMessageIds = <int>{};

      for (final topicId in topicIds) {
        final physical = await _getForumTopicHistoryCompat(
          chatId: folder.chatId,
          topicId: topicId,
          fromMessageId: fromMessageId,
          limit: safeLimit,
        );

        if (physical['_type']?.toString() == 'Error') {
          continue;
        }

        for (final message in _maps(physical['messages'])) {
          final id = _toInt(message['id']);

          if (id != 0 && seenMessageIds.add(id)) {
            mergedMessages.add(message);
          }
        }
      }

      mergedMessages.sort((a, b) {
        final byDate = _toInt(b['date']).compareTo(_toInt(a['date']));
        if (byDate != 0) {
          return byDate;
        }

        return _toInt(b['id']).compareTo(_toInt(a['id']));
      });

      result = <String, dynamic>{
        '_type': 'Messages',
        'messages': mergedMessages.take(safeLimit).toList(),
      };
    } else {
      result = await _td.execute('GetChatHistory', <String, dynamic>{
        'chatId': folder.chatId,
        'fromMessageId': fromMessageId,
        'offset': 0,
        'limit': safeLimit,
        'onlyLocal': false,
      });
    }
    if (result['_type']?.toString() == 'Error') {
      throw StateError(
        result['message']?.toString() ?? 'Falha ao carregar arquivos.',
      );
    }

    final messages = _maps(result['messages']);
    final files = <TCloudFile>[];

    var oldestMessageId = 0;

    for (final message in messages) {
      final id = _toInt(message['id']);
      if (id == 0) continue;

      if (oldestMessageId == 0 || id < oldestMessageId) {
        oldestMessageId = id;
      }

      final parsed = _messageToFile(message, folder);

      if (parsed != null && _isLiveFileUsable(parsed)) {
        files.add(parsed);
      }
    }

    // TCLOUD_MEDIA_ORDER_1024
    files.sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      if (byDate != 0) return byDate;
      return b.messageId.compareTo(a.messageId);
    });

    final page = TCloudFilePage(
      files: files,
      nextFromMessageId: oldestMessageId,
      hasMore:
          messages.length >= safeLimit &&
          oldestMessageId != 0 &&
          oldestMessageId != fromMessageId,
    );

    return page;
  }

  TCloudFile? _messageToFile(
    Map<String, dynamic> message,
    TCloudFolder folder,
  ) {
    return _messageToFileWithIdentity(
      message,
      chatId: folder.chatId,
      fallbackThreadId: folder.messageThreadId,
    );
  }

  TCloudFile? _messageToFileWithIdentity(
    Map<String, dynamic> message, {
    required int chatId,
    required int fallbackThreadId,
  }) {
    final messageId = _toInt(message['id']);
    final createdAt = _toInt(message['date']);
    final messageThreadId = _toInt(message['messageThreadId']);
    // IDs temporarios pertencem a uploads ainda pendentes ou ja falhos. Eles
    // nao podem entrar na biblioteca porque nao representam arquivos remotos.
    if (_asMap(message['sendingState']).isNotEmpty) return null;

    final content = _asMap(message['content']);
    final type = content['_type']?.toString() ?? '';

    Map<String, dynamic>? media;
    Map<String, dynamic>? primaryFile;
    Map<String, dynamic>? thumbnailFile;
    Map<String, dynamic> minithumbnail = <String, dynamic>{};

    String kind = 'arquivo';
    String? mime;
    String? name;
    var durationSeconds = 0;

    switch (type) {
      case 'MessageDocument':
        media = _asMap(content['document']);
        name = media['fileName']?.toString();
        mime = media['mimeType']?.toString();
        kind = _kindFromNameAndMime(name, mime, fallback: 'documento');
        primaryFile = _asMap(media['document']);
        thumbnailFile = _thumbnailFile(media);
        minithumbnail = _asMap(media['minithumbnail']);
        break;

      case 'MessageVideo':
        media = _asMap(content['video']);
        name = media['fileName']?.toString();
        mime = media['mimeType']?.toString();
        kind = 'video';
        durationSeconds = _toInt(media['duration']);
        primaryFile = _asMap(media['video']);
        thumbnailFile = _thumbnailFile(media);
        minithumbnail = _asMap(media['minithumbnail']);
        break;

      case 'MessageAnimation':
        media = _asMap(content['animation']);
        name = media['fileName']?.toString();
        mime = media['mimeType']?.toString();
        kind = 'animacao';
        durationSeconds = _toInt(media['duration']);
        primaryFile = _asMap(media['animation']);
        thumbnailFile = _thumbnailFile(media);
        minithumbnail = _asMap(media['minithumbnail']);
        break;

      case 'MessageAudio':
        media = _asMap(content['audio']);
        name = media['fileName']?.toString();
        mime = media['mimeType']?.toString();
        kind = 'audio';
        primaryFile = _asMap(media['audio']);
        thumbnailFile = _thumbnailFile(media);
        break;

      case 'MessageVoiceNote':
        media = _asMap(content['voiceNote']);
        mime = media['mimeType']?.toString();
        kind = 'audio';
        primaryFile = _asMap(media['voice']);
        if (primaryFile.isEmpty) {
          primaryFile = _asMap(media['voiceNote']);
        }
        break;

      case 'MessagePhoto':
        final photo = _asMap(content['photo']);
        minithumbnail = _asMap(photo['minithumbnail']);
        final sizes = _maps(photo['sizes']);
        if (sizes.isEmpty) return null;

        Map<String, dynamic>? displaySize;
        Map<String, dynamic>? fullSize;

        for (final size in sizes) {
          final width = _toInt(size['width']);
          final height = _toInt(size['height']);
          final area = width * height;

          if (fullSize == null ||
              area > _toInt(fullSize['width']) * _toInt(fullSize['height'])) {
            fullSize = size;
          }

          if (width >= 240 && height >= 240) {
            if (displaySize == null) {
              displaySize = size;
            } else {
              final currentArea =
                  _toInt(displaySize['width']) * _toInt(displaySize['height']);
              if (area < currentArea) displaySize = size;
            }
          }
        }

        fullSize ??= sizes.last;
        displaySize ??= sizes.first;

        primaryFile = _asMap(fullSize['photo']);
        thumbnailFile = _asMap(displaySize['photo']);

        kind = 'imagem';
        mime = 'image/jpeg';
        name = 'imagem_$messageId.jpg';
        break;

      default:
        return null;
    }

    if (primaryFile.isEmpty) return null;

    final fileId = _toInt(primaryFile['id']);
    final size = _toInt(primaryFile['size']) > 0
        ? _toInt(primaryFile['size'])
        : _toInt(primaryFile['expectedSize']);
    if (fileId == 0) return null;

    name = (name ?? '').trim();

    // Versoes antigas usavam o timestamp para tornar o arquivo temporario
    // unico e acabavam enviando esse prefixo como parte do nome ao Telegram.
    name = name.replaceFirst(RegExp(r'^\d{13,19}_(?=.+)'), '');

    if (name.isEmpty) {
      name = switch (kind) {
        'video' => 'video_$messageId.mp4',
        'audio' => 'audio_$messageId',
        'imagem' => 'imagem_$messageId.jpg',
        'animacao' => 'animacao_$messageId',
        _ => 'arquivo_$messageId',
      };
    }

    // Reclassify documents by extension/MIME, because Telegram often stores
    // photos and videos as MessageDocument.
    kind = _kindFromNameAndMime(name, mime, fallback: kind);

    final local = _asMap(primaryFile['local']);
    final downloaded = local['isDownloadingCompleted'] == true;
    final localPath = local['path']?.toString().trim();

    final thumbnailId = _toInt(thumbnailFile?['id']);
    final thumbnailLocal = _asMap(thumbnailFile?['local']);
    final thumbnailDownloaded =
        thumbnailLocal['isDownloadingCompleted'] == true;
    final thumbnailPath = thumbnailLocal['path']?.toString().trim();
    final remote = _asMap(primaryFile['remote']);
    if (remote['isUploadingCompleted'] == false) return null;

    return TCloudFile(
      coreFileId: (message['coreFileId'] ?? message['core_file_id'])
          ?.toString(),
      messageId: messageId,
      chatId: chatId,
      messageThreadId: messageThreadId != 0
          ? messageThreadId
          : fallbackThreadId,
      fileId: fileId,
      name: name,
      size: size,
      kind: kind,
      createdAt: createdAt,
      mimeType: mime,
      downloaded: downloaded,
      localPath: localPath == null || localPath.isEmpty ? null : localPath,
      thumbnailFileId: thumbnailId,
      thumbnailLocalPath:
          thumbnailDownloaded &&
              thumbnailPath != null &&
              thumbnailPath.isNotEmpty
          ? thumbnailPath
          : null,
      minithumbnailBase64: minithumbnail['data']?.toString(),
      durationSeconds: durationSeconds,
      remoteId: remote['id']?.toString(),
      remoteUniqueId: remote['uniqueId']?.toString(),
    );
  }

  bool _preferMediaCandidate(TCloudFile candidate, TCloudFile current) {
    final candidateLocal = candidate.localPath?.trim().isNotEmpty == true;
    final currentLocal = current.localPath?.trim().isNotEmpty == true;
    if (candidateLocal != currentLocal) return candidateLocal;
    if (candidate.size != current.size) return candidate.size > current.size;
    if (candidate.thumbnailFileId != current.thumbnailFileId) {
      return candidate.thumbnailFileId > 0;
    }
    return candidate.createdAt > current.createdAt;
  }

  // TCLOUD_MEDIA_HISTORY_RECOVERY_1034
  Future<TCloudFile?> _refreshMediaFromRemoteHistory(TCloudFile file) async {
    if (file.chatId == 0 || file.messageId == 0) {
      return null;
    }

    const offsets = <int>[-1, 0];
    const limits = <int>[4, 8];

    for (var i = 0; i < offsets.length; i++) {
      try {
        final history = await _td.execute('GetChatHistory', <String, dynamic>{
          'chatId': file.chatId,
          'fromMessageId': file.messageId,
          'offset': offsets[i],
          'limit': limits[i],
          'onlyLocal': false,
        });

        if (history['_type']?.toString() == 'Error') {
          continue;
        }

        for (final message in _maps(history['messages'])) {
          if (_toInt(message['id']) != file.messageId) {
            continue;
          }

          final resolved = _messageToFileWithIdentity(
            message,
            chatId: file.chatId,
            fallbackThreadId: file.messageThreadId,
          );

          if (resolved == null || resolved.fileId <= 0) {
            continue;
          }

          final localPath = resolved.localPath?.trim() ?? '';
          final localUsable =
              localPath.isNotEmpty && await File(localPath).exists();

          if (resolved.size > 0 || localUsable) {
            return resolved;
          }
        }
      } catch (_) {
        // A tentativa seguinte ainda pode obter o objeto atualizado.
      }
    }

    try {
      final response = await _td.execute('GetMessage', <String, dynamic>{
        'chatId': file.chatId,
        'messageId': file.messageId,
      });

      if (response['_type']?.toString() != 'Error') {
        final resolved = _messageToFileWithIdentity(
          response,
          chatId: file.chatId,
          fallbackThreadId: file.messageThreadId,
        );

        if (resolved != null && resolved.fileId > 0) {
          final localPath = resolved.localPath?.trim() ?? '';
          final localUsable =
              localPath.isNotEmpty && await File(localPath).exists();

          if (resolved.size > 0 || localUsable) {
            return resolved;
          }
        }
      }
    } catch (_) {}

    return null;
  }

  Future<TCloudFile> resolveCurrentMedia(TCloudFile file) {
    final key = file.stableIdentity;
    final cached = _resolvedMediaCache[key];

    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) <
            const Duration(minutes: 2)) {
      return Future<TCloudFile>.value(cached.file);
    }

    final running = _resolvedMediaInFlight[key];
    if (running != null) return running;

    final future = _resolveCurrentMediaUncached(file);
    _trackResolvedMedia(key, future);

    return future;
  }

  /// Descarta identificadores TDLib antigos e consulta novamente o servidor.
  /// Usado por tentativas manuais e por um DownloadFile que acabou de falhar.
  Future<TCloudFile> refreshCurrentMedia(TCloudFile file) async {
    final key = file.stableIdentity;

    // Deixa uma consulta anterior terminar antes de iniciar a consulta forçada,
    // evitando duas leituras concorrentes da mesma mensagem no MethodChannel.
    final running = _resolvedMediaInFlight[key];
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }

    _resolvedMediaCache.remove(key);
    final future = _resolveCurrentMediaUncached(
      file,
      preferRemoteHistory: true,
    );
    _trackResolvedMedia(key, future);
    return future;
  }

  void _trackResolvedMedia(String key, Future<TCloudFile> future) {
    _resolvedMediaInFlight[key] = future;

    future
        .then((resolved) {
          if (resolved.fileId > 0) {
            _resolvedMediaCache[key] = _ResolvedMediaCacheEntry(
              DateTime.now(),
              resolved,
            );
          }
        })
        .whenComplete(() {
          if (identical(_resolvedMediaInFlight[key], future)) {
            _resolvedMediaInFlight.remove(key);
          }
        });
  }

  Future<TCloudFile> _resolveCurrentMediaUncached(
    TCloudFile file, {
    bool preferRemoteHistory = false,
  }) async {
    if (file.chatId == 0 || file.messageId == 0) {
      return file;
    }

    TCloudFile best = file;

    if (preferRemoteHistory) {
      final remote = await _refreshMediaFromRemoteHistory(file);
      if (remote != null) {
        final enriched = await TCloudCoreCatalog.instance.enrich(remote);
        return enriched.coreFileId?.trim().isNotEmpty == true
            ? enriched
            : remote.copyWith(coreFileId: file.coreFileId);
      }
    }

    const delays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 120),
      Duration(milliseconds: 280),
    ];

    for (var attempt = 0; attempt < delays.length; attempt++) {
      final delay = delays[attempt];

      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }

      final response = await _td.execute('GetMessage', <String, dynamic>{
        'chatId': file.chatId,
        'messageId': file.messageId,
      });

      if (response['_type']?.toString() == 'Error') {
        continue;
      }

      final resolved = _messageToFileWithIdentity(
        response,
        chatId: file.chatId,
        fallbackThreadId: file.messageThreadId,
      );

      if (resolved == null) {
        continue;
      }

      best = resolved;

      final localPath = resolved.localPath?.trim() ?? '';
      final localUsable =
          localPath.isNotEmpty && await File(localPath).exists();

      // The diagnostic captured stale TDLib objects with:
      // fileId > 0, size == 0, path == "", remote.id == "".
      // A server-refreshed media object has a real size, or a valid local file.
      final usable = resolved.fileId > 0 && (resolved.size > 0 || localUsable);

      if (usable) {
        final enriched = await TCloudCoreCatalog.instance.enrich(resolved);
        return enriched.coreFileId?.trim().isNotEmpty == true
            ? enriched
            : resolved.copyWith(coreFileId: file.coreFileId);
      }
    }

    // Se GetMessage devolveu um objeto TDLib obsoleto, força uma leitura
    // remota do histórico antes de depender do Core local.
    final refreshedFromHistory = await _refreshMediaFromRemoteHistory(best);
    if (refreshedFromHistory != null) {
      final enriched = await TCloudCoreCatalog.instance.enrich(
        refreshedFromHistory,
      );
      return enriched.coreFileId?.trim().isNotEmpty == true
          ? enriched
          : refreshedFromHistory.copyWith(coreFileId: file.coreFileId);
    }

    return TCloudCoreCatalog.instance.enrich(best);
  }

  Map<String, dynamic>? _thumbnailFile(Map<String, dynamic> media) {
    final thumbnail = _asMap(media['thumbnail']);
    final file = _asMap(thumbnail['file']);
    return file.isEmpty ? null : file;
  }

  String _kindFromNameAndMime(
    String? name,
    String? mime, {
    required String fallback,
  }) {
    final lowerName = (name ?? '').toLowerCase();
    final lowerMime = (mime ?? '').toLowerCase();
    final ext = lowerName.contains('.')
        ? lowerName.substring(lowerName.lastIndexOf('.') + 1)
        : '';

    const imageExts = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif',
      'avif',
    };

    const videoExts = {'mp4', 'webm', 'mov', 'm4v', 'mkv', 'avi', '3gp'};

    const audioExts = {'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'flac'};

    if (lowerMime.startsWith('image/') || imageExts.contains(ext)) {
      return 'imagem';
    }

    if (lowerMime.startsWith('video/') || videoExts.contains(ext)) {
      return 'video';
    }

    if (lowerMime.startsWith('audio/') || audioExts.contains(ext)) {
      return 'audio';
    }

    return fallback;
  }

  Future<String?> ensureThumbnail(TCloudFile file) async {
    final current = await resolveCurrentMedia(file);

    final cachedPath = current.thumbnailLocalPath;
    if (cachedPath != null &&
        cachedPath.isNotEmpty &&
        await File(cachedPath).exists()) {
      return cachedPath;
    }

    // TCLOUD_TELEGRAM_CACHE_FAST_PATH_1052
    // Se a imagem completa ja esta no cache local gerenciado pelo TDLib,
    // usa o proprio arquivo do Telegram antes de iniciar qualquer DownloadFile.
    if (current.isImage) {
      final telegramLocal = current.localPath;
      if (telegramLocal != null &&
          telegramLocal.isNotEmpty &&
          await File(telegramLocal).exists()) {
        return telegramLocal;
      }
    }

    if (current.thumbnailFileId != 0) {
      final response = await _td.execute('DownloadFile', <String, dynamic>{
        'fileId': current.thumbnailFileId,
        'priority': 24,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      });

      if (response['_type']?.toString() != 'Error') {
        final local = _asMap(response['local']);
        final path = local['path']?.toString().trim() ?? '';

        if (local['isDownloadingCompleted'] == true &&
            path.isNotEmpty &&
            await File(path).exists()) {
          return path;
        }
      }
    }

    if (current.isImage &&
        current.fileId > 0 &&
        current.size > 0 &&
        current.size <= 8 * 1024 * 1024) {
      final response = await _td.execute('DownloadFile', <String, dynamic>{
        'fileId': current.fileId,
        'priority': 12,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      });

      if (response['_type']?.toString() != 'Error') {
        final local = _asMap(response['local']);
        final path = local['path']?.toString().trim() ?? '';

        if (local['isDownloadingCompleted'] == true &&
            path.isNotEmpty &&
            await File(path).exists()) {
          return path;
        }
      }
    }

    return null;
  }

  Future<String> download(TCloudFile file, {bool forceRefresh = false}) async {
    var current = forceRefresh
        ? await refreshCurrentMedia(file)
        : await resolveCurrentMedia(file);

    if (forceRefresh && current.fileId > 0) {
      // "Baixar e reproduzir" precisa ser um reparo real. Antes ele aceitava
      // novamente a mesma copia local incompleta/corrompida e falhava igual.
      try {
        await _td.execute('CancelDownloadFile', <String, dynamic>{
          'fileId': current.fileId,
          'onlyIfPending': false,
        });
      } catch (_) {}
      try {
        await _td.execute('DeleteFile', <String, dynamic>{
          'fileId': current.fileId,
        });
      } catch (_) {}
      _resolvedMediaCache.remove(file.stableIdentity);
      current = await refreshCurrentMedia(file);
    }
    final existingPath = current.localPath;

    if (!forceRefresh &&
        current.downloaded &&
        existingPath != null &&
        existingPath.trim().isNotEmpty &&
        await File(existingPath).exists()) {
      try {
        final remote = await _td.execute('GetFile', <String, dynamic>{
          'fileId': current.fileId,
        });

        if (remote['_type']?.toString() != 'Error') {
          final local = _asMap(remote['local']);
          final currentPath = local['path']?.toString().trim() ?? '';

          if (local['isDownloadingCompleted'] == true &&
              currentPath == existingPath.trim()) {
            return currentPath;
          }
        }
      } catch (_) {}
    }

    var target = current;

    var result = await _td.execute('DownloadFile', <String, dynamic>{
      'fileId': target.fileId,
      'priority': 32,
      'offset': 0,
      'limit': 0,
      'synchronous': true,
    });

    if (result['_type']?.toString() == 'Error') {
      // A mensagem pode ter sido atualizada pelo servidor imediatamente
      // depois da primeira resolucao. Faz um refresh final e tenta o novo ID.
      await Future<void>.delayed(const Duration(milliseconds: 350));

      target = await refreshCurrentMedia(file);

      if (target.fileId > 0) {
        result = await _td.execute('DownloadFile', <String, dynamic>{
          'fileId': target.fileId,
          'priority': 32,
          'offset': 0,
          'limit': 0,
          'synchronous': true,
        });
      }
    }

    if (result['_type']?.toString() == 'Error') {
      final canonical = target.coreFileId?.trim() ?? '';
      if (canonical.isNotEmpty) {
        return _downloadCanonicalFallback(target, canonical);
      }
      throw StateError(
        result['message']?.toString() ?? 'Falha ao baixar arquivo.',
      );
    }

    final local = _asMap(result['local']);
    final path = local['path']?.toString().trim() ?? '';
    final completed = local['isDownloadingCompleted'] == true;

    if (!completed || path.isEmpty || !await File(path).exists()) {
      final canonical = target.coreFileId?.trim() ?? '';
      if (canonical.isNotEmpty) {
        return _downloadCanonicalFallback(target, canonical);
      }
      throw StateError('O download nao foi concluido pelo Telegram.');
    }

    await rememberOffline(target.copyWith(localPath: path, downloaded: true));

    _resolvedMediaCache[target.stableIdentity] = _ResolvedMediaCacheEntry(
      DateTime.now(),
      target.copyWith(localPath: path, downloaded: true),
    );

    return path;
  }

  Future<String> _downloadCanonicalFallback(
    TCloudFile file,
    String coreFileId,
  ) async {
    final safeId = coreFileId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final safeName = file.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}tcloud_core_media',
    );
    final path =
        '${directory.path}${Platform.pathSeparator}${safeId}_${safeName.isEmpty ? 'arquivo' : safeName}';
    final downloadedPath = await _canonicalOps.downloadMedia(
      coreFileId,
      path,
      expectedSize: file.size,
    );
    final downloaded = file.copyWith(
      localPath: downloadedPath,
      downloaded: true,
    );
    await rememberOffline(downloaded);
    _resolvedMediaCache[file.stableIdentity] = _ResolvedMediaCacheEntry(
      DateTime.now(),
      downloaded,
    );
    return downloadedPath;
  }

  Future<void> upload({
    required TCloudFolder folder,
    required String path,
  }) async {
    final normalizedPath = path.trim();

    if (normalizedPath.isEmpty) {
      throw StateError('Arquivo local invalido.');
    }

    await _td.sendDocument(
      chatId: folder.chatId,
      forumTopicId: folder.forumTopicId,
      messageThreadId: folder.messageThreadId,
      path: normalizedPath,
    );
  }

  Future<Map<String, dynamic>> uploadTrackedBackup({
    required TCloudFolder folder,
    required String path,
  }) async {
    final normalizedPath = path.trim();

    if (normalizedPath.isEmpty) {
      throw StateError('Arquivo local invalido.');
    }

    final messageId = await _td.sendDocument(
      chatId: folder.chatId,
      forumTopicId: folder.forumTopicId,
      messageThreadId: folder.messageThreadId,
      path: normalizedPath,
    );

    if (messageId == 0) {
      throw StateError('Telegram nao confirmou o upload da midia.');
    }

    return <String, dynamic>{'_type': 'Message', 'id': messageId};
  }

  Future<void> deleteFiles(Iterable<TCloudFile> files) async {
    final byChat = <int, List<int>>{};

    for (final file in files) {
      if (file.chatId == 0 || file.messageId == 0) continue;

      byChat.putIfAbsent(file.chatId, () => <int>[]).add(file.messageId);
    }

    for (final entry in byChat.entries) {
      final ids = entry.value.toSet().toList()..sort();

      if (ids.isEmpty) continue;

      final result = await _td.execute('DeleteMessages', <String, dynamic>{
        'chatId': entry.key,
        'messageIds': ids,
        'revoke': true,
      });

      if (result['_type']?.toString() == 'Error') {
        throw StateError(
          result['message']?.toString() ?? 'Falha ao excluir arquivos.',
        );
      }
    }
  }

  Future<void> moveFiles(
    Iterable<TCloudFile> files,
    TCloudFolder destination,
  ) async {
    if (destination.chatId == 0 || destination.forumTopicId == 0) {
      throw StateError('A pasta de destino nao possui um topico valido.');
    }

    final bySourceChat = <int, List<TCloudFile>>{};

    for (final file in files) {
      if (file.chatId == 0 || file.messageId == 0) continue;

      bySourceChat.putIfAbsent(file.chatId, () => <TCloudFile>[]).add(file);
    }

    for (final entry in bySourceChat.entries) {
      final sourceChatId = entry.key;

      final group = entry.value
        ..sort((a, b) => a.messageId.compareTo(b.messageId));

      for (var start = 0; start < group.length; start += 100) {
        final end = (start + 100).clamp(0, group.length);

        final chunk = group.sublist(start, end);

        final ids = chunk.map((file) => file.messageId).toList();

        final result = await _td.execute('ForwardMessages', <String, dynamic>{
          'chatId': destination.chatId,
          'topicId': <String, dynamic>{
            '_type': 'MessageTopicForum',
            'forumTopicId': destination.forumTopicId,
          },
          'fromChatId': sourceChatId,
          'messageIds': ids,
          'options': null,
          'sendCopy': true,
          'removeCaption': false,
        });

        if (result['_type']?.toString() == 'Error') {
          throw StateError(
            result['message']?.toString() ??
                'Falha ao copiar arquivos para a nova pasta.',
          );
        }

        final messages = _maps(result['messages']);

        final copiedCount = messages
            .where(
              (message) =>
                  message.isNotEmpty && message['_type']?.toString() != 'Error',
            )
            .length;

        if (copiedCount != ids.length) {
          throw StateError(
            'Nem todos os arquivos puderam ser movidos. '
            'Os originais foram mantidos.',
          );
        }
      }
    }

    // Delete originals only after every copy succeeds.
    await deleteFiles(files);
  }

  Future<TCloudFolder> createFolderAndReturn({
    required int chatId,
    required String forumTitle,
    required String name,
  }) async {
    final cleanName = name.trim();

    if (cleanName.isEmpty || cleanName.length > 128) {
      throw StateError('Use um nome entre 1 e 128 caracteres.');
    }

    final result = await _td.execute('CreateForumTopic', <String, dynamic>{
      'chatId': chatId,
      'name': cleanName,
      'isNameImplicit': false,
      'icon': <String, dynamic>{
        '_type': 'ForumTopicIcon',
        'color': 7322096,
        'customEmojiId': 0,
      },
    });

    if (result['_type']?.toString() == 'Error') {
      throw StateError(
        result['message']?.toString() ?? 'Falha ao criar pasta.',
      );
    }

    final forumTopicId = _toInt(result['forumTopicId']);

    if (forumTopicId == 0) {
      throw StateError(
        'O Telegram criou a pasta, mas nao retornou '
        'um identificador de topico valido.',
      );
    }

    return TCloudFolder(
      chatId: chatId,
      title: cleanName,
      forumTitle: forumTitle,
      forumTopicId: forumTopicId,
    );
  }

  Future<void> rememberOffline(TCloudFile file) async {
    final prefs = await SharedPreferences.getInstance();
    final values = prefs.getStringList(_offlineKey) ?? <String>[];

    values.removeWhere((item) {
      try {
        final decoded = jsonDecode(item);
        return decoded is Map && _toInt(decoded['fileId']) == file.fileId;
      } catch (_) {
        return false;
      }
    });

    values.add(jsonEncode(file.toJson()));
    await prefs.setStringList(_offlineKey, values);
  }

  Future<void> removeOffline(TCloudFile file) async {
    final prefs = await SharedPreferences.getInstance();

    final values = prefs.getStringList(_offlineKey) ?? <String>[];

    values.removeWhere((item) {
      try {
        final decoded = jsonDecode(item);

        return decoded is Map && _toInt(decoded['fileId']) == file.fileId;
      } catch (_) {
        return false;
      }
    });

    await prefs.setStringList(_offlineKey, values);
  }

  Future<List<TCloudFile>> loadOffline() async {
    final prefs = await SharedPreferences.getInstance();
    final values = prefs.getStringList(_offlineKey) ?? <String>[];

    final validFiles = <TCloudFile>[];
    final validPayloads = <String>[];

    for (final value in values) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is! Map) continue;

        final file = TCloudFile.fromJson(
          decoded.map((k, v) => MapEntry(k.toString(), v)),
        );

        final path = file.localPath;

        if (path == null || path.isEmpty || !await File(path).exists()) {
          continue;
        }

        try {
          final current = await _td.execute('GetFile', <String, dynamic>{
            'fileId': file.fileId,
          });
          final currentLocal = _asMap(current['local']);
          final currentPath = currentLocal['path']?.toString().trim() ?? '';
          final completed = currentLocal['isDownloadingCompleted'] == true;

          if (!completed || currentPath != path.trim()) {
            continue;
          }
        } catch (_) {
          continue;
        }

        validFiles.add(file.copyWith(downloaded: true));
        validPayloads.add(value);
      } catch (_) {}
    }

    if (validPayloads.length != values.length) {
      await prefs.setStringList(_offlineKey, validPayloads);
    }

    return validFiles;
  }

  List<int> _intList(dynamic raw) {
    if (raw is! List) return <int>[];
    return raw.map(_toInt).where((id) => id != 0).toList();
  }

  Map<String, int> _intMap(dynamic raw) {
    if (raw is! Map) return <String, int>{};
    return raw.map((key, value) => MapEntry(key.toString(), _toInt(value)))
      ..removeWhere((_, value) => value == 0);
  }

  List<Map<String, dynamic>> _maps(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];

    return raw
        .whereType<Map>()
        .map(
          (value) => value.map((key, item) => MapEntry(key.toString(), item)),
        )
        .toList();
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

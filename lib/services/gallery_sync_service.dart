import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/tcloud_folder.dart';
import '../telegram/tdlib_service.dart';
import 'tcloud_repository.dart';
import 'library_preferences_service.dart';

class GallerySyncResult {
  const GallerySyncResult({
    required this.found,
    required this.uploaded,
    required this.failed,
    this.pending = 0,
  });

  final int found;
  final int uploaded;
  final int failed;
  final int pending;
}

class GallerySyncRateLimitException implements Exception {
  const GallerySyncRateLimitException(this.until);

  final DateTime until;

  Duration get remaining {
    final value = until.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  @override
  String toString() => 'Aguardando o limite temporário do Telegram.';
}

class GallerySyncService {
  GallerySyncService._();

  static final instance = GallerySyncService._();
  // TCLOUD_SYNC_PROGRESS_1051
  int _activityTotal = 0;
  int _activityUploaded = 0;
  int _activityFailed = 0;
  bool _activityRunning = false;
  final Map<String, Map<String, dynamic>> _activityItems =
      <String, Map<String, dynamic>>{};

  String _activityItemName(Map<String, dynamic> item) {
    final explicit = (item['displayName'] ?? item['name'])?.toString().trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final uri = item['uri']?.toString() ?? '';
    if (uri.isEmpty) return 'Arquivo';

    final clean = uri.replaceAll('\\', '/');
    final last = clean.split('/').last;
    return last.isEmpty ? 'Arquivo' : Uri.decodeComponent(last);
  }

  // TCLOUD_SYNC_NOTIFICATION_LIVE_1052
  Future<void> _activityPrepare(List<Map<String, dynamic>> batch) async {
    _activityTotal = batch.length;
    _activityUploaded = 0;
    _activityFailed = 0;
    _activityRunning = batch.isNotEmpty;

    await _td.showGallerySyncProgress(
      total: _activityTotal,
      done: 0,
      failed: 0,
      running: _activityRunning,
    );
    _activityItems.clear();

    for (final item in batch.take(120)) {
      final uri = item['uri']?.toString() ?? '';
      if (uri.isEmpty) continue;

      _activityItems[uri] = <String, dynamic>{
        'uri': uri,
        'name': _activityItemName(item),
        'album': _albumName(item),
        'state': 'aguardando',
      };
    }
  }

  void _activitySet(String uri, String state) {
    if (uri.isEmpty) return;
    final current = _activityItems[uri];
    if (current != null) current['state'] = state;
  }

  Future<Map<String, dynamic>> syncActivitySnapshot() async {
    final native = await _td.backgroundGalleryQueue();

    final nativeItems = native.take(120).map((item) {
      final uri = item['uri']?.toString() ?? '';
      return <String, dynamic>{
        'uri': uri,
        'name': _activityItemName(item),
        'album': _albumName(item),
        'state': 'na fila',
      };
    }).toList();

    final merged = <String, Map<String, dynamic>>{};

    for (final item in <Map<String, dynamic>>[
      ..._activityItems.values,
      ...nativeItems,
    ]) {
      final key = item['uri']?.toString() ?? '';
      if (key.isEmpty) continue;
      merged[key] = item;
    }

    return <String, dynamic>{
      'running': _activityRunning,
      'total': _activityTotal,
      'uploaded': _activityUploaded,
      'failed': _activityFailed,
      'pendingNative': native.length,
      'items': merged.values.toList(),
    };
  }

  static const _enabledKey = 'tcloud_gallery_sync_enabled_v2';
  static const _targetKey = 'tcloud_gallery_sync_target_v2';
  static const _lastSyncKey = 'tcloud_gallery_sync_last_ms_v2';
  static const _syncedUrisKey = 'tcloud_gallery_sync_uris_v2';
  static const _retryQueueKey = 'tcloud_gallery_retry_queue_v3';
  static const _wifiOnlyKey = 'tcloud_gallery_wifi_only_v1';
  static const _chargingOnlyKey = 'tcloud_gallery_charging_only_v1';

  static const _backupRecordsKey = 'tcloud_gallery_backup_records_v3';
  static const _oldBackupRecordsKey = 'tcloud_gallery_backup_records_v1';
  static const _createdFoldersKey = 'tcloud_gallery_created_folders_v3';

  static const _fullBeforeKey = 'tcloud_gallery_full_before_ms_v3';
  static const _fullCompleteKey = 'tcloud_gallery_full_complete_v3';
  static const _historicalRecovery1054Key =
      'tcloud_gallery_historical_recovery_1054';
  static const _lastErrorKey = 'tcloud_gallery_last_error_v3';
  static const _rateLimitUntilKey = 'tcloud_gallery_rate_limit_until_ms_v1';

  // ignore: unused_field
  static const _galleryHierarchyKey = 'tcloud_gallery_hierarchy_v4';

  static const _albumRoutingV6Key = 'tcloud_gallery_album_routing_v6';
  static const _cacheLimitMbKey = 'tcloud_cache_limit_mb_v1';
  static const _pageSize = 250;
  static const _maxPagesPerRun = 6;
  // Duas transferencias simultaneas mantem boa velocidade sem disparar o
  // controle anti-spam do Telegram durante backups grandes.
  static const _maxParallelUploads = 2;
  static const _persistEveryUploads = 8;
  final _td = TdlibService.instance;
  final _repo = TCloudRepository.instance;
  bool _syncNowRunning = false;

  int? _retryAfterSeconds(Object error) {
    final text = error.toString();
    final match = RegExp(
      r'(?:retry after|retry_after|flood_wait[_ ]?)(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  Future<DateTime?> rateLimitUntil() async {
    final prefs = await SharedPreferences.getInstance();
    final milliseconds = prefs.getInt(_rateLimitUntilKey) ?? 0;
    if (milliseconds <= DateTime.now().millisecondsSinceEpoch) {
      if (milliseconds != 0) await prefs.remove(_rateLimitUntilKey);
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  Future<DateTime?> registerRateLimit(Object error) async {
    final seconds = _retryAfterSeconds(error);
    if (seconds == null || seconds <= 0) return null;
    // Pequena margem impede que uma nova chamada chegue antes do desbloqueio.
    final until = DateTime.now().add(Duration(seconds: seconds + 5));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_rateLimitUntilKey, until.millisecondsSinceEpoch);
    await prefs.setString(
      _lastErrorKey,
      'O Telegram pediu uma pausa temporária no backup.',
    );
    return until;
  }

  String rateLimitMessage(DateTime until) {
    final remaining = until.difference(DateTime.now());
    if (remaining.isNegative || remaining == Duration.zero) {
      return 'O backup já pode ser retomado.';
    }
    final minutes = (remaining.inSeconds / 60).ceil();
    return minutes <= 1
        ? 'O Telegram pediu uma pausa. Tente novamente em cerca de 1 minuto.'
        : 'O Telegram pediu uma pausa. O backup retomará automaticamente em cerca de $minutes minutos.';
  }

  Future<bool> wifiOnly() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getBool(_wifiOnlyKey) ?? false;
  }

  Future<bool> chargingOnly() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getBool(_chargingOnlyKey) ?? false;
  }

  Future<void> setBackgroundOptions({
    required bool wifiOnly,
    required bool chargingOnly,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool(_wifiOnlyKey, wifiOnly);

    await prefs.setBool(_chargingOnlyKey, chargingOnly);

    await _td.configureBackgroundGalleryOptions(
      wifiOnly: wifiOnly,
      requiresCharging: chargingOnly,
    );
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool(_enabledKey, enabled);

    await _td.scheduleBackgroundGallerySync(enabled);
  }

  Future<String?> targetFolderKey() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_targetKey);
    if (saved == null || saved.isEmpty) return saved;

    // Versoes ate 1.0.57 incluiam o ID da ultima mensagem na identidade da
    // pasta. Migra a preferencia sem trocar o destino da sincronizacao.
    final parts = saved.split(':');
    if (parts.length == 4) {
      final migrated = parts.take(3).join(':');
      await prefs.setString(_targetKey, migrated);
      return migrated;
    }

    return saved;
  }

  Future<void> setTargetFolder(TCloudFolder folder) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_targetKey, folder.cacheKey);

    await _td.setBackgroundGalleryTarget(
      chatId: folder.chatId,
      messageThreadId: folder.messageThreadId,
    );
  }

  Future<int> pendingCount() async {
    final pending = await _loadRetryQueue(includeFuture: true);

    final staged = await _td.backgroundGalleryQueue();

    final uris = <String>{
      ...pending.map((item) => item['uri']?.toString() ?? ''),
      ...staged.map((item) => item['uri']?.toString() ?? ''),
    }..remove('');

    return uris.length;
  }

  Future<int> cacheLimitMb() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getInt(_cacheLimitMbKey) ?? 250;
  }

  Future<void> setCacheLimitMb(int value) async {
    if (!const <int>{100, 250, 500, 1024}.contains(value)) {
      throw StateError('Limite de cache invalido.');
    }

    final prefs = await SharedPreferences.getInstance();

    await prefs.setInt(_cacheLimitMbKey, value);

    await enforceSmartStorage();
  }

  Future<Map<String, dynamic>> cacheInfo() {
    return _td.tcloudCacheInfo();
  }

  Future<Map<String, dynamic>> clearCacheNow() {
    return _td.clearTCloudTemporaryCache();
  }

  Future<void> enforceSmartStorage() async {
    final info = await cacheInfo();
    final bytes = _asInt(info['bytes']);
    final limit = await cacheLimitMb();

    if (bytes > limit * 1024 * 1024) {
      await clearCacheNow();
    }
  }

  Future<String?> lastBackupError() async {
    final prefs = await SharedPreferences.getInstance();

    final value = prefs.getString(_lastErrorKey);

    if (value == null || value.trim().isEmpty) {
      return null;
    }

    return value.trim();
  }

  Future<int> backupRecordCount() async {
    final local = await _loadBackupRecords();

    final old = await _loadOldBackupRecords();

    final background = await _td.backgroundBackupRecords();

    final created = await _loadCreatedFolders();

    final messages = <String>{
      ...local.map(
        (item) => '${_asInt(item['chatId'])}:${_asInt(item['messageId'])}',
      ),
      ...old.map(
        (item) => '${_asInt(item['chatId'])}:${_asInt(item['messageId'])}',
      ),
      ...background.map(
        (item) => '${_asInt(item['chatId'])}:${_asInt(item['messageId'])}',
      ),
    }..removeWhere((value) => value.endsWith(':0'));

    final folders = <String>{
      ...created.map(
        (item) => '${_asInt(item['chatId'])}:${_asInt(item['forumTopicId'])}',
      ),
    }..removeWhere((value) => value.endsWith(':0'));

    return messages.length + folders.length;
  }

  // TCLOUD_BACKUP_JOURNAL_REPAIR_1049
  // Uma URI so pode continuar marcada como sincronizada quando existe um
  // registro rastreavel e a mensagem correspondente ainda existe no Telegram.
  // O reparo roda uma unica vez e nao apaga nenhuma mensagem/pasta remota.
  Future<void> _repairBackupJournalOnce(
    SharedPreferences prefs,
    Set<String> synced,
    List<Map<String, dynamic>> localRecords,
  ) async {
    const repairKey = 'tcloud_gallery_backup_journal_repair_1064_confirmed';

    if (prefs.getBool(repairKey) ?? false) {
      return;
    }

    final oldRecords = await _loadOldBackupRecords();
    final backgroundRecords = await _td.backgroundBackupRecords();

    final all = <Map<String, dynamic>>[
      ...localRecords,
      ...oldRecords,
      ...backgroundRecords,
    ];

    final byChat = <int, List<Map<String, dynamic>>>{};

    for (final record in all) {
      final chatId = _asInt(record['chatId']);
      final messageId = _asInt(record['messageId']);
      final uri = record['uri']?.toString() ?? '';

      if (chatId == 0 || messageId == 0 || uri.isEmpty) {
        continue;
      }

      byChat.putIfAbsent(chatId, () => <Map<String, dynamic>>[]).add(record);
    }

    final validUris = <String>{};

    for (final entry in byChat.entries) {
      final records = entry.value;

      for (var offset = 0; offset < records.length; offset += 100) {
        final end = (offset + 100).clamp(0, records.length);
        final chunk = records.sublist(offset, end);
        final ids = chunk
            .map((record) => _asInt(record['messageId']))
            .where((id) => id != 0)
            .toList();

        if (ids.isEmpty) {
          continue;
        }

        try {
          final response = await _td.execute('GetMessages', <String, dynamic>{
            'chatId': entry.key,
            'messageIds': ids,
          });

          if (response['_type']?.toString() == 'Error') {
            // Em falha temporaria nao arriscamos duplicar: preserva este lote.
            validUris.addAll(
              chunk
                  .map((record) => record['uri']?.toString() ?? '')
                  .where((uri) => uri.isNotEmpty),
            );
            continue;
          }

          // TCLOUD_BACKUP_JOURNAL_REPAIR_HOTFIX_1049
          final existingIds =
              ((response['messages'] as List?) ?? const <dynamic>[])
                  .whereType<Map>()
                  .where((message) => message['sendingState'] == null)
                  .map((message) => _asInt(message['id']))
                  .where((id) => id != 0)
                  .toSet();

          for (final record in chunk) {
            final messageId = _asInt(record['messageId']);
            final uri = record['uri']?.toString() ?? '';

            if (uri.isNotEmpty && existingIds.contains(messageId)) {
              validUris.add(uri);
            }
          }
        } catch (_) {
          validUris.addAll(
            chunk
                .map((record) => record['uri']?.toString() ?? '')
                .where((uri) => uri.isNotEmpty),
          );
        }
      }
    }

    // Tudo que nao possui mensagem rastreavel volta a ficar elegivel para
    // upload. Isso corrige o caso "pastas criadas, mas 0 arquivos".
    synced
      ..clear()
      ..addAll(validUris);

    final invalidUris = all
        .map((record) => record['uri']?.toString() ?? '')
        .where((uri) => uri.isNotEmpty && !validUris.contains(uri))
        .toSet();

    if (invalidUris.isNotEmpty) {
      localRecords.removeWhere(
        (record) => invalidUris.contains(record['uri']?.toString() ?? ''),
      );
      await _saveBackupRecords(localRecords);
      await _td.forgetBackgroundBackupUris(invalidUris);
    }

    await _saveSyncedUris(prefs, synced);

    // Forca uma nova varredura historica completa da galeria do celular.
    await prefs.remove(_fullBeforeKey);
    await prefs.remove(_fullCompleteKey);
    await prefs.remove(_lastSyncKey);
    await prefs.setBool(repairKey, true);
  }

  Future<GallerySyncResult> syncNow(List<TCloudFolder> folders) async {
    final blockedUntil = await rateLimitUntil();
    if (blockedUntil != null) {
      throw GallerySyncRateLimitException(blockedUntil);
    }
    if (_syncNowRunning) {
      throw StateError('Uma sincronização da galeria já está em andamento.');
    }
    _syncNowRunning = true;
    try {
      return await _syncNowInternal(folders);
    } finally {
      _syncNowRunning = false;
    }
  }

  Future<GallerySyncResult> _syncNowInternal(List<TCloudFolder> folders) async {
    if (folders.isEmpty) {
      return const GallerySyncResult(found: 0, uploaded: 0, failed: 0);
    }

    final permission = await _td.requestMediaPermission();
    if (!permission) {
      throw StateError('Permissao para fotos e videos nao foi concedida.');
    }

    final base = await _resolveTarget(folders);
    final prefs = await SharedPreferences.getInstance();
    final synced = (prefs.getStringList(_syncedUrisKey) ?? <String>[]).toSet();
    final records = await _loadBackupRecords();
    final known = <TCloudFolder>[...folders];

    await _recoverHistoricalMissesOnce(prefs);

    await _repairBackupJournalOnce(prefs, synced, records);

    await _migrateGenericAlbumBackup(
      prefs: prefs,
      synced: synced,
      records: records,
      known: known,
    );

    final galleryRoot = await _ensureGalleryRoot(base, known);

    final retryAll = await _loadRetryQueue(includeFuture: true);
    final now = DateTime.now().millisecondsSinceEpoch;

    final readyRetry = retryAll
        .where((item) => _asInt(item['nextAttemptMs']) <= now)
        .where((item) => !_isGenericAlbumName(item['album']?.toString() ?? ''))
        .toList();

    final futureRetry = retryAll
        .where((item) => _asInt(item['nextAttemptMs']) > now)
        .where((item) => !_isGenericAlbumName(item['album']?.toString() ?? ''))
        .toList();

    final staged = await _td.backgroundGalleryQueue();
    final staleQueuedUris = <String>[];
    final validStaged = <Map<String, dynamic>>[];

    for (final item in staged) {
      final album = _albumName(item);
      final uri = item['uri']?.toString() ?? '';
      final relative = item['relativePath']?.toString().trim() ?? '';

      if (album == 'Outros' && relative.isEmpty) {
        if (uri.isNotEmpty) {
          staleQueuedUris.add(uri);
        }
        continue;
      }

      validStaged.add(item);
    }

    final targets = <String, Future<TCloudFolder>>{};

    Future<TCloudFolder> targetFor(String album) {
      return targets.putIfAbsent(
        album,
        () => _ensureAlbumFolder(galleryRoot, album, known),
      );
    }

    var fullComplete = prefs.getBool(_fullCompleteKey) ?? false;
    final initialBefore = prefs.getInt(_fullBeforeKey) ?? 9223372036854775807;
    var nextBefore = initialBefore;
    var reachedEnd = false;
    final scanned = <Map<String, dynamic>>[];

    if (!fullComplete) {
      for (var pageIndex = 0; pageIndex < _maxPagesPerRun; pageIndex++) {
        final current = await _td.listGalleryMediaBefore(
          beforeMs: nextBefore,
          limit: _pageSize,
        );

        if (current.isEmpty) {
          reachedEnd = true;
          break;
        }

        scanned.addAll(current);

        var oldest = 9223372036854775807;
        for (final item in current) {
          final date = _asInt(item['dateMs']);
          if (date > 0 && date < oldest) {
            oldest = date;
          }
        }

        if (current.length < _pageSize || oldest == 9223372036854775807) {
          reachedEnd = true;
          break;
        }

        nextBefore = oldest;
      }
    } else {
      scanned.addAll(
        await _td.listGalleryMediaBefore(
          beforeMs: 9223372036854775807,
          limit: _pageSize,
        ),
      );
    }

    final merged = <String, Map<String, dynamic>>{};

    void addAll(Iterable<Map<String, dynamic>> values) {
      for (final item in values) {
        final uri = item['uri']?.toString() ?? '';
        if (uri.isEmpty || synced.contains(uri)) {
          continue;
        }
        merged[uri] = <String, dynamic>{...?merged[uri], ...item};
      }
    }

    addAll(readyRetry);
    addAll(validStaged);
    addAll(scanned);

    // TCLOUD_MEDIA_FAST_LANE_1045
    // Itens recem-detectados pela fila nativa/retry entram antes do backlog
    // historico. Dentro de cada classe a ordem cronologica continua preservada.
    final priorityUris = <String>{
      ...readyRetry.map((item) => item['uri']?.toString() ?? ''),
      ...validStaged.map((item) => item['uri']?.toString() ?? ''),
    }..remove('');

    final batch = _interleaveByAlbum(merged.values.toList());
    final hiddenAlbums =
        (await LibraryPreferencesService.instance.hiddenAlbums())
            .map((value) => value.trim().toLowerCase())
            .toSet();
    batch.removeWhere((item) {
      final name = _albumName(item).trim().toLowerCase();
      return hiddenAlbums.contains(name) ||
          hiddenAlbums.contains('galeria / $name');
    });
    await _activityPrepare(batch);
    final nextRetry = <Map<String, dynamic>>[...futureRetry];
    final ack = <String>[...staleQueuedUris];

    var uploaded = 0;
    var failed = 0;
    final found = batch.length;
    // TCLOUD_GALLERY_UPLOAD_ORDER_1024
    // Preserve phone gallery chronology inside this upload page.
    // Oldest -> newest keeps Telegram message order deterministic.
    batch.sort((a, b) {
      final aPriority = priorityUris.contains(a['uri']?.toString() ?? '');
      final bPriority = priorityUris.contains(b['uri']?.toString() ?? '');

      if (aPriority != bPriority) {
        return aPriority ? -1 : 1;
      }

      final da = _asInt(a['dateMs']);
      final db = _asInt(b['dateMs']);

      if (da == db) {
        return (a['uri']?.toString() ?? '').compareTo(
          b['uri']?.toString() ?? '',
        );
      }

      if (da == 0) return 1;
      if (db == 0) return -1;
      return da.compareTo(db);
    });

    var cursor = 0;
    var dirtyUploads = 0;
    Future<void> writeChain = Future<void>.value();

    Future<void> queueFlush() {
      if (dirtyUploads == 0) {
        return writeChain;
      }

      dirtyUploads = 0;
      final recordsSnapshot = records
          .map((item) => <String, dynamic>{...item})
          .toList();
      final syncedSnapshot = <String>{...synced};

      writeChain = writeChain.then((_) async {
        await _saveBackupRecords(recordsSnapshot);
        await _saveSyncedUris(prefs, syncedSnapshot);
      });

      return writeChain;
    }

    DateTime? detectedRateLimit;

    Future<void> worker() async {
      while (true) {
        if (detectedRateLimit != null) return;
        final index = cursor;
        if (index >= batch.length) {
          return;
        }
        cursor++;

        final item = batch[index];
        final uri = item['uri']?.toString() ?? '';
        if (uri.isEmpty) {
          continue;
        }

        final album = _albumName(item);
        String? temp;

        try {
          temp = await _td.copyContentUri(uri);
          if (temp.isEmpty) {
            throw StateError('Falha ao preparar o arquivo.');
          }

          final target = await targetFor(album);
          _activitySet(uri, 'enviando');
          final response = await _repo.uploadTrackedBackup(
            folder: target,
            path: temp,
          );
          final messageId = _asInt(response['id']);

          if (messageId == 0) {
            throw StateError('Upload sem messageId.');
          }

          records.removeWhere((record) => record['uri']?.toString() == uri);
          records.add(<String, dynamic>{
            'uri': uri,
            'chatId': target.chatId,
            'threadId': target.messageThreadId,
            'forumTopicId': target.forumTopicId,
            'messageId': messageId,
            'album': album,
            'dateMs': _asInt(item['dateMs']),
          });

          synced.add(uri);
          uploaded++;
          _activityUploaded = uploaded;
          _activitySet(uri, 'concluido');
          await _td.showGallerySyncProgress(
            total: _activityTotal,
            done: uploaded + failed,
            failed: failed,
            running: true,
          );
          dirtyUploads++;
          ack.add(uri);

          if (dirtyUploads >= _persistEveryUploads) {
            await queueFlush();
          }

          await prefs.remove(_lastErrorKey);
        } catch (error) {
          failed++;
          _activityFailed = failed;
          _activitySet(uri, 'erro');
          await _td.showGallerySyncProgress(
            total: _activityTotal,
            done: uploaded + failed,
            failed: failed,
            running: true,
          );
          final attempts = _asInt(item['attempts']) + 1;
          final limitedUntil = await registerRateLimit(error);
          if (limitedUntil != null) detectedRateLimit = limitedUntil;
          final retry = <String, dynamic>{
            ...item,
            'album': album,
            'attempts': attempts,
            'lastError': error.toString(),
            'nextAttemptMs':
                limitedUntil?.millisecondsSinceEpoch ??
                DateTime.now().millisecondsSinceEpoch + _retryDelayMs(attempts),
          };

          if (attempts <= 20) {
            nextRetry.add(retry);
          }

          await prefs.setString(_lastErrorKey, error.toString());
        } finally {
          if (temp != null && temp.isNotEmpty) {
            try {
              final file = File(temp);
              if (await file.exists()) {
                await file.delete();
              }
            } catch (_) {}
          }
        }
      }
    }

    // TCLOUD_MEDIA_FAST_LANE_WORKERS_1045
    // Dois workers reduzem a espera de imagens/videos sem abrir cinco uploads
    // simultaneos no Telegram. A UI continua ordenando a midia por metadados.
    final workerCount = _maxParallelUploads.clamp(1, 4);
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );

    if (detectedRateLimit != null && cursor < batch.length) {
      final queuedUris = nextRetry
          .map((item) => item['uri']?.toString() ?? '')
          .toSet();
      for (var index = cursor; index < batch.length; index++) {
        final item = batch[index];
        final uri = item['uri']?.toString() ?? '';
        if (uri.isEmpty || synced.contains(uri) || !queuedUris.add(uri)) {
          continue;
        }
        nextRetry.add(<String, dynamic>{
          ...item,
          'nextAttemptMs': detectedRateLimit!.millisecondsSinceEpoch,
          'lastError': 'Aguardando o limite temporário do Telegram.',
        });
      }
    }

    await queueFlush();
    await writeChain;
    await _saveRetryQueue(nextRetry);

    _activityRunning = false;
    _activityUploaded = uploaded;
    _activityFailed = failed;

    await _td.showGallerySyncProgress(
      total: _activityTotal,
      done: uploaded + failed,
      failed: failed,
      running: false,
    );

    if (ack.isNotEmpty) {
      await _td.acknowledgeBackgroundGalleryQueue(ack.toSet().toList());
    }

    if (!fullComplete) {
      if (reachedEnd) {
        fullComplete = true;
        await prefs.setBool(_fullCompleteKey, true);
        await prefs.remove(_fullBeforeKey);
      } else {
        await prefs.setInt(_fullBeforeKey, nextBefore);
      }
    }

    final nativeTargets = <String, int>{};
    for (final entry in targets.entries) {
      try {
        final folder = await entry.value;
        final routeId = folder.forumTopicId != 0
            ? folder.forumTopicId
            : folder.messageThreadId;
        if (routeId != 0) {
          nativeTargets[entry.key] = routeId;
        }
      } catch (_) {}
    }

    if (nativeTargets.isNotEmpty) {
      await _td.setBackgroundGalleryAlbumTargets(nativeTargets);
    }

    await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);

    await enforceSmartStorage();

    if (detectedRateLimit != null) {
      throw GallerySyncRateLimitException(detectedRateLimit!);
    }

    return GallerySyncResult(
      found: found,
      uploaded: uploaded,
      failed: failed,
      pending: nextRetry.length,
    );
  }

  Future<int> undoBackup() async {
    await setEnabled(false);

    final local = await _loadBackupRecords();

    final old = await _loadOldBackupRecords();

    final background = await _td.backgroundBackupRecords();

    final all = <Map<String, dynamic>>[...local, ...old, ...background];

    final byChat = <int, Set<int>>{};

    for (final item in all) {
      final chatId = _asInt(item['chatId']);

      final messageId = _asInt(item['messageId']);

      if (chatId == 0 || messageId == 0) {
        continue;
      }

      byChat.putIfAbsent(chatId, () => <int>{}).add(messageId);
    }

    var removedMessages = 0;

    for (final entry in byChat.entries) {
      final ids = entry.value.toList();

      if (ids.isEmpty) continue;

      final response = await _td.execute('DeleteMessages', <String, dynamic>{
        'chatId': entry.key,
        'messageIds': ids,
        'revoke': true,
      });

      if (response['_type']?.toString() == 'Error') {
        throw StateError(
          response['message']?.toString() ?? 'Falha ao remover backup.',
        );
      }

      removedMessages += ids.length;
    }

    final staged = await _td.backgroundGalleryQueue();

    final stagedUris = staged
        .map((item) => item['uri']?.toString() ?? '')
        .where((uri) => uri.isNotEmpty)
        .toList();

    if (stagedUris.isNotEmpty) {
      await _td.acknowledgeBackgroundGalleryQueue(stagedUris);
    }

    final created = await _loadCreatedFolders();

    final discoveredForUndo = await _repo.discoverFolders();

    for (final folder in discoveredForUndo) {
      final title = folder.title.trim();

      final isGalleryRoot = title.toLowerCase() == 'galeria';

      final isGalleryChild = title.toLowerCase().startsWith('galeria / ');

      if ((!isGalleryRoot && !isGalleryChild) ||
          folder.isGeneral ||
          folder.forumTopicId == 0) {
        continue;
      }

      final alreadyTracked = created.any(
        (item) =>
            _asInt(item['chatId']) == folder.chatId &&
            _asInt(item['forumTopicId']) == folder.forumTopicId,
      );

      if (!alreadyTracked) {
        created.add(<String, dynamic>{
          'chatId': folder.chatId,

          'forumTopicId': folder.forumTopicId,

          'title': folder.title,

          'forumTitle': folder.forumTitle,

          'adopted': true,
        });
      }
    }
    final remainingFolders = <Map<String, dynamic>>[];

    var removedFolders = 0;

    for (final item in created) {
      final chatId = _asInt(item['chatId']);

      final forumTopicId = _asInt(item['forumTopicId']);

      if (chatId == 0 || forumTopicId == 0) {
        continue;
      }

      try {
        final empty = await _topicIsEmpty(chatId, forumTopicId);

        if (!empty) {
          // Conteudo que nao pertence ao
          // backup existe; nao apaga pasta.
          remainingFolders.add(item);
          continue;
        }

        await _repo.deleteFolder(
          TCloudFolder(
            chatId: chatId,
            title: item['title']?.toString() ?? 'Album',
            forumTitle: item['forumTitle']?.toString() ?? '',
            forumTopicId: forumTopicId,
          ),
        );

        removedFolders++;
      } catch (error) {
        remainingFolders.add(item);

        final prefs = await SharedPreferences.getInstance();

        await prefs.setString(_lastErrorKey, error.toString());
      }
    }

    final prefs = await SharedPreferences.getInstance();

    await prefs.remove(_backupRecordsKey);

    await prefs.remove(_oldBackupRecordsKey);

    await prefs.remove(_syncedUrisKey);

    await prefs.remove(_retryQueueKey);

    await prefs.remove(_lastSyncKey);

    await prefs.remove(_fullBeforeKey);

    await prefs.remove(_fullCompleteKey);

    if (remainingFolders.isEmpty) {
      await prefs.remove(_createdFoldersKey);
    } else {
      await _saveCreatedFolders(remainingFolders);
    }

    await _td.clearBackgroundBackupRecords();

    await clearCacheNow();

    return removedMessages + removedFolders;
  }

  List<Map<String, dynamic>> _interleaveByAlbum(
    List<Map<String, dynamic>> input,
  ) {
    final groups = <String, List<Map<String, dynamic>>>{};

    for (final item in input) {
      final album = _albumName(item);
      groups.putIfAbsent(album, () => <Map<String, dynamic>>[]).add(item);
    }

    for (final values in groups.values) {
      values.sort((a, b) {
        final aSize = _asInt(a['size']);
        final bSize = _asInt(b['size']);

        if (aSize != bSize) {
          return aSize.compareTo(bSize);
        }

        return _asInt(b['dateMs']).compareTo(_asInt(a['dateMs']));
      });
    }

    final albums = groups.keys.toList()
      ..sort((a, b) {
        if (a == 'Outros' && b != 'Outros') {
          return 1;
        }
        if (b == 'Outros' && a != 'Outros') {
          return -1;
        }
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final offsets = <String, int>{for (final album in albums) album: 0};
    final result = <Map<String, dynamic>>[];

    while (true) {
      var added = false;
      for (final album in albums) {
        final values = groups[album]!;
        final index = offsets[album] ?? 0;
        if (index >= values.length) {
          continue;
        }
        result.add(values[index]);
        offsets[album] = index + 1;
        added = true;
      }
      if (!added) {
        break;
      }
    }

    return result;
  }

  Future<void> _migrateGenericAlbumBackup({
    required SharedPreferences prefs,
    required Set<String> synced,
    required List<Map<String, dynamic>> records,
    required List<TCloudFolder> known,
  }) async {
    if (prefs.getBool(_albumRoutingV6Key) ?? false) {
      return;
    }

    final wrong = records
        .where(
          (record) => _isGenericAlbumName(record['album']?.toString() ?? ''),
        )
        .toList();

    final removed = <Map<String, dynamic>>[];
    final byChat = <int, List<Map<String, dynamic>>>{};

    for (final record in wrong) {
      final chatId = _asInt(record['chatId']);
      final messageId = _asInt(record['messageId']);

      if (chatId == 0 || messageId == 0) {
        removed.add(record);
        continue;
      }

      byChat.putIfAbsent(chatId, () => <Map<String, dynamic>>[]).add(record);
    }

    var failed = false;

    for (final entry in byChat.entries) {
      final ids = entry.value
          .map((record) => _asInt(record['messageId']))
          .where((id) => id != 0)
          .toList();

      try {
        final response = await _td.execute('DeleteMessages', <String, dynamic>{
          'chatId': entry.key,
          'messageIds': ids,
          'revoke': true,
        });

        if (response['_type']?.toString() == 'Error') {
          failed = true;
          continue;
        }

        removed.addAll(entry.value);
      } catch (_) {
        failed = true;
      }
    }

    if (removed.isNotEmpty) {
      final uris = removed
          .map((record) => record['uri']?.toString() ?? '')
          .where((uri) => uri.isNotEmpty)
          .toSet();

      records.removeWhere(removed.contains);
      synced.removeAll(uris);

      await _saveBackupRecords(records);
      await _saveSyncedUris(prefs, synced);
      await prefs.remove(_fullBeforeKey);
      await prefs.remove(_fullCompleteKey);
      await prefs.remove(_lastSyncKey);
    }

    if (!failed) {
      for (final folder in List<TCloudFolder>.from(known)) {
        final title = folder.title.trim().toLowerCase();
        if (title != 'galeria / outros' && title != 'outros') {
          continue;
        }
        if (folder.forumTopicId == 0) {
          continue;
        }

        try {
          final empty = await _topicIsEmpty(folder.chatId, folder.forumTopicId);
          if (empty) {
            await _repo.deleteFolder(folder);
            known.remove(folder);
          }
        } catch (_) {}
      }

      await prefs.setBool(_albumRoutingV6Key, true);
    }
  }

  Future<TCloudFolder> _ensureGalleryRoot(
    TCloudFolder base,
    List<TCloudFolder> known,
  ) async {
    for (final folder in known) {
      if (folder.chatId != base.chatId) {
        continue;
      }
      if (folder.title.trim().toLowerCase() != 'galeria') {
        continue;
      }
      if (folder.forumTopicId != 0 || folder.messageThreadId != 0) {
        await _rememberCreatedFolder(folder, adopted: true);
        return folder;
      }
    }

    final created = await _repo.createFolderAndReturn(
      chatId: base.chatId,
      forumTitle: base.forumTitle,
      name: 'Galeria',
    );

    if (created.forumTopicId == 0 && created.messageThreadId == 0) {
      throw StateError(
        'A pasta Galeria foi criada sem identificador utilizavel.',
      );
    }

    known.add(created);
    await _rememberCreatedFolder(created, adopted: false);
    return created;
  }

  Future<TCloudFolder> _ensureAlbumFolder(
    TCloudFolder galleryRoot,
    String album,
    List<TCloudFolder> known,
  ) async {
    final cleanAlbum = _albumName(<String, dynamic>{'album': album});

    final childTitle = 'Galeria / $cleanAlbum';
    TCloudFolder? legacy;

    for (final folder in known) {
      if (folder.chatId != galleryRoot.chatId) {
        continue;
      }

      final title = folder.title.trim();

      if (title.toLowerCase() == childTitle.toLowerCase()) {
        return folder;
      }

      if (title.toLowerCase() == cleanAlbum.toLowerCase() &&
          !folder.isGeneral) {
        legacy ??= folder;
      }
    }

    if (legacy != null && legacy.forumTopicId != 0) {
      try {
        await _repo.renameFolder(legacy, childTitle);

        final renamed = TCloudFolder(
          chatId: legacy.chatId,
          title: childTitle,
          forumTitle: legacy.forumTitle,
          forumTopicId: legacy.forumTopicId,
          messageThreadId: legacy.messageThreadId,
          historyMessageId: legacy.historyMessageId,
          isGeneral: legacy.isGeneral,
        );

        final index = known.indexOf(legacy);
        if (index >= 0) {
          known[index] = renamed;
        }

        await _rememberCreatedFolder(renamed, adopted: true);

        return renamed;
      } catch (_) {}
    }

    final created = await _repo.createFolderAndReturn(
      chatId: galleryRoot.chatId,
      forumTitle: galleryRoot.forumTitle,
      name: childTitle,
    );

    if (created.forumTopicId == 0 && created.messageThreadId == 0) {
      throw StateError(
        'O album "$cleanAlbum" foi criado sem identificador utilizavel.',
      );
    }

    known.add(created);
    await _rememberCreatedFolder(created, adopted: false);
    return created;
  }

  Future<bool> _topicIsEmpty(int chatId, int forumTopicId) async {
    try {
      final response = await _td
          .execute('GetForumTopicHistory', <String, dynamic>{
            'chatId': chatId,
            'forumTopicId': forumTopicId,
            'fromMessageId': 0,
            'offset': 0,
            'limit': 1,
          });

      if (response['_type']?.toString() == 'Error') {
        return false;
      }

      final messages = response['messages'];

      return messages is List && messages.isEmpty;
    } catch (_) {
      return false;
    }
  }

  bool _isGenericAlbumName(String value) {
    final normalized = value.trim().toLowerCase();

    return const <String>{
      '',
      'outros',
      'other',
      'others',
      'galeria',
      'gallery',
      'pictures',
      'picture',
      'images',
      'image',
      'media',
      'android',
      'dcim',
      'download',
      'downloads',
      'movies',
      'videos',
      'video',
    }.contains(normalized);
  }

  String _cleanAlbumSegment(String value) {
    var result = value.replaceAll('\\', '/').trim();

    if (result.isEmpty) {
      return '';
    }

    result = result
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (result.length > 80) {
      result = result.substring(0, 80);
    }

    return result;
  }

  String _albumFromRelativePath(String value) {
    final parts = value
        .replaceAll('\\', '/')
        .split('/')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && !part.startsWith('.'))
        .toList();

    for (final raw in parts.reversed) {
      final part = _cleanAlbumSegment(raw);

      if (part.isEmpty || _isGenericAlbumName(part)) {
        continue;
      }

      final packageLike = RegExp(
        r'^[a-z0-9_]+(?:\.[a-z0-9_]+){1,}$',
        caseSensitive: false,
      ).hasMatch(part);

      if (packageLike) {
        continue;
      }

      return part;
    }

    return '';
  }

  String _albumName(Map<String, dynamic> item) {
    final relative = _albumFromRelativePath(
      item['relativePath']?.toString() ?? '',
    );

    if (relative.isNotEmpty) {
      return relative;
    }

    final album = _cleanAlbumSegment(item['album']?.toString() ?? '');

    if (!_isGenericAlbumName(album)) {
      return album;
    }

    final bucket = _cleanAlbumSegment(item['bucketName']?.toString() ?? '');

    if (!_isGenericAlbumName(bucket)) {
      return bucket;
    }

    return 'Outros';
  }

  Future<TCloudFolder> _resolveTarget(List<TCloudFolder> folders) async {
    final key = await targetFolderKey();

    if (key != null) {
      for (final folder in folders) {
        for (final source in _repo.sourcesForFolder(folder)) {
          if (source.cacheKey == key) {
            return source;
          }
        }
      }
    }

    for (final folder in folders) {
      if (folder.isGeneral) {
        return folder;
      }
    }

    return folders.first;
  }

  Future<int> lastSyncMs() async {
    final prefs = await SharedPreferences.getInstance();

    return prefs.getInt(_lastSyncKey) ?? 0;
  }

  // TCLOUD_HISTORICAL_RECOVERY_1054
  // Recupera fotos/videos que falharam em versoes anteriores e sairam da
  // fila antes de serem confirmados. Nao limpa _syncedUrisKey: arquivos que
  // ja tiveram sucesso continuam protegidos contra duplicacao.
  Future<void> _recoverHistoricalMissesOnce(SharedPreferences prefs) async {
    if (prefs.getBool(_historicalRecovery1054Key) ?? false) {
      return;
    }

    // Faz a proxima sincronizacao percorrer novamente toda a galeria.
    // O filtro synced.contains(uri) continua eliminando itens confirmados.
    await prefs.remove(_fullBeforeKey);
    await prefs.remove(_fullCompleteKey);
    await prefs.remove(_lastSyncKey);

    await prefs.setBool(_historicalRecovery1054Key, true);
  }

  Future<void> _saveSyncedUris(
    SharedPreferences prefs,
    Set<String> values,
  ) async {
    final list = values.toList();

    if (list.length > 20000) {
      list.removeRange(0, list.length - 20000);
    }

    await prefs.setStringList(_syncedUrisKey, list);
  }

  Future<List<Map<String, dynamic>>> _loadRetryQueue({
    bool includeFuture = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_retryQueueKey);

    if (raw == null || raw.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is! List) {
        return <Map<String, dynamic>>[];
      }

      final values = decoded
          .whereType<Map>()
          .map(
            (item) => item.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList();

      if (includeFuture) {
        return values;
      }

      final now = DateTime.now().millisecondsSinceEpoch;

      return values
          .where((item) => _asInt(item['nextAttemptMs']) <= now)
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _saveRetryQueue(List<Map<String, dynamic>> values) async {
    final prefs = await SharedPreferences.getInstance();

    final unique = <String, Map<String, dynamic>>{};

    for (final item in values) {
      final uri = item['uri']?.toString() ?? '';

      if (uri.isEmpty) continue;

      unique[uri] = item;
    }

    final list = unique.values.toList();

    final bounded = list.length <= 3000
        ? list
        : list.sublist(list.length - 3000);

    await prefs.setString(_retryQueueKey, jsonEncode(bounded));
  }

  Future<List<Map<String, dynamic>>> _loadBackupRecords() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_backupRecordsKey);

    return _decodeList(raw);
  }

  Future<List<Map<String, dynamic>>> _loadOldBackupRecords() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_oldBackupRecordsKey);

    return _decodeList(raw);
  }

  Future<void> _saveBackupRecords(List<Map<String, dynamic>> values) async {
    final prefs = await SharedPreferences.getInstance();

    final unique = <String, Map<String, dynamic>>{};

    for (final item in values) {
      final chatId = _asInt(item['chatId']);

      final messageId = _asInt(item['messageId']);

      if (chatId == 0 || messageId == 0) {
        continue;
      }

      unique['$chatId:$messageId'] = item;
    }

    final list = unique.values.toList();

    final bounded = list.length <= 20000
        ? list
        : list.sublist(list.length - 20000);

    await prefs.setString(_backupRecordsKey, jsonEncode(bounded));
  }

  Future<List<Map<String, dynamic>>> _loadCreatedFolders() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_createdFoldersKey);

    return _decodeList(raw);
  }

  Future<void> _saveCreatedFolders(List<Map<String, dynamic>> values) async {
    final prefs = await SharedPreferences.getInstance();

    final unique = <String, Map<String, dynamic>>{};

    for (final item in values) {
      final chatId = _asInt(item['chatId']);

      final forumTopicId = _asInt(item['forumTopicId']);

      if (chatId == 0 || forumTopicId == 0) {
        continue;
      }

      unique['$chatId:$forumTopicId'] = item;
    }

    await prefs.setString(
      _createdFoldersKey,
      jsonEncode(unique.values.toList()),
    );
  }

  Future<void> _rememberCreatedFolder(
    TCloudFolder folder, {
    required bool adopted,
  }) async {
    if (folder.isGeneral || folder.forumTopicId == 0) {
      return;
    }

    final values = await _loadCreatedFolders();

    values.removeWhere(
      (item) =>
          _asInt(item['chatId']) == folder.chatId &&
          _asInt(item['forumTopicId']) == folder.forumTopicId,
    );

    values.add(<String, dynamic>{
      'chatId': folder.chatId,
      'forumTopicId': folder.forumTopicId,
      'title': folder.title,
      'forumTitle': folder.forumTitle,
      'adopted': adopted,
    });

    await _saveCreatedFolders(values);
  }

  List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is! List) {
        return <Map<String, dynamic>>[];
      }

      return decoded
          .whereType<Map>()
          .map(
            (item) => item.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  int _retryDelayMs(int attempts) {
    final exponent = attempts.clamp(1, 8);

    final minutes = 1 << (exponent - 1);

    return Duration(minutes: minutes.clamp(1, 240)).inMilliseconds;
  }

  int _asInt(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

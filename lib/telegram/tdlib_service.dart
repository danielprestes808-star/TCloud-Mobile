import 'dart:async';

import 'package:flutter/services.dart';

import 'telegram_config.dart';

enum TdlibAuthorizationStage {
  uninitialized,
  initializing,
  phone,
  code,
  password,
  emailAddress,
  emailCode,
  registration,
  otherDevice,
  ready,
  loggingOut,
  closing,
  closed,
  authorization,
}

class TdlibEvent {
  const TdlibEvent({required this.type, this.stage, this.message});

  final String type;
  final TdlibAuthorizationStage? stage;
  final String? message;

  bool get isError => type == 'error';
}

class TdlibService {
  TdlibService._();

  static final TdlibService instance = TdlibService._();

  static const MethodChannel _methods = MethodChannel(
    'com.tcloud.mobile/tdlib',
  );

  static const EventChannel _events = EventChannel(
    'com.tcloud.mobile/tdlib_events',
  );

  Stream<TdlibEvent>? _eventStream;

  Stream<TdlibEvent> get events {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map<TdlibEvent>(_decodeEvent)
        .asBroadcastStream();
  }

  Future<void> initialize() async {
    if (!TelegramConfig.isConfigured) {
      throw StateError(
        'TCLOUD_TELEGRAM_API_ID e '
        'TCLOUD_TELEGRAM_API_HASH não configurados.',
      );
    }

    await _methods.invokeMethod<bool>('initialize', <String, Object>{
      'apiId': TelegramConfig.apiId,
      'apiHash': TelegramConfig.apiHash,
    });
  }

  Future<void> submitPhone(String phone) async {
    await _methods.invokeMethod<bool>('submitPhone', <String, Object>{
      'phone': phone,
    });
  }

  Future<void> submitCode(String code) async {
    await _methods.invokeMethod<bool>('submitCode', <String, Object>{
      'code': code,
    });
  }

  Future<void> submitPassword(String password) async {
    await _methods.invokeMethod<bool>('submitPassword', <String, Object>{
      'password': password,
    });
  }

  Future<void> logout() async {
    await _methods.invokeMethod<bool>('logout');
  }

  Future<void> switchAccount(String accountId) async {
    await _methods.invokeMethod<bool>('switchAccount', <String, dynamic>{
      'accountId': accountId,
    });
  }

  Future<List<String>> pickFiles() async {
    final raw = await _methods.invokeMethod<List<dynamic>>('pickFiles');

    if (raw == null) {
      return <String>[];
    }

    return raw
        .map((item) => item.toString())
        .where((path) => path.trim().isNotEmpty)
        .toList();
  }

  Future<int> sendDocument({
    required int chatId,
    required int forumTopicId,
    required int messageThreadId,
    required String path,
  }) async {
    final value = await _methods
        .invokeMethod<num>('sendDocument', <String, dynamic>{
          'chatId': chatId,
          'forumTopicId': forumTopicId,
          'messageThreadId': messageThreadId,
          'path': path,
        });

    return value?.toInt() ?? 0;
  }

  Future<String> getState() async {
    return await _methods.invokeMethod<String>('getState') ?? 'uninitialized';
  }

  Future<void> setBackgroundGalleryTarget({
    required int chatId,
    required int messageThreadId,
  }) async {
    await _methods.invokeMethod<bool>(
      'setBackgroundGalleryTarget',
      <String, dynamic>{'chatId': chatId, 'messageThreadId': messageThreadId},
    );
  }

  Future<void> configureBackgroundGalleryOptions({
    required bool wifiOnly,
    required bool requiresCharging,
  }) async {
    await _methods.invokeMethod<bool>(
      'configureBackgroundGalleryOptions',
      <String, dynamic>{
        'wifiOnly': wifiOnly,
        'requiresCharging': requiresCharging,
      },
    );
  }

  Future<void> setBackgroundHiddenAlbums(Iterable<String> albums) async {
    await _methods.invokeMethod<bool>(
      'setBackgroundHiddenAlbums',
      <String, dynamic>{'albums': albums.toList()},
    );
  }

  Future<void> requestBackupNotifications() async {
    await _methods.invokeMethod<bool>('requestBackupNotifications');
  }

  Future<Map<String, dynamic>> backgroundBackupStatus() async {
    final raw = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'getBackgroundBackupStatus',
    );
    return raw?.map((key, value) => MapEntry(key.toString(), value)) ??
        const <String, dynamic>{};
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    await _methods.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
  }

  Future<void> scheduleBackgroundGallerySync(bool enabled) async {
    await _methods.invokeMethod<bool>(
      'scheduleBackgroundGallerySync',
      <String, dynamic>{'enabled': enabled},
    );
  }

  Future<List<Map<String, dynamic>>> backgroundGalleryQueue() async {
    final raw =
        await _methods.invokeMethod<List<dynamic>>(
          'getBackgroundGalleryQueue',
        ) ??
        const <dynamic>[];

    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  Future<void> acknowledgeBackgroundGalleryQueue(Iterable<String> uris) async {
    await _methods.invokeMethod<bool>(
      'ackBackgroundGalleryQueue',
      <String, dynamic>{'uris': uris.toList()},
    );
  }

  Future<void> setBackgroundGalleryAlbumTargets(
    Map<String, int> targets,
  ) async {
    await _methods.invokeMethod<bool>(
      'setBackgroundGalleryAlbumTargets',
      <String, dynamic>{'targets': targets},
    );
  }

  Future<List<Map<String, dynamic>>> backgroundBackupRecords() async {
    final raw =
        await _methods.invokeMethod<List<dynamic>>(
          'getBackgroundBackupRecords',
        ) ??
        const <dynamic>[];
    return raw
        .whereType<Map>()
        .map((v) => v.map((k, x) => MapEntry(k.toString(), x)))
        .toList();
  }

  Future<void> clearBackgroundBackupRecords() async {
    await _methods.invokeMethod<bool>('clearBackgroundBackupRecords');
  }

  Future<void> forgetBackgroundBackupUris(Iterable<String> uris) async {
    final values = uris.where((uri) => uri.trim().isNotEmpty).toSet().toList();
    if (values.isEmpty) return;
    await _methods.invokeMethod<bool>(
      'forgetBackgroundBackupUris',
      <String, dynamic>{'uris': values},
    );
  }

  Future<Map<String, dynamic>> tcloudCacheInfo() async {
    final raw =
        await _methods.invokeMethod<Map<dynamic, dynamic>>(
          'getTCloudCacheInfo',
        ) ??
        const <dynamic, dynamic>{};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<Map<String, dynamic>> clearTCloudTemporaryCache() async {
    final raw =
        await _methods.invokeMethod<Map<dynamic, dynamic>>(
          'clearTCloudTemporaryCache',
        ) ??
        const <dynamic, dynamic>{};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<String?> generateVideoThumbnail(String path) async {
    final result = await _methods.invokeMethod<String>(
      'generateVideoThumbnail',
      <String, dynamic>{'path': path},
    );

    final clean = result?.trim();

    if (clean == null || clean.isEmpty) {
      return null;
    }

    return clean;
  }

  Future<String?> generateVideoFrameForAnalysis(
    String path, {
    required int timeMs,
  }) async {
    final result = await _methods.invokeMethod<String>(
      'generateVideoThumbnail',
      <String, dynamic>{
        'path': path,
        'timeMs': timeMs,
        'forFaceAnalysis': true,
      },
    );
    final clean = result?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

  Future<bool> requestMediaPermission() async {
    return await _methods.invokeMethod<bool>('requestMediaPermission') ?? false;
  }

  // TCLOUD_GALLERY_NOTIFICATION_PROGRESS_1052
  Future<void> showGallerySyncProgress({
    required int total,
    required int done,
    required int failed,
    required bool running,
  }) async {
    await _methods.invokeMethod<bool>(
      'showGallerySyncProgress',
      <String, dynamic>{
        'total': total,
        'done': done,
        'failed': failed,
        'running': running,
      },
    );
  }

  Future<List<Map<String, dynamic>>> listGalleryMedia({
    required int sinceMs,
    int limit = 500,
  }) async {
    final raw =
        await _methods.invokeMethod<List<dynamic>>(
          'listGalleryMedia',
          <String, dynamic>{'sinceMs': sinceMs, 'limit': limit},
        ) ??
        const <dynamic>[];

    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  Future<List<Map<String, dynamic>>> listGalleryMediaBefore({
    required int beforeMs,
    int limit = 80,
  }) async {
    final raw =
        await _methods.invokeMethod<List<dynamic>>(
          'listGalleryMediaBefore',
          <String, dynamic>{'beforeMs': beforeMs, 'limit': limit},
        ) ??
        const <dynamic>[];

    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  Future<String> copyContentUri(String uri) async {
    return await _methods.invokeMethod<String>(
          'copyContentUri',
          <String, dynamic>{'uri': uri},
        ) ??
        '';
  }

  Future<List<String>> takePendingSharedFiles() async {
    final raw =
        await _methods.invokeMethod<List<dynamic>>('getPendingSharedFiles') ??
        const <dynamic>[];

    return raw
        .map((item) => item?.toString() ?? '')
        .where((path) => path.isNotEmpty)
        .toList();
  }

  Future<String> prepareVideoStream({
    required int fileId,
    required int size,
    String? mimeType,
  }) async {
    final url = await _methods.invokeMethod<String>(
      'prepareVideoStream',
      <String, dynamic>{
        'fileId': fileId,
        'size': size,
        'mimeType': mimeType ?? 'video/mp4',
      },
    );

    if (url == null || url.trim().isEmpty) {
      throw StateError('Nao foi possivel preparar o streaming do video.');
    }

    return url;
  }

  Future<String> prepareCastStream({
    required int fileId,
    required int size,
    String? mimeType,
  }) async {
    final url = await _methods.invokeMethod<String>(
      'prepareCastStream',
      <String, dynamic>{
        'fileId': fileId,
        'size': size,
        'mimeType': mimeType ?? 'video/mp4',
      },
    );
    if (url == null || url.isEmpty) {
      throw StateError('Nao foi possivel preparar a transmissao.');
    }
    return url;
  }

  Future<void> shareFile(String path, {String? mimeType}) async {
    await _methods.invokeMethod<bool>('shareFile', <String, dynamic>{
      'path': path,
      'mimeType': mimeType ?? '*/*',
    });
  }

  Future<void> shareFiles(List<String> paths, {String? mimeType}) async {
    if (paths.isEmpty) return;
    if (paths.length == 1) {
      await shareFile(paths.first, mimeType: mimeType);
      return;
    }
    await _methods.invokeMethod<bool>('shareFiles', <String, dynamic>{
      'paths': paths,
      'mimeType': mimeType ?? '*/*',
    });
  }

  Future<bool> enterPictureInPicture({int width = 16, int height = 9}) async {
    return await _methods.invokeMethod<bool>(
          'enterPictureInPicture',
          <String, dynamic>{'width': width, 'height': height},
        ) ??
        false;
  }

  Future<void> setSecureScreen(bool enabled) async {
    await _methods.invokeMethod<bool>('setSecureScreen', <String, dynamic>{
      'enabled': enabled,
    });
  }

  Future<void> setDocumentProviderEnabled(bool enabled) async {
    await _methods.invokeMethod<bool>(
      'setDocumentProviderEnabled',
      <String, dynamic>{'enabled': enabled},
    );
  }

  Future<bool> openDocumentProvider() async {
    return await _methods.invokeMethod<bool>('openDocumentProvider') ?? false;
  }

  Future<Map<String, dynamic>> execute(
    String function, [
    Map<String, dynamic> fields = const {},
  ]) async {
    final raw = await _methods.invokeMethod<dynamic>(
      'execute',
      <String, dynamic>{'function': function, 'fields': fields},
    );

    return _map(raw);
  }

  Map<String, dynamic> _map(dynamic raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), _value(value)));
    }

    return <String, dynamic>{};
  }

  dynamic _value(dynamic value) {
    if (value is Map) {
      return _map(value);
    }

    if (value is List) {
      return value.map(_value).toList();
    }

    return value;
  }

  TdlibEvent _decodeEvent(dynamic raw) {
    if (raw is! Map) {
      return const TdlibEvent(type: 'error', message: 'Evento TDLib inválido.');
    }

    final type = raw['type']?.toString() ?? 'unknown';

    if (type == 'error') {
      return TdlibEvent(type: 'error', message: raw['message']?.toString());
    }

    final state = raw['state']?.toString() ?? 'authorization';

    return TdlibEvent(type: 'state', stage: _stageFromString(state));
  }

  TdlibAuthorizationStage _stageFromString(String value) {
    switch (value) {
      case 'initializing':
        return TdlibAuthorizationStage.initializing;
      case 'phone':
        return TdlibAuthorizationStage.phone;
      case 'code':
        return TdlibAuthorizationStage.code;
      case 'password':
        return TdlibAuthorizationStage.password;
      case 'email_address':
        return TdlibAuthorizationStage.emailAddress;
      case 'email_code':
        return TdlibAuthorizationStage.emailCode;
      case 'registration':
        return TdlibAuthorizationStage.registration;
      case 'other_device':
        return TdlibAuthorizationStage.otherDevice;
      case 'ready':
        return TdlibAuthorizationStage.ready;
      case 'logging_out':
        return TdlibAuthorizationStage.loggingOut;
      case 'closing':
        return TdlibAuthorizationStage.closing;
      case 'closed':
        return TdlibAuthorizationStage.closed;
      case 'authorization':
        return TdlibAuthorizationStage.authorization;
      default:
        return TdlibAuthorizationStage.uninitialized;
    }
  }
}

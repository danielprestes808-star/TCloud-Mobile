import 'dart:async';

import '../models/tcloud_file.dart';
import '../telegram/tdlib_service.dart';
import 'tcloud_repository.dart';

class MediaCachePolicy {
  MediaCachePolicy._();

  static final instance = MediaCachePolicy._();

  static const int maxBytes = 2 * 1024 * 1024 * 1024;
  static const int videoHeadBytes = 2 * 1024 * 1024;

  final _td = TdlibService.instance;
  final _repo = TCloudRepository.instance;

  DateTime? _lastOptimize;

  Future<void> optimize({bool force = false}) async {
    final now = DateTime.now();

    if (!force &&
        _lastOptimize != null &&
        now.difference(_lastOptimize!) < const Duration(minutes: 30)) {
      return;
    }

    _lastOptimize = now;

    try {
      await _td.execute('OptimizeStorage', <String, dynamic>{
        'size': maxBytes,
        'ttl': 30 * 24 * 60 * 60,
        'count': 0,
        'immunityDelay': 10 * 60,
        'fileTypes': <dynamic>[],
        'chatIds': <int>[],
        'excludeChatIds': <int>[],
        'returnDeletedFileStatistics': false,
        'chatLimit': 0,
      });
    } catch (_) {
      // Prefetch still works even if an older bridge cannot expose OptimizeStorage.
    }
  }

  Future<void> warm(TCloudFile file) async {
    try {
      final current = await _repo.resolveCurrentMedia(file);

      if (current.thumbnailFileId > 0) {
        unawaited(
          _td.execute('DownloadFile', <String, dynamic>{
            'fileId': current.thumbnailFileId,
            'priority': 6,
            'offset': 0,
            'limit': 0,
            'synchronous': false,
          }),
        );
      }

      if (current.fileId <= 0) return;

      if (current.isVideo) {
        unawaited(
          _td.execute('DownloadFile', <String, dynamic>{
            'fileId': current.fileId,
            'priority': 4,
            'offset': 0,
            'limit': videoHeadBytes,
            'synchronous': false,
          }),
        );
      } else if (current.isImage &&
          current.size > 0 &&
          current.size <= 16 * 1024 * 1024) {
        unawaited(
          _td.execute('DownloadFile', <String, dynamic>{
            'fileId': current.fileId,
            'priority': 3,
            'offset': 0,
            'limit': 0,
            'synchronous': false,
          }),
        );
      }
    } catch (_) {}
  }
}

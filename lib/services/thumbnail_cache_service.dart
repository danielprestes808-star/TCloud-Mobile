import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/tcloud_file.dart';
import '../telegram/tdlib_service.dart';
import 'tcloud_repository.dart';

class ThumbnailCacheService {
  ThumbnailCacheService._();

  static final instance = ThumbnailCacheService._();

  // v3 invalida automaticamente os caminhos antigos que podiam
  // ser associados a cards de outros albuns.
  static const _diskKey = 'tcloud_thumbnail_paths_v7_stable_message';

  final _repo = TCloudRepository.instance;
  final _td = TdlibService.instance;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();

  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};
  final Queue<Completer<void>> _downloadQueue = Queue<Completer<void>>();
  int _activeDownloads = 0;
  static const _maximumConcurrentDownloads = 4;

  Map<String, String>? _diskPaths;
  Timer? _persistTimer;
  bool _diskDirty = false;

  String _previewKey(TCloudFile file) => file.stableIdentity;

  Uint8List? instantPreview(TCloudFile file) {
    final key = _previewKey(file);
    final existing = _memory.remove(key);
    if (existing != null) {
      _memory[key] = existing;
      return existing;
    }
    final raw = file.minithumbnailBase64;
    if (raw == null || raw.isEmpty) return null;
    try {
      final bytes = base64Decode(raw);
      _memory[key] = bytes;
      while (_memory.length > 180) {
        _memory.remove(_memory.keys.first);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<String?> fullPreviewPath(TCloudFile file) {
    final key = _previewKey(file);
    final running = _inFlight[key];
    if (running != null) return running;
    final future = _resolveFullPath(file, key);
    _inFlight[key] = future;
    future.whenComplete(() {
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    });
    return future;
  }

  Future<String?> _resolveFullPath(TCloudFile file, String key) async {
    await _loadDiskPaths();
    final cached = _diskPaths?[key];
    if (cached != null && cached.isNotEmpty && await File(cached).exists()) {
      return cached;
    }
    final path = await _withDownloadSlot(() async {
      // Outro pedido pode ter preenchido o cache enquanto este aguardava.
      final latest = _diskPaths?[key];
      if (latest != null && latest.isNotEmpty && await File(latest).exists()) {
        return latest;
      }
      return _repo.ensureThumbnail(file);
    });
    if (path != null && path.isNotEmpty && await File(path).exists()) {
      await _rememberPath(key, path);
      return path;
    }
    if (file.isVideo) {
      final localPath = file.localPath;
      if (localPath != null &&
          localPath.isNotEmpty &&
          await File(localPath).exists()) {
        try {
          final generated = await _td.generateVideoThumbnail(localPath);
          if (generated != null &&
              generated.isNotEmpty &&
              await File(generated).exists()) {
            await _rememberPath(key, generated);
            return generated;
          }
        } catch (_) {}
      }
    }
    return null;
  }

  Future<T> _withDownloadSlot<T>(Future<T> Function() operation) async {
    if (_activeDownloads >= _maximumConcurrentDownloads) {
      final waiter = Completer<void>();
      _downloadQueue.add(waiter);
      await waiter.future;
    } else {
      _activeDownloads++;
    }
    try {
      return await operation();
    } finally {
      if (_downloadQueue.isNotEmpty) {
        // Transfere este slot diretamente ao primeiro pedido da fila.
        _downloadQueue.removeFirst().complete();
      } else {
        _activeDownloads--;
      }
    }
  }

  Future<void> prewarm(
    Iterable<TCloudFile> files, {
    int maximum = 30,
    int concurrency = 4,
  }) async {
    final target = files.where((file) => file.isMedia).take(maximum).toList();

    for (var start = 0; start < target.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, target.length);

      final batch = target.sublist(start, end);

      await Future.wait(
        batch.map((file) async {
          instantPreview(file);

          try {
            await fullPreviewPath(file);
          } catch (_) {}
        }),
      );
    }
  }

  Future<void> _loadDiskPaths() async {
    if (_diskPaths != null) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_diskKey);

    if (raw == null || raw.isEmpty) {
      _diskPaths = <String, String>{};
      return;
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is Map) {
        _diskPaths = decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      } else {
        _diskPaths = <String, String>{};
      }
    } catch (_) {
      _diskPaths = <String, String>{};
    }
  }

  Future<void> _rememberPath(String key, String path) async {
    await _loadDiskPaths();

    final map = _diskPaths!;

    map.remove(key);
    map[key] = path;

    if (map.length > 700) {
      final keys = map.keys.toList();

      for (var index = 0; index < map.length - 700; index++) {
        map.remove(keys[index]);
      }
    }

    _diskDirty = true;
    _persistTimer?.cancel();

    _persistTimer = Timer(const Duration(milliseconds: 650), () {
      unawaited(_flushDiskPaths());
    });
  }

  Future<void> _flushDiskPaths() async {
    if (!_diskDirty || _diskPaths == null) return;

    _persistTimer?.cancel();
    _persistTimer = null;

    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_diskKey, jsonEncode(_diskPaths));

    _diskDirty = false;
  }

  Future<int> cachedPreviewCount() async {
    await _loadDiskPaths();
    return _diskPaths?.length ?? 0;
  }

  Future<int> cachedPreviewBytes() async {
    await _loadDiskPaths();

    var total = 0;

    for (final path in _diskPaths?.values ?? const <String>[]) {
      try {
        final file = File(path);

        if (await file.exists()) {
          total += await file.length();
        }
      } catch (_) {}
    }

    return total;
  }

  Future<void> clearPreviewCache() async {
    await _loadDiskPaths();

    _persistTimer?.cancel();
    _persistTimer = null;

    final paths = _diskPaths?.values.toSet() ?? <String>{};

    for (final path in paths) {
      try {
        final file = File(path);

        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }

    _memory.clear();
    _inFlight.clear();
    _diskPaths = <String, String>{};
    _diskDirty = false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_diskKey);
  }

  Future<void> prunePreviewCache({
    int maximumEntries = 700,
    int maximumBytes = 256 * 1024 * 1024,
  }) async {
    await _loadDiskPaths();

    final map = _diskPaths!;
    final valid = <String, String>{};
    var bytes = 0;

    for (final entry in map.entries.toList().reversed) {
      if (valid.length >= maximumEntries || bytes >= maximumBytes) {
        break;
      }

      try {
        final file = File(entry.value);

        if (!await file.exists()) {
          continue;
        }

        final length = await file.length();

        if (bytes + length > maximumBytes && valid.isNotEmpty) {
          continue;
        }

        valid[entry.key] = entry.value;
        bytes += length;
      } catch (_) {}
    }

    _diskPaths = Map<String, String>.fromEntries(
      valid.entries.toList().reversed,
    );

    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_diskKey, jsonEncode(_diskPaths));
    _diskDirty = false;
  }
}

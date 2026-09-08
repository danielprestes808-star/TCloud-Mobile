import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class TCloudUpdateInfo {
  const TCloudUpdateInfo({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.sha256,
    required this.notes,
    required this.mandatory,
  });

  final String version;
  final int versionCode;
  final String apkUrl;
  final String sha256;
  final String notes;
  final bool mandatory;

  factory TCloudUpdateInfo.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    final version = json['version']?.toString().trim() ?? '';
    final apkUrl = json['apkUrl']?.toString().trim() ?? '';
    final sha256 = json['sha256']?.toString().trim().toLowerCase() ?? '';

    if (version.isEmpty ||
        asInt(json['versionCode']) <= 0 ||
        apkUrl.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Manifesto de atualizacao invalido.');
    }

    final uri = Uri.tryParse(apkUrl);

    if (uri == null || uri.scheme != 'https') {
      throw const FormatException('A atualizacao precisa usar HTTPS.');
    }

    return TCloudUpdateInfo(
      version: version,
      versionCode: asInt(json['versionCode']),
      apkUrl: apkUrl,
      sha256: sha256,
      notes: json['notes']?.toString().trim() ?? '',
      mandatory: json['mandatory'] == true,
    );
  }
}

class TCloudAppInfo {
  const TCloudAppInfo({
    required this.version,
    required this.versionCode,
    required this.canInstallPackages,
  });

  final String version;
  final int versionCode;
  final bool canInstallPackages;
}

class TCloudAppUpdateService {
  Future<void> _ensureUpdateNotificationPermission() async {
    try {
      await _channel.invokeMethod<bool>('ensureUpdateNotificationPermission');
    } catch (_) {
      // O download continua mesmo se notificacoes estiverem bloqueadas.
    }
  }

  TCloudAppUpdateService._();

  static final instance = TCloudAppUpdateService._();

  static const MethodChannel _channel = MethodChannel(
    'com.tcloud.mobile/updater',
  );

  static const String manifestUrl =
      'https://raw.githubusercontent.com/'
      'danielprestes808-star/TCloud-Releases/'
      'main/mobile-latest.json';

  Future<TCloudAppInfo> currentAppInfo() async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>('getAppInfo');

    final map = raw ?? const <Object?, Object?>{};

    int asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return TCloudAppInfo(
      version: map['version']?.toString() ?? '0.0.0',
      versionCode: asInt(map['versionCode']),
      canInstallPackages: map['canInstallPackages'] == true,
    );
  }

  Future<TCloudUpdateInfo?> check() async {
    final current = await currentAppInfo();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 10);

    try {
      Object? lastError;

      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          return await _checkOnce(client, current);
        } catch (error) {
          lastError = error;
          if (attempt == 2) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: attempt == 0 ? 450 : 1200),
          );
        }
      }

      throw StateError('Falha ao consultar atualizacoes: $lastError');
    } finally {
      client.close(force: true);
    }
  }

  Future<TCloudUpdateInfo?> _checkOnce(
    HttpClient client,
    TCloudAppInfo current,
  ) async {
    // TCLOUD_UPDATER_CACHE_BUSTER_1039
    final manifestUri = Uri.parse(manifestUrl).replace(
      queryParameters: <String, String>{
        'ts': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );

    final request = await client.getUrl(manifestUri);

    request.headers.set(
      HttpHeaders.cacheControlHeader,
      'no-cache, no-store, max-age=0',
    );
    request.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
    request.headers.set(HttpHeaders.expiresHeader, '0');
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'TCloud-Mobile-Updater/${current.version}',
    );

    final response = await request.close().timeout(const Duration(seconds: 10));

    if (response.statusCode == HttpStatus.notFound) return null;

    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'Servidor de atualizacao retornou ${response.statusCode}.',
      );
    }

    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 8));
    final decoded = jsonDecode(body);

    if (decoded is! Map) {
      throw const FormatException('Manifesto de atualizacao invalido.');
    }

    final info = TCloudUpdateInfo.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );

    return info.versionCode <= current.versionCode ? null : info;
  }

  Future<String> updateDownloadPath() async {
    final path = await _channel.invokeMethod<String>('getUpdateDownloadPath');

    if (path == null || path.isEmpty) {
      throw StateError('Nao foi possivel preparar o arquivo de atualizacao.');
    }

    return path;
  }

  Future<String> download(
    TCloudUpdateInfo info, {
    required void Function(double progress) onProgress,
  }) async {
    await _ensureUpdateNotificationPermission();

    await _channel.invokeMethod<void>(
      'startNativeUpdateDownload',
      <String, dynamic>{
        'url': info.apkUrl,
        'version': info.version,
        'sha256': info.sha256,
      },
    );

    while (true) {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getNativeUpdateDownloadStatus',
      );

      final state = raw ?? const <Object?, Object?>{};

      int asInt(dynamic value) {
        if (value is int) return value;
        if (value is num) return value.toInt();
        return int.tryParse(value?.toString() ?? '') ?? 0;
      }

      final status = state['status']?.toString().trim().toLowerCase() ?? '';

      final received = asInt(state['received']);
      final total = asInt(state['total']);

      if (total > 0) {
        onProgress((received / total).clamp(0.0, 1.0));
      }

      if (status == 'completed') {
        final path = state['path']?.toString().trim() ?? '';

        if (path.isEmpty) {
          throw StateError(
            'A atualizacao terminou, mas o APK nao foi localizado.',
          );
        }

        onProgress(1);
        return path;
      }

      if (status == 'failed') {
        final message = state['error']?.toString().trim() ?? '';

        throw StateError(
          message.isEmpty ? 'Falha ao baixar a atualizacao.' : message,
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  Future<bool> canInstallPackages() async {
    return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
  }

  Future<void> openInstallPermission() async {
    await _channel.invokeMethod<void>('openInstallPermission');
  }

  Future<void> install(String path) async {
    await _channel.invokeMethod<void>('installApk', <String, dynamic>{
      'path': path,
    });
  }
}

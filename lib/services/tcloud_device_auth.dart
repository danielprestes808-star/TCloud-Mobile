import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'account_service.dart';

class TCloudDeviceAuth {
  TCloudDeviceAuth._();

  static final instance = TCloudDeviceAuth._();
  static const coreBaseUrl = String.fromEnvironment(
    'TCLOUD_CORE_URL',
    defaultValue: 'https://tcloud-core.onrender.com',
  );
  static const _tokenKey = 'tcloud_core_device_token_v1';
  static const _deviceIdKey = 'tcloud_core_device_id_v1';

  Future<String> _key(String base) async {
    final account = await AccountService.instance.activeId();
    return account == 'default' ? base : '${base}_$account';
  }

  Future<String?> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(await _key(_deviceIdKey))?.trim();
  }

  Future<String?> token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(await _key(_tokenKey))?.trim();
  }

  Future<bool> get paired async => (await token())?.isNotEmpty == true;

  /// Confirma a sessão no Core sem desconectar o aparelho por uma simples
  /// indisponibilidade de rede. Credenciais rejeitadas são removidas.
  Future<bool> validate() async {
    final value = await token();
    final currentDeviceId = await deviceId();
    if (value?.isNotEmpty != true || currentDeviceId?.isNotEmpty != true) {
      return false;
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(
        Uri.parse('$coreBaseUrl/api/v1/devices'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $value');
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        await disconnect();
        return false;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return true;
      }
      final body = await utf8.decoder.bind(response).join();
      final decoded = body.isEmpty ? const <dynamic>[] : jsonDecode(body);
      if (decoded is! List) return true;
      final found = decoded.whereType<Map>().any(
        (device) => device['id']?.toString() == currentDeviceId,
      );
      if (!found) await disconnect();
      return found;
    } on SocketException {
      return true;
    } on TimeoutException {
      return true;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> authorize(HttpClientRequest request) async {
    final value = await token();
    if (value?.isNotEmpty == true) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $value');
    }
  }

  Future<Map<String, dynamic>?> profile() async {
    final value = await token();
    if (value?.isNotEmpty != true) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('$coreBaseUrl/api/v1/profile'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $value');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, dynamic>>> devices() async {
    final value = await token();
    if (value?.isNotEmpty != true) return const [];
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('$coreBaseUrl/api/v1/devices'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $value');
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Não foi possível carregar os dispositivos.');
      }
      return (jsonDecode(body) as List)
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> revokeDevice(String deviceId) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('$coreBaseUrl/api/v1/devices/revoke'),
      );
      await authorize(request);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'deviceId': deviceId}));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Não foi possível revogar o dispositivo.');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> register({
    required String displayName,
    required String username,
    String? avatarDataUrl,
  }) async {
    final currentToken = await token();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final updating = currentToken?.isNotEmpty == true;
      final request = updating
          ? await client.patchUrl(Uri.parse('$coreBaseUrl/api/v1/profile'))
          : await client.postUrl(
              Uri.parse('$coreBaseUrl/api/v1/onboarding/register'),
            );
      request.headers.contentType = ContentType.json;
      if (updating) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $currentToken',
        );
      }
      request.write(
        jsonEncode(
          updating
              ? {
                  'displayName': displayName,
                  'username': username,
                  // ignore: use_null_aware_elements
                  if (avatarDataUrl != null) 'avatarDataUrl': avatarDataUrl,
                }
              : {
                  'displayName': displayName,
                  'username': username,
                  'deviceName': Platform.localHostname.isEmpty
                      ? 'TCloud Mobile'
                      : Platform.localHostname,
                  'platform': 'android',
                  'appVersion': '1.1.34',
                },
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decoder.bind(response).join();
      final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
      final data = decoded is Map
          ? decoded.cast<String, dynamic>()
          : <String, dynamic>{};
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          (!updating && (data['token'] == null || data['deviceId'] == null))) {
        throw StateError(
          data['message']?.toString() ??
              'Não foi possível criar sua conta TCloud.',
        );
      }
      if (!updating) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(await _key(_tokenKey), data['token'].toString());
        await prefs.setString(
          await _key(_deviceIdKey),
          data['deviceId'].toString(),
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> pair(String rawCode) async {
    final code = rawCode.trim().replaceAll('-', '').toUpperCase();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('$coreBaseUrl/api/v1/device-auth/exchange'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'code': code,
          'deviceName': Platform.localHostname.isEmpty
              ? 'TCloud Mobile'
              : Platform.localHostname,
          'platform': 'android',
          'appVersion': '1.1.34',
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await utf8.decoder.bind(response).join();
      final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
      final data = decoded is Map
          ? decoded.cast<String, dynamic>()
          : <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          data['message']?.toString() ?? 'Código inválido ou expirado.',
        );
      }
      final token = data['token']?.toString().trim() ?? '';
      final deviceId = data['deviceId']?.toString().trim() ?? '';
      if (token.isEmpty || deviceId.isEmpty) {
        throw StateError('Resposta de pareamento inválida.');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(await _key(_tokenKey), token);
      await prefs.setString(await _key(_deviceIdKey), deviceId);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(await _key(_tokenKey));
    await prefs.remove(await _key(_deviceIdKey));
  }
}

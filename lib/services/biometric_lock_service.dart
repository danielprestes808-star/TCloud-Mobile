import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_service.dart';

class BiometricLockService {
  BiometricLockService._();

  static final instance = BiometricLockService._();
  static const _enabledKey = 'tcloud_biometric_lock_enabled_v1';
  static const _timeoutKey = 'tcloud_biometric_lock_timeout_seconds_v1';
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate({String reason = 'Desbloqueie o TCloud'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
        sensitiveTransaction: true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      if (!await AccountService.instance.profileComplete()) {
        throw StateError('Conclua seu cadastro antes de ativar a biometria.');
      }
      if (!await isAvailable()) {
        throw StateError(
          'Configure uma impressão digital ou reconhecimento facial no Android primeiro.',
        );
      }
      if (!await authenticate(
        reason: 'Confirme para ativar o desbloqueio do TCloud',
      )) {
        throw StateError('A biometria não foi confirmada.');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  Future<int> timeoutSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_timeoutKey) ?? 8;
  }

  Future<void> setTimeoutSeconds(int seconds) async {
    if (!const <int>{0, 8, 30, 60, 300}.contains(seconds)) {
      throw ArgumentError.value(seconds, 'seconds');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_timeoutKey, seconds);
  }
}

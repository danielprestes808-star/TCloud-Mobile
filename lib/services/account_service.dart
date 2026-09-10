import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class TCloudAccount {
  const TCloudAccount({required this.id, required this.label, this.displayName, this.username});
  final String id;
  final String label;
  final String? displayName;
  final String? username;

  bool get profileComplete =>
      (displayName?.trim().length ?? 0) >= 2 &&
      RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(username?.trim() ?? '');
}

class AccountService {
  AccountService._();
  static final instance = AccountService._();
  static const _accountsKey = 'tcloud_accounts_v1';
  static const _activeKey = 'tcloud_active_account_v1';

  Future<String> activeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey) ?? 'default';
  }

  Future<List<TCloudAccount>> accounts() async {
    final prefs = await SharedPreferences.getInstance();
    final active = await activeId();
    final decoded = jsonDecode(prefs.getString(_accountsKey) ?? '[]') as List;
    final result = decoded
        .whereType<Map>()
        .map(
          (item) => TCloudAccount(
            id: item['id']?.toString() ?? '',
            label: item['label']?.toString() ?? 'Conta TCloud',
            displayName: item['displayName']?.toString(),
            username: item['username']?.toString(),
          ),
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
    if (!result.any((item) => item.id == active)) {
      result.add(TCloudAccount(id: active, label: 'Conta atual'));
    }
    return result;
  }

  Future<void> rememberPhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    final active = await activeId();
    final list = await accounts();
    final updated = list
        .map(
          (item) => item.id == active
              ? TCloudAccount(
                  id: item.id,
                  label: phone,
                  displayName: item.displayName,
                  username: item.username,
                )
              : item,
        )
        .toList();
    await prefs.setString(
      _accountsKey,
      jsonEncode(
        updated.map(_encode).toList(),
      ),
    );
  }

  Future<String> createAccount() async {
    final id = 'account_${DateTime.now().millisecondsSinceEpoch}';
    final prefs = await SharedPreferences.getInstance();
    final list = await accounts();
    list.add(TCloudAccount(id: id, label: 'Nova conta'));
    await prefs.setString(
      _accountsKey,
      jsonEncode(list.map(_encode).toList()),
    );
    await prefs.setString(_activeKey, id);
    return id;
  }

  Future<void> setActive(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
  }

  Map<String, dynamic> _encode(TCloudAccount item) => {
    'id': item.id,
    'label': item.label,
    if (item.displayName != null) 'displayName': item.displayName,
    if (item.username != null) 'username': item.username,
  };

  Future<TCloudAccount> activeAccount() async {
    final id = await activeId();
    return (await accounts()).firstWhere((item) => item.id == id);
  }

  Future<bool> profileComplete() async => (await activeAccount()).profileComplete;

  Future<TCloudAccount> saveProfile(String rawName, String rawUsername) async {
    final name = rawName.trim().replaceAll(RegExp(r'\s+'), ' ');
    final username = rawUsername.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();
    if (name.length < 2 || name.length > 60) {
      throw StateError('Informe um nome entre 2 e 60 caracteres.');
    }
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(username)) {
      throw StateError('Use de 3 a 32 letras, números ou _ no nome de usuário.');
    }
    final prefs = await SharedPreferences.getInstance();
    final active = await activeId();
    final list = await accounts();
    final updated = list.map((item) => item.id == active
        ? TCloudAccount(id: item.id, label: item.label, displayName: name, username: username)
        : item).toList();
    await prefs.setString(_accountsKey, jsonEncode(updated.map(_encode).toList()));
    return updated.firstWhere((item) => item.id == active);
  }
}

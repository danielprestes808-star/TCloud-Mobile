import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class TCloudAccount {
  const TCloudAccount({required this.id, required this.label});
  final String id;
  final String label;
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
              ? TCloudAccount(id: item.id, label: phone)
              : item,
        )
        .toList();
    await prefs.setString(
      _accountsKey,
      jsonEncode(
        updated.map((item) => {'id': item.id, 'label': item.label}).toList(),
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
      jsonEncode(
        list.map((item) => {'id': item.id, 'label': item.label}).toList(),
      ),
    );
    await prefs.setString(_activeKey, id);
    return id;
  }

  Future<void> setActive(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
  }
}

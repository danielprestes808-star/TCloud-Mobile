import 'telegram_credentials.g.dart';

class TelegramConfig {
  const TelegramConfig._();

  static const int apiId = TCloudTelegramCredentials.apiId;
  static const String apiHash = TCloudTelegramCredentials.apiHash;

  static bool get isConfigured => apiId > 0 && apiHash.trim().isNotEmpty;
}

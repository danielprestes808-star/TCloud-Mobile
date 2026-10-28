/// Modelo de credenciais da API do Telegram para o TCloud Mobile.
///
/// Para compilar o projeto localmente:
/// 1. Obtenha suas credenciais em https://my.telegram.org (API development tools).
/// 2. Crie uma cópia deste arquivo chamada `telegram_credentials.g.dart` no mesmo diretório.
/// 3. Preencha com seu apiId e apiHash reais.
///
/// Alternativamente, utilize parâmetros de compilação:
/// flutter build apk --dart-define=TELEGRAM_API_ID=xxx --dart-define=TELEGRAM_API_HASH=yyy
class TCloudTelegramCredentials {
  const TCloudTelegramCredentials._();

  static const int apiId = 0; // Substitua pelo seu Telegram API ID
  static const String apiHash = 'INSIRA_SEU_API_HASH_AQUI';
}

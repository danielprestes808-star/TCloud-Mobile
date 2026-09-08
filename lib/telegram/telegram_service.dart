abstract class TelegramService {
  Future<void> initialize();

  Future<void> submitPhone(String phoneNumber);

  Future<void> submitCode(String code);

  Future<void> submitPassword(String password);

  Future<void> logout();

  Future<void> dispose();
}

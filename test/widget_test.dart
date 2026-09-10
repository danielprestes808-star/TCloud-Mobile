import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app.dart';
import 'package:mobile/widgets/biometric_app_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('TCloud inicia a interface', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const TCloudApp());
    await tester.pumpAndSettle();

    expect(find.byType(BiometricAppLock), findsOneWidget);
  });
}

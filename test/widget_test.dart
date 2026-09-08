import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app.dart';

void main() {
  testWidgets('TCloud inicia a interface', (WidgetTester tester) async {
    await tester.pumpWidget(const TCloudApp());

    await tester.pump();

    expect(find.text('TCloud'), findsOneWidget);

    expect(find.text('Seus arquivos, sempre com você.'), findsOneWidget);
  });
}

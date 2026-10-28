import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/screens/storage_management_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('StorageManagementScreen renderiza e exibe estatísticas', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const MaterialApp(
        home: StorageManagementScreen(),
      ),
    );

    // Aguarda o carregamento das estatísticas de armazenamento
    await tester.pumpAndSettle();

    expect(find.text('Armazenamento e Cache'), findsOneWidget);
    expect(find.text('Espaço em uso pelo TCloud'), findsOneWidget);
    expect(find.text('Limpar cache de miniaturas'), findsOneWidget);
    expect(find.text('Otimizar armazenamento local'), findsOneWidget);
  });
}

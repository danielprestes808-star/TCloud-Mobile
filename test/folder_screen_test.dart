import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/tcloud_file.dart';
import 'package:mobile/models/tcloud_folder.dart';
import 'package:mobile/screens/folder_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tdlibChannel = MethodChannel('com.tcloud.mobile/tdlib');
  final binding = TestDefaultBinaryMessengerBinding.instance;

  setUp(() async {
    final folder = TCloudFolder(chatId: 10, title: 'Camera');
    final cacheKey = base64Url
        .encode(utf8.encode(folder.title.toLowerCase()))
        .replaceAll('=', '');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tcloud_file_page_v12_numbered_duplicates_$cacheKey': jsonEncode(
        <String, Object?>{
          'files': <Map<String, dynamic>>[
            _file(1, kind: 'imagem').toJson(),
            _file(2, kind: 'video').toJson(),
          ],
          'nextFromMessageId': 0,
          'nextFromMessageIds': <String, int>{},
          'hasMore': false,
        },
      ),
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(tdlibChannel, (
      call,
    ) async {
      if (call.method == 'execute') {
        return <String, Object>{'_type': 'Error', 'message': 'offline'};
      }
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(tdlibChannel, null);
  });

  testWidgets('search stays available in list and gallery views', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FolderScreen(folder: TCloudFolder(chatId: 10, title: 'Camera')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pesquisar nesta pasta'), findsOneWidget);
    await tester.tap(find.byTooltip('Lista'));
    await tester.pumpAndSettle();
    expect(find.text('Pesquisar nesta pasta'), findsOneWidget);
  });

  testWidgets('face grouping is available in video-only folders', (
    tester,
  ) async {
    final folder = TCloudFolder(chatId: 10, title: 'Camera');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tcloud_file_page_v12_numbered_duplicates_'
              '${base64Url.encode(utf8.encode(folder.title.toLowerCase())).replaceAll('=', '')}':
          jsonEncode(<String, Object?>{
            'files': <Map<String, dynamic>>[_file(2, kind: 'video').toJson()],
            'nextFromMessageId': 0,
            'nextFromMessageIds': <String, int>{},
            'hasMore': false,
          }),
    });
    await tester.pumpWidget(MaterialApp(home: FolderScreen(folder: folder)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Mais opções da pasta'));
    await tester.pumpAndSettle();
    expect(find.text('Agrupar por rosto'), findsOneWidget);
  });
}

TCloudFile _file(int messageId, {required String kind}) => TCloudFile(
  messageId: messageId,
  chatId: 10,
  messageThreadId: 0,
  fileId: messageId,
  name: 'media-$messageId',
  size: 100,
  kind: kind,
);

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/tcloud_file.dart';
import 'package:mobile/screens/face_groups_screen.dart';
import 'package:mobile/services/face_grouping_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final service = FaceGroupingService.instance;
  late Directory documentsDirectory;

  setUpAll(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'tcloud-face-group-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return documentsDirectory.path;
          }
          return null;
        });
  });

  setUp(() async {
    final index = File(
      '${documentsDirectory.path}${Platform.pathSeparator}'
      'tcloud_face_groups_v1.json',
    );
    if (await index.exists()) await index.delete();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await documentsDirectory.delete(recursive: true);
  });

  test(
    'combining people keeps a canonical group across future scans',
    () async {
      await _writeIndex(documentsDirectory, <String, Object>{
        'associations': <String, List<String>>{
          '10:0:1': <String>['person_a'],
          '10:0:2': <String>['person_b'],
        },
        'names': <String, String>{'person_a': 'Pessoa 1', 'person_b': 'Ana'},
      });

      await service.mergeGroups('person_a', 'person_b');

      final groups = await service.groupsFor(<TCloudFile>[_file(1), _file(2)]);
      expect(groups, hasLength(1));
      expect(groups.single.id, 'person_b');
      expect(groups.single.name, 'Ana');
      expect(groups.single.files, hasLength(2));

      final storedIndex =
          jsonDecode(
                await File(
                  '${documentsDirectory.path}${Platform.pathSeparator}'
                  'tcloud_face_groups_v1.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(storedIndex['aliases'], <String, String>{'person_a': 'person_b'});
    },
  );

  test('removing selected photos only unlinks them from that person', () async {
    await _writeIndex(documentsDirectory, <String, Object>{
      'associations': <String, List<String>>{
        '10:0:1': <String>['person_a', 'person_b'],
        '10:0:2': <String>['person_a'],
      },
      'names': <String, String>{'person_a': 'Ana', 'person_b': 'Bruno'},
    });

    await service.removeFilesFromGroup('person_a', <String>['10:0:1']);

    final groups = await service.groupsFor(<TCloudFile>[_file(1), _file(2)]);
    final ana = groups.singleWhere((group) => group.id == 'person_a');
    final bruno = groups.singleWhere((group) => group.id == 'person_b');
    expect(ana.files.map((file) => file.messageId), <int>[2]);
    expect(bruno.files.map((file) => file.messageId), <int>[1]);
  });

  test(
    'cancel requested before scanning does not initialize face detection',
    () async {
      final result = await service.analyze(
        <TCloudFile>[_file(1)],
        onProgress: (_, _) {},
        shouldCancel: () => true,
      );

      expect(result.cancelled, isTrue);
      expect(result.scannedCount, 0);
      expect(result.failedFiles, isEmpty);
    },
  );

  testWidgets('remote photos require confirmation with a transfer estimate', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FaceGroupsScreen(
          folderTitle: 'Camera',
          files: <TCloudFile>[_file(1)],
          loadAllFiles: () async => <TCloudFile>[_file(1)],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Analisar rostos'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('100 B estimados'), findsOneWidget);
    expect(find.text('Baixar e analisar'), findsOneWidget);

    await tester.tap(find.text('Agora não'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Analisar rostos deste álbum?'), findsNothing);
  });
}

TCloudFile _file(int messageId) => TCloudFile(
  messageId: messageId,
  chatId: 10,
  messageThreadId: 0,
  fileId: messageId,
  name: 'photo-$messageId.jpg',
  size: 100,
  kind: 'imagem',
);

Future<void> _writeIndex(Directory directory, Map<String, Object> index) =>
    File(
      '${directory.path}${Platform.pathSeparator}tcloud_face_groups_v1.json',
    ).writeAsString(jsonEncode(index));

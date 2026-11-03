import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/tcloud_folder.dart';
import 'package:mobile/services/tcloud_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tdlibChannel = MethodChannel('com.tcloud.mobile/tdlib');
  final binding = TestDefaultBinaryMessengerBinding.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(tdlibChannel, null);
  });

  test(
    'loadAllFiles returns videos from every Telegram history page',
    () async {
      final requestedCursors = <int>[];
      final messages = List<Map<String, Object?>>.generate(101, (index) {
        final messageId = 201 - index;
        return <String, Object?>{
          'id': messageId,
          'date': 1_700_000_000 - index,
          'content': <String, Object?>{
            '_type': 'MessageVideo',
            'video': <String, Object?>{
              'fileName': 'video-$messageId.mp4',
              'mimeType': 'video/mp4',
              'duration': 20,
              'video': <String, Object?>{
                'id': messageId + 1000,
                'size': 1024,
                'remote': <String, Object?>{'isUploadingCompleted': true},
              },
            },
          },
        };
      });

      binding.defaultBinaryMessenger.setMockMethodCallHandler(tdlibChannel, (
        call,
      ) async {
        if (call.method != 'execute') return null;
        final arguments = Map<String, Object?>.from(call.arguments as Map);
        if (arguments['function'] != 'GetChatHistory') {
          return <String, Object?>{'_type': 'Error', 'message': 'unexpected'};
        }

        final fields = Map<String, Object?>.from(arguments['fields'] as Map);
        final cursor = fields['fromMessageId'] as int;
        requestedCursors.add(cursor);
        final page = messages
            .where((message) => cursor == 0 || (message['id'] as int) < cursor)
            .take(fields['limit'] as int)
            .toList();
        return <String, Object?>{'_type': 'Messages', 'messages': page};
      });

      final files = await TCloudRepository.instance.loadAllFiles(
        const TCloudFolder(chatId: 987654, title: 'Telegram'),
      );

      expect(files, hasLength(101));
      expect(files.every((file) => file.isVideo), isTrue);
      expect(requestedCursors, <int>[0, 102]);
    },
  );
}

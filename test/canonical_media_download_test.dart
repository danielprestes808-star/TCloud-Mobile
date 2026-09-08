import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/tcloud_canonical_ops.dart';

void main() {
  test(
    'download canônico reúne todas as faixas e retoma arquivo parcial',
    () async {
      final payload = Uint8List.fromList(
        List<int>.generate(37, (index) => index),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = server.listen((request) async {
        final rawRange =
            request.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-';
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(rawRange)!.group(1)!,
        );
        final end = (start + 6).clamp(0, payload.length - 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
      });

      final temp = await Directory.systemTemp.createTemp('tcloud_core_test_');
      final target = '${temp.path}${Platform.pathSeparator}media.bin';
      await File('$target.part').writeAsBytes(payload.sublist(0, 5));
      final ops = TCloudCanonicalOps(
        coreBaseUrl: 'http://${server.address.host}:${server.port}',
        authorizeRequests: false,
      );

      try {
        final path = await ops.downloadMedia(
          'core-file-1',
          target,
          expectedSize: payload.length,
        );
        expect(await File(path).readAsBytes(), payload);
        expect(await File('$target.part').exists(), isFalse);
      } finally {
        ops.close();
        await server.close(force: true);
        await serving.cancel();
        await temp.delete(recursive: true);
      }
    },
  );
}

import 'tcloud_file.dart';

class TCloudFilePage {
  const TCloudFilePage({
    required this.files,
    required this.nextFromMessageId,
    required this.hasMore,
    this.nextFromMessageIds = const <String, int>{},
    this.fromCache = false,
  });

  final List<TCloudFile> files;
  final int nextFromMessageId;
  final bool hasMore;
  final Map<String, int> nextFromMessageIds;
  final bool fromCache;
}

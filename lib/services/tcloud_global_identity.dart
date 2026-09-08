class TCloudCanonicalFileIdentity {
  const TCloudCanonicalFileIdentity({
    required this.coreFileId,
    this.telegramPeerId,
    this.telegramTopicId,
    this.telegramMessageId,
  });

  final String coreFileId;
  final int? telegramPeerId;
  final int? telegramTopicId;
  final int? telegramMessageId;

  static String requireCoreFileId(String? value) {
    final normalized = value?.trim() ?? "";
    if (normalized.isEmpty) {
      throw StateError("coreFileId canônico é obrigatório.");
    }
    return normalized;
  }
}

class TCloudCanonicalFolderIdentity {
  const TCloudCanonicalFolderIdentity({
    required this.coreFolderId,
    this.telegramPeerId,
    this.telegramTopicId,
  });

  final String coreFolderId;
  final int? telegramPeerId;
  final int? telegramTopicId;
}
